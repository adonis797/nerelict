/// 播放期间的网页弹窗守卫。
///
/// 应用内播放器是 Flutter 浮层，网页自己的浮层广告盖不到它；但页面仍会继续跑，
/// 常见骚扰是「播放到一半，页面弹一个 window.open / alert，或者直接跳走」。
/// 系统级弹窗（WebView 的 JS 对话框）会压到播放器上面，用户点按钮时点到的是
/// 弹窗而不是播放器——这就是「点不到播放按钮」最常见的成因之一。
///
/// 这里在**播放期间**接管四个出口，播放器关闭立刻还原：
/// `window.open`（新窗口 / 广告弹窗）、`alert` / `confirm` / `prompt`（原生对话框）。
/// 只接管这四个，不动 `location`、不动事件、不动 DOM，因此不影响页面正常渲染与播放。
const String kPlaybackGuardJs = r'''
(function () {
  try {
    if (window.__nerelictGuard) return;
    var w = window;
    var orig = {
      open: w.open,
      alert: w.alert,
      confirm: w.confirm,
      prompt: w.prompt
    };
    w.__nerelictGuard = { orig: orig, blocked: 0 };

    // 广告弹窗：直接吞掉，返回 null 等价于用户浏览器拦截了弹窗
    w.open = function () {
      try { w.__nerelictGuard.blocked++; } catch (e) {}
      return null;
    };
    // 原生对话框会盖住播放器（系统窗口级），播放期间一律不弹
    w.alert = function () { return undefined; };
    w.confirm = function () { return false; };
    w.prompt = function () { return null; };
  } catch (e) {}
})();
''';

/// 播放结束 / 播放器关闭后还原被接管的四个出口。
///
/// 必须还原：页面后续可能真的要用 `window.open` 打开登录页，
/// 一直拦着等于把站点功能弄坏。
const String kPlaybackGuardRestoreJs = r'''
(function () {
  try {
    var g = window.__nerelictGuard;
    if (!g) return;
    var w = window;
    var o = g.orig || {};
    if (o.open) w.open = o.open;
    if (o.alert) w.alert = o.alert;
    if (o.confirm) w.confirm = o.confirm;
    if (o.prompt) w.prompt = o.prompt;
    w.__nerelictGuard = null;
  } catch (e) {}
})();
''';
