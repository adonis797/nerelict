import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'hls_parser.dart';

/// 播放器能交给系统解码器直接播放的封装格式。
/// 覆盖范围按 ExoPlayer 常见能力扩展：常见容器、音视频单轨、老式封装都算在内，
/// 具体能否解码仍由设备的硬件/软件解码器决定。
const List<String> _progressiveExtensions = <String>[
  // 视频容器
  '.mp4', '.m4v', '.mov', '.webm', '.mkv', '.ts', '.flv', '.avi',
  '.3gp', '.3g2', '.m2ts', '.mts', '.m2v', '.mpg', '.mpeg', '.vob',
  '.ogv', '.wmv', '.asf', '.rm', '.rmvb', '.f4v', '.m4s',
  // 音频
  '.m4a', '.mp3', '.aac', '.flac', '.wav', '.ogg', '.oga', '.opus',
  '.amr', '.ape', '.mka', '.wma',
];

/// 播放器支持的媒体封装类型。
enum MediaKind { hls, dash, progressive, unknown }

extension MediaKindX on MediaKind {
  String get label => switch (this) {
        MediaKind.hls => 'HLS',
        MediaKind.dash => 'DASH',
        MediaKind.progressive => 'MP4',
        MediaKind.unknown => '视频',
      };
}

/// media_source 层：URL 归一化、Referer/UA 注入、类型与能力探测。
///
/// 这一层只描述「要播什么、带什么请求头」，不持有任何播放器对象，
/// 因此嗅探 / 下载 / 播放三条链路可以共用同一份归一化结果。
@immutable
class MediaSource {
  const MediaSource({
    required this.raw,
    required this.uri,
    required this.title,
    required this.referer,
    required this.local,
    required this.kind,
    required this.unsupportedReason,
  });

  /// 原始地址。本地文件可能是纯路径而非合法 URI，播放与截图都用它。
  final String raw;

  final Uri uri;
  final String title;
  final String? referer;
  final bool local;
  final MediaKind kind;
  final String? unsupportedReason;

  String get url => uri.toString();
  bool get supported => unsupportedReason == null;

  /// 传给 ExoPlayer 的请求头。带签名参数的站点常校验 Referer / UA。
  Map<String, String> get headers => <String, String>{
        'User-Agent': kDefaultUserAgent,
        if (referer != null && referer!.startsWith('http'))
          'Referer': referer!,
      };

  /// 播放进度记忆的 key：去掉易变的签名参数，保留路径与主机名。
  String get memoryKey {
    if (local) return 'file:$raw';
    final path = uri.path.isEmpty ? '/' : uri.path;
    return '${uri.host}$path';
  }

  String get displayTitle {
    final t = title.trim();
    if (t.isNotEmpty && !t.startsWith('http')) return t;
    if (local) {
      final parts = raw.split(RegExp(r'[/\\]'));
      final name = parts.isEmpty ? '' : parts.last;
      return name.isEmpty ? '本地视频' : name;
    }
    return uri.host.isEmpty ? 'Nerelict' : uri.host;
  }

  String get badge => local ? '本地' : kind.label;

  static const String kDefaultUserAgent =
      'Mozilla/5.0 (Linux; Android 15; M8Browser) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';

  static MediaSource parse({
    required String url,
    String title = '',
    String? referer,
    bool local = false,
  }) {
    final raw = url.trim();
    final uri = Uri.tryParse(raw);
    if (uri == null) {
      return MediaSource(
        raw: raw,
        uri: Uri(),
        title: title,
        referer: referer,
        local: local,
        kind: MediaKind.unknown,
        unsupportedReason: '地址格式不正确',
      );
    }

    final scheme = uri.scheme.toLowerCase();
    String? reason;
    if (scheme == 'blob' || scheme == 'data') {
      reason = 'blob:/data: 页面内地址无法交给系统播放器';
    } else if (!local && scheme != 'http' && scheme != 'https') {
      reason = '仅支持 http/https 或本地文件';
    }

    final path = uri.path.toLowerCase();
    MediaKind kind = MediaKind.unknown;
    if (path.endsWith('.m3u8') || path.contains('.m3u8?') || path.endsWith('.m3u')) {
      kind = MediaKind.hls;
    } else if (path.endsWith('.mpd') || path.contains('.mpd?')) {
      kind = MediaKind.dash;
    } else if (_progressiveExtensions.any(path.endsWith)) {
      kind = MediaKind.progressive;
    } else if (local) {
      kind = MediaKind.progressive;
    } else if (referer != null && referer.contains('.m3u8')) {
      kind = MediaKind.hls;
    }

    return MediaSource(
      raw: raw,
      uri: uri,
      title: title,
      referer: (referer == null || referer.trim().isEmpty) ? null : referer.trim(),
      local: local,
      kind: kind,
      unsupportedReason: reason,
    );
  }
}

