// 真机冒烟：冷启动、底部三页切换、截图留证与崩溃日志检查。
//
// 不依赖 Flutter 引擎，也不属于常规回归链（需要一台已安装本应用的设备）。
// 用法（在 `nerelict/` 下）：
//   dart run tool/smoke_device.dart
//   dart run tool/smoke_device.dart --adb /path/to/adb
//   dart run tool/smoke_device.dart --shots /path/to/shots --expect 0.4.1
// 退出码 0 表示全部通过，1 表示有检查失败。
import 'dart:io';

const String kDefaultPackage = 'com.nerelict.nerelict';

final String projectRoot = () {
  final script = Platform.script;
  if (script.scheme == 'file' || script.scheme.isEmpty) {
    return File.fromUri(script).parent.parent.path;
  }
  return Directory.current.path;
}();

final List<String> failures = <String>[];
int passed = 0;

void ok(String label) {
  passed++;
  stdout.writeln('  ✓ $label');
}

void fail(String label, [String detail = '']) {
  failures.add(label);
  stdout.writeln('  ✗ $label${detail.isEmpty ? '' : ' → $detail'}');
}

String join(String a, String b) =>
    a.endsWith('/') || a.endsWith('\\') ? '$a$b' : '$a${Platform.pathSeparator}$b';

String readProject(String relative) {
  try {
    final f = File(join(projectRoot, relative));
    return f.existsSync() ? f.readAsStringSync() : '';
  } catch (_) {
    return '';
  }
}

class Adb {
  Adb(this.path);

  final String path;

  Future<ProcessResult> call(List<String> args) => Process.run(
        path,
        args,
        stdoutEncoding: systemEncoding,
        stderrEncoding: systemEncoding,
      );
}

Future<void> main(List<String> argv) async {
  var adbPath = 'adb';
  var package = kDefaultPackage;
  var shotsDir = join(join(projectRoot, '.tmp'), 'smoke-shots');
  var expected = '';
  for (var i = 0; i < argv.length; i++) {
    final key = argv[i];
    if (i + 1 >= argv.length) continue;
    final value = argv[i + 1];
    switch (key) {
      case '--adb':
        adbPath = value;
      case '--package':
        package = value;
      case '--shots':
        shotsDir = value;
      case '--expect':
        expected = value;
    }
    i++;
  }
  if (expected.isEmpty) {
    final m = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+',
            multiLine: true)
        .firstMatch(readProject('pubspec.yaml'));
    expected = m?.group(1) ?? '';
  }

  stdout.writeln('=== Nerelict 真机冒烟 ===');
  stdout.writeln('adb：$adbPath');
  stdout.writeln('包名：$package');
  final adb = Adb(adbPath);

  ProcessResult devices;
  try {
    devices = await adb(['devices']);
  } catch (e) {
    fail('adb 可执行', '找不到 adb，请用 --adb 指定绝对路径');
    _summary(shotsDir);
    return;
  }
  final online = devices.stdout
      .toString()
      .split('\n')
      .where((l) => l.trim().endsWith('\tdevice'))
      .length;
  if (online == 0) {
    fail('设备在线', '没有 device 状态的设备');
    _summary(shotsDir);
    return;
  }
  ok('设备在线（$online 台）');

  final dump = await adb(['shell', 'dumpsys', 'package', package]);
  final dumpText = dump.stdout.toString();
  if (!dumpText.contains('versionName=')) {
    fail('已安装目标包', 'dumpsys 读不到版本信息');
  } else {
    final name = RegExp(r'versionName=([^\s]+)').firstMatch(dumpText)?.group(1);
    final code = RegExp(r'versionCode=(\d+)').firstMatch(dumpText)?.group(1);
    if (expected.isNotEmpty && name != expected) {
      fail('设备版本与 pubspec 一致', '设备 $name / 期望 $expected');
    } else {
      ok('设备版本 versionName=$name / versionCode=$code');
    }
  }

  await adb(['shell', 'am', 'force-stop', package]);
  final start = await adb([
    'shell',
    'am',
    'start',
    '-W',
    '-n',
    '$package/.MainActivity',
  ]);
  if (start.stdout.toString().contains('Status: ok') ||
      start.stdout.toString().contains('Activity:')) {
    ok('冷启动 MainActivity');
  } else {
    fail('冷启动 MainActivity', start.stdout.toString().trim());
  }
  await Future<void>.delayed(const Duration(milliseconds: 2500));

  final sizeOut = await adb(['shell', 'wm', 'size']);
  final sizeMatch =
      RegExp(r'(\d+)x(\d+)').firstMatch(sizeOut.stdout.toString());
  final w = int.tryParse(sizeMatch?.group(1) ?? '') ?? 1080;
  final h = int.tryParse(sizeMatch?.group(2) ?? '') ?? 2400;
  final bottomY = (h * 0.975).round();

  Directory(shotsDir).createSync(recursive: true);
  final remoteShots = <String>[];

  Future<void> capture(String tag) async {
    final remote = '/sdcard/nerelict_smoke_$tag.png';
    final local = join(shotsDir, 'smoke_$tag.png');
    final cap = await adb(['shell', 'screencap', '-p', remote]);
    final pull = await adb(['pull', remote, local]);
    remoteShots.add(remote);
    final localFile = File(local);
    if (cap.exitCode == 0 && pull.exitCode == 0 && localFile.existsSync() &&
        localFile.lengthSync() > 1000) {
      ok('截图 $tag（${localFile.lengthSync()} B）');
    } else {
      fail('截图 $tag', pull.stderr.toString().trim());
    }
  }

  Future<void> tapTab(double fx, String tag) async {
    await adb([
      'shell',
      'input',
      'tap',
      (w * fx).round().toString(),
      bottomY.toString(),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await capture(tag);
  }

  await capture('01_browser');
  await tapTab(0.5, '02_files');
  await tapTab(0.833, '03_settings');

  final pidOut = await adb(['shell', 'pidof', package]);
  final pid = pidOut.stdout.toString().trim().split(RegExp(r'\s+')).first;
  if (pid.isEmpty) {
    fail('进程存活', 'pidof 返回空');
  } else {
    ok('进程存活（pid $pid）');
    final log = await adb(['logcat', '-d', '-t', '1200', '--pid=$pid']);
    final fatal = log.stdout
        .toString()
        .split('\n')
        .where((l) =>
            l.contains('FATAL EXCEPTION') || l.contains('AndroidRuntime'))
        .toList();
    if (fatal.isEmpty) {
      ok('logcat 无崩溃 / AndroidRuntime 异常');
    } else {
      fail('logcat 无崩溃', fatal.take(3).join(' | '));
    }
  }

  for (final remote in remoteShots) {
    await adb(['shell', 'rm', '-f', remote]);
  }
  _summary(shotsDir);
}

void _summary(String shotsDir) {
  stdout.writeln();
  if (failures.isEmpty) {
    stdout.writeln('冒烟全部通过：$passed 项检查');
    stdout.writeln('截图目录：$shotsDir');
  } else {
    stdout.writeln('冒烟失败 ${failures.length} 项：');
    for (final f in failures) {
      stdout.writeln(' - $f');
    }
    exitCode = 1;
  }
}
