// 点击捕获（浮层播放）行为测试：不依赖 Flutter 引擎 / 真机 / 网络。
//
//   dart run tool/verify_click_sniff.dart
//
// 覆盖：
//   1. ClickSniffEvent 解析：脏消息不炸、字段缺失有默认值、分数有上限；
//   2. 点击归因并入聚合：被动嗅探先建好的项被原地补标记，不产生第二条；
//   3. 页面脚本的硬性约束：捕获阶段 passive、不阻断交互、阈值与 Dart 一致；
//   4. UI / 设置接线：通道注册、脚本注入、筛选入口与开关默认值。
import 'dart:io';

import 'package:nerelict/models/sniffed_media.dart';
import 'package:nerelict/services/click_sniff.dart';
import 'package:nerelict/services/click_sniff_js.dart';
import 'package:nerelict/services/resource_aggregator.dart';

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

/// 项目根以脚本自身位置为准（与 verify_v35 保持一致）
final String projectRoot = () {
  final script = Platform.script;
  if (script.scheme == 'file' || script.scheme.isEmpty) {
    return File.fromUri(script).parent.parent.path;
  }
  return Directory.current.path;
}();

String read(String relative) {
  try {
    final f = File('$projectRoot/$relative');
    return f.existsSync() ? f.readAsStringSync() : '';
  } catch (_) {
    return '';
  }
}

String json(Map<String, Object?> data) {
  final parts = data.entries.map((e) {
    final v = e.value;
    if (v is String) return '"${e.key}":"${v.replaceAll('"', '\\"')}"';
    return '"${e.key}":$v';
  });
  return '{${parts.join(',')}}';
}

