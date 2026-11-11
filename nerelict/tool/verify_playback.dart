// 主机端行为测试：用本地 HTTP 服务真实跑一遍「302 回源 → 解析最终 URI →
// 改写 m3u8 → 按改写结果取分片」，验证播放代理链路的重定向修复。
//
//   dart run tool/verify_playback.dart
//
// 播放代理本体依赖 path_provider / Flutter 引擎，无法在纯 Dart 主机脚本里
// 直接导入，因此与 Flutter 无关的逻辑集中在 services/playlist_rewriter.dart，
// 这里测的就是代理实际调用的那几个函数。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nerelict/services/playlist_rewriter.dart';

int passed = 0;
final List<String> failures = <String>[];

void check(bool ok, String label) {
  if (ok) {
    passed++;
    stdout.writeln('  ✓ $label');
  } else {
    failures.add(label);
    stdout.writeln('  ✗ $label');
  }
}

class _Redirect implements RedirectInfo {
  _Redirect(this.statusCode, this.location);

  @override
  final int statusCode;
  @override
  final Uri location;
  @override
  String get method => 'GET';
}

const String _vodPlaylist = '#EXTM3U\r\n'
    '#EXT-X-VERSION:4\r\n'
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="main",URI="audio.m3u8"\r\n'
    '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\r\n'
    '#EXT-X-MAP:URI="init.mp4"\r\n'
    '#EXTINF:4,\r\n'
    'seg0.ts\r\n'
    '#EXTINF:4,\r\n'
    'seg1.ts\r\n'
    '#EXT-X-ENDLIST\r\n';

final List<String> originPaths = <String>[];
late int originPort;

Future<void> handleOrigin(HttpRequest req) async {
  final path = req.uri.path;
  originPaths.add(path);
  final res = req.response;
  if (path == '/start.m3u8') {
    // 相对 Location：最容易暴露「realUri 没有 host」的场景
    res.statusCode = HttpStatus.found;
    res.headers.set(HttpHeaders.locationHeader, '/vod/index.m3u8');
    await res.close();
    return;
  }
  res.headers.contentType = ContentType.binary;
  switch (path) {
    case '/vod/index.m3u8':
      res.headers.contentType =
          ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
      // 带 UTF-8 BOM，验证解码容错
      res.add(<int>[0xEF, 0xBB, 0xBF, ...utf8.encode(_vodPlaylist)]);
      break;
    case '/vod/seg0.ts':
      res.add(utf8.encode('SEG0'));
      break;
    case '/vod/seg1.ts':
      res.add(utf8.encode('SEG1'));
      break;
    case '/vod/key.bin':
      res.add(utf8.encode('KEY16'));
      break;
    case '/vod/init.mp4':
      res.add(utf8.encode('INIT'));
      break;
    case '/vod/audio.m3u8':
      res.add(utf8.encode('#EXTM3U\n#EXT-X-ENDLIST\n'));
      break;
    default:
      res.statusCode = HttpStatus.notFound;
  }
  await res.close();
}

Future<String> fetch(Uri uri) async {
  final client = HttpClient()..autoUncompress = true;
  try {
    final req = await client.getUrl(uri);
    final res = await req.close();
    final builder = BytesBuilder(copy: false);
    await res.fold<BytesBuilder>(builder, (b, c) => b..add(c));
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  } finally {
    client.close(force: true);
  }
}

