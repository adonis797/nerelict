// 纯 Dart 主机侧断言：验证下载文件管理的核心逻辑，不依赖 Flutter / 真机。
// 运行：dart run tool/verify_file_manager.dart
import 'dart:io';

import 'package:nerelict/services/file_manager.dart';

int _passed = 0;

void check(bool ok, String name) {
  if (!ok) throw StateError('断言失败：$name');
  _passed++;
  stdout.writeln('  ✓ $name');
}

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('m8_filemgr_');
  try {
    final file = File('${dir.path}${Platform.pathSeparator}clip.ts');
    await file.writeAsBytes(List<int>.filled(2048, 0x47));

    final info = await FileManager.inspect(file.path);
    check(info != null, '可以读取文件信息');
    check(info!.name == 'clip.ts', '文件名正确');
    check(info.typeLabel == 'TS 视频', '类型标签正确');
    check(info.sizeText == '2.0 KB', '大小格式化正确 (${info.sizeText})');
    check(info.isPlayable, 'TS 文件被判定为可播放');

    final renamed = await FileManager.rename(file.path, '我的视频');
    check(renamed.endsWith('我的视频.ts'), '重命名自动保留原扩展名');
    check(!await file.exists(), '旧路径已不存在');
    check(await File(renamed).exists(), '新路径存在');

    final cleaned = await FileManager.rename(renamed, 'a/b:c*?');
    check(cleaned.endsWith('a_b_c__.ts'), '非法字符被替换为下划线');
    check(!cleaned.contains('/b'), '路径分隔符不会拼进文件名');

    final keptExt = await FileManager.rename(cleaned, '换成mp4.mp4');
    check(keptExt.endsWith('.ts'), '不允许改成其它扩展名，避免播放失效');

    final same = await FileManager.rename(keptExt, '换成mp4');
    check(same == keptExt, '同名重命名是无操作，不产生重复文件');

    var conflict = false;
    try {
      await FileManager.rename(keptExt, '重复');
      final duplicate = File('${dir.path}${Platform.pathSeparator}重复.ts');
      await duplicate.writeAsBytes(const <int>[1]);
      await FileManager.rename(keptExt, '重复');
    } on FileManagerException {
      conflict = true;
    }
    check(conflict, '同名冲突被拒绝，不会覆盖已有文件');

    await FileManager.delete(keptExt);
    check(!await File(keptExt).exists(), '删除后文件确实不存在');
    check(await FileManager.inspect(keptExt) == null, '删除后读取信息返回 null');
    await FileManager.delete(keptExt); // 幂等，不应抛异常
    check(true, '重复删除是幂等操作');

    stdout.writeln('\n全部 $_passed 项断言通过');
  } finally {
    await dir.delete(recursive: true);
  }
}
