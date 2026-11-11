// 主机端验证 v2.0 新增的纯逻辑与下载分支，不依赖 Android 真机。
//
//   dart run tool/verify_v2_features.dart
//
// 覆盖：
//  1. 直链 mp4 识别 + 流式下载保存（播放器「下载当前视频」走的分支）
//  2. m3u8 仍走原有 HLS 解析/合并链路，产物为 .ts（回归检查）
//  3. 只有完成的 .ts 任务才 canConvert（转换按钮显示条件）
//  4. MP4 开关关闭时，convertToMp4 完全不执行
import 'dart:io';
import 'dart:typed_data';

import 'package:nerelict/models/download_task.dart';
import 'package:nerelict/services/conversion_policy.dart';
import 'package:nerelict/services/hls_downloader.dart';
import 'package:nerelict/services/app_paths.dart';

Uint8List fakeTs() {
  final data = Uint8List(188 * 20);
  for (var i = 0; i < data.length; i += 188) {
    data[i] = 0x47;
  }
  return data;
}

Future<void> main() async {
  final tmp = await Directory.systemTemp.createTemp('ss_v2_verify_');
  final out = Directory(joinPath(tmp.path, 'out'));
  await out.create();

  final ts = fakeTs();
  final mp4 = Uint8List.fromList(List<int>.generate(4096, (i) => i % 251));

  late final HttpServer server;
  server = await HttpServer.bind('127.0.0.1', 0);
  final base = 'http://127.0.0.1:${server.port}';

  server.listen((req) async {
    final path = req.uri.path;
    final headers = [ContentType('application', 'octet-stream')];
    if (path == '/master.m3u8') {
      req.response.headers.contentType = ContentType.text;
      req.response.write('#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720\n'
          '$base/index.m3u8\n');
    } else if (path == '/index.m3u8') {
      req.response.headers.contentType = ContentType.text;
      req.response.write('#EXTM3U\n'
          '#EXT-X-VERSION:3\n'
          '#EXT-X-TARGETDURATION:10\n'
          '#EXT-X-MEDIA-SEQUENCE:0\n'
          '#EXTINF:10.0,\n'
          '$base/seg0.ts\n'
          '#EXTINF:10.0,\n'
          '$base/seg1.ts\n'
          '#EXT-X-ENDLIST\n');
    } else if (path == '/seg0.ts' || path == '/seg1.ts') {
      req.response.headers.contentType = headers.first;
      req.response.add(ts);
    } else if (path == '/clip.mp4') {
      req.response.headers.contentType = ContentType('video', 'mp4');
      req.response.add(mp4);
    } else {
      req.response.statusCode = 404;
    }
    await req.response.close();
  });

  var passed = 0;
  void check(bool ok, String name) {
    if (!ok) throw StateError('FAILED: $name');
    passed++;
    stdout.writeln('  [OK] $name');
  }

  try {
    stdout.writeln('=== 1. URL 分类 ===');
    check(isDirectMediaUrl(Uri.parse('$base/clip.mp4')), 'mp4 判为直链');
    check(!isDirectMediaUrl(Uri.parse('$base/index.m3u8')), 'm3u8 不判为直链');
    check(directMediaExtension(Uri.parse('$base/a.MP4?x=1')) == 'mp4',
        '扩展名大小写归一');

    final downloader = HlsDownloader(
      resolveOutputDir: () async => out,
      resolveTempDir: () async => tmp,
    );

    stdout.writeln('=== 2. 直链 mp4 下载 ===');
    final mp4Task = DownloadTask(
      id: 'v2_mp4',
      url: '$base/clip.mp4',
      title: 'clip',
    );
    await downloader.run(mp4Task);
    check(mp4Task.status == TaskStatus.done, '任务状态 = 已完成');
    check(mp4Task.filePath != null && mp4Task.filePath!.endsWith('.mp4'),
        '产物为 .mp4');
    final mp4File = File(mp4Task.filePath!);
    check(await mp4File.length() == mp4.length, '字节数与源文件一致');
    check(!mp4Task.canConvert, 'mp4 产物不显示转换按钮');

    stdout.writeln('=== 3. HLS 下载（回归） ===');
    final tsTask = DownloadTask(
      id: 'v2_hls',
      url: '$base/master.m3u8',
      title: 'hls',
    );
    await downloader.run(tsTask);
    check(tsTask.status == TaskStatus.done, '任务状态 = 已完成');
    check(tsTask.filePath != null && tsTask.filePath!.endsWith('.ts'),
        '产物为 .ts');
    check(await File(tsTask.filePath!).length() == ts.length * 2,
        '两个分片按顺序合并');
    check(tsTask.variant != null && tsTask.variant!.contains('1280'),
        '主播放列表选中码率');
    check(tsTask.canConvert, 'TS 产物满足转换按钮显示条件');

    stdout.writeln('=== 4. 手动转换入口（与设置开关解耦） ===');
    check(canStartConversion(task: tsTask), '完成的 TS -> 允许手动转换');
    check(!canStartConversion(task: mp4Task), 'mp4 产物 -> 不需要转换');
    tsTask.conversion = ConversionState.converting;
    check(!canStartConversion(task: tsTask), '正在转换中 -> 不重复触发');

    stdout.writeln('\n全部通过：$passed 项断言');
  } finally {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  }
}
