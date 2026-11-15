import '../services/header_policy.dart';

/// 聚合后的一类媒体资源。
enum MediaKind {
  /// HLS 播放列表（master / media playlist），可直接交给 Nerelict 播放
  playlist,

  /// 一组同视频的分片（没有配套播放列表时），只能作为整体下载
  segmentGroup,
}

/// 浮层判定阈值：页面脚本 `OVERLAY_MIN` 与这里的值必须一致。
///
/// 50 分对应「固定定位 + 铺满屏幕 + 类名像弹窗」或「点击后新插入的视频容器」，
/// 普通内联播放器一般停在 30~45，不会被误标成浮层。
const int kOverlayThreshold = 50;

/// 一次点击捕获带来的归因信息。
///
/// 只描述「这次命中和哪次点击有关、当时浮层置信多少」，
/// 不参与聚合去重，聚合仍然按地址与目录分组。
class ClickAttribution {
  const ClickAttribution({
    required this.sessionId,
    required this.overlayScore,
    this.label = '',
  });

  final int sessionId;
  final int overlayScore;

  /// 点击目标描述，例如 `div.thumb 「第 3 集」`
  final String label;
}

/// 一条聚合后的媒体资源项。
///
/// 同一视频的多个地址（master / 码率变体 / 带不同签名的重复地址）
/// 与多个分片都会被收敛到同一个对象里，资源列表只展示这一项。
class SniffedMedia {
  SniffedMedia({
    required this.url,
    required this.pageUrl,
    required this.source,
    this.pageTitle = '',
    this.kind = MediaKind.playlist,
    this.adReason = '',
    String? canonicalKey,
    String? groupKey,
    Iterable<String>? segments,
  })  : suspectAd = adReason.isNotEmpty,
        canonicalKey = canonicalKey ?? canonicalMediaKey(url),
        groupKey = groupKey ?? mediaGroupKey(url),
        _segments = <String>{...?segments},
        foundAt = DateTime.now();

  /// 该资源的主地址：playlist 用于播放与统一下载；segmentGroup 仅作展示
  final String url;

  /// 发现它的页面地址
  final String pageUrl;

  /// 来源：fetch / xhr / perf / dom / page
  final String source;

  final String pageTitle;
  final DateTime foundAt;

  /// 去掉 query/fragment 后的去重键
  final String canonicalKey;

  /// 目录级分组键，用于把同一视频的变体与分片聚到一起
  final String groupKey;

  final MediaKind kind;

  /// 疑似广告（地址形态命中广告域名 / 广告路径段），列表里默认折叠
  bool suspectAd;

  /// 判为广告的依据，空串表示未命中
  String adReason;

  /// 页面发起这个请求时带的鉴权头（Authorization / X-*），播放与下载时回放。
  ///
  /// 只存白名单内的头、只在内存里；Cookie 仍然由 CookieStore 按站点实时取，
  /// 不在这里冗余一份。值为空表示这个地址是匿名可访问的。
  Map<String, String> _requestHeaders = const <String, String>{};

  Map<String, String> get requestHeaders => _requestHeaders;

  /// 合并新到的头：同名覆盖（token 刷新后要取新值）。
  /// 返回是否发生了变化，供聚合器决定要不要刷新界面。
  bool mergeHeaders(Map<String, String>? incoming) {
    if (incoming == null || incoming.isEmpty) return false;
    final next = HeaderPolicy.merge(_requestHeaders, incoming);
    if (next.isEmpty) return false;
    if (_sameHeaders(next, _requestHeaders)) return false;
    _requestHeaders = next;
    return true;
  }

