import 'dart:io';

import 'package:nerelict/services/file_index.dart';
import 'package:nerelict/services/storage_scanner.dart';

/// 文件索引与全盘扫描的行为断言（纯 Dart，可直接 `dart run`）。
///
/// 覆盖三件在真机上很难回归的事：
/// 1. `Android/` 被整体跳过之后，应用自己的下载目录必须能补扫进来；
/// 2. 主根与额外根重叠时同一个文件不能出现两次；
/// 3. 索引常驻——TTL 内重复调用不重扫，`markDirty` 之后才重扫。

int _pass = 0;
int _fail = 0;

void check(bool ok, String label) {
  if (ok) {
    _pass++;
    stdout.writeln('  ✓ $label');
  } else {
    _fail++;
    stdout.writeln('  ✗ $label');
  }
}

Future<void> main() async {
  final base = await Directory.systemTemp.createTemp('nerelict_files_');
  final root = Directory('${base.path}${Platform.pathSeparator}storage');
  final download = Directory('${root.path}${Platform.pathSeparator}Android'
      '${Platform.pathSeparator}data'
      '${Platform.pathSeparator}com.nerelict.nerelict'
      '${Platform.pathSeparator}files'
      '${Platform.pathSeparator}Nerelict');
  final dcim = Directory('${root.path}${Platform.pathSeparator}DCIM');
  final downloads = Directory('${root.path}${Platform.pathSeparator}Download');

  try {
    for (final dir in <Directory>[download, dcim, downloads]) {
      await dir.create(recursive: true);
    }
    Future<void> write(Directory dir, String name, int size) async {
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(List<int>.filled(size, 7));
    }

    await write(dcim, 'photo.jpg', 64);
    await write(downloads, 'manual.pdf', 64);
    await write(download, 'movie.mp4', 128);
    await write(download, 'cover.png', 64);

    stdout.writeln('=== 1. 全盘扫描必须补扫应用下载目录 ===');
    final plain = await scanAllStorage(root: root.path);
    final plainNames = plain.files.map((f) => f.name).toSet();
    check(plainNames.contains('photo.jpg'), '普通目录里的图片被扫到');
    check(plainNames.contains('manual.pdf'), 'Download 目录里的文档被扫到');
    check(!plainNames.contains('movie.mp4'),
        '不传额外根时 Android/ 里的下载成品依旧看不到（回归基线）');

    final withExtra = await scanAllStorage(
      root: root.path,
      extraRoots: <String>[download.path],
    );
    final extraNames = withExtra.files.map((f) => f.name).toList();
    check(extraNames.contains('movie.mp4'), '补扫后能看到下载的视频');
    check(extraNames.contains('cover.png'), '补扫后能看到下载的图片');
    check(
      extraNames.where((n) => n == 'movie.mp4').length == 1,
      '同一个文件只出现一次',
    );
    check(extraNames.length == plainNames.length + 2, '只多出下载目录里的两个文件');

    stdout.writeln('=== 2. 主根与额外根重叠时去重 ===');
    final overlap = await scanAllStorage(
      root: root.path,
      extraRoots: <String>[root.path, dcim.path],
    );
    final overlapPaths = overlap.files.map((f) => f.path).toList();
    check(
      overlapPaths.length == overlapPaths.toSet().length,
      '额外的根与主根重叠时按路径去重',
    );

    stdout.writeln('=== 3. 增量回调 ===');
    final chunks = <int>[];
    await scanAllStorage(
      root: root.path,
      extraRoots: <String>[download.path],
      onChunk: (partial) => chunks.add(partial.length),
    );
    check(chunks.isNotEmpty, '扫描过程中推送了增量结果');
    check(chunks.last <= withExtra.files.length, '增量结果不会多于最终结果');

    stdout.writeln('=== 4. 索引常驻：TTL 内不重扫 ===');
    final index = FileIndex.instance;
    index.reset();
    await index.ensureFresh(root: root.path);
    final firstRevision = index.revision;
    check(index.hasResult, '首次扫描落地后 hasResult 为 true');
    check(index.files.any((f) => f.name == 'photo.jpg'), '索引里有图片');

    await index.ensureFresh(root: root.path);
    check(index.revision == firstRevision, 'TTL 内再次进入不重扫');
    check(!index.scanning, '扫描结束后不残留扫描态');

    stdout.writeln('=== 5. markDirty 之后必须重扫 ===');
    index.markDirty();
    await index.ensureFresh(root: root.path);
    check(index.revision == firstRevision + 1, '标脏后重扫一轮');
    check(index.needsScan == false, '重扫完成后不再需要重扫');

    stdout.writeln('=== 6. 改名 / 删除就地回写 ===');
    final photo = index.files.firstWhere((f) => f.name == 'photo.jpg');
    index.applyMove(photo.path,
        '${dcim.path}${Platform.pathSeparator}photo2.jpg');
    check(index.files.any((f) => f.name == 'photo2.jpg'), '改名后列表里的名字同步');
    check(!index.files.any((f) => f.name == 'photo.jpg'), '旧名字不再出现');

    final renamed =
        index.files.firstWhere((f) => f.name == 'photo2.jpg');
    index.applyMove(renamed.path, null);
    check(!index.files.any((f) => f.name == 'photo2.jpg'), '删除后就地移除该条目');
    check(index.revision == firstRevision + 1, '就地回写不触发重扫');

    stdout.writeln('=== 7. 取消与空根防护 ===');
    index.reset();
    check(!index.hasResult, 'reset 清空结果');
    await index.ensureFresh(root: '');
    check(!index.hasResult, '空根不发起扫描');
  } finally {
    try {
      await base.delete(recursive: true);
    } catch (_) {}
  }

  stdout.writeln('');
  if (_fail == 0) {
    stdout.writeln('全部通过：$_pass 项断言');
  } else {
    stdout.writeln('失败 $_fail 项 / 共 ${_pass + _fail} 项');
    exitCode = 1;
  }
}