/// playlist / DRM 探测结果（只做轻量 GET，不改变播放链路）。
class MediaProbe {
  const MediaProbe({
    required this.isMaster,
    required this.hasDrm,
    this.variants = const <HlsVariant>[],
    this.detail = '',
  });

  final bool isMaster;
  final bool hasDrm;
  final List<HlsVariant> variants;
  final String detail;

  bool get hasVariants => variants.length > 1;
}

/// 读取 m3u8 文本，识别 master 变体与 DRM 标记。
/// 失败时返回空探测结果，播放器继续按原地址交给系统解码器。
/// 结果短暂缓存，重复打开同一视频不再重复请求。
Future<MediaProbe> probePlaylist(MediaSource source, {bool refresh = false}) async {
  if (source.local || source.kind != MediaKind.hls || !source.supported) {
    return const MediaProbe(isMaster: false, hasDrm: false);
  }
  if (!refresh) {
    final cached = cachedProbe(source);
    if (cached != null) return cached;
  }
  HttpClient? client;
  try {
    client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final request = await client.getUrl(source.uri);
    source.headers.forEach((k, v) => request.headers.set(k, v));
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      return _remember(
        source,
        MediaProbe(
          isMaster: false,
          hasDrm: false,
          detail: 'HTTP ${response.statusCode}',
        ),
      );
    }
    final text = await response.transform(utf8.decoder).join();
    final upper = text.toUpperCase();
    final hasDrm = upper.contains('SAMPLE-AES') ||
        upper.contains('#EXT-X-KEY:METHOD=AES-CTR') ||
        upper.contains('#EXT-X-SESSION-KEY') ||
        text.contains('urn:uuid:') ||
        text.contains('com.widevine');
    final master = isMasterPlaylist(text);
    return _remember(
      source,
      MediaProbe(
        isMaster: master,
        hasDrm: hasDrm,
        variants: master ? parseMasterPlaylist(text, source.uri) : const [],
        detail: master ? 'master playlist' : 'media playlist',
      ),
    );
  } catch (e) {
    return MediaProbe(
      isMaster: false,
      hasDrm: false,
      detail: e.toString().length > 60
          ? e.toString().substring(0, 60)
          : e.toString(),
    );
  } finally {
    client?.close(force: true);
  }
}

/// 同一个视频反复打开时不必重新拉一遍 m3u8：结果短暂缓存（3 分钟），
/// 既减少一次网络往返，也避免直播地址频繁解析。
final Map<String, _ProbeCacheEntry> _probeCache = <String, _ProbeCacheEntry>{};

class _ProbeCacheEntry {
  const _ProbeCacheEntry(this.probe, this.at);

  final MediaProbe probe;
  final DateTime at;
}

MediaProbe _remember(MediaSource source, MediaProbe probe) {
  if (_probeCache.length > 24) _probeCache.clear();
  _probeCache[source.memoryKey] = _ProbeCacheEntry(probe, DateTime.now());
  return probe;
}

/// 读取缓存（供播放器在探测与起播并行时复用）
MediaProbe? cachedProbe(MediaSource source) {
  final entry = _probeCache[source.memoryKey];
  if (entry == null) return null;
  if (DateTime.now().difference(entry.at) > const Duration(minutes: 3)) {
    return null;
  }
  return entry.probe;
}
