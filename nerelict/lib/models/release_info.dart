/// 更新源的纯数据层：GitHub Release 的最小投影 + 三段版本比较。
///
/// 这里刻意不 import 任何 IO / Flutter 依赖，`tool/verify_update.dart`
/// 可以 `dart run` 直接跑断言；网络请求与缓存分别放在 `release_feed.dart`。
library;

/// 体积的人类可读格式：1023 B 以下按字节，其余一位小数的 KB / MB。
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  return '${(kb / 1024).toStringAsFixed(1)} MB';
}

/// Release 里的一个附件。只关心安装包本身，其余（校验文件等）忽略。
class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.url,
    required this.size,
  });

  final String name;

  /// `browser_download_url`：可直接 GET 的地址，不需要 token。
  final String url;

  /// 字节数。GitHub 偶尔给 0，此时跳过体积校验但不阻断下载。
  final int size;

  bool get isApk => name.toLowerCase().endsWith('.apk');

  String get sizeLabel => formatBytes(size);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'url': url,
        'size': size,
      };

  static ReleaseAsset? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    final url = raw['url'];
    if (name is! String || url is! String) return null;
    if (name.isEmpty || url.isEmpty) return null;
    final size = raw['size'];
    return ReleaseAsset(
      name: name,
      url: url,
      size: size is int ? size : 0,
    );
  }
}

/// 一个已发布的版本。`version` 是归一后的 `x.y[.z]`，比较时一律按段补零。
class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.version,
    required this.notes,
    required this.htmlUrl,
    this.asset,
    this.prerelease = false,
  });

  /// 原始 tag，如 `v0.5.0`，用于展示与拼下载文件名。
  final String tag;

  /// 归一后的版本，如 `0.5.0`。
  final String version;

  /// Release 正文，可能为空。
  final String notes;

  final String htmlUrl;

  /// 找不到 `.apk` 时为 null：版本照样能比较，只是不能应用内安装。
  final ReleaseAsset? asset;

  final bool prerelease;

  bool get hasAsset => asset != null;

  /// 说明里常带 Markdown 标题与链接，纯文本预览先把标记削掉。
  String get plainNotes {
    var text = notes;
    text = text.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
    text = text.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ');
    // 链接只留文字：`replaceAll` 不支持 `$1` 这类反向引用，必须走 mapped
    text = text.replaceAllMapped(
      RegExp(r'\[([^\]]*)\]\([^)]*\)'),
      (m) => m.group(1) ?? '',
    );
    text = text.replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '');
    text = text.replaceAllMapped(
      RegExp(r'(\*\*|__)(.*?)\1'),
      (m) => m.group(2) ?? '',
    );
    // 行内代码只保留内容：Release 正文里 `AppState` 这类标记直接显示会很脏
    text = text.replaceAllMapped(
      RegExp(r'`([^`\n]*)`'),
      (m) => m.group(1) ?? '',
    );
    text = text.replaceAll('`', '');
    text = text.replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '· ');
    text = text.replaceAll(RegExp(r'[ \t]+\n'), '\n');
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return text.trim();
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'tag': tag,
        'version': version,
        'notes': notes,
        'htmlUrl': htmlUrl,
        'asset': asset?.toJson(),
        'prerelease': prerelease,
      };

  static ReleaseInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final tag = raw['tag'];
    final version = raw['version'];
    if (tag is! String || version is! String) return null;
    if (tag.isEmpty || version.isEmpty) return null;
    return ReleaseInfo(
      tag: tag,
      version: version,
      notes: raw['notes'] is String ? raw['notes'] as String : '',
      htmlUrl: raw['htmlUrl'] is String ? raw['htmlUrl'] as String : '',
      asset: ReleaseAsset.fromJson(raw['asset']),
      prerelease: raw['prerelease'] == true,
    );
  }
}

