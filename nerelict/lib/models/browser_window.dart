/// 浏览器多窗口：一个窗口的不可变状态快照，以及地址输入的归一化。
///
/// 刻意不引入 `package:flutter`：窗口的创建、去重、状态隔离与关闭都是纯逻辑，
/// `tool/verify_windows.dart` 可以直接用 `dart run` 验证，不需要 Flutter 引擎。
/// 窗口对应的 `WebViewController` 由 UI 层按 [BrowserWindow.id] 单独持有，
/// 不进模型，避免把平台对象带进可测试的状态层。
library;

/// 窗口当前所处的阶段。
enum WindowPhase {
  /// 刚创建、还没有加载任何地址。
  blank,

  /// 正在加载。
  loading,

  /// 页面已加载完成。
  ready,

  /// 主框架加载失败。
  error,
}

/// 地址栏输入的种类。
enum WindowInputKind {
  /// 可以直接交给 WebView 的 http(s) 地址。
  url,

  /// 搜索词，由 UI 层按当前搜索引擎转成地址。
  search,

  /// 空输入。
  empty,

  /// 非法地址（例如自定义 scheme）。
  invalid,
}

/// 一次「输入网址」的归一化结果。
class WindowInput {
  const WindowInput._({
    required this.kind,
    this.url,
    this.searchTerm,
    this.message,
  });

  final WindowInputKind kind;

  /// 归一化后的 http(s) 地址，仅 [WindowInputKind.url] 时有值。
  final String? url;

  /// 原始搜索词，仅 [WindowInputKind.search] 时有值。
  final String? searchTerm;

  /// 面向用户的提示，空输入与非法地址时有值。
  final String? message;

  bool get isUrl => kind == WindowInputKind.url;
  bool get isSearch => kind == WindowInputKind.search;
  bool get isEmpty => kind == WindowInputKind.empty;
  bool get isInvalid => kind == WindowInputKind.invalid;
}

/// 把地址栏输入解析成可加载的地址。
///
/// 规则与主界面 `_open()` 保持一致：带空格、或不含 `.` 的输入按搜索词处理；
/// 没写 scheme 时补 `https://`。只放行 http/https，`intent://`、`javascript:`
/// 这类自定义 scheme 明确拒绝，免得把深链直接交给 WebView。
WindowInput normalizeWindowInput(String raw) {
  final text = raw.trim();
  if (text.isEmpty) {
    return const WindowInput._(
      kind: WindowInputKind.empty,
      message: '请输入网址',
    );
  }

  // 形如 `intent://` / `ftp://` 的输入，即使带点也不是网页。
  // 只拦带 `//` 的自定义 scheme：`localhost:8080` 这类本机地址仍按主界面规则
  // 处理（无点即搜索词），`javascript:alert(1)` 同理，不会被交给 WebView。
  final schemeWithSlashes = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://');
  final lower = text.toLowerCase();
  if (schemeWithSlashes.hasMatch(text) &&
      !lower.startsWith('http://') &&
      !lower.startsWith('https://')) {
    return const WindowInput._(
      kind: WindowInputKind.invalid,
      message: '仅支持 http / https 网址',
    );
  }

  final hasScheme = text.contains('://');
  final looksLikeUrl = !text.contains(' ') && (hasScheme || text.contains('.'));
  if (!looksLikeUrl) {
    return WindowInput._(kind: WindowInputKind.search, searchTerm: text);
  }

  final candidate = hasScheme ? text : 'https://$text';
  final uri = Uri.tryParse(candidate);
  final scheme = uri?.scheme.toLowerCase() ?? '';
  if (uri == null ||
      uri.host.isEmpty ||
      (scheme != 'http' && scheme != 'https')) {
    return const WindowInput._(
      kind: WindowInputKind.invalid,
      message: '仅支持 http / https 网址',
    );
  }
  return WindowInput._(kind: WindowInputKind.url, url: uri.toString());
}

