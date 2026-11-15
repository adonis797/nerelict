import '../models/sniffed_media.dart';
import 'ad_filter.dart';

/// 聚合结果：是否要刷新界面 + 命中的资源项。
///
/// [item] 为 null 表示这是一条被丢弃的上报（地址非法、超出上限等），
/// 点击归因因此只挂在真正沉淀下来的资源上。
class SniffAcceptResult {
  const SniffAcceptResult(this.changed, this.item);

  const SniffAcceptResult.ignored()
      : changed = false,
        item = null;

  final bool changed;
  final SniffedMedia? item;
}

/// 把嗅探到的地址收敛成「统一资源项」。
///
/// - 规范化去重：同一个 m3u8 带不同签名 / query 只算一条；
/// - 变体聚合：同目录下 master / 码率变体归为一个视频；
/// - 分片聚合：.ts / .m4s 等分片挂到所属视频上，不在列表里单独成项；
/// - 先到分片、后到播放列表时，会把分片组合并回播放列表资源，避免重复项残留；
/// - 点击归因：被动嗅探先建好的项，之后被点击捕获命中时原地补上浮层评分，
///   不新建第二条。
class ResourceAggregator {
  final List<SniffedMedia> _items = <SniffedMedia>[];

  List<SniffedMedia> get items => List.unmodifiable(_items);

  void clear() => _items.clear();

  /// 返回是否需要刷新界面（分片计数做节流，避免频繁 rebuild）
  ///
  /// [attribution] 非空表示这条上报来自一次点击捕获：除了照常去重聚合，
  /// 还会把「浮层置信分 / 点击描述」记到对应资源项上。
  SniffAcceptResult accept({
    required String url,
    required String kind,
    required String page,
    required String source,
    required String title,
    String? parent,
    Map<String, String>? headers,
    ClickAttribution? attribution,
  }) {
    if (!url.startsWith('http')) return const SniffAcceptResult.ignored();
    final result = kind == 'segment'
        ? _acceptSegment(url, page, source, title, parent)
        : _acceptPlaylist(url, page, source, title);

    final item = result.item;
    if (item == null) return result;
    var changed = result.changed;
    // 后到的鉴权头补进已存在的资源项：首屏播放器常常先被 performance
    // 扫描发现（只有地址），之后才被 fetch/XHR 命中（带 Authorization）
    if (item.mergeHeaders(headers)) changed = true;
    // 广告标记与归因互不影响：广告照样记进列表（可手动查看），
    // 只是不参与自动接管、默认折叠在「疑似广告」里
    final verdict = AdFilter.inspect(url);
    if (verdict.isAd && item.markSuspectAd(verdict.reason)) changed = true;
    if (attribution != null && item.noteAttribution(attribution)) {
      changed = true;
    }
    return SniffAcceptResult(changed, item);
  }

  SniffAcceptResult _acceptPlaylist(
    String url,
    String page,
    String source,
    String title,
  ) {
    final key = canonicalMediaKey(url);
    for (final item in _items) {
      if (item.canonicalKey == key) {
        item.addVariant(url);
        return SniffAcceptResult(true, item);
      }
    }

    final group = mediaGroupKey(url);
    SniffedMedia? sibling;
    SniffedMedia? orphanGroup;
    for (final item in _items) {
      if (item.groupKey != group) continue;
      if (item.kind == MediaKind.playlist && _sameVideo(item.url, url)) {
        sibling ??= item;
      } else if (item.kind == MediaKind.segmentGroup) {
        orphanGroup ??= item;
      }
    }

    if (sibling != null) {
      sibling.addVariant(url);
      return SniffAcceptResult(true, sibling);
    }

    final resource = SniffedMedia(
      url: url,
      pageUrl: page,
      source: source,
      pageTitle: title,
      kind: MediaKind.playlist,
      canonicalKey: key,
      groupKey: group,
      segments: orphanGroup?.segmentUrls,
    );
    if (orphanGroup != null) _items.remove(orphanGroup);
    _items.insert(0, resource);
    _trim();
    return SniffAcceptResult(true, resource);
  }

  SniffAcceptResult _acceptSegment(
    String url,
    String page,
    String source,
    String title,
    String? parent,
  ) {
    final group = mediaGroupKey(url);
    SniffedMedia? target;

    if (parent != null && parent.isNotEmpty) {
      final parentKey = canonicalMediaKey(parent);
      for (final item in _items) {
        if (item.kind == MediaKind.playlist &&
            item.canonicalKey == parentKey) {
          target = item;
          break;
        }
      }
    }
    for (final item in _items) {
      if (target != null) break;
      if (item.groupKey == group && item.kind == MediaKind.playlist) {
        target = item;
      }
    }
    for (final item in _items) {
      if (target != null) break;
      if (item.groupKey == group && item.kind == MediaKind.segmentGroup) {
        target = item;
      }
    }

    if (target == null) {
      target = SniffedMedia(
        url: url,
        pageUrl: page,
        source: source,
        pageTitle: title,
        kind: MediaKind.segmentGroup,
        canonicalKey: 'segments:$group',
        groupKey: group,
      );
      _items.insert(0, target);
      _trim();
    }

    final changed = target.addSegment(url);
    if (!changed) return SniffAcceptResult(false, target);
    // 新建分片组、或每累计 8 个分片刷新一次界面
    final refresh = target.segmentCount == 1 || target.segmentCount % 8 == 0;
    return SniffAcceptResult(refresh, target);
  }

  void _trim() {
    if (_items.length > 60) _items.removeRange(60, _items.length);
  }
}

/// 列表展示顺序：真实条目在前，疑似广告沉底；组内保持原有先后。
///
/// 站点常把广告位排在页面 / 列表顶部，嗅探结果如果照搬发现顺序，
/// 用户第一眼看到的就是广告。这里只调整展示顺序，不丢数据。
List<SniffedMedia> orderForDisplay(Iterable<SniffedMedia> items) =>
    <SniffedMedia>[
      ...items.where((m) => !m.suspectAd),
      ...items.where((m) => m.suspectAd),
    ];

/// 判断同目录下两个播放列表是否像同一个视频的码率变体。
/// 普通的文件名（如 a.m3u8 / b.m3u8）不会被误合并。
bool _sameVideo(String a, String b) {
  final sa = _stem(a);
  final sb = _stem(b);
  if (sa.isEmpty || sb.isEmpty) return false;
  if (sa == sb) return true;
  return _isVariantName(sa) && _isVariantName(sb);
}

String _stem(String raw) {
  final uri = Uri.tryParse(raw);
  if (uri == null) return '';
  final name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
  return name
      .toLowerCase()
      .replaceAll(RegExp(r'\.(m3u8|ts|m4s|mp4|m4v|webm)$'), '');
}

final RegExp _variantWord = RegExp(
  r'^(master|index|playlist|main|hls|chunklist|stream|video|audio|sub|'
  r'\d+|\d+[km]|\d+p|\d+k|\d+m|\d+x\d+|\d+kbps|\d+mbps)$',
  caseSensitive: false,
);

bool _isVariantName(String stem) =>
    _variantWord.hasMatch(stem) ||
    RegExp(r'^\d+').hasMatch(stem) ||
    stem.contains('master') ||
    stem.contains('chunklist');
