/// 多窗口注册表：所有窗口状态转换的纯逻辑层。
///
/// 这里不持有 `WebViewController`，也不认识 Flutter；`WindowsState` 只是把它
/// 包成 `ChangeNotifier` 通知 UI。这样窗口的去重、上限、隔离与关闭顺序都能被
/// `tool/verify_windows.dart` 用 `dart run` 直接验证。
///
/// 三条硬约束：
/// 1. 每个窗口是不可变快照，更新时整体替换，绝不会「顺手改到」别的窗口；
/// 2. 同一地址不重复开窗，命中已有窗口时只激活并回报 `reused`；
/// 3. 关闭是幂等的，已关闭的 id 会被记进 `releasedIds`，后续写操作全部静默忽略，
///    避免 WebView 回调晚到时把状态写回已销毁的窗口。
library;

import '../models/browser_window.dart';

/// 一次窗口操作的结果。`ok` 为假时 [message] 是给用户看的中文提示。
class WindowOp {
  const WindowOp(this.ok, {this.id, this.message, this.reused = false});

  final bool ok;
  final String? id;
  final String? message;

  /// 是否命中了「同地址已有窗口」而没有新建。
  final bool reused;
}

class WindowRegistry {
  /// 同时保活的 WebView 上限。每个窗口都是一个真实的 Android WebView 实例，
  /// 无节制开窗会直接推高内存，低端机还可能被系统回收后台实例。
  static const int maxWindows = 5;

  final List<BrowserWindow> _windows = <BrowserWindow>[];
  final Set<String> _released = <String>{};
  String? _activeId;
  int _seq = 0;

  List<BrowserWindow> get windows => List.unmodifiable(_windows);
  Set<String> get releasedIds => Set.unmodifiable(_released);
  int get count => _windows.length;
  bool get isFull => _windows.length >= maxWindows;
  String? get activeId => _activeId;

  BrowserWindow? get active => byId(_activeId);

  int get activeIndex {
    if (_activeId == null) return -1;
    return _windows.indexWhere((w) => w.id == _activeId);
  }

  BrowserWindow? byId(String? id) {
    if (id == null) return null;
    for (final w in _windows) {
      if (w.id == id) return w;
    }
    return null;
  }

  /// 打开一个指定地址的窗口。同地址已经有窗口时只激活它，不产生第二个实例。
  WindowOp open(String url, {String? title}) {
    final key = windowUrlKey(url);
    for (final w in _windows) {
      final existing = w.url;
      if (existing != null && windowUrlKey(existing) == key) {
        _activeId = w.id;
        return WindowOp(true, id: w.id, message: '已切换到已有窗口', reused: true);
      }
    }
    if (isFull) {
      return const WindowOp(
        false,
        message: '最多同时打开 $maxWindows 个窗口，请先关闭一个',
      );
    }
    final id = 'w${++_seq}';
    _windows.add(BrowserWindow(
      id: id,
      createdAt: DateTime.now(),
      url: url,
      title: title,
      phase: WindowPhase.loading,
      loading: true,
    ));
    _activeId = id;
    return WindowOp(true, id: id, message: '已打开新窗口');
  }

  /// 打开一个空白窗口，由用户随后在地址栏输入网址。空白窗口不参与去重。
  WindowOp openBlank() {
    if (isFull) {
      return const WindowOp(
        false,
        message: '最多同时打开 $maxWindows 个窗口，请先关闭一个',
      );
    }
    final id = 'w${++_seq}';
    _windows.add(BrowserWindow(id: id, createdAt: DateTime.now()));
    _activeId = id;
    return WindowOp(true, id: id, message: '已打开空白窗口');
  }

  bool activate(String id) {
    if (byId(id) == null || _activeId == id) return false;
    _activeId = id;
    return true;
  }

  /// 关闭窗口并重新挑选活动窗口：优先继承被关闭位置的下一个，否则退回前一个。
  /// 重复关闭同一个 id 只会返回 false，不会再动列表或活动窗口。
  bool close(String id) {
    final index = _windows.indexWhere((w) => w.id == id);
    if (index < 0) return false;
    final wasActive = _activeId == id;
    _windows.removeAt(index);
    _released.add(id);
    if (wasActive) {
      _activeId = _windows.isEmpty
          ? null
          : _windows[index < _windows.length ? index : _windows.length - 1].id;
    } else if (_activeId != null && byId(_activeId) == null) {
      _activeId = _windows.isEmpty ? null : _windows.last.id;
    }
    return true;
  }

  /// 关闭全部窗口，返回被关闭的 id，供 UI 层逐个释放 WebView 资源。
  List<String> closeAll() {
    final ids = _windows.map((w) => w.id).toList();
    _released.addAll(ids);
    _windows.clear();
    _activeId = null;
    return ids;
  }

  /// 通用状态更新。窗口不存在时返回 false，不抛异常。
  bool update(String id, BrowserWindow Function(BrowserWindow current) transform) {
    final index = _windows.indexWhere((w) => w.id == id);
    if (index < 0) return false;
    _windows[index] = transform(_windows[index]);
    return true;
  }

  /// 页面开始加载：清掉上一条错误、把标题先回落成域名，进度归零。
  bool markStarted(String id, String url) {
    final host = Uri.tryParse(url)?.host;
    return update(
      id,
      (w) => w.copyWith(
        url: url,
        title: (host != null && host.isNotEmpty) ? host : w.title,
        phase: WindowPhase.loading,
        progress: 0,
        loading: true,
        error: null,
      ),
    );
  }

  bool setTitle(String id, String? title) {
    final t = title?.trim();
    if (t == null || t.isEmpty) return false;
    return update(id, (w) => w.copyWith(title: t));
  }

  bool setUrl(String id, String url) {
    return update(id, (w) => w.copyWith(url: url));
  }

  bool setProgress(String id, double progress) {
    final value = progress.clamp(0.0, 1.0).toDouble();
    return update(id, (w) => w.copyWith(progress: value));
  }

  bool markFinished(String id, String? title) {
    final t = title?.trim();
    return update(id, (w) {
      // 只在拿到有效标题时覆盖；`getTitle()` 偶尔返回空，此时保留域名占位标题
      final base = w.copyWith(
        phase: WindowPhase.ready,
        progress: 1,
        loading: false,
        error: null,
      );
      return (t != null && t.isNotEmpty) ? base.copyWith(title: t) : base;
    });
  }

  bool setError(String id, String message) {
    return update(
      id,
      (w) => w.copyWith(
        phase: WindowPhase.error,
        loading: false,
        error: message,
      ),
    );
  }

  bool clearError(String id) {
    return update(
      id,
      (w) => w.copyWith(phase: WindowPhase.blank, error: null),
    );
  }

  bool setNavigation(
    String id, {
    required bool canGoBack,
    required bool canGoForward,
  }) {
    return update(
      id,
      (w) => w.copyWith(canGoBack: canGoBack, canGoForward: canGoForward),
    );
  }
}
