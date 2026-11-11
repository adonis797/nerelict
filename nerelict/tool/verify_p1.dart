// 主机端行为测试：真实跑 HlsDownloader 的临时分片清理与直链流式写入，
// 验证 P1 修复，不依赖 Flutter 引擎 / 真机 / 公网。
//
//   dart run tool/verify_p1.dart
//
// 覆盖：孤儿 ss_* 目录清理与活跃目录保留、直链大文件带背压写盘、
//       流中途暂停的状态收敛与分片保留。
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

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('nerelict_p1_');
  final outDir = Directory(joinPath(root.path, 'out'));
  final tmpDir = Directory(joinPath(root.path, 'tmp'));
  await outDir.create(recursive: true);
  await tmpDir.create(recursive: true);
  final downloader = HlsDownloader(
    resolveOutputDir: () async => outDir,
    resolveTempDir: () async => tmpDir,
  );
  HttpServer? server;

  try {
    stdout.writeln('=== 1. 孤儿分片目录清理 ===');
    final active = Directory(joinPath(tmpDir.path, 'ss_active'));
    final staleA = Directory(joinPath(tmpDir.path, 'ss_stale_a'));
    final staleB = Directory(joinPath(tmpDir.path, 'ss_stale_b'));
    final unrelated = Directory(joinPath(tmpDir.path, 'cache_other'));
    for (final dir in <Directory>[active, staleA, staleB, unrelated]) {
      await dir.create(recursive: true);
    }
    await File(joinPath(active.path, 'seg_a.bin'))
        .writeAsBytes(Uint8List(100));
    await File(joinPath(staleA.path, 'seg_b.bin'))
        .writeAsBytes(Uint8List(200));
    await File(joinPath(staleB.path, 'seg_c.bin'))
        .writeAsBytes(Uint8List(300));
    await File(joinPath(unrelated.path, 'keep.bin'))
        .writeAsBytes(Uint8List(10));

    final first = await downloader.cleanupStaleParts(<String>{'active'});
    check(first.dirs == 2, '只删除两个孤儿 ss_* 目录');
    check(first.bytes == 500, '释放字节数按目录内实际文件统计');
    final activeKept = await active.exists() &&
        await File(joinPath(active.path, 'seg_a.bin')).exists();
    check(activeKept, '活跃任务的分片完整保留');
    final staleGone = !await staleA.exists() && !await staleB.exists();
    check(staleGone, '孤儿目录已删除');
    check(await unrelated.exists(), '非 ss_ 前缀目录不受影响');
    final second = await downloader.cleanupStaleParts(<String>{'active'});
    check(second.dirs == 0 && second.bytes == 0, '重复清理是幂等的');

    stdout.writeln('=== 2. 直链大文件带背压写盘 ===');
    final payload = Uint8List.fromList(
        List<int>.generate(2 * 1024 * 1024, (i) => i % 251));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final res = req.response;
      if (req.uri.path == '/big.mp4' || req.uri.path == '/pause.mp4') {
        res.headers.contentType = ContentType('video', 'mp4');
        res.headers.contentLength = payload.length;
        const int chunk = 64 * 1024;
        for (var off = 0; off < payload.length; off += chunk) {
          final end = off + chunk > payload.length ? payload.length : off + chunk;
          res.add(Uint8List.fromList(payload.sublist(off, end)));
          await Future<void>.delayed(Duration.zero);
        }
        await res.close();
      } else {
        res.statusCode = HttpStatus.notFound;
        await res.close();
      }
    });
    final base = 'http://127.0.0.1:${server.port}';

    final big = DownloadTask(
        id: 'p1_big', url: '$base/big.mp4', title: 'big');
    var ticks = 0;
    await downloader.run(big, onUpdate: () => ticks++);
    check(big.status == TaskStatus.done, '2 MB 直链下载完成');
    check(big.progress == 1, '完成时进度为 100%');
    check(big.bytes == payload.length, '下载字节数与 Content-Length 一致');
    check(ticks > 1, '写入过程持续更新进度（流式而非一次性缓冲）');
    final outPath = big.filePath;
    if (outPath != null) {
      final bytes = await File(outPath).readAsBytes();
      var same = bytes.length == payload.length;
      if (same) {
        for (var i = 0; i < payload.length; i++) {
          if (bytes[i] != payload[i]) {
            same = false;
            break;
          }
        }
      }
      check(same, '落盘内容逐字节一致');
    } else {
      check(false, '落盘内容逐字节一致');
    }
    check(!await Directory(joinPath(tmpDir.path, 'ss_p1_big')).exists(),
        '成功后清理临时分片目录');

    stdout.writeln('=== 3. 流中途暂停保留分片 ===');
    final paused = DownloadTask(
        id: 'p1_pause', url: '$base/pause.mp4', title: 'pause');
    var pauseTicks = 0;
    await downloader.run(paused, onUpdate: () {
      pauseTicks++;
      if (pauseTicks == 2) paused.pauseRequested = true;
    });
    check(paused.status == TaskStatus.paused, '中断后状态收敛为暂停');
    final pauseDir = Directory(joinPath(tmpDir.path, 'ss_p1_pause'));
    check(await pauseDir.exists(), '暂停保留临时目录供续传');
    final part =
        File(joinPath(pauseDir.path, 'direct_p1_pause.part'));
    final partOk =
        await part.exists() && await part.length() < payload.length;
    check(partOk, '已写入的分片未丢失且未写满');
  } finally {
    await server?.close(force: true);
    try {
      await root.delete(recursive: true);
    } catch (_) {}
    stdout.writeln();
    if (failures.isEmpty) {
      stdout.writeln('全部通过：$passed 项断言');
    } else {
      stdout.writeln('失败 ${failures.length} 项：');
      for (final f in failures) {
        stdout.writeln(' - $f');
      }
      exitCode = 1;
    }
  }
}
