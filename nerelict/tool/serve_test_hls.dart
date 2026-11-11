// 真机验证辅助：起一个极小的 HLS 服务（取公开测试流前 2 个真实 TS 分片），
// 配合 `adb reverse tcp:<port> tcp:<port>`，手机里访问 http://<host>:<port>/index.m3u8
// 即可在几秒内跑完「嗅探 → 接管 → 下载 → 一键转 MP4 → 播放 MP4」全链路，
// 不必下载几百 MB 的完整视频。
//
//   dart run tool/serve_test_hls.dart
//
// 监听地址与端口可通过 NERELICT_HLS_HOST / NERELICT_HLS_PORT 覆盖，
// 非法或越界的端口值会回退到默认值。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:nerelict/services/app_paths.dart';
import 'package:nerelict/services/hls_parser.dart';

const int defaultPort = 8899;
const String defaultHost = '127.0.0.1';
const String hlsHostEnv = 'NERELICT_HLS_HOST';
const String hlsPortEnv = 'NERELICT_HLS_PORT';
const String masterUrl =
    'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

Future<void> main() async {
  final host = Platform.environment[hlsHostEnv]?.trim().isEmpty ?? true
      ? defaultHost
      : Platform.environment[hlsHostEnv]!.trim();
  final port = parseConfiguredPort(Platform.environment[hlsPortEnv],
      fallback: defaultPort);
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

  // parseMasterPlaylist 已按码率降序，取最低码率，分片最小
  final chosen = variants.last;
  final mediaText = (await dio.get<String>(
    chosen.uri.toString(),
    options: Options(responseType: ResponseType.plain),
  )).data!;
  final media = parseMediaPlaylist(mediaText, chosen.uri);
  if (media.segments.length < 2) throw StateError('分片不足');
  if (media.segments.any((s) => s.key?.isAes128 == true)) {
    throw StateError('该测试流带 AES 加密，请换一个未加密流');
  }

  final segments = <List<int>>[];
  for (final seg in media.segments.take(2)) {
    final data = (await dio.get<List<int>>(
      seg.uri.toString(),
      options: Options(responseType: ResponseType.bytes),
    )).data!;
    segments.add(data);
    stdout.writeln('下载分片 ${segments.length}: ${data.length} 字节');
  }

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

  final server = await HttpServer.bind(host, port);
  stdout.writeln('READY  http://$host:$port/index.m3u8  '
      '(${segments.length} 分片，${chosen.label})');

  server.listen((req) async {
    final path = req.uri.path;
    if (path == '/index.m3u8') {
      req.response.headers.contentType =
          ContentType('application', 'vnd.apple.mpegurl');
      req.response.write(playlist.toString());
    } else if (RegExp(r'^/seg\d+\.ts$').hasMatch(path)) {
      // 路径形如 /seg0.ts
      final idx =
          int.tryParse(RegExp(r'\d+').firstMatch(path)?.group(0) ?? '') ?? 0;
      if (idx < segments.length) {
        req.response.headers.contentType =
            ContentType('video', 'mp2t');
        req.response.add(segments[idx]);
      } else {
        req.response.statusCode = 404;
      }
    } else {
      req.response.statusCode = 404;
    }
    await req.response.close();
  });
}
