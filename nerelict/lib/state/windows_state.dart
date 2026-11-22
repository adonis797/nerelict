import 'package:flutter/foundation.dart';

import '../models/browser_window.dart';
import 'window_registry.dart';

/// 多窗口的 provider 状态：只负责「状态变了通知 UI」，转换逻辑全在 [WindowRegistry]。
///
/// 窗口元数据刻意做得比 WebView 轻：退出多窗口页时 `WebViewController` 会被释放，
/// 但窗口快照保留下来，下次进入页面按 `BrowserWindow.url` 恢复加载，
/// 既不会留下后台常驻的 WebView，也不会出现「窗口还在、页面是空的」僵尸状态。
class WindowsState extends ChangeNotifier {
  final WindowRegistry _registry = WindowRegistry();
  bool _disposed = false;

  List<BrowserWindow> get windows => _registry.windows;
  Set<String> get releasedIds => _registry.releasedIds;
  int get count => _registry.count;
  bool get isFull => _registry.isFull;
  String? get activeId => _registry.activeId;
  BrowserWindow? get active => _registry.active;
  int get activeIndex => _registry.activeIndex;

  BrowserWindow? byId(String? id) => _registry.byId(id);

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  WindowOp open(String url, {String? title}) {
    final op = _registry.open(url, title: title);
    _changed();
    return op;
  }

  WindowOp openBlank() {
    final op = _registry.openBlank();
    _changed();
    return op;
  }

  bool activate(String id) {
    final changed = _registry.activate(id);
    if (changed) _changed();
    return changed;
  }

  bool close(String id) {
    final changed = _registry.close(id);
    if (changed) _changed();
    return changed;
  }

  /// 关闭全部窗口。返回被关闭的 id，供 UI 层兜底释放残留的 controller。
  List<String> closeAll() {
    final ids = _registry.closeAll();
    if (ids.isNotEmpty) _changed();
    return ids;
  }

  bool markStarted(String id, String url) {
    final changed = _registry.markStarted(id, url);
    if (changed) _changed();
    return changed;
  }

  bool setTitle(String id, String? title) {
    final changed = _registry.setTitle(id, title);
    if (changed) _changed();
    return changed;
  }

  bool setUrl(String id, String url) {
    final changed = _registry.setUrl(id, url);
    if (changed) _changed();
    return changed;
  }

  bool setProgress(String id, double progress) {
    final changed = _registry.setProgress(id, progress);
    if (changed) _changed();
    return changed;
  }

  bool markFinished(String id, String? title) {
    final changed = _registry.markFinished(id, title);
    if (changed) _changed();
    return changed;
  }

  bool setError(String id, String message) {
    final changed = _registry.setError(id, message);
    if (changed) _changed();
    return changed;
  }

  bool clearError(String id) {
    final changed = _registry.clearError(id);
    if (changed) _changed();
    return changed;
  }

  /// 回到首页：地址、标题、前进后退都清空，窗口保留。
  bool goHome(String id) {
    final changed = _registry.goHome(id);
    if (changed) _changed();
    return changed;
  }

  bool setNavigation(
    String id, {
    required bool canGoBack,
    required bool canGoForward,
  }) {
    final changed = _registry.setNavigation(
      id,
      canGoBack: canGoBack,
      canGoForward: canGoForward,
    );
    if (changed) _changed();
    return changed;
  }

  @override
  void dispose() {
    _disposed = true;
    // 应用退出 / Provider 销毁：静默清空，销毁阶段不再通知监听者
    _registry.closeAll();
    super.dispose();
  }
}
