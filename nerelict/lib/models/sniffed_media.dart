/// 聚合后的一类媒体资源。
enum MediaKind {
  /// HLS 播放列表（master / media playlist），可直接交给 MA8N播放
  playlist,

  /// 一组同视频的分片（没有配套播放列表时），只能作为整体下载
  segmentGroup,
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
    String? canonicalKey,
    String? groupKey,
    Iterable<String>? segments,
  })  : canonicalKey = canonicalKey ?? canonicalMediaKey(url),
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

  final Set<String> _variants = <String>{};
  final Set<String> _segments;

  /// 同一地址只保留一条，用规范化键作为去重键
  String get id => canonicalKey;

  int get variantCount => _variants.length;
  int get segmentCount => _segments.length;
  List<String> get segmentUrls => List.unmodifiable(_segments.toList());

  /// 只有 HLS 播放列表能直接交给 MA8N
  bool get isPlayable => kind == MediaKind.playlist;

  /// 分片组没有播放列表，需要把已收集的分片作为一个整体下载
  bool get needsSegmentDownload => kind == MediaKind.segmentGroup;

  bool addVariant(String u) => _variants.add(u);
  bool addSegment(String u) => _segments.add(u);

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
