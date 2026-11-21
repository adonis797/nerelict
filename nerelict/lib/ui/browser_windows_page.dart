/// 浏览器多窗口：一次进入会话里可以开多个独立 WebView 窗口。
///
/// 设计取舍（与单窗口主界面刻意分开）：
/// - 每个窗口一个 `WebViewController` + 一份 `BrowserWindow` 快照，用 `IndexedStack`
///   保活，窗口条切换只换 index，不重建别人的 State；
/// - 多窗口是**轻量浏览上下文**：不注入嗅探 / 点击捕获 / 浮层播放脚本。那些脚本
///   依赖 `AppState` 聚合器与 `PageCookieProbe` 等「单一当前页」的全局单例，
///   同时挂到多个 WebView 上会互相串扰；下载与嗅探仍以主界面单窗口为准；
/// - 窗口元数据留在 `WindowsState`，`WebViewController` 由 `BrowserWindowView` 持有，
///   关闭窗口或退出页面时统一走 `_releaseController()`：先换掉导航回调，
///   再卸载到 `about:blank`，让页面里的媒体、定时器和请求停下来。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../models/browser_window.dart';
import '../services/app_log.dart';
import '../state/app_state.dart';
import '../state/history_state.dart';
import '../state/settings_state.dart';
import '../state/window_registry.dart';
import '../state/windows_state.dart';
import 'app_theme.dart';
import 'neon_progress_bar.dart';

/// 多窗口会话的入口。
///
/// [initialUrl] 由主界面传入当前地址，进入后作为第一个窗口打开；为空则显示空状态，
/// 由用户点「新建窗口」。每次 push 都是一份新的 `WindowsState`，退出页面不会留下
/// 后台常驻的 WebView，也不会有跨会话的重复实例。
class BrowserWindowsPage extends StatelessWidget {
  const BrowserWindowsPage({super.key, this.initialUrl});

  final String? initialUrl;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<WindowsState>(
      create: (_) => WindowsState(),
      child: _BrowserWindowsView(initialUrl: initialUrl),
    );
  }
}

class _BrowserWindowsView extends StatefulWidget {
  const _BrowserWindowsView({required this.initialUrl});

  final String? initialUrl;

  @override
  State<_BrowserWindowsView> createState() => _BrowserWindowsViewState();
}

class _BrowserWindowsViewState extends State<_BrowserWindowsView> {
  late final WindowsState _windows;

  /// 窗口 id → controller。控制栏的前进 / 后退 / 刷新按活动窗口从这里取。
  final Map<String, WebViewController> _controllers =
      <String, WebViewController>{};

  /// 已释放的 controller，按对象身份去重：同一个窗口可能被 view 与页面兜底路径
  /// 同时要求释放，重复卸载 `about:blank` 是无意义甚至会抛异常的。
  final Set<WebViewController> _released = <WebViewController>{};

  final TextEditingController _urlCtrl = TextEditingController();
  final FocusNode _urlFocus = FocusNode();
  String? _syncedUrl;
  bool _disposed = false;
  bool _initialOpened = false;