/// 窗口去重用的地址键：忽略协议外的大小写、末尾斜杠与 fragment。
///
/// 保留 query：`?a=1` 与 `?a=2` 是两个不同页面，不该被误判成重复窗口。
String windowUrlKey(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return url.trim().toLowerCase();
  final path = uri.path.endsWith('/') && uri.path.length > 1
      ? uri.path.substring(0, uri.path.length - 1)
      : uri.path;
  final port = uri.hasPort ? ':${uri.port}' : '';
  final query = uri.query.isEmpty ? '' : '?${uri.query}';
  return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}$port$path$query';
}

/// 一个窗口的状态快照。字段全部 `final`，更新时由 `WindowRegistry` 整体替换，
/// 这样「改一个窗口不会影响另一个窗口」是数据结构层面的保证，而不是约定。
class BrowserWindow {
  const BrowserWindow({
    required this.id,
    required this.createdAt,
    this.url,
    this.title,
    this.phase = WindowPhase.blank,
    this.progress = 0,
    this.loading = false,
    this.canGoBack = false,
    this.canGoForward = false,
    this.error,
  });

  final String id;
  final DateTime createdAt;

  /// 窗口当前地址；也是下次进入多窗口页时恢复加载的依据。
  final String? url;

  /// 页面标题，由 `getTitle()` 与 `document.title` 同步进来。
  final String? title;
  final WindowPhase phase;
  final double progress;
  final bool loading;
  final bool canGoBack;
  final bool canGoForward;

  /// 主框架加载失败时的人话提示；非空即显示错误页。
  final String? error;

  /// 是不是停在首页（新窗口，或点了「首页」）。
  ///
  /// 首页由 UI 层画，不加载任何远端页面：地址为空即首页。
  bool get isHome => url == null || url!.isEmpty;

  /// 窗口条与标题栏用的显示名：优先页面标题，其次域名，最后「新标签页」。
  String get displayTitle {
    final t = title?.trim();
    if (t != null && t.isNotEmpty) return t;
    if (isHome) return '新标签页';
    final u = url;
    if (u != null && u.isNotEmpty) {
      final host = Uri.tryParse(u)?.host;
      if (host != null && host.isNotEmpty) return host;
      return u;
    }
    return '新标签页';
  }

  BrowserWindow copyWith({
    String? id,
    DateTime? createdAt,
    Object? url = _kUnset,
    Object? title = _kUnset,
    WindowPhase? phase,
    double? progress,
    bool? loading,
    bool? canGoBack,
    bool? canGoForward,
    Object? error = _kUnset,
  }) {
    return BrowserWindow(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      url: identical(url, _kUnset) ? this.url : url as String?,
      title: identical(title, _kUnset) ? this.title : title as String?,
      phase: phase ?? this.phase,
      progress: progress ?? this.progress,
      loading: loading ?? this.loading,
      canGoBack: canGoBack ?? this.canGoBack,
      canGoForward: canGoForward ?? this.canGoForward,
      error: identical(error, _kUnset) ? this.error : error as String?,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'url': url,
        'title': title,
        'phase': phase.index,
        'progress': progress,
        'loading': loading,
        'canGoBack': canGoBack,
        'canGoForward': canGoForward,
        'error': error,
      };

  factory BrowserWindow.fromJson(Map<String, Object?> json) {
    final phaseIndex = json['phase'];
    return BrowserWindow(
      id: json['id'] as String? ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        json['createdAt'] as int? ?? 0,
      ),
      url: json['url'] as String?,
      title: json['title'] as String?,
      phase: phaseIndex is int && phaseIndex >= 0 && phaseIndex < WindowPhase.values.length
          ? WindowPhase.values[phaseIndex]
          : WindowPhase.blank,
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      loading: json['loading'] as bool? ?? false,
      canGoBack: json['canGoBack'] as bool? ?? false,
      canGoForward: json['canGoForward'] as bool? ?? false,
      error: json['error'] as String?,
    );
  }

  /// 区分「不传这个参数」与「传 null 清空该字段」。
  static const Object _kUnset = Object();
}
