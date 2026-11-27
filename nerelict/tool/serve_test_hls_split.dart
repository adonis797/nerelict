// 音轨独立流的端到端验证辅助：起一个本地 HLS 服务，主播放列表里把音轨
// 声明成独立的 AUDIO 组，用来跑「解析 → 双轨下载 → 双输入转封装」整条链路。
//
//   dart run tool/serve_test_hls_split.dart
//   adb reverse tcp:8899 tcp:8899
//   手机浏览器打开 http://127.0.0.1:8899/master.m3u8
//
// 音轨与视频轨共用同一批真实 TS 分片：分片本身是音视频复用的，
// 视频轨只取画面、音轨只取声音，正好验证两条 extractor 的归并与 PTS 对齐。
//
// 监听地址与端口可通过 NERELICT_HLS_HOST / NERELICT_HLS_PORT 覆盖。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:nerelict/services/app_paths.dart';
import 'package:nerelict/services/hls_parser.dart';

const int defaultPort = 8899;
const String defaultHost = '127.0.0.1';
const String hlsHostEnv = 'NERELICT_HLS_HOST';
const String hlsPortEnv = 'NERELICT_HLS_PORT';
const String masterUrl = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

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

  final chosen = variants.last;
  final mediaText = (await dio.get<String>(
    chosen.uri.toString(),
    options: Options(responseType: ResponseType.plain),
  )).data!;
  final media = parseMediaPlaylist(mediaText, chosen.uri);
  if (media.segments.isEmpty) throw StateError('分片为空');
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

  String mediaPlaylist() {
    final buf = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:3')
      ..writeln('#EXT-X-TARGETDURATION:10')
      ..writeln('#EXT-X-MEDIA-SEQUENCE:0');
    for (var i = 0; i < segments.length; i++) {
      buf
        ..writeln('#EXTINF:10.0,')
        // 必须与下面的路由一致：分片按 media playlist 的地址解析成 /segN.ts，
        // 写成裸 0.ts 会解析到 /0.ts 直接 404。
        ..writeln('seg$i.ts');
    }
    buf.writeln('#EXT-X-ENDLIST');
    return buf.toString();
  }

  // 音轨单独成组，且带 URI —— 这正是 0.4.x 会直接拒绝、0.5.0 要合并的形态。
  // NAME 用 ASCII：Dart 的 HttpResponse 在没显式声明 charset 时按 latin1 编码，
  // 中文会直接抛「Contains invalid characters」并把服务进程带走。
  final master = StringBuffer()
    ..writeln('#EXTM3U')
    ..writeln('#EXT-X-VERSION:3')
    ..writeln('#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Main",'
        'LANGUAGE="zh-CN",DEFAULT=YES,URI="audio.m3u8"')
    ..writeln('#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,'
        'CODECS="avc1.4d401e,mp4a.40.2",AUDIO="aud"')
    ..writeln('video.m3u8');

  final server = await HttpServer.bind(host, port);
  stdout.writeln('READY  http://$host:$port/master.m3u8  '
      '(${segments.length} 分片，${chosen.label}，音轨独立)');

  server.listen((req) async {
    try {
      final path = req.uri.path;
      if (path == '/master.m3u8') {
        req.response.headers.contentType = ContentType(
            'application', 'vnd.apple.mpegurl',
            charset: 'utf-8');
        req.response.write(master.toString());
      } else if (path == '/video.m3u8' || path == '/audio.m3u8') {
        req.response.headers.contentType = ContentType(
            'application', 'vnd.apple.mpegurl',
            charset: 'utf-8');
        req.response.write(mediaPlaylist());
      } else if (RegExp(r'^/seg\d+\.ts$').hasMatch(path)) {
        final idx =
            int.tryParse(RegExp(r'\d+').firstMatch(path)?.group(0) ?? '') ?? 0;
        if (idx < segments.length) {
          req.response.headers.contentType = ContentType('video', 'mp2t');
          req.response.add(segments[idx]);
        } else {
          req.response.statusCode = 404;
        }
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    } catch (e) {
      // 单个请求出错不能带走整个服务，否则后面每一轮验证都要重启
      stdout.writeln('请求失败 ${req.uri}: $e');
      try {
        await req.response.close();
      } catch (_) {}
    }
  });
}