/// 解析版本号里的数字段。
///
/// tag 上常带前缀与后缀（`v0.5.0`、`release-0.5.0`、`0.5.0-beta1`），
/// 这里只取第一段连续的 `数字(.数字)*`，后续的 `-beta` 之类不参与比较。
List<int>? parseVersion(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return null;
  final match = RegExp(r'\d+(?:\.\d+)*').firstMatch(value);
  if (match == null) return null;
  final parts = match.group(0)!.split('.').map(int.tryParse).toList();
  if (parts.any((p) => p == null)) return null;
  return parts.cast<int>();
}

/// `v0.4.14` / `0.4.14` / `release-0.4.14` 都归一成 `0.4.14`；无法识别返回 null。
String? versionFromTag(String? tag) {
  final parts = parseVersion(tag);
  if (parts == null || parts.isEmpty) return null;
  return parts.join('.');
}

/// 三段语义比较：**不能按字符串比**，否则 `0.4.9` 会排到 `0.4.10` 后面。
///
/// 返回 -1 / 0 / 1；段数不同按缺失位 0 处理，`0.5` 与 `0.5.0` 视为相同。
int compareVersionStrings(String a, String b) {
  final left = parseVersion(a) ?? const <int>[];
  final right = parseVersion(b) ?? const <int>[];
  final len = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < len; i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) return l < r ? -1 : 1;
  }
  return 0;
}

/// `latest` 是否比 `current` 新。任一侧无法解析时返回 false（宁可不提醒）。
bool isNewerVersion(String latest, String current) {
  if (parseVersion(latest) == null) return false;
  if (parseVersion(current) == null) return false;
  return compareVersionStrings(latest, current) > 0;
}

/// 从 assets 里挑安装包：优先 arm64（本项目只发 arm64），否则第一个 `.apk`。
///
/// 不用「取 assets.first」——Release 可能同时挂校验文件或源码包，
/// 取错会把 zip 当 APK 下载下来，安装时才失败。
ReleaseAsset? pickApkAsset(List<dynamic> assets) {
  final apks = <ReleaseAsset>[];
  for (final raw in assets) {
    if (raw is! Map) continue;
    final asset = ReleaseAsset.fromJson(<String, dynamic>{
      'name': raw['name'],
      'url': raw['browser_download_url'],
      'size': raw['size'],
    });
    if (asset != null && asset.isApk) apks.add(asset);
  }
  if (apks.isEmpty) return null;
  for (final apk in apks) {
    if (apk.name.toLowerCase().contains('arm64')) return apk;
  }
  return apks.first;
}

/// GitHub `releases/latest` 的 JSON → [ReleaseInfo]。
///
/// 只要求 `tag_name` 能解析出版本；缺 `assets` / 缺 apk 都返回带空 asset 的对象，
/// 由界面决定「去网页看看」，不把整个检查判成失败。
ReleaseInfo? parseReleaseJson(Map<String, dynamic> json) {
  final tag = json['tag_name'];
  if (tag is! String) return null;
  final version = versionFromTag(tag);
  if (version == null) return null;
  final assets = json['assets'];
  return ReleaseInfo(
    tag: tag,
    version: version,
    notes: json['body'] is String ? (json['body'] as String) : '',
    htmlUrl: json['html_url'] is String ? json['html_url'] as String : '',
    asset: assets is List ? pickApkAsset(assets) : null,
    prerelease: json['prerelease'] == true,
  );
}

/// 距上次检查是否仍在节流窗口内。
///
/// 匿名调用 GitHub API 每小时 60 次，设置页被反复打开很容易撞上；
/// `lastMs` 为 0 或大于当前时间（改过系统时间）都视为「应当重新检查」。
bool withinThrottle({
  required int lastMs,
  required int nowMs,
  required Duration window,
}) {
  if (lastMs <= 0) return false;
  if (lastMs > nowMs) return false;
  return nowMs - lastMs < window.inMilliseconds;
}
