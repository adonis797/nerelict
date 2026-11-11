// 主机端行为测试：用本地 HTTP 服务真实跑一遍「解析 → 分片下载 → 合并」，
// 验证 P0 四项修复，不依赖 Flutter 引擎 / 真机 / 公网。
//
//   dart run tool/verify_p0.dart
//
// 覆盖：重定向后相对分片解析、直播流标记、续传不复用错位分片、
//       直链 Range 续传的 If-Range 校验与校验值失效时从头重写。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nerelict/models/download_task.dart';
import 'package:nerelict/services/app_paths.dart';
import 'package:nerelict/services/hls_downloader.dart';

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

final List<String> requestedPaths = <String>[];
final List<Map<String, String?>> directRequests = <Map<String, String?>>[];

String playlist({required bool live}) =>
    '#EXTM3U\n'
    '#EXT-X-VERSION:3\n'
    '#EXT-X-TARGETDURATION:4\n'
    '#EXT-X-MEDIA-SEQUENCE:0\n'
    '#EXTINF:4,\n'
    'seg0.ts\n'
    '#EXTINF:4,\n'
    'seg1.ts\n'
    '${live ? '' : '#EXT-X-ENDLIST\n'}';

Future<void> handle(HttpRequest req) async {
  final path = req.uri.path;
  requestedPaths.add(path);
  final res = req.response;

  if (path == '/start.m3u8') {
    // 相对 Location：Dio 跟随重定向后 realUri 应变成 /vod/index.m3u8
    res.statusCode = HttpStatus.found;
    res.headers.set(HttpHeaders.locationHeader, '/vod/index.m3u8');
    await res.close();
    return;
  }
  if (path == '/vod/index.m3u8' || path == '/live/index.m3u8') {
    res.headers.contentType =
        ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
    res.write(playlist(live: path.startsWith('/live')));
    await res.close();
    return;
  }
  if (path == '/vod/seg0.ts' || path == '/live/seg0.ts') {
    res.add(Uint8List.fromList(<int>[1, 2, 3]));
    await res.close();
    return;
  }
  if (path == '/vod/seg1.ts' || path == '/live/seg1.ts') {
    res.add(Uint8List.fromList(<int>[4, 5, 6]));
    await res.close();
    return;
  }
  if (path == '/direct.mp4') {
    final data = List<int>.generate(100, (i) => i);
    final range = req.headers.value(HttpHeaders.rangeHeader);
    final ifRange = req.headers.value('if-range');
    directRequests.add(<String, String?>{'range': range, 'ifRange': ifRange});
    res.headers.set(HttpHeaders.etagHeader, '"v1"');
    res.headers.set('Accept-Ranges', 'bytes');
    // 校验值不匹配（或没带）时按 HTTP 语义返回 200 全文
    if (range != null && ifRange == '"v1"') {
      final start = int.parse(range.split('=').last.split('-').first);
      res.statusCode = HttpStatus.partialContent;
      res.headers.set('Content-Range', 'bytes $start-99/100');
      res.add(Uint8List.fromList(data.sublist(start)));
    } else {
      res.statusCode = HttpStatus.ok;
      res.add(Uint8List.fromList(data));
    }
    await res.close();
    return;
  }
  res.statusCode = HttpStatus.notFound;
  await res.close();
}

Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handle);
  final base = 'http://127.0.0.1:${server.port}';

  final root = await Directory.systemTemp.createTemp('nerelict_p0_');
  final outDir = Directory(joinPath(root.path, 'out'));
  final tmpDir = Directory(joinPath(root.path, 'tmp'));
  await outDir.create(recursive: true);
  await tmpDir.create(recursive: true);
  final downloader = HlsDownloader(
    resolveOutputDir: () async => outDir,
    resolveTempDir: () async => tmpDir,
  );

  try {
    stdout.writeln('=== 1. 重定向后相对分片解析 ===');
    final t1 = DownloadTask(
      id: 'p0_redirect',
      url: '$base/start.m3u8',
      title: 'redirect',
    );
    await downloader.run(t1);
    check(t1.status == TaskStatus.done, '重定向后的流能完整下载');
    check(requestedPaths.contains('/vod/seg0.ts') &&
        requestedPaths.contains('/vod/seg1.ts'), '分片基于重定向后的最终 URI 解析');
    check(!requestedPaths.contains('/seg0.ts'), '不再请求重定向前地址下的旧路径');
    if (t1.filePath != null) {
      final bytes = await File(t1.filePath!).readAsBytes();
      check(bytes.length == 6 && bytes.first == 1 && bytes.last == 6,
          '合并结果只包含两个真实分片');
    } else {
      check(false, '合并结果只包含两个真实分片');
    }
    check(t1.isLive == false, '带 ENDLIST 的 VOD 不标记为直播');

    stdout.writeln('=== 2. 直播流标记 ===');
    final t2 = DownloadTask(
      id: 'p0_live',
      url: '$base/live/index.m3u8',
      title: 'live',
    );
    await downloader.run(t2);
    check(t2.status == TaskStatus.done, '直播快照仍可保存');
    check(t2.isLive, '无 ENDLIST 的播放列表会标记为直播片段');
    check(jsonEncode(t2.toJson()).contains('"isLive":true'),
        '直播标记会随任务持久化');

    stdout.writeln('=== 3. 续传不复用错位分片 ===');
    const resumeId = 'p0_resume';
    final taskTmp = Directory(joinPath(tmpDir.path, 'ss_$resumeId'));
    await taskTmp.create(recursive: true);
    // 旧版按索引命名的分片，以及一个不属于当前 playlist 的分片：
    // 修复前 part_000000.bin 会被当成第 0 片直接拼进成品。
    await File(joinPath(taskTmp.path, 'part_000000.bin'))
        .writeAsBytes(<int>[9, 9, 9]);
    await File(joinPath(taskTmp.path, 'seg_deadbeef.bin'))
        .writeAsBytes(<int>[8, 8, 8]);
    final t3 = DownloadTask(
      id: resumeId,
      url: '$base/vod/index.m3u8',
      title: 'resume',
    );
    await downloader.run(t3, resume: true);
    check(t3.status == TaskStatus.done, '带残留分片的续传能完成');
    if (t3.filePath != null) {
      final bytes = await File(t3.filePath!).readAsBytes();
      check(bytes.length == 6 && bytes.first == 1 && bytes.last == 6,
          '成品不含旧分片数据（未串片）');
    } else {
      check(false, '成品不含旧分片数据（未串片）');
    }

    stdout.writeln('=== 4. 直链 Range 续传与 If-Range ===');
    Future<DownloadTask> rangeTask(String id, String validator) async {
      final dir = Directory(joinPath(tmpDir.path, 'ss_$id'));
      await dir.create(recursive: true);
      await File(joinPath(dir.path, 'direct_$id.part'))
          .writeAsBytes(List<int>.generate(40, (i) => i));
      await File(joinPath(dir.path, 'direct.meta')).writeAsString(validator);
      final task = DownloadTask(
        id: id,
        url: '$base/direct.mp4',
        title: id,
      );
      await downloader.run(task, resume: true);
      return task;
    }

    final t4 = await rangeTask('p0_range_ok', '"v1"');
    check(t4.status == TaskStatus.done, '校验值一致时续传成功');
    check(directRequests.any((e) =>
        e['range'] == 'bytes=40-' && e['ifRange'] == '"v1"'),
        '续传同时发送 Range 与 If-Range');
    if (t4.filePath != null) {
      final bytes = await File(t4.filePath!).readAsBytes();
      check(bytes.length == 100 && bytes.last == 99, '续传拼出完整 100 字节');
    } else {
      check(false, '续传拼出完整 100 字节');
    }

    final t5 = await rangeTask('p0_range_stale', '"expired"');
    check(t5.status == TaskStatus.done, '校验值失效时仍能完成下载');
    if (t5.filePath != null) {
      final bytes = await File(t5.filePath!).readAsBytes();
      check(bytes.length == 100 && bytes.first == 0 && bytes.last == 99,
          '源文件变化时从头重写，未把新旧版本拼接');
    } else {
      check(false, '源文件变化时从头重写，未把新旧版本拼接');
    }
  } finally {
    await server.close(force: true);
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  }

  stdout.writeln();
  if (failures.isEmpty) {
    stdout.writeln('全部通过：$passed 项行为断言');
  } else {
    stdout.writeln('失败 ${failures.length} 项：');
    for (final f in failures) {
      stdout.writeln(' - $f');
    }
    exitCode = 1;
  }
}
