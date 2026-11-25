// 运行：dart run tool/verify_windows.dart
// 覆盖：地址归一化与去重键、窗口注册表（创建 / 去重 / 上限 / 状态隔离 / 错误态 /
//       幂等关闭 / 资源释放标记）、窗口模型序列化，以及 UI 层源码护栏。
// 纯 Dart，不依赖 Flutter 引擎与公网。
import 'dart:io';

import 'package:nerelict/models/browser_window.dart';
import 'package:nerelict/state/window_registry.dart';

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

String read(String relative) => File(relative).readAsStringSync();

void main() {
  stdout.writeln('=== 1. 地址归一化 ===');
  final trimmed = normalizeWindowInput('  https://a.example/p  ');
  check(trimmed.isUrl && trimmed.url == 'https://a.example/p', '去掉首尾空白');
  final noScheme = normalizeWindowInput('a.example/p');
  check(noScheme.isUrl && noScheme.url == 'https://a.example/p', '没写 scheme 补 https');
  final upperScheme = normalizeWindowInput('HTTPS://a.example/p');
  check(upperScheme.isUrl, '大写 scheme 也放行');
  check(normalizeWindowInput('').isEmpty, '空输入标为空');
  check(normalizeWindowInput('   ').isEmpty, '纯空白标为空');
  check(normalizeWindowInput('hello world').isSearch, '带空格按搜索词');
  check(normalizeWindowInput('flutter').isSearch, '不含点按搜索词');
  check(normalizeWindowInput('intent://a.example').isInvalid, '拒绝 intent 深链');
  check(normalizeWindowInput('ftp://a.example').isInvalid, '拒绝非 http(s) 协议');
  check(normalizeWindowInput('javascript:alert(1)').isInvalid == false &&
          normalizeWindowInput('javascript:alert(1)').isSearch,
      '危险脚本不交给 WebView，降级成搜索词');
  check(normalizeWindowInput('https://').isInvalid, '缺 host 判为非法');
  check(normalizeWindowInput('http://127.0.0.1:8080/a').isUrl, '本机调试地址可用');

  stdout.writeln('=== 2. 地址去重键 ===');
  check(
    windowUrlKey('https://A.example/p/') == windowUrlKey('https://a.example/p'),
    '忽略 host 大小写与末尾斜杠',
  );
  check(
    windowUrlKey('https://a.example/p#frag') ==
        windowUrlKey('https://a.example/p'),
    '忽略 fragment',
  );
  check(
    windowUrlKey('https://a.example/p?a=1') !=
        windowUrlKey('https://a.example/p?a=2'),
    'query 不同不合并',
  );
  check(
    windowUrlKey('https://a.example:8080/p') !=
        windowUrlKey('https://a.example/p'),
    '端口不同不合并',
  );
  check(
    windowUrlKey('http://a.example/p') != windowUrlKey('https://a.example/p'),
    '协议不同不合并',
  );

  stdout.writeln('=== 3. 创建 / 去重 / 上限 ===');
  final r = WindowRegistry();
  check(r.count == 0 && r.activeId == null && r.activeIndex == -1, '初始为空');
  final first = r.open('https://a.example/a');
  check(first.ok && first.id == 'w1' && !first.reused, '打开第一个窗口');
  final reused = r.open('https://a.example/a/#frag');
  check(reused.ok && reused.reused && reused.id == 'w1', '同地址只激活不新建');
  check(r.count == 1, '去重后窗口数不变');
  final second = r.open('https://b.example/b');
  check(second.ok && r.count == 2 && r.activeIndex == 1, '打开第二个窗口并激活');
  check(r.active?.id == 'w2', '活动窗口指向新窗口');
  final blank = r.openBlank();
  check(blank.ok && r.count == 3, '空白窗口可创建');
  check(r.openBlank().ok, '空白窗口不参与地址去重');

  stdout.writeln('=== 4. 状态隔离 ===');
  final bBefore = r.byId('w2');
  r.markStarted('w1', 'https://a.example/new');
  r.setTitle('w1', '标题一');
  r.setError('w1', '页面加载失败');
  final bAfter = r.byId('w2');
  check(identical(bBefore, bAfter), '改窗口 A 不替换窗口 B 的快照对象');
  check(bAfter?.phase == WindowPhase.loading, '窗口 B 阶段不受影响');
  check(bAfter?.error == null, '窗口 B 错误态不受影响');
  check(bAfter?.title != '标题一', '窗口 B 标题不受影响');
  final a = r.byId('w1')!;
  check(a.phase == WindowPhase.error && a.error == '页面加载失败' && !a.loading,
      '窗口 A 进入错误态且停止 loading');
  r.markStarted('w1', 'https://a.example/new');
  check(r.byId('w1')!.error == null, '重新加载会清掉旧错误');
  r.markFinished('w1', null);
  check(r.byId('w1')!.title == 'a.example', '空标题时保留域名占位标题');
  r.setTitle('w1', '标题一');
  r.markFinished('w1', '  新标题  ');
  final finished = r.byId('w1')!;
  check(finished.title == '新标题', '标题同步去掉首尾空白');
  check(finished.phase == WindowPhase.ready && finished.progress == 1 &&
          !finished.loading, '加载完成收敛到 ready');
  r.setProgress('w1', 1.8);
  check(r.byId('w1')!.progress == 1.0, '进度上限钳到 1.0');
  r.setProgress('w1', -0.3);
  check(r.byId('w1')!.progress == 0.0, '进度下限钳到 0.0');
  r.setNavigation('w1', canGoBack: true, canGoForward: false);
  check(r.byId('w1')!.canGoBack && !r.byId('w1')!.canGoForward,
      '前进后退标志按窗口保存');

  stdout.writeln('=== 5. 关闭 / 生命周期 / 幂等 ===');
  final activeBefore = r.activeId;
  check(r.close('w1'), '关闭非活动窗口返回 true');
  check(r.activeId == activeBefore, '关闭非活动窗口不改变活动窗口');
  check(!r.close('w1'), '重复关闭返回 false');
  check(r.releasedIds.contains('w1'), '被关闭的 id 记入释放集合');
  check(!r.setError('w1', '晚到的回调'), '已关闭窗口拒绝写状态');
  check(!r.markStarted('w1', 'https://a.example'), '已关闭窗口拒绝重新加载');
  check(!r.activate('w1'), '已关闭窗口无法激活');
  check(r.close(r.activeId!), '关闭活动窗口');
  check(r.active != null && r.activeIndex >= 0 && r.active!.id != 'w4',
      '活动窗口自动切到剩余窗口');
  final closed = r.closeAll();
  check(closed.isNotEmpty, 'closeAll 返回被关闭的 id');
  check(r.count == 0 && r.activeId == null && r.activeIndex == -1, '全部关闭后为空');
  check(r.closeAll().isEmpty, '空注册表 closeAll 幂等');
  check(r.releasedIds.length >= 4, '所有窗口都有释放记录');

  stdout.writeln('=== 6. 窗口数量上限 ===');
  final full = WindowRegistry();
  for (var i = 0; i < WindowRegistry.maxWindows; i++) {
    check(full.open('https://s$i.example/').ok, '第 ${i + 1} 个窗口可创建');
  }
  check(full.isFull, '达到上限后 isFull 为真');
  final overflow = full.open('https://overflow.example/');
  check(!overflow.ok, '超过上限拒绝创建');
  check((overflow.message ?? '').contains('最多同时打开'), '给出中文上限提示');
  check(full.count == WindowRegistry.maxWindows, '上限检查不新增窗口');
  check(!full.openBlank().ok, '空白窗口同样受上限约束');
  check(full.close('w1') && full.open('https://new.example/').ok,
      '关闭一个后又能新建');

  stdout.writeln('=== 7. 模型 ===');
  final t = DateTime.fromMillisecondsSinceEpoch(1700000000000);
  check(BrowserWindow(id: 'x', createdAt: t, url: 'https://a.example/p')
          .displayTitle ==
      'a.example', '无标题时显示域名');
  check(BrowserWindow(id: 'x', createdAt: t).displayTitle == '新标签页',
      '空白窗口显示「新标签页」');
  check(BrowserWindow(id: 'x', createdAt: t).isHome, '地址为空即首页');
  check(!BrowserWindow(id: 'x', createdAt: t, url: 'https://a.example').isHome,
      '有地址就不是首页');

  stdout.writeln('=== 7b. 回首页 ===');
  final home = WindowRegistry();
  final homeOp = home.open('https://a.example/p');
  home.setTitle(homeOp.id!, '页面标题');
  home.markFinished(homeOp.id!, '页面标题');
  home.setNavigation(homeOp.id!, canGoBack: true, canGoForward: true);
  check(home.goHome(homeOp.id!), '可以把窗口退回首页');
  final homeWindow = home.byId(homeOp.id!)!;
  check(homeWindow.isHome && homeWindow.url == null, '回首页后地址清空');
  check(homeWindow.title == null && !homeWindow.canGoBack && !homeWindow.canGoForward,
      '回首页后标题与前进后退状态一起清空');
  check(homeWindow.displayTitle == '新标签页', '回首页后显示名回到新标签页');
  check(!home.goHome('不存在'), '对不存在的窗口回首页不抛异常');
  check(BrowserWindow(id: 'x', createdAt: t, title: '  页面  ')
          .displayTitle ==
      '页面', '标题优先且去空白');
  final model = BrowserWindow(
    id: 'x',
    createdAt: t,
    url: 'https://a.example',
    title: '标题',
    phase: WindowPhase.error,
    progress: 0.5,
    loading: true,
    canGoBack: true,
    error: '失败',
  );
  final restored = BrowserWindow.fromJson(model.toJson());
  check(
    restored.id == 'x' &&
        restored.title == '标题' &&
        restored.error == '失败' &&
        restored.phase == WindowPhase.error &&
        restored.progress == 0.5 &&
        restored.loading &&
        restored.canGoBack &&
        restored.createdAt.millisecondsSinceEpoch ==
            t.millisecondsSinceEpoch,
    'toJson / fromJson 往返不丢字段',
  );
  check(model.copyWith().error == '失败', 'copyWith 不传参数保留字段');
  check(model.copyWith(error: null).error == null, 'copyWith 传 null 能清空错误');
  check(model.copyWith(url: null).url == null, 'copyWith 传 null 能清空地址');

  stdout.writeln('=== 8. 源码护栏 ===');
  final page = read('lib/ui/browser_windows_page.dart');
  final tab = read('lib/ui/browser_tab.dart');
  final registrySrc = read('lib/state/window_registry.dart');
  final modelSrc = read('lib/models/browser_window.dart');
  check(page.contains("ValueKey<String>('browser-window-"),
      'IndexedStack 子项按窗口 id 加 key，避免 State 错配');
  check(page.contains('setNavigationDelegate(NavigationDelegate())'),
      '关闭窗口时断开导航回调');
  check(page.contains("Uri.parse('about:blank')"), '关闭窗口时卸载页面');
  check(!page.contains('controller.clearCache()'),
      '不调用 clearCache，避免清掉其它窗口的共享缓存');
  check(page.contains('bool get _alive'), '平台回调有生命周期守卫');
  check(page.contains('_released.add(controller)'), 'controller 释放按身份去重');
  check(!page.contains('SniffChannel') && !page.contains('kSniffJs'),
      '多窗口不注入嗅探脚本，避免全局单例串扰');
  check(page.contains('_windows.openBlank()') && !page.contains('_showNewWindowDialog'),
      '新建窗口直接落在首页，不再先弹「输入网址」对话框');
  check(page.contains('_WindowHomeView'), '空白窗口显示原生首页（搜索框 + 常用站点）');
  check(page.contains('_showWindowManager'), '窗口列表以卡片总览呈现');
  check(page.contains("case 'home':") || page.contains('_goHomeActive'),
      '能把窗口退回首页');
  check(page.contains('_isBlank'), 'about:blank 不写回窗口地址，首页状态不被覆盖');
  check(page.contains('_buildBottomBar') && page.contains("label: '后退'"),
      '底部工具条提供后退 / 前进 / 首页 / 窗口 / 关闭');
  check(tab.contains('BrowserWindowsPage(initialUrl: _currentUrl)'),
      '主界面把当前地址带进多窗口页');
  check(tab.contains('_openingWindows'), '多窗口入口有重复 push 防抖');
  check(
      tab.contains('_buildHomeHeader') &&
          tab.contains('onPressed: _openWindows'),
      '首页把多窗口入口收进标题栏，不再占一张通栏卡压首屏');
  check(
      tab.contains('WindowRegistry.maxWindows') &&
          !tab.contains('_WindowsEntryCard'),
      '标题栏提示的上限取自 WindowRegistry，首页不再有第二张多窗口卡');
  check(!registrySrc.contains("import 'package:flutter") &&
          !modelSrc.contains("import 'package:flutter"),
      '状态层与模型层保持纯 Dart，可被 dart run 直接测试');

  stdout.writeln('');
  if (failures.isEmpty) {
    stdout.writeln('全部通过：$passed 项断言');
  } else {
    stdout.writeln('通过 $passed 项，失败 ${failures.length} 项：');
    for (final f in failures) {
      stdout.writeln('  - $f');
    }
    exitCode = 1;
  }
}