  @override
  void initState() {
    super.initState();
    _windows = context.read<WindowsState>();
    final url = widget.initialUrl;
    if (url != null && url.startsWith('http')) {
      // 放在首帧之后：`open()` 会 notifyListeners，不能在 build 阶段改状态
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _initialOpened) return;
        _initialOpened = true;
        final op = _windows.open(url);
        if (!op.ok) _toast(op.message ?? '无法打开窗口');
      });
    }
  }

  @override
  void dispose() {
    _disposed = true;
    // 兜底：正常路径下每个窗口的 view 会先 dispose 并注销自己的 controller；
    // 万一某次卸载没走到，这里再释放一次，避免留下还在跑的 WebView。
    for (final controller in _controllers.values.toList()) {
      unawaited(_releaseController(controller));
    }
    _controllers.clear();
    _urlCtrl.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    context.read<AppState>().showToast(message);
  }

  void _onControllerReady(String id, WebViewController controller) {
    if (_disposed) return;
    final old = _controllers[id];
    if (old != null && !identical(old, controller)) {
      // 同一个 id 冒出第二个实例属于异常，先释放旧的，不让 WebView 泄漏
      AppLog.instance.w('Windows', '重复实例 $id，释放旧 controller');
      unawaited(_releaseController(old));
    }
    _controllers[id] = controller;
  }

  void _onControllerReleased(String id, WebViewController controller) {
    if (identical(_controllers[id], controller)) _controllers.remove(id);
    unawaited(_releaseController(controller));
  }

  /// 卸载窗口页面。
  ///
  /// 刻意**不**调用 `clearCache()`：Android WebView 的缓存目录是应用级共享的，
  /// 关掉一个窗口会把其它窗口和主界面浏览器的缓存一起清掉。
  Future<void> _releaseController(WebViewController controller) async {
    if (!_released.add(controller)) return;
    // 换掉导航回调：既断开对已销毁 State 的引用，也让 about:blank 不被拦下
    try {
      await controller.setNavigationDelegate(NavigationDelegate());
    } catch (_) {
      // platform view 已经回收时这些方法会抛，忽略即可
    }
    try {
      await controller.loadRequest(Uri.parse('about:blank'));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final state = context.watch<WindowsState>();
    final windows = state.windows;
    final active = state.active;
    _syncUrlBar(active);

    final children = <Widget>[
      for (final w in windows)
        BrowserWindowView(
          // key 必须按窗口 id：IndexedStack 按位置复用 child，移除中间一个窗口时
          // 没有 key 会把旧窗口的 State / controller 错配到新窗口上
          key: ValueKey<String>('browser-window-${w.id}'),
          windowId: w.id,
          initialUrl: w.url,
          onControllerReady: _onControllerReady,
          onControllerReleased: _onControllerReleased,
        ),
    ];
    final index = state.activeIndex;
    final stackIndex = index < 0
        ? 0
        : (index < children.length ? index : children.length - 1);

    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.navBg,
        foregroundColor: p.text,
        title: Text(
          active?.displayTitle ?? '多窗口浏览',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: <Widget>[
          IconButton(
            tooltip: '新建窗口',
            icon: const Icon(Icons.add),
            onPressed: _showNewWindowDialog,
          ),
          if (windows.isNotEmpty)
            IconButton(
              tooltip: '关闭全部窗口',
              icon: const Icon(Icons.clear_all),
              onPressed: _confirmCloseAll,
            ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _buildWindowStrip(p, state, windows),
          _buildUrlBar(p, active),
          _buildToolbar(p, active),
          Expanded(
            child: Stack(
              children: <Widget>[
                if (children.isEmpty)
                  _EmptyWindowsView(onNew: _showNewWindowDialog)
                else
                  IndexedStack(index: stackIndex, children: children),
                if (active?.error != null)
                  Positioned.fill(
                    child: _WindowErrorView(
                      message: active!.error!,
                      onRetry: _retryActive,
                      onNewUrl: () => _urlFocus.requestFocus(),
                    ),
                  ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: NeonProgressBar(
                      value: active?.loading == true
                          ? (active!.progress <= 0 ? null : active.progress)
                          : 1.0,
                      visible: active?.loading == true,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWindowStrip(
    AppPalette p,
    WindowsState state,
    List<BrowserWindow> windows,
  ) {
    return Container(
      height: 46,
      color: p.navBg,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        itemCount: windows.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          if (i == windows.length) {
            return ActionChip(
              avatar: Icon(Icons.add, size: 15, color: p.textSub),
              label: Text('新建', style: TextStyle(fontSize: 12, color: p.textSub)),
              backgroundColor: p.surfaceAlt,
              onPressed: _showNewWindowDialog,
            );
          }
          final w = windows[i];
          final selected = w.id == state.activeId;
          return GestureDetector(
            onTap: () => _windows.activate(w.id),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 168),
              padding: const EdgeInsets.only(left: 12, right: 3),
              decoration: BoxDecoration(
                color: selected
                    ? p.accent.withValues(alpha: 0.18)
                    : p.surfaceAlt,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: selected ? p.accent : p.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Flexible(
                    child: Text(
                      w.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: p.text),
                    ),
                  ),
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _closeWindow(w.id),
                    child: Padding(
                      padding: const EdgeInsets.all(5),
                      child: Icon(Icons.close, size: 14, color: p.textFaint),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildUrlBar(AppPalette p, BrowserWindow? active) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      color: p.bg,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Container(
              height: 40,
              decoration: BoxDecoration(
                color: p.surfaceAlt,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: p.border),
              ),
              padding: const EdgeInsets.only(left: 13, right: 4),
              alignment: Alignment.center,
              child: Row(
                children: <Widget>[
                  Icon(Icons.public, size: 16, color: p.textFaint),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _urlCtrl,
                      focusNode: _urlFocus,
                      enabled: active != null,
                      textInputAction: TextInputAction.go,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      style: TextStyle(fontSize: 13, color: p.text),
                      decoration: InputDecoration(
                        isDense: true,
                        isCollapsed: true,
                        border: InputBorder.none,
                        hintText: '输入网址或搜索',
                        hintStyle:
                            TextStyle(color: p.textFaint, fontSize: 13),
                      ),
                      onSubmitted: _loadInActive,
                    ),
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _urlCtrl,
                    builder: (context, value, _) {
                      if (value.text.isEmpty) return const SizedBox.shrink();
                      return InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => setState(_urlCtrl.clear),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(Icons.cancel,
                              size: 15, color: p.textDisabled),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: '前往',
            constraints: const BoxConstraints.tightFor(width: 38, height: 38),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.arrow_forward, size: 19),
            color: active != null ? p.accent : p.textDisabled,
            onPressed:
                active != null ? () => _loadInActive(_urlCtrl.text) : null,
          ),
        ],
      ),
    );
  }

  Widget _toolButton(
    AppPalette p, {
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return IconButton(
      tooltip: tooltip,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      padding: EdgeInsets.zero,
      icon: Icon(icon, size: 18, color: enabled ? p.textSub : p.textDisabled),
      onPressed: enabled ? onTap : null,
    );
  }

  Widget _buildToolbar(AppPalette p, BrowserWindow? active) {
    final id = active?.id;
    final hasController = id != null && _controllers.containsKey(id);
    return Container(
      height: 44,
      color: p.bg,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: <Widget>[
          _toolButton(
            p,
            icon: Icons.arrow_back,
            tooltip: '后退',
            enabled: active?.canGoBack == true && hasController,
            onTap: () => _act(id, (c) => c.goBack()),
          ),
          _toolButton(
            p,
            icon: Icons.arrow_forward,
            tooltip: '前进',
            enabled: active?.canGoForward == true && hasController,
            onTap: () => _act(id, (c) => c.goForward()),
          ),
          _toolButton(
            p,
            icon: Icons.refresh,
            tooltip: '刷新',
            enabled: hasController,
            onTap: () => _act(id, (c) => c.reload()),
          ),
          const Spacer(),
          Text(
            '${_windows.count} / ${WindowRegistry.maxWindows}',
            style: TextStyle(fontSize: 11, color: p.textFaint),
          ),
          const Spacer(),
          _toolButton(
            p,
            icon: Icons.close,
            tooltip: '关闭当前窗口',
            enabled: active != null,
            onTap: () {
              if (active != null) _closeWindow(active.id);
            },
          ),
        ],
      ),
    );
  }

  void _syncUrlBar(BrowserWindow? active) {
    final expected = active?.url ?? '';
    if (_syncedUrl == expected) return;
    _syncedUrl = expected;
    // 不能在 build 里直接给 TextEditingController.text 赋值：它会 notifyListeners，
    // 触发正在 build 的 TextField 重建。推到帧末再同步。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _syncedUrl != expected) return;
      if (_urlCtrl.text != expected) _urlCtrl.text = expected;
    });
  }

  Future<void> _act(
    String? id,
    Future<void> Function(WebViewController controller) action,
  ) async {
    if (id == null) return;
    final controller = _controllers[id];
    if (controller == null) return;
    try {
      await action(controller);
      await _refreshNav(id, controller);
    } catch (_) {
      _toast('操作失败，请重试');
    }
  }

  Future<void> _refreshNav(String id, WebViewController controller) async {
    try {
      final back = await controller.canGoBack();
      final forward = await controller.canGoForward();
      if (!mounted) return;
      _windows.setNavigation(id, canGoBack: back, canGoForward: forward);
    } catch (_) {}
  }

  Future<void> _performLoad(
    String id,
    WebViewController controller,
    Uri uri,
  ) async {
    try {
      await controller.loadRequest(uri);
      await _refreshNav(id, controller);
    } catch (_) {
      if (!mounted) return;
      _windows.setError(id, '页面加载失败，请检查网址后重试');
    }
  }

  void _loadInActive(String raw) {
    final id = _windows.activeId;
    if (id == null) {
      // 没有窗口时，地址栏输入等价于「用这个地址新建窗口」
      _createWindow(raw);
      return;
    }
    final parsed = normalizeWindowInput(raw);
    if (parsed.isEmpty || parsed.isInvalid) {
      _toast(parsed.message ?? '地址无效');
      return;
    }
    final url = _resolveInput(parsed);
    final controller = _controllers[id];
    if (controller == null) {
      _toast('窗口尚未就绪，请稍后再试');
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      _toast('地址无效');
      return;
    }
    _windows.markStarted(id, url);
    unawaited(_performLoad(id, controller, uri));
  }

  String _resolveInput(WindowInput parsed) {
    if (parsed.isSearch) {
      return context
          .read<SettingsState>()
          .searchEngine
          .searchUrl(parsed.searchTerm ?? '');
    }
    return parsed.url ?? '';
  }

  void _createWindow(String raw) {
    final parsed = normalizeWindowInput(raw);
    if (parsed.isEmpty) {
      final op = _windows.openBlank();
      if (!op.ok) _toast(op.message ?? '无法新建窗口');
      return;
    }
    if (parsed.isInvalid) {
      _toast(parsed.message ?? '地址无效');
      return;
    }
    final op = _windows.open(_resolveInput(parsed));
    if (!op.ok) {
      _toast(op.message ?? '无法新建窗口');
    } else if (op.reused && op.message != null) {
      _toast(op.message!);
    }
  }

  Future<void> _showNewWindowDialog() async {
    if (_windows.isFull) {
      _toast('最多同时打开 ${WindowRegistry.maxWindows} 个窗口，请先关闭一个');
      return;
    }
    final ctrl = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: paletteOf(ctx).surface,
        title: const Text('新建窗口'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textInputAction: TextInputAction.go,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            hintText: '输入网址，留空则新建空白窗口',
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('打开'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (!mounted || input == null) return;
    _createWindow(input);
  }

  void _closeWindow(String id) => _windows.close(id);

  Future<void> _confirmCloseAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('关闭全部窗口'),
        content: Text('将关闭当前 ${_windows.count} 个窗口，浏览状态不会保留。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _windows.closeAll();
  }

  void _retryActive() {
    final id = _windows.activeId;
    final controller = id == null ? null : _controllers[id];
    if (id == null || controller == null) return;
    final url = _windows.byId(id)?.url;
    _windows.clearError(id);
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      _windows.markStarted(id, uri.toString());
      unawaited(_performLoad(id, controller, uri));
    } else {
      unawaited(_reloadOnly(controller));
    }
  }

  Future<void> _reloadOnly(WebViewController controller) async {
    try {
      await controller.reload();
    } catch (_) {}
  }
}

/// 单个窗口的 WebView。控制器由自己创建和持有，关闭时交给页面层统一释放。
class BrowserWindowView extends StatefulWidget {
  const BrowserWindowView({
    super.key,
    required this.windowId,
    required this.initialUrl,
    required this.onControllerReady,
    required this.onControllerReleased,
  });

  final String windowId;

  /// 首次创建时加载的地址；后续导航由 controller 驱动，不再因该值变化重载。
  final String? initialUrl;
  final void Function(String id, WebViewController controller) onControllerReady;
  final void Function(String id, WebViewController controller)
      onControllerReleased;

  @override
  State<BrowserWindowView> createState() => _BrowserWindowViewState();
}

class _BrowserWindowViewState extends State<BrowserWindowView> {
  late final WebViewController _controller;
  late final WindowsState _windows;
  Color? _appliedWebBg;
  bool _disposed = false;

  /// 所有平台回调统一先过这个门：窗口已关闭或页面已销毁时，晚到的回调
  /// 不许再把状态写回一个已经不存在的窗口。
  bool get _alive =>
      !_disposed && mounted && _windows.byId(widget.windowId) != null;

  @override
  void initState() {
    super.initState();
    _windows = context.read<WindowsState>();
    _controller = _buildController();
    widget.onControllerReady(widget.windowId, _controller);
    final url = widget.initialUrl;
    if (url != null && url.isNotEmpty) unawaited(_load(Uri.tryParse(url)));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = paletteOf(context);
    if (_appliedWebBg != p.webBg) {
      _appliedWebBg = p.webBg;
      _controller.setBackgroundColor(p.webBg);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    widget.onControllerReleased(widget.windowId, _controller);
    super.dispose();
  }

  WebViewController _buildController() {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(AppPalette.dark.webBg)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            if (_disposed) return NavigationDecision.prevent;
            final url = request.url;
            // about:blank 是关闭窗口时卸载页面用的，必须放行
            if (url == 'about:blank' ||
                url.startsWith('http://') ||
                url.startsWith('https://')) {
              return NavigationDecision.navigate;
            }
            // 多窗口里不把深链交给系统应用：切出去再回来容易造成窗口状态错乱
            return NavigationDecision.prevent;
          },
          onPageStarted: (url) {
            if (_alive) _windows.markStarted(widget.windowId, url);
          },
          onProgress: (progress) {
            if (!_alive) return;
            final next = (progress / 100).clamp(0.0, 1.0).toDouble();
            final current = _windows.byId(widget.windowId)?.progress ?? 0;
            // 与主界面一致：进度每变化 2% 才刷新，避免整页高频重建
            if ((next - current).abs() < 0.02 && next < 1.0) return;
            _windows.setProgress(widget.windowId, next);
          },
          onPageFinished: (url) async {
            if (!_alive) return;
            String? title;
            try {
              title = await _controller.getTitle();
            } catch (_) {}
            if (!_alive) return;
            _windows.markFinished(widget.windowId, title);
            await _refreshNav();
            await _recordHistory(url, title);
          },
          onUrlChange: (change) {
            final url = change.url;
            if (url == null || !_alive) return;
            _windows.setUrl(widget.windowId, url);
            // SPA 用 pushState 换地址时不触发 onPageFinished，补读一次标题
            unawaited(_syncTitleFromJs());
          },
          onWebResourceError: (error) {
            if (!_alive || error.isForMainFrame != true) return;
            final raw = error.description.trim();
            final brief = raw.length > 80 ? '${raw.substring(0, 80)}…' : raw;
            _windows.setError(
              widget.windowId,
              brief.isEmpty ? '页面加载失败' : '页面加载失败：$brief',
            );
          },
        ),
      );

    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      platform.setMediaPlaybackRequiresUserGesture(false);
      platform.setAllowFileAccess(false);
    }
    return controller;
  }

  Future<void> _load(Uri? uri) async {
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      if (_alive) {
        _windows.setError(widget.windowId, '地址无效，请重新输入');
      }
      return;
    }
    if (_alive) _windows.markStarted(widget.windowId, uri.toString());
    try {
      await _controller.loadRequest(uri);
      await _refreshNav();
    } catch (_) {
      if (_alive) {
        _windows.setError(widget.windowId, '页面加载失败，请检查网址后重试');
      }
    }
  }

  Future<void> _refreshNav() async {
    try {
      final back = await _controller.canGoBack();
      final forward = await _controller.canGoForward();
      if (!_alive) return;
      _windows.setNavigation(
        widget.windowId,
        canGoBack: back,
        canGoForward: forward,
      );
    } catch (_) {}
  }

  /// 标题同步的第二条路：`getTitle()` 只在 onPageFinished 触发，
  /// 单页应用换路由时标题变了却不会回调，这里用 `document.title` 补一次。
  Future<void> _syncTitleFromJs() async {
    try {
      final result =
          await _controller.runJavaScriptReturningResult('document.title');
      if (!_alive) return;
      var title = result.toString().trim();
      // Android 的 evaluateJavascript 会返回带引号的 JSON 字符串
      if (title.length >= 2 && title.startsWith('"') && title.endsWith('"')) {
        title = title.substring(1, title.length - 1);
      }
      if (title.isNotEmpty && title != 'null' && title != 'undefined') {
        _windows.setTitle(widget.windowId, title);
      }
    } catch (_) {}
  }

  Future<void> _recordHistory(String url, String? title) async {
    if (!url.startsWith('http') || !mounted) return;
    try {
      await context.read<HistoryState>().add(url, title ?? '');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}

class _EmptyWindowsView extends StatelessWidget {
  const _EmptyWindowsView({required this.onNew});

  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.tab, size: 48, color: p.textFaint),
          const SizedBox(height: 16),
          Text('还没有打开的窗口',
              style: TextStyle(color: p.textSub, fontSize: 14)),
          const SizedBox(height: 8),
          Text('每个窗口独立加载网址，互不干扰',
              style: TextStyle(color: p.textFaint, fontSize: 12)),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onNew,
            icon: const Icon(Icons.add),
            label: const Text('新建窗口'),
          ),
        ],
      ),
    );
  }
}

class _WindowErrorView extends StatelessWidget {
  const _WindowErrorView({
    required this.message,
    required this.onRetry,
    required this.onNewUrl,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onNewUrl;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Container(
      color: p.bg,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.error_outline, size: 42, color: p.textFaint),
          const SizedBox(height: 14),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: p.textSub, fontSize: 13),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FilledButton(onPressed: onRetry, child: const Text('重试')),
              const SizedBox(width: 10),
              OutlinedButton(
                  onPressed: onNewUrl, child: const Text('换个网址')),
            ],
          ),
        ],
      ),
    );
  }
}
