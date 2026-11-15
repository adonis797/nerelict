// 真机验证辅助：起一个「必须带 Authorization 才给数据」的 HLS 站点。
//
//   dart run tool/serve_auth_hls.dart
//   adb reverse tcp:8899 tcp:8899
//   手机打开 http://127.0.0.1:8899/auth.html
//
// 链路：页面 fetch('/api/play') 带 Bearer 头 → 响应体里有 m3u8 绝对地址
//      → 嗅探脚本从 body 里抓到地址，并把发起该请求的 Authorization 一起上报
//      → Nerelict 播放时由代理回源注入该头 → 分片沿用同一令牌 → 出画面。
//
// 服务端会把每个请求的鉴权结果打到 stdout，用来确认「头到底有没有送到」。
// 只用于本地联调，不进常规回归链。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:nerelict/services/app_paths.dart';
import 'package:nerelict/services/hls_parser.dart';

const int defaultPort = 8899;
const String defaultHost = '127.0.0.1';
const String token = 'Bearer test-token-123';
const String masterUrl = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

bool authorized(HttpRequest req) {
  final value = req.headers.value('authorization');
  return value != null && value.trim() == token;
}

void log(HttpRequest req, bool ok, {String extra = ''}) {
  final ua = req.headers.value('user-agent') ?? '';
  final shortUa = ua.length > 72 ? '${ua.substring(0, 72)}…' : ua;
  stdout.writeln('[${req.method} ${req.uri.path}] '
      'auth=${ok ? 'OK' : 'MISSING'} ua="$shortUa" $extra');
}

Future<void> main() async {
  final host = Platform.environment['NERELICT_HLS_HOST']?.trim() ?? defaultHost;
  final port = parseConfiguredPort(
    Platform.environment['NERELICT_HLS_PORT'],
    fallback: defaultPort,
  );
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 60),
    headers: {
      'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
    },
  ));

  final masterText = (await dio.get<String>(
    masterUrl,
    options: Options(responseType: ResponseType.plain),
  )).data!;
  final variants = parseMasterPlaylist(masterText, Uri.parse(masterUrl));
  if (variants.isEmpty) throw StateError('主播放列表为空');
  final chosen = variants.last;
  final mediaText = (await dio.get<String>(
    chosen.uri.toString(),
    options: Options(responseType: ResponseType.plain),
  )).data!;
  final media = parseMediaPlaylist(mediaText, chosen.uri);
  if (media.segments.length < 2) throw StateError('分片不足');

  final segments = <List<int>>[];
  for (final seg in media.segments.take(2)) {
    segments.add((await dio.get<List<int>>(
      seg.uri.toString(),
      options: Options(responseType: ResponseType.bytes),
    )).data!);
    stdout.writeln('素材分片 ${segments.length}: ${segments.last.length} 字节');
  }

  // 分片用相对路径：顺带验证「m3u8 重写后分片仍带同一个鉴权令牌」
  final playlist = StringBuffer()
    ..writeln('#EXTM3U')
    ..writeln('#EXT-X-VERSION:3')
    ..writeln('#EXT-X-TARGETDURATION:10')
    ..writeln('#EXT-X-MEDIA-SEQUENCE:0');
  for (var i = 0; i < segments.length; i++) {
    playlist
      ..writeln('#EXTINF:10.0,')
      ..writeln('seg$i.ts');
  }
  playlist.writeln('#EXT-X-ENDLIST');

  const page = '''
<!doctype html><meta charset="utf-8"><title>auth hls</title>
<h3>需要 Authorization 的测试页</h3>
<button id="b" style="font-size:20px;padding:12px 20px">取播放地址</button>
<p id="s">未请求</p>
<script>
document.getElementById('b').onclick = function () {
  document.getElementById('s').textContent = '请求中…';
  fetch('/api/play', {headers: {'Authorization': 'Bearer test-token-123', 'X-Client': 'page'}})
    .then(function (r) { return r.json(); })
    .then(function (d) {
      document.getElementById('s').textContent = '已取到地址，回到 Nerelict 嗅探面板';
      window.__got = d.url;
    })
    .catch(function (e) { document.getElementById('s').textContent = '失败: ' + e; });
};
</script>
''';

  final server = await HttpServer.bind(host, port);
  stdout.writeln('READY  http://$host:$port/auth.html');

  server.listen((req) async {
    final path = req.uri.path;
    final ok = authorized(req);

    if (path == '/auth.html' || path == '/') {
      req.response.headers.contentType = ContentType.html;
      req.response.write(page);
      await req.response.close();
      return;
    }

    if (path == '/api/play') {
      log(req, ok);
      if (!ok) {
        req.response.statusCode = HttpStatus.forbidden;
        await req.response.close();
        return;
      }
      final hostHeader = req.headers.value('host') ?? '$host:$port';
      req.response.headers.contentType = ContentType.json;
      // 绝对地址：嗅探脚本只在响应体里匹配 http(s) 开头的媒体地址
      req.response.write('{"url":"http://$hostHeader/v/index.m3u8"}');
      await req.response.close();
      return;
    }

    if (path == '/v/index.m3u8') {
      log(req, ok);
      if (!ok) {
        req.response.statusCode = HttpStatus.forbidden;
        await req.response.close();
        return;
      }
      req.response.headers.contentType =
          ContentType('application', 'vnd.apple.mpegurl');
      req.response.write(playlist.toString());
      await req.response.close();
      return;
    }

    final segMatch = RegExp(r'^/v/seg(\d+)\.ts$').firstMatch(path);
    if (segMatch != null) {
      final idx = int.tryParse(segMatch.group(1)!) ?? -1;
      log(req, ok, extra: 'seg=$idx bytes=${req.headers.contentLength}');
      if (!ok) {
        req.response.statusCode = HttpStatus.forbidden;
        await req.response.close();
        return;
      }
      if (idx < 0 || idx >= segments.length) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      req.response.headers.contentType = ContentType('video', 'mp2t');
      req.response.add(segments[idx]);
      await req.response.close();
      return;
    }

    log(req, ok, extra: '404');
    req.response.statusCode = HttpStatus.notFound;
    await req.response.close();
  });
}