void main() {
  stdout.writeln('=== 1. 事件解析 ===');
  final click = ClickSniffEvent.parse(json(<String, Object?>{
    't': 'click',
    'id': 3,
    'label': 'div.thumb 「第 3 集」',
    'tag': 'div',
    'x': 120,
    'y': 340,
    'page': 'https://v.example.com/list',
    'title': '剧集列表',
  }));
  check(click != null && click.type == ClickEventType.click, 'click 事件可解析');
  check(click!.sessionId == 3, '会话序号透传');
  check(click.label.contains('第 3 集'), '点击目标描述保留');
  check(click.summary.contains('#3'), '提示语带会话序号');

  final hit = ClickSniffEvent.parse(json(<String, Object?>{
    't': 'hit',
    'id': 3,
    'url': 'https://cdn.example.com/v/ep3/index.m3u8?sign=abc',
    'kind': 'playlist',
    'from': 'fetch',
    'delay': 420,
    'score': 80,
    'label': 'div.thumb 「第 3 集」',
  }));
  check(hit != null && hit.type == ClickEventType.hit, 'hit 事件可解析');
  check(hit!.url.contains('index.m3u8'), '媒体地址透传');
  check(hit.kind == 'playlist' && hit.delayMs == 420, '类型与延迟透传');
  check(hit.isOverlay, 'score 80 判定为浮层');
  check(hit.summary.contains('浮层'), '浮层命中在提示语里标注');

  final low = ClickSniffEvent.parse(json(<String, Object?>{
    't': 'hit',
    'id': 1,
    'url': 'https://cdn.example.com/v/a.m3u8',
    'kind': 'playlist',
    'score': 30,
  }));
  check(low != null && !low.isOverlay, '普通内联播放器不算浮层');

  final clamped = ClickSniffEvent.parse(json(<String, Object?>{
    't': 'overlay',
    'id': 2,
    'score': 480,
  }));
  check(clamped != null && clamped.overlayScore == 100, '分数上限收敛到 100');

  final mse = ClickSniffEvent.parse(json(<String, Object?>{
    't': 'mse',
    'id': 4,
    'from': 'mediasource',
  }));
  check(mse != null && mse.isMse, 'mse 事件可解析');

  final frame = ClickSniffEvent.parse(json(<String, Object?>{
    't': 'iframe',
    'id': 5,
    'url': 'https://player.example.net/embed/xyz',
  }));
  check(frame != null && frame.type == ClickEventType.iframe, '跨域 iframe 事件可解析');

  check(ClickSniffEvent.parse('not json') == null, '非 JSON 消息被丢弃');
  check(ClickSniffEvent.parse('{"t":"hit","id":1,"url":"blob:abc"}') == null,
      'blob 地址不进捕获链路');
  check(ClickSniffEvent.parse('{"t":"nope","id":1}') == null, '未知类型被丢弃');
  check(ClickSniffEvent.parse('{"t":"click"}') != null, '缺字段的 click 仍可用');

  stdout.writeln('=== 2. 点击归因并入聚合 ===');
  final agg = ResourceAggregator();
  // 被动嗅探先建项
  final base = agg.accept(
    url: 'https://cdn.example.com/v/ep3/index.m3u8?token=old',
    kind: 'playlist',
    page: 'https://v.example.com/list',
    source: 'perf',
    title: '剧集列表',
  );
  check(base.changed && base.item != null, '被动嗅探建立资源项');
  check(!base.item!.clickCaptured, '尚未被点击捕获');

  // 同一视频被点击捕获：地址只差签名参数，必须并到同一条
  final attributed = agg.accept(
    url: 'https://cdn.example.com/v/ep3/index.m3u8?token=new',
    kind: 'playlist',
    page: 'https://v.example.com/list',
    source: '点击/fetch',
    title: '剧集列表',
    attribution: const ClickAttribution(
      sessionId: 3,
      overlayScore: 80,
      label: 'div.thumb 「第 3 集」',
    ),
  );
  check(attributed.changed && attributed.item != null, '归因命中返回变更');
  check(agg.items.length == 1, '带签名参数的同一地址不新增条目');
  final item = agg.items.single;
  check(item.clickCaptured && item.clickHits == 1, '捕获次数记为 1');
  check(item.overlayPlay, '达到阈值标记为浮层播放');
  check(item.captureNote.contains('浮层播放'), '列表说明包含浮层字样');
  check(item.captureNote.contains('第 3 集'), '列表说明带上点击目标');

  // 再点一次同一个视频：次数累加，浮层分数取高值
  final again = agg.accept(
    url: 'https://cdn.example.com/v/ep3/index.m3u8',
    kind: 'playlist',
    page: 'https://v.example.com/list',
    source: '点击/xhr',
    title: '剧集列表',
    attribution: const ClickAttribution(sessionId: 4, overlayScore: 55),
  );
  check(again.changed, '重复捕获仍触发刷新');
  check(agg.items.length == 1, '重复捕获不新增条目');
  check(item.clickHits == 2, '捕获次数累加到 2');
  check(item.overlayScore == 80, '浮层分数保留更高的一次');
  check(item.captureNote.contains('捕获 2 次'), '多次捕获在说明里体现');

  // 同一会话的补报（浮层分数在动画结束后才越线）不重复计次数
  final patched = agg.accept(
    url: 'https://cdn.example.com/v/ep3/index.m3u8',
    kind: 'playlist',
    page: 'https://v.example.com/list',
    source: '点击/overlay',
    title: '剧集列表',
    attribution: const ClickAttribution(sessionId: 4, overlayScore: 95),
  );
  check(patched.changed, '同会话补报分数仍触发刷新');
  check(item.clickHits == 2, '同会话补报不重复计捕获次数');
  check(item.overlayScore == 95, '补报的更高分数被采纳');

  // 未越线的点击不改变浮层标记
  final plain = ResourceAggregator();
  final plainItem = plain.accept(
    url: 'https://cdn.example.com/v/a.m3u8',
    kind: 'playlist',
    page: 'https://v.example.com/a',
    source: '点击/video',
    title: 'A',
    attribution: const ClickAttribution(sessionId: 1, overlayScore: 40),
  ).item!;
  check(plainItem.clickCaptured && !plainItem.overlayPlay, '低分命中只记点击不算浮层');

  // 分片归因挂到同目录的播放列表
  final segAgg = ResourceAggregator();
  segAgg.accept(
    url: 'https://cdn.example.com/v/ep9/index.m3u8',
    kind: 'playlist',
    page: 'https://v.example.com/list',
    source: 'fetch',
    title: '剧集列表',
  );
  final seg = segAgg.accept(
    url: 'https://cdn.example.com/v/ep9/seg-1.ts',
    kind: 'segment',
    page: 'https://v.example.com/list',
    source: '点击/fetch',
    title: '剧集列表',
    attribution: const ClickAttribution(sessionId: 2, overlayScore: 70),
  );
  check(seg.item != null && segAgg.items.length == 1, '分片归因并回所属播放列表');
  check(segAgg.items.single.segmentCount == 1, '分片被记录');
  check(segAgg.items.single.overlayPlay, '分片命中同样带浮层标记');

  check(!agg.accept(
    url: 'ftp://x/y.m3u8',
    kind: 'playlist',
    page: '',
    source: 'click',
    title: '',
  ).changed, '非 http 地址被丢弃');

  stdout.writeln('=== 3. 页面脚本约束 ===');
  check(kClickSniffJs.contains('__ssClickInjected'), '脚本有重复注入保护');
  check(kClickSniffJs.contains("addEventListener('pointerdown'"), '捕获 pointerdown');
  check(kClickSniffJs.contains("addEventListener('click'"), 'click 兜底');
  check(kClickSniffJs.contains('capture: true, passive: true'),
      '监听为捕获阶段且 passive');
  // 唯一的例外：刚识别出广告遮挡层的那一次点击，在 document 捕获阶段掐掉，
  // 否则它仍会触发广告层自己的跳转。普通点击全程 passive。
  final gu = kClickSniffJs.indexOf('if (!shell.blockClickUntil');
  final pd = kClickSniffJs.indexOf('preventDefault(');
  check(pd > 0 && gu > 0 && pd > gu && pd - gu < 700,
      '仅遮挡层拦截这一处阻止默认行为');
  check(kClickSniffJs.contains('blockClickUntil = 0;'),
      '一次性：拦完立刻复位，不影响后续点击');
  check(kClickSniffJs.contains('{ capture: true }'),
      '拦截挂在捕获阶段，先于页面自己的处理器');
  check(kClickSniffJs.contains('MutationObserver'), '用 MutationObserver 抓动态插入');
  check(kClickSniffJs.contains("getEntriesByType('resource')"),
      '用 performance 条目兜住 Worker / 早发请求');
  check(kClickSniffJs.contains('ATTR_MS = 8000'), '归因窗口 8 秒');
  check(kClickSniffJs.contains('OVERLAY_MIN = 50'), '脚本阈值 50');
  check(kOverlayThreshold == 50, 'Dart 阈值与脚本一致');
  check(kClickSniffJs.contains('MediaSource'), '识别 MSE / blob 播放');
  check(kClickSniffJs.contains('contentDocument'), '同源 iframe 直读');
  check(kClickSniffJs.contains("t: 'iframe'"), '跨域 iframe 上报');
  check(kClickSniffJs.contains('__ssClickReset'), '提供重置入口');
  check(kClickSniffResetJs.contains('__ssClickReset'), '重置脚本调用正确');
  check(kClickSniffScanJs.contains('__ssClickScan'), '补扫脚本调用正确');
  check(!kClickSniffJs.contains('XMLHttpRequest.prototype.send'), '不篡改请求发送过程');

  stdout.writeln('=== 4. UI 与设置接线 ===');
  final browser = read('lib/ui/browser_tab.dart');
  final settings = read('lib/ui/settings_tab.dart');
  final settingsState = read('lib/state/settings_state.dart');
  final appState = read('lib/state/app_state.dart');

  check(browser.contains("'ClickChannel'"), '注册 ClickChannel');
  check(browser.contains('kClickSniffJs'), '注入点击捕获脚本');
  check(browser.contains('_onClickMessage'), '有消息处理入口');
  check(browser.contains('浮层视频已捕获'), '浮层捕获有浮标文案');
  check(browser.contains('浮层捕获'), '面板有浮层筛选');
  check(browser.contains('clickHints'), '面板展示跨域播放器候选');
  check(browser.contains('点击捕获说明'), '菜单里有说明入口');
  check(settings.contains('点击捕获浮层视频'), '设置页有开关');
  check(settingsState.contains("_kClickCapture = 'click_capture'"), '开关持久化键');
  check(settingsState.contains('_clickCapture = true'), '默认开启');
  check(appState.contains('onClickSniffMessage'), 'AppState 接收点击消息');
  check(appState.contains(r'点击/${event.from.isEmpty'), '归因来源可区分');
  check(appState.contains('_clickHints.clear()'), '换页清空跨域候选');

  stdout.writeln('');
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