  static bool _sameHeaders(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  final Set<String> _variants = <String>{};
  final Set<String> _segments;

  /// 点击归因：被「点开才加载」的播放器捕获过几次
  int _clickHits = 0;
  int _overlayScore = 0;
  String _clickLabel = '';
  DateTime? _lastClickAt;

  /// 最近一次归因来自哪个点击会话，用于同会话补报去重
  int _lastSession = -1;

  /// 同一地址只保留一条，用规范化键作为去重键
  String get id => canonicalKey;

  int get variantCount => _variants.length;
  int get segmentCount => _segments.length;
  List<String> get segmentUrls => List.unmodifiable(_segments.toList());

  /// 被点击捕获的次数（同一次点击对同一地址只算一次）
  int get clickHits => _clickHits;
  int get overlayScore => _overlayScore;
  DateTime? get lastClickAt => _lastClickAt;
  String get clickLabel => _clickLabel;

  /// 列表里的一条捕获说明，没有点击归因时为空
  String get captureNote {
    if (!clickCaptured) return '';
    final parts = <String>[
      if (overlayPlay) '浮层播放',
      clickHits > 1 ? '捕获 $clickHits 次' : '点击捕获',
      if (_clickLabel.isNotEmpty) _clickLabel,
    ];
    return parts.join(' · ');
  }

  /// 点击捕获过
  bool get clickCaptured => _clickHits > 0;

  /// 属于「点击后浮层弹窗播放」的那一类
  bool get overlayPlay => _overlayScore >= kOverlayThreshold;

  /// 只有 HLS 播放列表能直接交给 Nerelict
  bool get isPlayable => kind == MediaKind.playlist;

  /// 分片组没有播放列表，需要把已收集的分片作为一个整体下载
  bool get needsSegmentDownload => kind == MediaKind.segmentGroup;

  bool addVariant(String u) => _variants.add(u);
  bool addSegment(String u) => _segments.add(u);

  /// 标记为疑似广告，返回是否改变了状态（用于决定是否刷新界面）
  bool markSuspectAd(String reason) {
    if (suspectAd) return false;
    suspectAd = true;
    adReason = reason;
    return true;
  }

  /// 记一次点击归因，返回是否带来了新信息（用于决定是否刷新界面）。
  ///
  /// 同一会话可能补报多次（浮层分数在容器动画结束后才越线），
  /// 所以捕获次数按「会话」去重，不按消息条数累加。
  bool noteAttribution(ClickAttribution attribution) {
    final hadScore = _overlayScore;
    final hadHits = _clickHits;
    if (attribution.sessionId != _lastSession) {
      _clickHits++;
      _lastSession = attribution.sessionId;
    }
    _lastClickAt = DateTime.now();
    if (attribution.label.isNotEmpty) _clickLabel = attribution.label;
    if (attribution.overlayScore > _overlayScore) {
      _overlayScore = attribution.overlayScore;
    }
    return _clickHits != hadHits || _overlayScore != hadScore;
  }

  /// 给用户看的短名：域名 + 文件名 + 聚合信息
  String get label {
    final uri = Uri.tryParse(url);
    var base = url;
    if (uri != null) {
      final name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
      base = '${uri.host}${name.isEmpty ? '' : ' / $name'}';
    }
    final extra = <String>[
      if (variantCount > 0) '${variantCount + 1} 个地址',
      if (segmentCount > 0) '$segmentCount 个分片',
    ];
    if (extra.isEmpty) return base;
    return '$base · ${extra.join(' · ')}';
  }

  /// 资源类型标签
  String get kindLabel =>
      kind == MediaKind.playlist ? 'M3U8' : '分片视频';

  /// 从地址推导一个可用的文件名
  String get suggestedName {
    final uri = Uri.tryParse(url);
    var base = (uri != null && uri.pathSegments.isNotEmpty)
        ? uri.pathSegments.last
        : 'video';
    base = base.split('?').first;
    if (base.toLowerCase().endsWith('.m3u8')) {
      base = base.substring(0, base.length - 5);
    }
    base = base.replaceAll(RegExp(r'\.(ts|m4s|mp4|m4v|webm)$',
        caseSensitive: false), '');
    final cleaned = base.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5\-]+'), '_');
    return cleaned.isEmpty ? 'video' : cleaned;
  }
}

/// 去掉 query / fragment，统一大小写，避免带签名参数的同一地址被当成多个资源。
String canonicalMediaKey(String raw) {
  final uri = Uri.tryParse(raw);
  if (uri == null) return raw;
  final path = uri.path.isEmpty ? '/' : uri.path;
  final port = uri.hasPort ? ':${uri.port}' : '';
  return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}$port$path';
}

/// 目录级分组键：同目录下的变体 / 分片归到同一个视频。
String mediaGroupKey(String raw) {
  final uri = Uri.tryParse(raw);
  if (uri == null) return raw;
  final parts = uri.path.split('/')..removeLast();
  final dir = parts.join('/');
  final port = uri.hasPort ? ':${uri.port}' : '';
  return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}$port$dir';
}
