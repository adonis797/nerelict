// 播放器触控与播放期弹窗守卫的行为测试：不需要真机、不需要网络。
//
//   dart run tool/verify_player_touch.dart
//
// 覆盖：
//   1. 控制条触控目标 ≥44dp，不再用 compact 密度，也不再用横向滚动容器
//      （滚动容器会和按钮抢手势，稍微带位移的点击就变成滚动、按钮收不到 tap）；
//   2. 播放器打开后 350ms 内不响应手势（防「点开封面那一下把自己点成暂停」）；
//   3. 播放期弹窗守卫只接管 window.open / alert / confirm / prompt，
//      关掉播放器必须原样还原；守卫脚本可重复执行（换页补挂不会套娃）；
//   4. 设置项默认开启，并提供关闭开关。
import 'dart:io';

import 'package:nerelict/services/playback_guard_js.dart';

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

String read(String path) => File(path).readAsStringSync();

void main() {
  final player = read('lib/ui/player_page.dart');
  final browser = read('lib/ui/browser_tab.dart');
  final settings = read('lib/state/settings_state.dart');

  stdout.writeln('=== 1. 触控目标 ===');
  check(player.contains('const double kPlayerMinTap = 44'),
      '触控目标下限定义为 44dp');
  check(player.contains('static const double kMinTap = kPlayerMinTap'),
      '控制条与标题栏共用同一个下限');
  check(
      player.contains('minHeight: kMinTap') &&
          player.contains('minWidth: kMinTap'),
      '图标按钮用约束撑到 44dp，不依赖默认内边距');
  check(!player.contains('visualDensity: VisualDensity.compact'),
      '控制条不再用 compact 密度（命中区曾只有 28~34dp）');
  check(
      player.contains('Widget _textChip(String label, VoidCallback onTap)') &&
          player.contains('width: kChipWidth') &&
          player.contains('height: kMinTap'),
      '倍速 / 画质 / 音轨 / 字幕 胶囊统一 50x44dp');
  check(player.contains('SizedBox(\n            width: kMinTap,\n            height: kMinTap'),
      '锁定按钮的圆形热区也撑到 44dp');
  check(
      !player.contains("SingleChildScrollView(\n                scrollDirection: Axis.horizontal"),
      '控制条不再用横向滚动容器抢手势');
  check(
      player.contains('Flexible(\n                            child: FittedBox(') &&
          player.contains('fit: BoxFit.scaleDown'),
      '窄屏下胶囊弹性缩放，单行不换行、不溢出');
  check(!player.contains('Wrap(\n                alignment: WrapAlignment.start'),
      '不用 Wrap（真实浮层里可用宽度被压窄会竖排成一列）');

  stdout.writeln();
  stdout.writeln('=== 2. 误触屏蔽 ===');
  check(player.contains('final DateTime _openedAt = DateTime.now()'),
      '记录播放器出现时刻');
  check(player.contains('bool get _inputShielded'), '提供 350ms 屏蔽窗口');
  check(player.contains('Duration(milliseconds: 350)'), '屏蔽时长 350ms');
  check(
      player.contains('void _toggleControls() {\n    if (_inputShielded) return;'),
      '屏蔽期内点击不切换控制条');
  check(
      player.contains('void _handleDoubleTap(double width) {\n    if (_inputShielded) return;'),
      '屏蔽期内双击不触发快进 / 暂停');

  stdout.writeln();
  stdout.writeln('=== 3. 播放期弹窗守卫 ===');
  for (final name in <String>['open', 'alert', 'confirm', 'prompt']) {
    check(kPlaybackGuardJs.contains('w.$name = function'),
        '接管 window.$name');
  }
  check(kPlaybackGuardJs.contains('window.__nerelictGuard'), '守卫可判定是否已挂');
  check(kPlaybackGuardJs.contains('if (window.__nerelictGuard) return;'),
      '重复注入直接返回，不会把已被替换的函数再套一层');
  check(!kPlaybackGuardJs.contains('location'), '不动 location，页面跳转仍归广告判定逻辑');
  check(!kPlaybackGuardJs.contains('preventDefault'), '不碰事件，不影响页面交互');
  for (final name in <String>['open', 'alert', 'confirm', 'prompt']) {
    check(kPlaybackGuardRestoreJs.contains('w.$name = o.$name'),
        '还原 window.$name');
  }
  check(kPlaybackGuardRestoreJs.contains('.__nerelictGuard = null'),
      '还原后清掉标记，下次播放能重新挂上');

  check(browser.contains("import '../services/playback_guard_js.dart';"),
      '浏览器页引入守卫脚本');
  check(browser.contains('_state.addListener(_syncPopupGuard)'),
      '监听播放器开关');
  check(browser.contains('_state.removeListener(_syncPopupGuard)'),
      '销毁时注销监听');
  check(browser.contains('_state.player != null && settings.playerBlockPagePopups'),
      '仅播放中且开关打开时接管');
  check(
      browser.contains('final js = want ? kPlaybackGuardJs : kPlaybackGuardRestoreJs;'),
      '关闭播放器即还原网页出口');
  check(browser.contains('if (_popupGuardOn) {\n      try {\n        await _controller.runJavaScript(kPlaybackGuardJs);'),
      '换页后补挂守卫（新页面是新的 JS 上下文）');

  stdout.writeln();
  stdout.writeln('=== 4. 设置项 ===');
  check(settings.contains("'player_block_page_popups'"), '持久化键独立');
  check(
      settings.contains(
          'prefs.getBool(_kPlayerBlockPagePopups) ?? true'),
      '默认开启');
  check(settings.contains('Future<void> setPlayerBlockPagePopups(bool value)'),
      '提供开关');
  final settingsTab = read('lib/ui/settings_tab.dart');
  check(settingsTab.contains("'播放时拦截网页弹窗'"), '设置页可见');
  check(settingsTab.contains('settings.setPlayerBlockPagePopups'),
      '设置页可切换');

  stdout.writeln();
  if (failures.isEmpty) {
    stdout.writeln('全部通过：$passed 项');
  } else {
    stdout.writeln('通过 $passed 项，失败 ${failures.length} 项：');
    for (final f in failures) {
      stdout.writeln('  - $f');
    }
    exitCode = 1;
  }
}
