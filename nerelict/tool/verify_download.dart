// 主机端验证脚本：不依赖 Flutter，直接跑「解析 → 分片下载 → AES 解密 → 合并」。
//
//   dart run tool/verify_download.dart
//
// 不参与 App 打包，只用于验证下载内核。
import 'dart:io';

import 'package:nerelict/models/download_task.dart';
import 'package:nerelict/services/hls_downloader.dart';
import 'package:nerelict/services/app_paths.dart';

const _streams = <String, String>{
  '普通 TS 流': 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
  'AES-128 加密流':
      'https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel-aes.ism/.m3u8',
};

Future<void> main() async {
  final outDir = Directory(
      joinPath(Directory.systemTemp.path, 'nerelict_verify'));
  if (await outDir.exists()) await outDir.delete(recursive: true);
  await outDir.create(recursive: true);

  var failed = 0;

  for (final entry in _streams.entries) {
    stdout.writeln('\n=== ${entry.key} ===');
    stdout.writeln(entry.value);

    final task = DownloadTask(
      id: DownloadTask.newId(),
      url: entry.value,
      title: entry.key.replaceAll(RegExp(r'[^\w]'), '_'),
    );

    var lastPct = -1;
    final downloader = HlsDownloader(
      concurrency: 4,
      resolveOutputDir: () async => outDir,
      resolveTempDir: () async => Directory.systemTemp,
    );

    final watch = Stopwatch()..start();
    await downloader.run(
      task,
      limitSegments: 2,
      onUpdate: () {
        final pct = (task.progress * 100).floor();
        if (pct != lastPct) {
          lastPct = pct;
          stdout.write('\r  ${task.status.label} $pct%  '
              '(${task.doneSegments}/${task.totalSegments} 分片, ${task.sizeText})   ');
        }
      },
    );
    watch.stop();
    stdout.writeln('');

    if (task.status != TaskStatus.done) {
      failed++;
      stdout.writeln('  [失败] ${task.error}');
      continue;
    }

    final file = File(task.filePath!);
    final len = await file.length();
    final head = await file.openRead(0, 16).first;
    final isMp4 = String.fromCharCodes(head.sublist(4, 8)) == 'ftyp';

    // TS 包长 188 字节，包头固定 0x47：连续多个对上基本可证明解密正确
    var isTs = true;
    for (final offset in [0, 188, 376, 564]) {
      if (offset + 1 > len) break;
      final b = await file.openRead(offset, offset + 1).first;
      if (b[0] != 0x47) isTs = false;
    }

    stdout.writeln('  用时 ${watch.elapsed.inSeconds}s, 码率 ${task.variant ?? '单码率'}');
    stdout.writeln('  输出 ${task.filePath}');
    stdout.writeln('  大小 ${(len / 1024 / 1024).toStringAsFixed(2)} MB, '
        '头部 ${isTs ? 'TS 同步字节 0x47 ✓' : isMp4 ? 'MP4 ftyp ✓' : '未知 ✗'}');

    if (len < 100 * 1024 || !(isTs || isMp4)) {
      failed++;
      stdout.writeln('  [失败] 产物不合法');
    } else {
      stdout.writeln('  [通过]');
    }
  }

  stdout.writeln('\n${failed == 0 ? '全部通过' : '$failed 个失败'}');
  exit(failed == 0 ? 0 : 1);
}