Future<void> main() async {
  stdout.writeln('=== 播放代理链路行为测试 ===');

  // ---- 1. 最终 URI 推导 ----
  final start = Uri.parse('http://cdn.example.com/start.m3u8');
  final relative = finalUriAfterRedirects(start, <RedirectInfo>[
    _Redirect(302, Uri(path: '/vod/index.m3u8')),
  ]);
  check(relative.host == 'cdn.example.com', '相对 Location 仍保留原 host');
  check(relative.path == '/vod/index.m3u8', '相对 Location 路径正确');

  final multi = finalUriAfterRedirects(start, <RedirectInfo>[
    _Redirect(302, Uri(path: '/hop/index.m3u8')),
    _Redirect(302, Uri(path: '/final/index.m3u8')),
  ]);
  check(multi.path == '/final/index.m3u8', '多次重定向逐跳解析');

  final absolute = finalUriAfterRedirects(start, <RedirectInfo>[
    _Redirect(302, Uri.parse('https://other.example.com/vod/i.m3u8')),
  ]);
  check(absolute.host == 'other.example.com', '跨域名绝对 Location 正确');

  // ---- 2. 解码容错 ----
  final decoded = decodePlaylistText(<int>[
    0xEF, 0xBB, 0xBF,
    ...utf8.encode(_vodPlaylist),
    0xFF, // 非法 UTF-8 字节不得让整份 playlist 失败
  ]);
  check(!decoded.startsWith('\uFEFF'), '去掉 UTF-8 BOM');
  check(!decoded.contains('\r\n'), 'CRLF 统一成 LF');
  check(decoded.trimLeft().startsWith('#EXTM3U'), '解码后仍是合法 m3u8');

  // ---- 3. 改写规则（纯逻辑） ----
  final classified = <String, String>{};
  final rewrittenSimple = rewritePlaylistUris(
    '#EXTM3U\n'
    '#EXT-X-KEY:METHOD=AES-128,URI="k.key"\n'
    '#EXT-X-MAP:URI="init.mp4"\n'
    '#EXT-X-MEDIA:TYPE=AUDIO,URI="a.m3u8"\n'
    '#EXT-X-I-FRAME-STREAM-INF:URI="i.m3u8"\n'
    '#EXT-X-MEDIA-SEQUENCE:0\n'
    '720p.m3u8\n'
    'seg0.ts\n',
    Uri.parse('http://h.example.com/vod/index.m3u8'),
    null,
    (path, abs, ref) {
      classified[abs] = path;
      return 'PROXY($path,$abs)';
    },
  );
  check(classified['http://h.example.com/vod/k.key'] == '/key',
      'EXT-X-KEY 走 /key');
  check(classified['http://h.example.com/vod/init.mp4'] == '/seg',
      'EXT-X-MAP 走 /seg');
  check(classified['http://h.example.com/vod/a.m3u8'] == '/hls',
      '独立音轨 EXT-X-MEDIA 不再被整行放过');
  check(classified['http://h.example.com/vod/i.m3u8'] == '/hls',
      'I-FRAME-STREAM-INF 走 /hls');
  check(classified['http://h.example.com/vod/720p.m3u8'] == '/hls',
      'master 变体行按 .m3u8 走 /hls');
  check(classified['http://h.example.com/vod/seg0.ts'] == '/seg',
      '分片行走 /seg');
  check(rewrittenSimple.contains('#EXT-X-MEDIA-SEQUENCE:0\n'),
      'MEDIA-SEQUENCE 不被误判成 MEDIA 标签');

  // ---- 4. 缓存键与 MIME ----
  check(stableCacheKey('http://a/b.ts') == stableCacheKey('http://a/b.ts'),
      '缓存键稳定可复现');
  check(stableCacheKey('http://a/b.ts') != stableCacheKey('http://a/c.ts'),
      '不同 URL 缓存键不同');
  check(cachedContentType('http://a/init.mp4') == 'video/mp4',
      'fMP4 init.mp4 不再被标成 video/mp2t');
  check(cachedContentType('http://a/seg.m4s?token=x') == 'video/mp4',
      '带 query 的 m4s 仍能识别');
  check(cachedContentType('http://a/seg.ts') == 'video/mp2t',
      'TS 分片保持 video/mp2t');

  // ---- 4b. 代理路径必须让系统播放器能推断媒体类型 ----
  check(proxyPathSuffix('/hls', 'http://a/vod/index.m3u8') == '/index.m3u8',
      'HLS 代理地址以 .m3u8 结尾（否则被当成渐进式流）');
  check(proxyPathSuffix('/seg', 'http://a/vod/seg0.ts') == '/segment.ts',
      'TS 分片代理地址带 .ts');
  check(proxyPathSuffix('/seg', 'http://a/vod/init.m4s') == '/segment.m4s',
      'fMP4 分片保留 .m4s');
  check(proxyPathSuffix('/raw', 'http://a/sample.mp4') == '/media.mp4',
      '直链代理地址保留 .mp4');
  check(proxyPathSuffix('/key', 'http://a/k.key') == '/key.key',
      '密钥地址带可识别后缀');
  check(proxyPathSuffix('/seg', 'http://a/x.ts/evil') == '/segment.ts',
      '异常扩展名不会进入代理路径');
  final realistic = rewritePlaylistUris(
    'seg0.ts\n',
    Uri.parse('http://h.example.com/vod/index.m3u8'),
    null,
    (path, abs, ref) =>
        'http://127.0.0.1:1$path${proxyPathSuffix(path, abs)}?u=$abs',
  );
  check(realistic.contains('/seg/segment.ts?u='),
      '改写后的分片 URL 携带可识别扩展名');

  // ---- 5. 端到端：302 → 改写 → 取分片 ----
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  originPort = server.port;
  server.listen(handleOrigin, onError: (_) {});

  final client = HttpClient()..autoUncompress = true;
  late List<RedirectInfo> hops;
  late String body;
  try {
    final req = await client.getUrl(Uri.parse(
        'http://127.0.0.1:$originPort/start.m3u8'));
    req.followRedirects = true;
    req.maxRedirects = 8;
    final res = await req.close();
    hops = res.redirects;
    final builder = BytesBuilder(copy: false);
    await res.fold<BytesBuilder>(builder, (b, c) => b..add(c));
    body = decodePlaylistText(builder.takeBytes());
  } finally {
    client.close(force: true);
  }
  check(hops.isNotEmpty, 'HttpClient 确实跟随了 302');
  final requested = Uri.parse('http://127.0.0.1:$originPort/start.m3u8');
  final base = finalUriAfterRedirects(requested, hops);
  check(base.path == '/vod/index.m3u8',
      '最终 base 是重定向后的 playlist 路径');

  final targets = <String>[];
  final rewritten = rewritePlaylistUris(
    body,
    base,
    null,
    (path, abs, ref) {
      targets.add(abs);
      return 'http://127.0.0.1:$originPort$path'
          '?u=${Uri.encodeComponent(abs)}';
    },
  );
  check(rewritten.contains('u=http'), '改写结果指向代理地址');

  final bodyByUrl = <String, String>{};
  for (final abs in targets) {
    bodyByUrl[abs] = await fetch(Uri.parse(abs));
  }
  check(originPaths.contains('/vod/seg0.ts') &&
          originPaths.contains('/vod/seg1.ts'),
      '分片按最终 base 解析到 /vod/ 下（不再 404）');
  check(bodyByUrl['http://127.0.0.1:$originPort/vod/seg0.ts'] == 'SEG0' &&
          bodyByUrl['http://127.0.0.1:$originPort/vod/seg1.ts'] == 'SEG1',
      '改写后的分片地址能取到真实内容');
  check(bodyByUrl['http://127.0.0.1:$originPort/vod/key.bin'] == 'KEY16',
      '密钥 URI 也按最终 base 解析');
  check(bodyByUrl['http://127.0.0.1:$originPort/vod/audio.m3u8']!
          .startsWith('#EXTM3U'),
      '独立音轨 playlist 可通过代理地址取到');

  await server.close(force: true);

  stdout.writeln();
  if (failures.isEmpty) {
    stdout.writeln('✓ 全部 $passed 项通过');
  } else {
    stdout.writeln('✗ ${failures.length} 项失败（共 ${passed + failures.length} 项）：');
    for (final f in failures) {
      stdout.writeln('   - $f');
    }
    exitCode = 1;
  }
}
