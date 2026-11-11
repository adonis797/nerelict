import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';

/// 播放代理里与 Flutter 无关的纯逻辑，抽出来是为了能在主机端直接跑行为测试。
///
/// 只依赖 `dart:io` / `dart:convert`，不碰 method channel，也不需要 Flutter 引擎。

/// 依据 HttpClient 自动跟随重定向后的记录，推导最终 URI。
///
/// `HttpClientResponse.realUri` 在 Dart 里不存在；`redirects` 里每一项的
/// location 可能是相对路径，必须逐跳基于上一跳的 URI 解析，否则 CDN 用相对
/// Location 时会得到没有 host 的 URI，后续分片 URL 全部算错。
Uri finalUriAfterRedirects(Uri requested, List<RedirectInfo> redirects) {
  var current = requested;
  for (final hop in redirects) {
    current = current.resolveUri(hop.location);
  }
  return current;
}

/// 解码 m3u8：容忍 BOM 与非 UTF-8 字节，不因个别非法字节整份失败。
String decodePlaylistText(List<int> bytes) {
  var text = const Utf8Decoder(allowMalformed: true).convert(bytes);
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  // 少量服务器会用 CRLF，统一成 LF 后再按行处理
  return text.replaceAll('\r\n', '\n');
}

final RegExp _uriAttribute = RegExp(r'URI="([^"]+)"');

/// 把 m3u8 中的 URI 全部改写成本地代理地址。
///
/// [base] 必须是重定向之后的最终 URI；[proxyUrl] 由调用方提供，负责生成
/// `http://127.0.0.1:port/...?u=...` 形式的地址。
String rewritePlaylistUris(
  String text,
  Uri base,
  String? referer,
  String Function(String path, String abs, String? referer) proxyUrl,
) {
  final lines = const LineSplitter().convert(text).map((line) {
    final t = line.trim();
    if (t.isEmpty) return line;
    if (t.startsWith('#')) {
      String? path;
      if (t.startsWith('#EXT-X-KEY:') ||
          t.startsWith('#EXT-X-SESSION-KEY:')) {
        path = '/key';
      } else if (t.startsWith('#EXT-X-MAP:')) {
        path = '/seg';
      } else if (t.startsWith('#EXT-X-MEDIA:') ||
          t.startsWith('#EXT-X-I-FRAME-STREAM-INF:')) {
        // master 里的独立音轨 / I 帧列表，之前被整行放过导致不走代理
        path = '/hls';
      }
      if (path == null) return line;
      return t.replaceAllMapped(_uriAttribute, (m) {
        final abs = base.resolve(m.group(1)!).toString();
        return 'URI="${proxyUrl(path!, abs, referer)}"';
      });
    }
    final abs = base.resolve(t).toString();
    final isPlaylist = Uri.parse(abs).path.toLowerCase().endsWith('.m3u8');
    return proxyUrl(isPlaylist ? '/hls' : '/seg', abs, referer);
  });
  return lines.join('\n');
}

/// 代理 URL 的路径后缀。
///
/// 系统播放器（ExoPlayer）靠 URL 最后一段的扩展名推断媒体类型：如果代理地址
/// 是 `/hls?u=...`，会被当成未知格式的渐进式流，把 m3u8 文本当视频数据送去
/// extractor，直接报 Source error。因此代理路径必须保留可推断的文件名。
String proxyPathSuffix(String path, String target) {
  final uriPath = Uri.tryParse(target)?.path ?? '';
  final dot = uriPath.lastIndexOf('.');
  final raw = dot >= 0 ? uriPath.substring(dot).toLowerCase() : '';
  final ext = RegExp(r'^\.[a-z0-9]{1,5}$').hasMatch(raw) ? raw : '';
  switch (path) {
    case '/hls':
      return '/index.m3u8';
    case '/seg':
      return '/segment${ext.isEmpty ? '.ts' : ext}';
    case '/key':
      return '/key.key';
    case '/raw':
      return '/media${ext.isEmpty ? '.mp4' : ext}';
    default:
      return '';
  }
}

/// 稳定缓存键：SHA-256 摘要，取代跨进程不保证稳定的 `String.hashCode`。
String stableCacheKey(String url) {
  final digest = SHA256Digest()
      .process(Uint8List.fromList(utf8.encode(url)))
      .take(16);
  final buf = StringBuffer();
  for (final b in digest) {
    buf.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return '$buf.bin';
}

/// 缓存命中时回给播放器的 MIME：按目标扩展名推断，避免把 fMP4 的
/// init.mp4 / m4s 一律标成 video/mp2t。
String cachedContentType(String target) {
  final path = Uri.tryParse(target)?.path.toLowerCase() ?? '';
  if (path.endsWith('.mp4') ||
      path.endsWith('.m4s') ||
      path.endsWith('.m4v') ||
      path.endsWith('.mp4v')) {
    return 'video/mp4';
  }
  if (path.endsWith('.m4a') || path.endsWith('.aac')) return 'audio/aac';
  if (path.endsWith('.vtt') || path.endsWith('.webvtt')) return 'text/vtt';
  return 'video/mp2t';
}
