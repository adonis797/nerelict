import '../models/sniffed_media.dart';

/// 把嗅探到的地址收敛成「统一资源项」。
///
/// - 规范化去重：同一个 m3u8 带不同签名 / query 只算一条；
/// - 变体聚合：同目录下 master / 码率变体归为一个视频；
/// - 分片聚合：.ts / .m4s 等分片挂到所属视频上，不在列表里单独成项；
/// - 先到分片、后到播放列表时，会把分片组合并回播放列表资源，避免重复项残留。
class ResourceAggregator {
  final List<SniffedMedia> _items = <SniffedMedia>[];

  List<SniffedMedia> get items => List.unmodifiable(_items);

  void clear() => _items.clear();

  /// 返回是否需要刷新界面（分片计数做节流，避免频繁 rebuild）
  bool accept({
    required String url,
    required String kind,
    required String page,
    required String source,
    required String title,
    String? parent,
  }) {
    if (!url.startsWith('http')) return false;
    if (kind == 'segment') {
      return _acceptSegment(url, page, source, title, parent);
    }
    return _acceptPlaylist(url, page, source, title);
  }

  bool _acceptPlaylist(String url, String page, String source, String title) {
    final key = canonicalMediaKey(url);
    for (final item in _items) {
      if (item.canonicalKey == key) {
        item.addVariant(url);
        return true;
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
      return true;
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
    return true;
  }

  bool _acceptSegment(
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
    if (!changed) return false;
    // 新建分片组、或每累计 8 个分片刷新一次界面
    return target.segmentCount == 1 || target.segmentCount % 8 == 0;
  }

  void _trim() {
    if (_items.length > 60) _items.removeRange(60, _items.length);
  }
}

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
