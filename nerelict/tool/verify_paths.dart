// 路径层的边界验证：不依赖 Flutter，可直接 `dart run tool/verify_paths.dart`。
// 覆盖缺失配置、空白配置、相对路径、绝对路径、路径穿越、异常路径与回退行为。
import 'dart:io';

import 'package:nerelict/services/app_paths.dart';

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
  stdout.writeln('=== 1. 配置读取 ===');
  check(cleanEnvValue(null) == null, '未配置返回 null');
  check(cleanEnvValue('   ') == null, '全空白配置返回 null');
  check(cleanEnvValue('  /tmp/videos  ') == '/tmp/videos', '配置去除首尾空白');
  check(readEnvPath('__NERELICT_UNSET_VAR__') == null,
      '不存在的环境变量返回 null');

  stdout.writeln('=== 2. 平台无关拼接 ===');
  final sep = Platform.pathSeparator;
  check(joinPath('', 'child') == 'child', '空 base');
  check(joinPath('base', '') == 'base', '空 child');
  check(joinPath('base$sep', '${sep}child') == 'base${sep}child',
      '重复分隔符被清理');
  check(joinPath(sep, 'child') == '${sep}child', '根目录拼接不产生双分隔符');
  check(joinPath('base', 'a/b') == 'base${sep}a/b', '保留子路径层级');

  stdout.writeln('=== 3. 配置值解析 ===');
  final base = Directory.systemTemp.path;
  check(resolveConfiguredPath(null, relativeBase: base) == null, '缺失配置');
  check(resolveConfiguredPath('  ', relativeBase: base) == null, '空白配置');
  check(resolveConfiguredPath('out', relativeBase: base) == joinPath(base, 'out'),
      '相对路径相对显式基准解析');
  check(
      resolveConfiguredPath('./out', relativeBase: base) ==
          joinPath(base, 'out'),
      '带 ./ 的相对路径');
  check(resolveConfiguredPath('../escape', relativeBase: base) == null,
      '拒绝 .. 路径穿越');
  check(resolveConfiguredPath('a/../b', relativeBase: base) == null,
      '拒绝中间的 .. 段');
  check(resolveConfiguredPath('.', relativeBase: base) == null,
      '纯相对点视为无效配置');
  final absolute = joinPath(base, 'absolute_target');
  check(
      resolveConfiguredPath(absolute, relativeBase: '${base}_other') ==
          absolute,
      '绝对路径不受基准影响');

  stdout.writeln('=== 4. 目录解析与回退（真实 IO）===');
  final tmp = await Directory.systemTemp.createTemp('nerelict_paths_');
  try {
    final root = Directory(joinPath(tmp.path, 'root'));
    await root.create(recursive: true);
    Future<Directory> rootFn() async => root;
    final fallbackPath = joinPath(root.path, kDownloadDirName);

    final d1 = await defaultOutputDirectory(fallbackRoot: rootFn);
    check(d1.path == fallbackPath, '未配置时回退到默认目录');
    check(await d1.exists(), '默认目录已创建');

    final d2 = await defaultOutputDirectory(
        configured: 'custom/out', fallbackRoot: rootFn);
    check(d2.path == joinPath(root.path, joinPath('custom', 'out')),
        '相对配置按层级解析');
    check(await d2.exists(), '配置目录已创建');

    final absDir = Directory(joinPath(tmp.path, 'abs_target'));
    final d3 = await defaultOutputDirectory(
        configured: absDir.path, fallbackRoot: rootFn);
    check(d3.path == absDir.path, '绝对配置直接使用');
    check(await d3.exists(), '绝对配置目录已创建');

    final d4 = await defaultOutputDirectory(
        configured: '../escape', fallbackRoot: rootFn);
    check(d4.path == fallbackPath, '含 .. 的异常配置回退默认');
    check(await d4.exists(), '异常配置回退后目录仍可用');

    final blocker = File(joinPath(tmp.path, 'blocker'));
    await blocker.writeAsString('not a directory');
    final d5 = await defaultOutputDirectory(
        configured: blocker.path, fallbackRoot: rootFn);
    check(d5.path == fallbackPath, '配置指向文件时回退默认');
    check(await d5.exists(), '指向文件的配置不影响功能');
  } finally {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  }

  stdout.writeln('=== 5. 端口配置边界 ===');
  check(parseConfiguredPort(null, fallback: 8899) == 8899, '缺失配置回退默认端口');
  check(parseConfiguredPort('  ', fallback: 8899) == 8899, '空白配置回退默认端口');
  check(parseConfiguredPort('abc', fallback: 8899) == 8899, '非数字回退默认端口');
  check(parseConfiguredPort('0', fallback: 8899) == 8899, '端口 0 回退默认端口');
  check(parseConfiguredPort('65536', fallback: 8899) == 8899, '越界端口回退默认端口');
  check(parseConfiguredPort(' 9000 ', fallback: 8899) == 9000, '合法端口生效');

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
