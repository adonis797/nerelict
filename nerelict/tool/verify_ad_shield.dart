// 广告遮挡层防护 + 错误文案归一化 + 控制条胶囊尺寸 的行为测试。
//
//   dart run tool/verify_ad_shield.dart
//
// 覆盖：
//   1. 遮挡层判定足够保守（不透明的正常遮罩、含 video 的容器、小元素都不动）；
//   2. 只关 `pointer-events`，不删节点、不影响页面外观；
//   3. 点击后 1.5 秒内的 `window.open` 被拒绝并上报；
//   4. `shield` 事件能被 Dart 解析，且不进入资源聚合；
//   5. 原始播放错误能翻译成人话（401/403/DRM/编码/超时等）；
//   6. 四个胶囊同宽、倍速文案定长。
import 'dart:io';

import 'package:nerelict/services/click_sniff.dart';
import 'package:nerelict/services/click_sniff_js.dart';
import 'package:nerelict/services/playback_error.dart';

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
  final js = kClickSniffJs;

  stdout.writeln('=== 1. 遮挡层判定（保守） ===');
  check(js.contains('function looksLikeAdLayer'), '提供遮挡层判定函数');
  check(js.contains("st.position !== 'fixed' && st.position !== 'absolute'"),
      '只认定位过的层');
  check(js.contains('z < 20'), 'z-index 低于 20 不判（正常内容层不误伤）');
  check(js.contains('vw * vh * 0.45'), '必须覆盖 ≥45% 视口');
  check(js.contains("el.querySelector('video,iframe,canvas')"),
      '容器里有 video/iframe/canvas 一律不动');
  check(js.contains('alphaOf(st.backgroundColor) > 0.35'),
      '不透明的大色块不判（那是正常遮罩/背景）');
  check(js.contains("txt.length > 80"), '文字多的层不判（多半是真正的弹窗）');
  check(js.contains("tag === 'BODY'") && js.contains("tag === 'HTML'"),
      'body/html 永不处理');

  stdout.writeln();
  stdout.writeln('=== 2. 处理方式可逆、不改外观 ===');
  check(js.contains("setProperty('pointer-events', 'none', 'important')"),
      '只关指针事件');
  check(!js.contains('display = ?\'none\''), '不隐藏节点（页面外观不变）');
  check(!js.contains('.remove()'), '不删除 DOM 节点');
  check(js.contains('window.__ssClearLayers'), '提供手动清理入口');
  check(js.contains("t: 'shield'"), '清理结果通过 ClickChannel 上报');

  stdout.writeln();
  stdout.writeln('=== 3. 点击弹窗拦截 ===');
  check(js.contains('shell.tapAt = lastDown'), '记录最近一次点击时刻');
  check(js.contains('Date.now() - shell.tapAt < 1500'), '点击后 1.5 秒窗口');
  check(js.contains('return null;') && js.contains('shell.popups++'),
      '窗口内 window.open 返回 null 并计数');
  // 收窄条件：只有「正在播放」或「点在视频容器里」才算广告弹窗，
  // 否则登录 / OAuth 弹窗也会被一起吞掉。
  check(js.contains('anyPlaying()') && js.contains('tapInPlayer()'),
      'window.open 只在播放中或点在视频容器时拦');
  // WebView 侧没有 onCreateWindow，放行原生 window.open 也开不出窗口，
  // 所以 http(s) 一律降级成同页跳转，非 http 才交回原生。
  check(js.contains('location.href = target'), 'http(s) 降级成同页跳转');
  check(js.contains('ssOpen.apply(window, arguments)'),
      '非 http(s) 仍交回原生 window.open');
  check(js.contains('window.__ssOpenWrapped'), '只包一次，重复注入不会套娃');
  check(js.contains('blockClickUntil'),
      '只拦截「刚清掉遮挡层」的那一次点击');
  check(js.split('preventDefault(').length - 1 == 2,
      '只有遮挡层当次点击与 target=_blank 接管会 preventDefault');

  stdout.writeln();
  stdout.writeln('=== 4. Dart 侧解析 ===');
  final shield = ClickSniffEvent.parse(
      '{"t":"shield","kind":"layer","id":2,"page":"https://a.b/c"}');
  check(shield != null && shield.type == ClickEventType.shield,
      'shield 事件可解析');
  check(shield?.kind == 'layer', '保留 kind');
  check(shield!.summary.contains('遮挡层'), '摘要说明是遮挡层');
  final popup = ClickSniffEvent.parse('{"t":"shield","kind":"popup","id":3}');
  check(popup!.summary.contains('弹窗'), '弹窗类摘要正确');
  final unknown = ClickSniffEvent.parse('{"t":"whatever"}');
  check(unknown == null, '未知类型仍然被丢弃');

  final appState = read('lib/state/app_state.dart');
  check(
      appState.contains('case ClickEventType.shield:') &&
          appState.contains('不参与资源聚合'),
      'shield 不进入资源聚合');
  final browser = read('lib/ui/browser_tab.dart');
  check(browser.contains('已移除播放器上的广告遮挡层'), '自动命中后提示一次');
  check(browser.contains("'清理页面遮挡层'"), '菜单提供手动清理');
  check(browser.contains('_shieldNotified'), '提示每页只弹一次');

  stdout.writeln();
  stdout.writeln('=== 5. 错误文案 ===');
  final source = humanizePlaybackError(
      'PlatformException(VideoError, Video player had error zn: Source error, null, null)');
  check(source.summary == '视频源打不开', 'Source error → 视频源打不开');
  check(source.hint.contains('防盗链'), '并给出可能原因');
  check(!source.text.contains('PlatformException'), '不再把原始异常甩给用户');
  check(humanizePlaybackError('HttpDataSourceException: 403 Forbidden').summary
          .contains('403'),
      '403 可识别');
  check(humanizePlaybackError('404 Not Found').summary.contains('404'),
      '404 可识别');
  check(humanizePlaybackError('MediaCodecVideoRenderer error: decoder init failed')
          .summary
          .contains('解码'),
      '解码失败可识别');
  check(humanizePlaybackError('DRM license request failed').summary.contains('DRM'),
      'DRM 可识别');
  check(humanizePlaybackError('SocketException: Failed host lookup')
          .summary
          .contains('域名'),
      'DNS 失败可识别');
  check(humanizePlaybackError('').summary == '未知错误', '空串有兜底');
  check(humanizePlaybackError('something weird').summary == 'something weird',
      '无法识别时原样保留，不丢信息');
  check(stripPlatformException('PlatformException(VideoError, x, null, null)') ==
          'VideoError, x',
      '剥离 PlatformException 外壳与 null 尾巴');

  stdout.writeln();
  stdout.writeln('=== 6. 胶囊尺寸 ===');
  final player = read('lib/ui/player_page.dart');
  check(player.contains('static const double kChipWidth = 50'), '胶囊统一宽度 50dp');
  check(player.contains('height: kMinTap'), '胶囊统一高度 44dp');
  check(player.contains('FontFeature.tabularFigures()'), '数字等宽，切换倍速不跳动');
  check(player.contains('toStringAsFixed(rounded ? 1 : 2)'),
      '整数倍速也补一位小数（1.0x）');
  check(!player.contains('_textChip(formatSpeed(_speed)'),
      '不再直接用不等宽的 formatSpeed 文案');

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
