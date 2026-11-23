import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../models/player_request.dart' show PlayerMode;
import '../models/sniffed_media.dart';
import '../services/ad_filter.dart';
import '../services/app_log.dart';
import '../services/click_sniff.dart';
import '../services/click_sniff_js.dart';
import '../services/open_external.dart';
import '../services/page_cookie_probe.dart';
import '../services/user_agent.dart' show UserAgent;
import '../services/playback_guard_js.dart';
import '../services/player_probe_js.dart';
import '../services/sniffer_js.dart';
import '../services/streaming_proxy.dart';
import '../services/video_float_js.dart';
import '../state/app_state.dart';
import '../state/history_state.dart';
import '../state/settings_state.dart';
import '../state/web_favorites_state.dart';
import '../state/window_registry.dart' show WindowRegistry;
import '../ui/app_theme.dart';
import '../ui/browser_windows_page.dart';
import '../ui/history_page.dart';
import '../ui/neon_progress_bar.dart';
import '../ui/site_icon.dart';
import '../ui/variant_picker.dart';
import '../ui/web_favorites_page.dart';
import '../ui/widgets/app_menu.dart';
import '../ui/widgets/home_search_box.dart';

/// 地址栏右上角三点菜单的动作
enum _UrlMenuAction {
  favorite,
  sniff,
  clearLayers,
  clickHelp,
  resetClick,
  favorites,
  windows,
}

class BrowserTab extends StatefulWidget {
  const BrowserTab({super.key});

  @override
  State<BrowserTab> createState() => _BrowserTabState();
}

class _BrowserTabState extends State<BrowserTab> {
  late final AppState _state;
  late final WebViewController _controller;
  final TextEditingController _urlCtrl = TextEditingController();

  double _progress = 1;
  bool _loading = false;
  bool _canGoBack = false;
  bool _hasPage = false;

  /// 当前网页地址（用于网页收藏星标状态）
  String? _currentUrl;

  /// 主框架加载失败的现场（null 表示当前没有错误）。
  ///
  /// 以前只在错误回调里弹一条 2 秒的 toast，用户错过之后就只剩 WebView
  /// 自带的「网页无法打开」错误页，没有任何重试入口——看起来就是页面打不开。
  String? _loadError;
  String? _loadErrorUrl;

  /// 本次地址是否由我们补的 `https://`：只支持 HTTP 的站点失败后据此自动回退。
  bool _autoScheme = false;

  /// 已经对哪些 host 试过 http 回退，避免 https → http → https 来回跳。
  final Set<String> _httpRetried = <String>{};

  /// 主框架加载超时兜底：WebView 会卡在「请求已发出但没有响应」，
  /// 既不回调错误也不回调 `onPageFinished`，进度条就一直转。
  Timer? _loadWatchdog;

  /// 加载令牌：每次主框架导航自增。
  ///
  /// 回调是异步的，`onPageFinished` 里还要 `await getTitle()`；这期间用户可能
  /// 已经发起新的加载（例如 https 失败后自动回退 http）。用令牌把「上一页的回调」
  /// 丢掉，否则错误卡片会盖在正在加载的新页面上。
  int _loadToken = 0;

  /// 当前页面里已经处理过的视频地址，避免关闭 Nerelict 后反复接管
  final Set<String> _handled = <String>{};

  /// 网页视频长按后出现的「用 Nerelict 打开」浮标
  String? _floatUrl;
  String _floatPage = '';
  String _floatTitle = '';

  /// 浮标是否来自「点击后浮层播放」的捕获（文案会不同）
  bool _floatOverlay = false;

  /// 最近一次点击的时间：用于判断「点击后立刻跳到广告页」这类跳转
  DateTime? _lastClickAt;

  /// 本页是否已经因为广告命中提示过，避免反复弹
  bool _adSkipNotified = false;

  /// 本页是否已经自动回退过一次广告页（防止来回弹）
  bool _autoSkippedAd = false;

  /// 是否正处于「点了视频却被带到广告页」的途中
  bool _adDetour = false;

  /// 播放期间的网页弹窗守卫是否已挂上（避免每次 AppState 通知都重复执行脚本）
  bool _popupGuardOn = false;

  /// 遮挡层 / 点击弹窗的提示每页只弹一次，避免连续点击刷屏
  bool _shieldNotified = false;

  /// MSE 回扫的提示每页只弹一次：页面用 blob: 播放时，每点一次播放都会触发
  /// 回扫，逐次弹提示会把人烦死，而这个信息说一次就够了。
  bool _mseNotified = false;

  /// 本页已清掉的广告遮挡层数量（面板里显示）
  int _shieldedLayers = 0;

  Color? _appliedWebBg;

  /// 多窗口入口防抖：连续点两次不该 push 出两个多窗口页
  bool _openingWindows = false;

  @override
  void initState() {
    super.initState();
    _state = context.read<AppState>();
    _state.addBackInterceptor(_handleSystemBack);
    // 播放器开着的时候把网页的弹窗出口接管掉，关掉立刻还原
    _state.addListener(_syncPopupGuard);
    // 下载器 403 时要把「该域没有 Cookie」和「只有 HttpOnly」分开，
    // 后者只能由页面自己回答，所以这里给它挂一个读数探针
    PageCookieProbe.attach(_readDocumentCookieLength);

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(AppPalette.dark.webBg)
      ..addJavaScriptChannel(
        'SniffChannel',
        onMessageReceived: (msg) => _state.onSniffMessage(msg.message),
      )
      ..addJavaScriptChannel(
        'PlayerChannel',
        onMessageReceived: (msg) => _onPlayerMessage(msg.message),
      )
      ..addJavaScriptChannel(
        'FloatChannel',
        onMessageReceived: (msg) => _onFloatMessage(msg.message),
      )
      ..addJavaScriptChannel(
        'ClickChannel',
        onMessageReceived: (msg) => _onClickMessage(msg.message),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          // 只放行 http/https，拦掉 intent://、baiduboxapp:// 这类 App 深链。
          // 例外：登录用的自定义 scheme（weixin:// 等）WebView 开不了，
          // 静默拦掉的表现就是「点登录按钮完全没反应」，所以转交系统去处理。
          onNavigationRequest: (request) {
            final url = request.url;
            if (url.startsWith('http://') || url.startsWith('https://')) {
              return NavigationDecision.navigate;
            }
            final scheme = Uri.tryParse(url)?.scheme.toLowerCase() ?? '';
            if (scheme.isNotEmpty) unawaited(_openDeepLink(url, scheme));
            return NavigationDecision.prevent;
          },
          onProgress: (p) {
            if (!mounted) return;
            final next = (p / 100).clamp(0.0, 1.0);
            // 节流：进度每变化 2% 才刷新一次，避免整页高频重建拖慢加载
            if ((next - _progress).abs() < 0.02 && next < 1.0) return;
            setState(() => _progress = next);
          },
          onPageStarted: (url) {
            if (!mounted) return;
            _loadToken++;
            _handleAdNavigation(url);
            _handled.clear(); // 新页面重新开始自动接管
            _shieldNotified = false;
            _mseNotified = false;
            _shieldedLayers = 0;
            // 换页了：上一个站点的 Cookie 读数不再适用
            PageCookieProbe.clear();
            // 离开上一页：清空该页的嗅探资源、选中项、播放浮层与临时数据
            _state.resetPageResources();
            _floatUrl = null;
            _armLoadWatchdog();
            setState(() {
              _loading = true;
              _loadError = null;
              _loadErrorUrl = null;
              _syncUrl(url);
            });
            _inject();
          },
          onPageFinished: (url) async {
            if (!mounted) return;
            // 这一页对应的令牌：等待 title 期间若又发起了新的加载，就别再按
            // 这一页的结果去写历史或弹错误卡片
            final token = _loadToken;
            _loadWatchdog?.cancel();
            setState(() {
              _loading = false;
              _progress = 1;
              _syncUrl(url);
            });
            _inject();
            _refreshNavState();
            // 页面加载完再读一次「页面可见 Cookie」：
            // 挑战与登录态都是在这一步之后才落到 Cookie 上的
            unawaited(PageCookieProbe.refresh(Uri.tryParse(url)?.host ?? ''));
            // 记录浏览历史（非 http/https 地址由 HistoryState 自行过滤）
            try {
              final title = await _controller.getTitle();
              if (!mounted || token != _loadToken) return;
              // WebView 自己的错误页也会回调 onPageFinished，标题固定是
              // 「网页无法打开」：这种页面不该进历史，否则历史里全是死链
              final errorPage = (title ?? '').contains('网页无法打开');
              if (!errorPage && _loadError == null) {
                await context.read<HistoryState>().add(url, title ?? '');
              }
              // HTTP 状态错误（4xx/5xx）不会走 onWebResourceError，只会渲染成
              // 这张错误页；这里按页面内容兜底，才不至于只剩 WebView 的错误页
              if (errorPage) await _reportErrorPage(url, token);
            } catch (_) {}
          },
          onUrlChange: (change) {
            final url = change.url;
            if (url != null && mounted) _syncUrl(url);
          },
          onWebResourceError: (err) {
            if (!mounted) return;
            // 只忽略「明确是子资源」的错误。`isForMainFrame` 在部分回调路径
            // （兼容回调 / 旧 WebView）里会是 null，直接 `!= true` 会让主框架
            // 失败被静默吞掉：进度条一直转，用户只看到 WebView 的错误页。
            if (err.isForMainFrame == false) return;
            _onLoadFailed(err);
          },
        ),
      );

    // Android 侧：允许页面内媒体在无用户手势时起播（内联播放），
    // 视频一旦接手就不用再等一次点击，页面响应也更快。
    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      platform.setMediaPlaybackRequiresUserGesture(false);
      platform.setAllowFileAccess(false); // 只加载 http/https，关掉文件访问更稳妥
    }

    // 出站请求用 WebView 的真实 UA，避免「同一个地址、另一个客户端」被 403
    unawaited(_adoptWebViewUserAgent());
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
    _loadWatchdog?.cancel();
    _state.removeListener(_syncPopupGuard);
    _state.removeBackInterceptor(_handleSystemBack);
    // 页面卸载：同样清空本页资源与播放状态（销毁阶段不再通知监听者）
    _state.resetPageResources(notify: false);
    _handled.clear();
    PageCookieProbe.attach(null);
    _urlCtrl.dispose();
    super.dispose();
  }

  void _syncUrl(String url) {
    if (!url.startsWith('http')) return;
    _urlCtrl.text = url;
    _currentUrl = url;
  }

  Future<void> _toggleFavorite() async {
    final url = _currentUrl;
    if (url == null || !url.startsWith('http')) return;
    var title = '';
    try {
      title = await _controller.getTitle() ?? '';
    } catch (_) {}
    // 自动识别网站图标：读页面里声明的 <link rel="icon">
    String? iconUrl;
    try {
      final raw = await _controller.runJavaScriptReturningResult(kPageIconJs);
      final text = raw.toString().replaceAll('"', '').trim();
      if (text.startsWith('http') || text.startsWith('//')) iconUrl = text;
    } catch (_) {}
    if (!mounted) return;
    final favorites = context.read<WebFavoritesState>();
    final added =
        await favorites.toggle(url: url, title: title, iconUrl: iconUrl);
    if (!mounted) return;
    if (!added) {
      _toast('已取消收藏');
      return;
    }
    // 统一轻提示：自动消失，可点 × 关闭，并带「加入快速访问」动作
    context.read<AppState>().showToast(
          '已收藏当前网页',
          actionLabel: '快速访问',
          onAction: () => favorites.setQuickAccess(url, true),
        );
  }

  /// 多支注入脚本合并成一次通道调用：相比串行多次往返，
  /// 页面首帧前的空窗更短；任一支脚本异常也不会影响其他几支。
  ///
  /// 点击捕获脚本只在开关打开时注入：关掉后页面里连监听都不挂，
  /// 而不是挂着监听再把消息丢掉。
  String _buildInjectedScript({required bool clickCapture}) => <String>[
        kSniffJs,
        kPlayerProbeJs,
        kVideoFloatJs,
        if (clickCapture) kClickSniffJs,
      ].map((s) => 'try{\n$s\n}catch(e){}\n').join();

  /// 让下载器与播放代理沿用 WebView 的真实 UA。
  ///
  /// 源站是按这个 UA 发的地址。换成下载器自带的 UA 去取，等于「同一个地址、
  /// 另一个客户端」，很多 CDN 会按 UA 与会话不一致直接 403。采纳一次即可，
  /// 之后所有出站请求都读 [UserAgent.current]。
  Future<void> _adoptWebViewUserAgent() async {
    try {
      final ua = await _controller.getUserAgent();
      UserAgent.adopt(ua);
      logD('Browser', 'ua adopted=${ua != null && ua.length > 20}');
    } catch (_) {
      // 拿不到就继续用兜底 UA，不影响浏览
    }
  }

  Future<void> _inject() async {
    final capture = context.read<SettingsState>().clickCapture;
    try {
      await _controller.runJavaScript(_buildInjectedScript(clickCapture: capture));
    } catch (_) {
      // 页面可能禁止执行脚本，忽略
    }
    // 换页会丢掉上一页的守卫：播放器还开着就补挂一次
    if (_popupGuardOn) {
      try {
        await _controller.runJavaScript(kPlaybackGuardJs);
      } catch (_) {}
    }
  }

  /// 播放中接管网页的弹窗出口（`window.open` / `alert` / `confirm` / `prompt`）。
  ///
  /// 原生 JS 对话框是系统窗口，会压在 Flutter 浮层之上：用户想点播放键，
  /// 实际点到的是弹窗，还会被拖走。播放器一关就把出口原样还原，
  /// 不影响站点后续用 `window.open` 打开登录页这类正常功能。
  void _syncPopupGuard() {
    if (!mounted) return;
    final settings = context.read<SettingsState>();
    final want = _state.player != null && settings.playerBlockPagePopups;
    if (want == _popupGuardOn) return;
    _popupGuardOn = want;
    final js = want ? kPlaybackGuardJs : kPlaybackGuardRestoreJs;
    unawaited(_controller.runJavaScript(js).catchError((Object _) {}));
  }

  /// 网页里检测到可播放视频 -> 在当前页面上打开 Nerelict 浮层。
  /// 不做任何路由跳转，WebView 页面、滚动位置与浏览状态都不被打断。
  Future<void> _onPlayerMessage(String raw) async {
    if (!mounted || _state.player != null) return;
    final settings = context.read<SettingsState>();
    if (!settings.autoTakeover) return;
    final closedAt = _state.playerClosedAt;
    if (closedAt != null &&
        DateTime.now().difference(closedAt) < const Duration(seconds: 10)) {
      return;
    }

    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final url = (data['url'] as String?)?.trim() ?? '';
      if (url.isEmpty || !url.startsWith('http')) return;
      // 广告媒体的自动接管会让用户刚点完就被广告抢走画面，直接不接
      final verdict = AdFilter.inspect(url);
      if (verdict.isAd) {
        _handled.add(url);
        _notifyAdSkipped(verdict.reason);
        return;
      }
      if (_handled.contains(url)) return;
      _handled.add(url);

      final page = (data['page'] as String?) ?? '';
      final title = (data['title'] as String?) ?? '';

      // 先暂停网页里的 <video>，避免和 Nerelict 同时出声
      try {
        await _controller.runJavaScript(kPauseWebVideosJs);
      } catch (_) {}

      if (!mounted || _state.player != null) return;
      _state.openPlayer(
        url: url,
        title: title,
        referer: page.startsWith('http') ? page : null,
      );
    } catch (_) {}
  }

  /// 横幅 / 列表里的「播放」：同样只打开浮层，不跳转页面
  Future<void> _openPlayer(SniffedMedia media) async {
    // 分片组：把已收到的 TS 分片合成播放列表，交给本地代理边下边播。
    // fMP4 分片缺 init，合出来放不了，只能提示下载——不静默失败。
    if (!media.isPlayable) {
      if (!media.needsSegmentDownload) return;
      final ok = await _playSegmentGroup(media);
      if (!ok && mounted) {
        _toast('这组分片没法直接播放（片数太少，或是缺少初始化段的 fMP4），建议下载');
      }
      return;
    }
    _state.selectResource(media.id);
    try {
      await _controller.runJavaScript(kPauseWebVideosJs);
    } catch (_) {}
    if (!mounted) return;
    _state.openPlayer(
      url: media.url,
      title: media.pageTitle,
      referer: media.pageUrl.startsWith('http') ? media.pageUrl : null,
      headers: media.requestHeaders,
    );
  }

  /// 分片组直接播放：合成播放列表走代理，鉴权与在线播放一致
  Future<bool> _playSegmentGroup(SniffedMedia media) async {
    String? url;
    try {
      url = await StreamingProxy.instance.playbackUrlForSegments(
        media.segmentUrls,
        referer: media.pageUrl.startsWith('http') ? media.pageUrl : null,
        headers: media.requestHeaders,
      );
    } catch (_) {
      url = null;
    }
    if (url == null || !mounted) return false;
    try {
      await _controller.runJavaScript(kPauseWebVideosJs);
    } catch (_) {}
    if (!mounted) return false;
    _state.selectResource(media.id);
    _state.openPlayer(url: url, title: media.pageTitle);
    logD('Sniff', 'segment-group play ${media.segmentCount} segs -> $url');
    return true;
  }

  /// 长按网页视频：只显示浮标，不自动打断当前浏览
  void _onFloatMessage(String raw) {
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final url = (data['url'] as String?)?.trim() ?? '';
      if (url.isEmpty || !url.startsWith('http') || !mounted) return;
      setState(() {
        _floatUrl = url;
        _floatPage = (data['page'] as String?) ?? '';
        _floatTitle = (data['title'] as String?) ?? '';
        _floatOverlay = false;
      });
    } catch (_) {}
  }

  /// 点击捕获回调：把「点开才加载」的播放器接进现有链路。
  ///
  /// 分工：
  /// - m3u8 / 分片交给 AppState 并入资源列表（被动嗅探已建好的项会被原地补标记）；
  /// - mp4 直链只用于浮标提示，不进列表，避免和 HLS 的下载链路混淆；
  /// - MSE / 跨域 iframe 属于「拿不到地址」的情况，走兜底提示。
  Future<void> _onClickMessage(String raw) async {
    if (!mounted) return;
    final settings = context.read<SettingsState>();
    if (!settings.clickCapture) return;

    final event = _state.onClickSniffMessage(raw);
    if (event == null || !mounted) return;
    if (event.type == ClickEventType.hit ||
        event.type == ClickEventType.overlay ||
        event.type == ClickEventType.iframe ||
        event.type == ClickEventType.mse) {
      logD('Click', '${event.type.name} #${event.sessionId} '
          'score=${event.overlayScore} ${event.kind} ${event.url}');
    }

    switch (event.type) {
      case ClickEventType.hit:
        if (AdFilter.isAdUrl(event.url)) break;
        // 自动接管关闭时不打断浏览，但浮层播放这类明确命中仍给一个入口
        if (event.isOverlay && !settings.autoTakeover) {
          _showOverlayFloat(event);
        }
        break;
      case ClickEventType.mse:
        // blob 地址拿不到真实 URL：退回被动嗅探，把请求记录再扫一遍
        try {
          await _controller.runJavaScript(kManualSniffJs);
          await _controller.runJavaScript(kClickSniffScanJs);
        } catch (_) {}
        if (mounted && !_mseNotified) {
          _mseNotified = true;
          _toast('页面用 MSE 播放，直链不可见，已回扫请求记录');
        }
        break;
      case ClickEventType.iframe:
        // 跨域播放器只记进候选列表（⚡ 面板里有「打开继续嗅探」的入口），
        // 不再每次点击都弹提示：同一页面反复点播放会连续刷屏，反而挡视线。
        break;
      case ClickEventType.click:
        // 记下点击时刻：随后若跳到广告页，用这个时间判断是不是「点出来的」
        _lastClickAt = DateTime.now();
        break;
      case ClickEventType.overlay:
        break;
      case ClickEventType.shield:
        // 遮挡层：第一次命中就说清楚为什么用户「点播放没反应」
        if (event.kind == 'layer' || event.kind == 'manual') {
          _shieldedLayers = event.kind == 'manual' ? event.sessionId : _shieldedLayers + 1;
          logD('Ad', 'shield ${event.kind} total=$_shieldedLayers');
          if (!_shieldNotified) {
            _shieldNotified = true;
            _toast('已移除播放器上的广告遮挡层，再点一次即可播放');
          }
        } else if (event.kind == 'blocked') {
          // 同一次点击的第二条消息：层已经计过数，不再累加也不再提示
          logD('Ad', 'shield blocked-tap');
        } else if (event.kind == 'popup') {
          logD('Ad', 'shield popup #${event.sessionId}');
          if (!_shieldNotified) {
            _shieldNotified = true;
            _toast('已拦截点击广告弹窗；如未起播请再点一次');
          }
        }
        break;
    }
  }

  /// 广告页命中提示：同一页只提示一次，避免每次重定向都弹
  void _notifyAdSkipped(String reason) {
    if (_adSkipNotified || !mounted) return;
    _adSkipNotified = true;
    logD('Ad', 'skip $reason');
    _toast('已跳过疑似广告（$reason）');
  }

  /// 处理「点了视频却被带到广告页」：识别、必要时代退回并提示。
  ///
  /// 只有高置信度（已知广告网络域名）才自动回退；靠路径关键词判定的
  /// 只提示不劫持，避免误判把用户从正常页面弹回去。
  void _handleAdNavigation(String url) {
    final verdict = AdFilter.inspectPage(url);
    if (!verdict.isAd) {
      if (_adDetour) {
        _adDetour = false;
        _adSkipNotified = false;
        if (mounted) _toast('已从广告页返回，再点一次视频即可播放');
      }
      _autoSkippedAd = false;
      return;
    }

    final clickedAt = _lastClickAt;
    final fromClick = clickedAt != null &&
        DateTime.now().difference(clickedAt) < const Duration(seconds: 6);
    if (!fromClick) return;

    logD('Ad', 'detour ${verdict.reason} $url');
    _adDetour = true;
    if (!verdict.isHighConfidenceAd) {
      _notifyAdSkipped(verdict.reason);
      return;
    }
    if (_autoSkippedAd) return;
    _autoSkippedAd = true;
    // 高置信广告页：给它半秒开始渲染就退回，用户不必手动按返回
    Timer(const Duration(milliseconds: 500), () async {
      if (!mounted) return;
      try {
        if (!await _controller.canGoBack()) return;
        await _controller.goBack();
        if (mounted) _toast('已自动跳过广告页，再点一次视频即可播放');
      } catch (_) {}
    });
  }

  void _showOverlayFloat(ClickSniffEvent event) {
    if (_floatUrl == event.url || _state.player != null) return;
    setState(() {
      _floatUrl = event.url;
      _floatPage = event.page;
      _floatTitle = event.title;
      _floatOverlay = true;
    });
  }

  Future<void> _openFloatPlayer() async {
    final url = _floatUrl;
    if (url == null) return;
    final page = _floatPage;
    final title = _floatTitle;
    setState(() {
      _floatUrl = null;
      _floatOverlay = false;
    });
    _state.selectResource(url);
    try {
      await _controller.runJavaScript(kPauseWebVideosJs);
    } catch (_) {}
    if (!mounted) return;
    _state.openPlayer(
      url: url,
      title: title,
      referer: page.startsWith('http') ? page : null,
    );
  }

  Future<void> _refreshNavState() async {
    final back = await _controller.canGoBack();
    if (!mounted) return;
    setState(() => _canGoBack = back);
  }

  void _toast(String msg) {
    context.read<AppState>().showToast(msg);
  }

  /// 只有登录常用的几个 scheme 才自动交给系统。
  /// 其余深链（`intent://` 等）保持拦截——广告页常靠它们顺手拉起不相干的 App。
  static const Set<String> _loginSchemes = <String>{
    'weixin',
    'wechat',
    'mqqapi',
    'mqqwpa',
    'mqqticket',
    'wtlogin',
    'alipays',
    'alipay',
    'openlogin',
    'sinaweibo',
    'taobao',
  };

  /// 把登录深链递交给系统：能起 App 就切过去，起不来给一句人话，
  /// 不让用户面对一个「点了没反应」的按钮。
  Future<void> _openDeepLink(String url, String scheme) async {
    if (!_loginSchemes.contains(scheme)) return;
    logD('Web', 'deeplink $scheme');
    final ok = await OpenExternal.open(url);
    if (!mounted) return;
    _toast(ok ? '已交给外部应用，授权完成后返回' : '没有找到能打开该登录方式的应用');
  }

  /// 读本页 `document.cookie` 的字符数。
  ///
  /// 只用来区分两种 403：该域压根没有 Cookie，还是 Cookie 存在但都是 HttpOnly
  /// （`CookieManager.getCookie` 看不到）。返回 null 表示读不到，绝不返回 0 冒充。
  Future<int?> _readDocumentCookieLength() async {
    try {
      final raw = await _controller
          .runJavaScriptReturningResult('document.cookie.length');
      return int.tryParse(raw.toString().trim());
    } catch (_) {
      return null;
    }
  }

  void _open(String input) {
    final text = input.trim();
    if (text.isEmpty) return;

    Uri uri;
    var autoScheme = false;
    final looksLikeUrl = !text.contains(' ') && text.contains('.');
    if (looksLikeUrl) {
      final hasScheme = text.contains('://');
      uri = Uri.parse(hasScheme ? text : 'https://$text');
      // 记下「https 是补出来的」：只支持 HTTP 的站点（老视频站、内网服务）
      // 用 https 必然失败，失败后据此自动退回 http 再试一次
      autoScheme = !hasScheme;
    } else {
      // 搜索引擎由「设置」决定，默认 Google；只影响之后发起的搜索
      final engine = context.read<SettingsState>().searchEngine;
      uri = Uri.parse(engine.searchUrl(text));
    }
    _autoScheme = autoScheme;
    _loadUrl(uri);
  }

  /// 统一入口：清错误、置加载态、挂超时兜底，再交给 WebView。
  void _loadUrl(Uri uri) {
    _loadToken++;
    _armLoadWatchdog();
    setState(() {
      _hasPage = true;
      _loading = true;
      _progress = 0;
      _loadError = null;
      _loadErrorUrl = null;
      _urlCtrl.text = uri.toString();
      _currentUrl = uri.toString();
    });
    unawaited(_controller.loadRequest(uri));
  }

  /// 主框架加载超时兜底。
  ///
  /// WebView 在「连接已建立但服务器一直不回包」时会既不报错也不回调
  /// `onPageFinished`：没有这个超时，进度条就会一直转，用户面对一片空白。
  void _armLoadWatchdog() {
    _loadWatchdog?.cancel();
    _loadWatchdog = Timer(const Duration(seconds: 25), () {
      if (!mounted || !_loading || _loadError != null) return;
      final url = _currentUrl;
      logD('Browser', 'load watchdog fired: $url');
      setState(() {
        _loading = false;
        _progress = 1;
        _loadErrorUrl = url;
        _loadError = '等了 25 秒还没有响应，服务器可能已停止响应';
      });
    });
  }

  /// 主框架加载失败：先判断能不能自动回退 http，再落到可重试的错误卡片。
  void _onLoadFailed(WebResourceError err) {
    // 回退 http 之后，https 那次的错误回调可能才姗姗来迟：地址已经变了，
    // 不要把旧地址的失败盖到正在加载的新页面上
    final failing = err.url;
    if (_loading &&
        failing != null &&
        _currentUrl != null &&
        failing != _currentUrl) {
      logD('Browser', 'stale failure ignored: $failing');
      return;
    }
    _loadWatchdog?.cancel();
    final failedUrl = err.url ?? _currentUrl ?? '';
    final uri = Uri.tryParse(failedUrl);
    // 只支持 HTTP 的站点：我们补出来的 https 走不通，自动退回 http 再试
    if (_autoScheme &&
        uri != null &&
        uri.scheme == 'https' &&
        _httpRetried.add(uri.host.toLowerCase())) {
      logD('Browser', 'https failed (${err.errorCode}), retry http: $failedUrl');
      _autoScheme = false;
      // 地址栏要跟着换成真的在加载的地址，否则用户看到的还是 https
      _loadUrl(uri.replace(scheme: 'http'));
      _toast('该站点不支持 HTTPS，已改用 HTTP 重新打开');
      return;
    }
    logD('Browser', 'load failed ${err.errorCode} $failedUrl ${err.description}');
    setState(() {
      _loading = false;
      _progress = 1;
      _loadErrorUrl = failedUrl;
      _loadError = _describeLoadError(err);
    });
  }

  /// HTTP 状态错误（404 / 403 / 5xx）只会渲染成 WebView 自带的错误页，
  /// 不会触发 `onWebResourceError`。这里从错误页正文里挖出 `net::ERR_*`，
  /// 换成应用自己的可重试卡片。
  Future<void> _reportErrorPage(String url, int token) async {
    // 已经在加载 / 已经有错误了就别再盖一层（自动回退 http 时会出现这个时序）
    if (!mounted || _loading || _loadError != null) return;
    var code = '';
    try {
      final raw = await _controller.runJavaScriptReturningResult(
        'String(document.body&&document.body.innerText||"").slice(0,400)',
      );
      final hit = RegExp(r'net::[A-Z_]+').firstMatch(raw.toString());
      code = hit?.group(0) ?? '';
    } catch (_) {}
    if (!mounted || _loading || _loadError != null || token != _loadToken) {
      return;
    }
    logD('Browser', 'error page $url code=${code.isEmpty ? '-' : code}');
    setState(() {
      _loading = false;
      _progress = 1;
      _loadErrorUrl = url;
      _loadError = code.isEmpty
          ? '站点没有返回可用内容，连接被中断或请求被拒绝'
          : '站点没有返回可用内容（$code）';
    });
  }

  /// 把 `net::ERR_*` 翻译成一句能指导下一步的中文，原始错误码附在后面。
  String _describeLoadError(WebResourceError err) {
    final hint = switch (err.errorType) {
      WebResourceErrorType.hostLookup => '域名解析失败，网址可能写错，或当前网络无法解析',
      WebResourceErrorType.timeout => '连接超时，服务器一直没有响应',
      WebResourceErrorType.connect => '无法连接到服务器，站点可能拒绝访问，或被网络拦截',
      WebResourceErrorType.failedSslHandshake => 'HTTPS 握手失败，证书可能已过期或不受信任',
      WebResourceErrorType.io => '连接被中途断开，服务器没有返回完整内容',
      WebResourceErrorType.redirectLoop => '重定向次数过多，站点配置可能有误',
      WebResourceErrorType.badUrl => '网址格式不正确',
      WebResourceErrorType.tooManyRequests => '请求过于频繁，被站点临时限制',
      WebResourceErrorType.authentication ||
      WebResourceErrorType.proxyAuthentication =>
        '需要先通过身份验证',
      _ => '连接被中断或服务器没有返回内容',
    };
    final raw = err.description.trim();
    return raw.isEmpty ? hint : '$hint（$raw）';
  }

  /// 地址栏右侧的刷新 / 停止。
  ///
  /// 出错后这个按钮要能把错误态一起清掉，所以先走 [retry] 再回退到 reload：
  /// 直接 `reload()` 的话，加载态与错误卡片会同时挂着。
  void _reloadOrRetry() {
    if (_loadError != null) {
      _retryCurrent();
      return;
    }
    unawaited(_controller.reload());
  }

  /// 错误卡片上的「重试」：按当前地址重新加载一次。
  void _retryCurrent() {
    final url = _loadErrorUrl ?? _currentUrl;
    if (url == null || url.isEmpty) {
      _goHome();
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      _goHome();
      return;
    }
    _loadUrl(uri);
  }

  /// 错误卡片上的「改用 HTTP」：https 站点在部分网络下握手被掐、
  /// 而站点本身也提供 http 时，这一步往往能直接打开。
  void _retryAsHttp() {
    final url = _loadErrorUrl ?? _currentUrl;
    if (url == null || !url.startsWith('https://')) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    _autoScheme = false;
    _loadUrl(uri.replace(scheme: 'http'));
  }

  /// 手动清理「盖在播放器上的透明广告层」。
  ///
  /// 有些站点把广告层做成整屏透明 div，用户点播放其实点在广告上；
  /// 自动拦截依赖「刚好点在那层上」，这里再给一个不依赖点击的入口。
  Future<void> _clearAdLayers() async {
    if (!context.read<SettingsState>().clickCapture) {
      _toast('该功能随「点击捕获」一起关闭了，先在设置里打开');
      return;
    }
    var count = 0;
    try {
      await _controller.runJavaScript(kClickSniffJs);
      await _controller.runJavaScript('try{window.__ssClearLayers&&window.__ssClearLayers()}catch(e){}');
      final raw = await _controller
          .runJavaScriptReturningResult('(window.__ssShell||{}).layers||0');
      count = int.tryParse(raw.toString().replaceAll('"', '')) ?? 0;
    } catch (_) {}
    if (!mounted) return;
    _toast(count > 0
        ? '已移除 $count 个遮挡层，现在可以直接点播放'
        : '这一页没找到透明遮挡层');
  }

  /// 右上角手动嗅探：对当前页面主动重新扫描一次。
  /// 复用同一套上报/聚合逻辑，已有资源不会重复出现。
  Future<void> _manualSniff() async {
    try {
      await _controller.runJavaScript(kSniffJs);
      await _controller.runJavaScript(kManualSniffJs);
      // 有活跃点击会话时顺带补扫一次窗口内的播放器
      await _controller.runJavaScript(kClickSniffScanJs);
    } catch (_) {}
    if (!mounted) return;
    _toast('已重新嗅探当前页，点 ⚡ 查看资源');
  }

  /// 点击捕获说明：写清适用场景、判定规则与兜底方式
  Future<void> _showClickCaptureHelp() async {
    final p = paletteOf(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface,
        title: Text('点击捕获怎么工作', style: TextStyle(fontSize: 15, color: p.text)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _helpBlock(p, '适用场景', '视频要点一下封面 / 剧集才加载，点开后以浮层弹窗'
                  '（lightbox、模态播放器、iframe 播放器）浮起播放窗口。'),
              _helpBlock(p, '怎么判定', '点击后 8 秒内出现的播放列表请求、新插入的 '
                  '<video>、play() 调用都算到这次点击；容器是固定定位、铺满屏幕、'
                  '带遮罩或类名像弹窗时记为「浮层播放」。'),
              _helpBlock(p, '不会做什么', '不拦截点击、不阻止默认行为、不点广告，'
                  '只旁路记录地址；每条地址仍按原有规则去重聚合。'),
              _helpBlock(p, '拿不到地址时', 'MSE（blob:）会回扫请求记录；跨域 iframe '
                  '只给播放器地址，可在 ⚡ 资源面板里打开它继续嗅探；实在不行用「手动嗅探」。'),
            ],
          ),
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Widget _helpBlock(AppPalette p, String title, String body) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: TextStyle(fontSize: 12.5, color: p.accent, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(body, style: TextStyle(fontSize: 12, color: p.textSub, height: 1.5)),
        ],
      ),
    );
  }

  Future<void> _resetClickCapture() async {
    if (!context.read<SettingsState>().clickCapture) {
      _toast('点击捕获已在设置里关闭');
      return;
    }
    try {
      await _controller.runJavaScript(kClickSniffResetJs);
      await _controller.runJavaScript(kClickSniffJs);
    } catch (_) {}
    _state.clearClickHints();
    if (mounted) _toast('已重置点击捕获，下一次点击从 #1 重新计数');
  }

  void _goHome() {
    // 回首页前先停掉网页里的声音，避免 WebView 移出树后仍在后台播放
    unawaited(_controller.runJavaScript(kPauseWebVideosJs).catchError((_) {}));
    _loadWatchdog?.cancel();
    setState(() {
      _hasPage = false;
      _canGoBack = false;
      _currentUrl = null;
      _urlCtrl.clear();
      _loading = false;
      _progress = 1;
      _loadError = null;
      _loadErrorUrl = null;
    });
  }

  /// 系统返回：先回退网页，退无可退时回首页；首页交还给 HomeScreen 处理。
  Future<bool> _handleSystemBack() async {
    // 拦截器是全局注册的：不在「浏览器」页时不要抢返回，
    // 否则在文件页按返回会去导航那个看不见的网页
    if (_state.tabIndex != 0) return false;
    if (!_hasPage) return false;
    if (_canGoBack) {
      await _controller.goBack();
      await _refreshNavState();
    } else {
      _goHome();
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    // 返回键统一由 HomeScreen 分发（见 AppState.handleBack），这里只渲染内容
    return Column(
      children: [
        SafeArea(bottom: false, child: _buildUrlBar(p)),
        Expanded(
          child: Stack(
            children: [
              if (_hasPage)
                Stack(
                  children: [
                    WebViewWidget(controller: _controller),
                    if (_floatUrl != null)
                      Positioned(
                        right: 14,
                        bottom: 18,
                        child: _VideoFloatEntry(
                          overlay: _floatOverlay,
                          onOpen: _openFloatPlayer,
                          onDismiss: () => setState(() {
                            _floatUrl = null;
                            _floatOverlay = false;
                          }),
                        ),
                      ),
                  ],
                )
              else
                _StartPage(onOpen: _open, onWindows: _openWindows),
              // 加载失败：用应用自己的错误卡片盖住 WebView 的错误页。
              // WebView 的错误页只有一行 `net::ERR_*`，没有重试入口，
              // 用户只能手动点地址栏——这正是「网页打不开」的体感来源。
              if (_hasPage && _loadError != null)
                Positioned.fill(
                  child: _LoadErrorCard(
                    palette: p,
                    url: _loadErrorUrl ?? _currentUrl ?? '',
                    message: _loadError!,
                    onRetry: _retryCurrent,
                    onRetryHttp: (_loadErrorUrl ?? _currentUrl ?? '')
                            .startsWith('https://')
                        ? _retryAsHttp
                        : null,
                    onHome: _goHome,
                  ),
                ),
              // 赛博朋克霓虹加载进度：浮在内容顶部，不占布局高度
              Positioned(
                top: -2,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: NeonProgressBar(
                    value: _loading ? (_progress <= 0 ? null : _progress) : 1,
                    visible: _loading,
                  ),
                ),
              ),
            ],
          ),
        ),
        // 嗅探结果不再在底部重复展示，统一由右上角「小闪电」入口查看
      ],
    );
  }

  Widget _buildUrlBar(AppPalette p) {
    // 只订阅资源数量：底部横幅移除后，让入口本身能反映当前结果
    final sniffCount = context.select<AppState, int>((s) => s.sniffed.length);
    final favorites = context.watch<WebFavoritesState>();
    final currentUrl = _currentUrl;
    final favorited = currentUrl != null && favorites.contains(currentUrl);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
      color: p.bg,
      child: Row(
        children: [
          // 最左侧不再放独立的返回框：地址栏整体左移，成为这一行的视觉起点
          Expanded(
            child: Container(
              height: 40,
              decoration: BoxDecoration(
                color: p.surfaceAlt,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _loading
                      ? p.accent.withValues(alpha: 0.45)
                      : p.border.withValues(alpha: p.isCyber ? 1 : 0.7),
                ),
                boxShadow: _loading
                    ? <BoxShadow>[
                        BoxShadow(
                          color: p.accent.withValues(alpha: 0.18),
                          blurRadius: 12,
                        ),
                      ]
                    : null,
              ),
              padding: const EdgeInsets.only(left: 13, right: 4),
              alignment: Alignment.center,
              child: Row(
                children: [
                  Icon(Icons.search, size: 16, color: p.textFaint),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _urlCtrl,
                      textInputAction: TextInputAction.go,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      style: TextStyle(fontSize: 13, color: p.text),
                      decoration: InputDecoration(
                        isDense: true,
                        isCollapsed: true,
                        border: InputBorder.none,
                        hintText: '输入网址或搜索',
                        hintStyle: TextStyle(color: p.textFaint, fontSize: 13),
                      ),
                      onSubmitted: _open,
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
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            padding: EdgeInsets.zero,
            icon: Icon(_loading ? Icons.close : Icons.refresh, size: 19),
            color: _hasPage ? p.textSub : p.textDisabled,
            onPressed: _hasPage ? _reloadOrRetry : null,
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.home_outlined, size: 19),
            color: p.textSub,
            onPressed: _goHome,
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            padding: EdgeInsets.zero,
            icon: Badge(
              isLabelVisible: sniffCount > 0,
              label: Text('$sniffCount'),
              child: Icon(
                sniffCount > 0 ? Icons.bolt : Icons.bolt_outlined,
                size: 20,
              ),
            ),
            color: sniffCount > 0 ? p.accent : p.textSub,
            tooltip:
                sniffCount > 0 ? '已嗅探 $sniffCount 个视频资源，点击查看全部' : '已嗅探的源（点击查看）',
            onPressed: () => showSniffedSheet(
              context,
              _state,
              _openPlayer,
              onOpenPage: _open,
            ),
          ),
          // 收藏与主动嗅探统一收纳进右上角三点菜单，地址栏只留高频入口
          Builder(
            builder: (menuContext) => IconButton(
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              padding: EdgeInsets.zero,
              tooltip: '更多',
              icon: Icon(Icons.more_vert, size: 20, color: p.textSub),
              onPressed: () async {
                final action = await showAppMenu<_UrlMenuAction>(
                  context: menuContext,
                  anchorContext: menuContext,
                  title: '页面操作',
                  items: <AppMenuItem<_UrlMenuAction>>[
                    AppMenuItem<_UrlMenuAction>(
                      value: _UrlMenuAction.favorite,
                      label: favorited ? '取消收藏本页' : '收藏本页',
                      icon: favorited ? Icons.star : Icons.star_border,
                      enabled: _hasPage && currentUrl != null,
                    ),
                    AppMenuItem<_UrlMenuAction>(
                      value: _UrlMenuAction.sniff,
                      label: '手动嗅探当前页',
                      icon: Icons.radar_outlined,
                      enabled: _hasPage,
                    ),
                    AppMenuItem<_UrlMenuAction>(
                      value: _UrlMenuAction.clearLayers,
                      label: '清理页面遮挡层',
                      icon: Icons.layers_clear_outlined,
                      enabled: _hasPage,
                    ),
                    AppMenuItem<_UrlMenuAction>(
                      value: _UrlMenuAction.clickHelp,
                      label: '点击捕获说明',
                      icon: Icons.ads_click_outlined,
                      enabled: _hasPage,
                    ),
                    AppMenuItem<_UrlMenuAction>(
                      value: _UrlMenuAction.resetClick,
                      label: '重置点击捕获',
                      icon: Icons.restart_alt,
                      enabled: _hasPage,
                    ),
                    AppMenuItem<_UrlMenuAction>(
                      value: _UrlMenuAction.favorites,
                      label: '全部网页收藏',
                      icon: Icons.bookmarks_outlined,
                    ),
                    AppMenuItem<_UrlMenuAction>(
                      value: _UrlMenuAction.windows,
                      label: '多窗口浏览',
                      icon: Icons.tab,
                    ),
                  ],
                );
                if (action != null) await _onUrlMenu(action);
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 三点菜单：收藏 / 主动嗅探 / 网页收藏单页
  Future<void> _onUrlMenu(_UrlMenuAction action) async {
    switch (action) {
      case _UrlMenuAction.favorite:
        await _toggleFavorite();
        break;
      case _UrlMenuAction.sniff:
        await _manualSniff();
        break;
      case _UrlMenuAction.clearLayers:
        await _clearAdLayers();
        break;
      case _UrlMenuAction.clickHelp:
        await _showClickCaptureHelp();
        break;
      case _UrlMenuAction.resetClick:
        await _resetClickCapture();
        break;
      case _UrlMenuAction.favorites:
        final url = await Navigator.of(context).push<String>(
          MaterialPageRoute<String>(builder: (_) => const WebFavoritesPage()),
        );
        if (url != null && mounted) _open(url);
        break;
      case _UrlMenuAction.windows:
        await _openWindows();
        break;
    }
  }

  /// 打开多窗口页：把当前地址带过去作为第一个窗口，同时防止重复 push。
  Future<void> _openWindows() async {
    if (_openingWindows) return;
    _openingWindows = true;
    try {
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => BrowserWindowsPage(initialUrl: _currentUrl),
        ),
      );
    } finally {
      _openingWindows = false;
    }
  }
}

/// 原生起始页：不加载任何远端首页，避免被 App 深链劫持。
///
/// 只保留能用的东西：搜索框、多窗口入口、常用站点、快速访问、收藏与历史。
/// 刻意不写「怎么用」的引导文案——第一次打开就该直接能搜。
class _StartPage extends StatelessWidget {
  const _StartPage({required this.onOpen, required this.onWindows});

  final void Function(String) onOpen;

  /// 进入多窗口页：首页是「一眼能看到」的入口，不再只藏在三点菜单里
  final VoidCallback onWindows;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HomeSearchBox(onSubmit: onOpen),
          const SizedBox(height: 14),
          _WindowsEntryCard(onTap: onWindows),
          const SizedBox(height: 24),
          Text(
            '常用站点',
            style: TextStyle(fontSize: 13, color: p.textFaint),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _QuickChip(
                p: p,
                label: 'hls.js 演示页',
                onTap: () => onOpen('https://hlsjs.video-dev.org/demo/'),
              ),
              _QuickChip(
                p: p,
                label: 'Bing',
                onTap: () => onOpen('https://www.bing.com'),
              ),
              _QuickChip(
                p: p,
                label: '百度',
                onTap: () => onOpen('https://m.baidu.com'),
              ),
              _QuickChip(
                p: p,
                label: '谷歌',
                icon: Icons.g_mobiledata,
                onTap: () => onOpen('https://www.google.com'),
              ),
            ],
          ),
          const SizedBox(height: 22),
          _QuickAccessSection(onOpen: onOpen),
          const SizedBox(height: 24),
          _WebFavoritesSection(onOpen: onOpen),
          const SizedBox(height: 24),
          _HistorySection(onOpen: onOpen),
        ],
      ),
    );
  }
}

/// 主框架加载失败的兜底界面。
///
/// 铺满内容区（连同 WebView 自带的错误页一起盖住），因为那张页面既不能重试、
/// 也不会被我们的地址栏状态影响，留着只会让人以为「这个 App 打不开网页」。
class _LoadErrorCard extends StatelessWidget {
  const _LoadErrorCard({
    required this.palette,
    required this.url,
    required this.message,
    required this.onRetry,
    required this.onHome,
    this.onRetryHttp,
  });

  final AppPalette palette;
  final String url;
  final String message;
  final VoidCallback onRetry;

  /// 仅在 https 地址时提供：部分站点/网络下 https 握手被掐，http 反而能开
  final VoidCallback? onRetryHttp;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return ColoredBox(
      color: p.bg,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(p.isCyber ? 4 : 16),
              border: Border.all(
                color: p.isCyber ? p.accent.withValues(alpha: 0.45) : p.border,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.wifi_off, size: 30, color: p.textFaint),
                const SizedBox(height: 12),
                Text(
                  '网页打不开',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
                if (url.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    url,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: p.textFaint),
                  ),
                ],
                const SizedBox(height: 10),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, height: 1.45, color: p.textSub),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    FilledButton(
                      onPressed: onRetry,
                      child: const Text('重试'),
                    ),
                    if (onRetryHttp != null) ...<Widget>[
                      const SizedBox(width: 10),
                      OutlinedButton(
                        onPressed: onRetryHttp,
                        child: const Text('改用 HTTP'),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: onHome,
                  child: Text(
                    '回到首页',
                    style: TextStyle(fontSize: 12, color: p.textFaint),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 首页的多窗口入口：卡片紧贴搜索框下方，进浏览器第一屏就能看到。
///
/// 主界面只维护一个浏览上下文，多窗口是另一套独立的 WebView 集合；
/// 把它做成首页常驻入口，比只放在右上角三点菜单里更容易被发现。
class _WindowsEntryCard extends StatelessWidget {
  const _WindowsEntryCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: p.isCyber ? p.accent.withValues(alpha: 0.32) : p.border,
          ),
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(Icons.filter_none, size: 17, color: p.accent),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '多窗口浏览',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: p.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '同时开多个网页，最多 ${WindowRegistry.maxWindows} 个',
                    style: TextStyle(fontSize: 10.5, color: p.textFaint),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: p.textFaint),
          ],
        ),
      ),
    );
  }
}

/// 首页「快速访问」：放进快速访问的网页收藏，图标自动识别。
class _QuickAccessSection extends StatelessWidget {
  const _QuickAccessSection({required this.onOpen});

  final void Function(String) onOpen;

  Future<void> _manage(BuildContext context) async {
    final url = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const WebFavoritesPage()),
    );
    if (url != null && context.mounted) onOpen(url);
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final items = context.watch<WebFavoritesState>().quickAccessItems;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('快速访问', style: TextStyle(fontSize: 13, color: p.textFaint)),
            if (items.isNotEmpty) ...<Widget>[
              const SizedBox(width: 6),
              Text('${items.length}',
                  style: TextStyle(fontSize: 11, color: p.textDisabled)),
            ],
            const Spacer(),
            TextButton.icon(
              onPressed: () => _manage(context),
              icon: Icon(Icons.tune, size: 14, color: p.accent),
              label:
                  Text('管理', style: TextStyle(fontSize: 11.5, color: p.accent)),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (items.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: p.border),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.bolt_outlined, size: 15, color: p.textDisabled),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '把常看的网页加入快速访问：全部收藏 → 条目右侧 ☆',
                    style: TextStyle(fontSize: 11.5, color: p.textDisabled),
                  ),
                ),
              ],
            ),
          )
        else
          GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.92,
            children: <Widget>[
              for (final item in items)
                InkWell(
                  onTap: () => onOpen(item.url),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    decoration: BoxDecoration(
                      color: p.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: p.isCyber
                            ? p.accent.withValues(alpha: 0.28)
                            : p.border,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        SiteIcon(
                          url: item.url,
                          iconUrl: item.iconUrl,
                          size: 30,
                          radius: 8,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          item.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 10.5, color: p.textSub),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// 首页「网页收藏」：最近收藏的页面，分类与图标一并展示；
/// 排序、归类、编辑都在「全部收藏」单页里完成。
class _WebFavoritesSection extends StatelessWidget {
  const _WebFavoritesSection({required this.onOpen});

  final void Function(String) onOpen;

  Future<void> _openAll(BuildContext context) async {
    final url = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const WebFavoritesPage()),
    );
    if (url != null && context.mounted) onOpen(url);
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final favorites = context.watch<WebFavoritesState>();
    final all = favorites.items;
    final items = all.take(5).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('网页收藏', style: TextStyle(fontSize: 13, color: p.textFaint)),
            if (all.isNotEmpty) ...[
              const SizedBox(width: 6),
              Text('${all.length}',
                  style: TextStyle(fontSize: 11, color: p.textDisabled)),
            ],
            const Spacer(),
            TextButton.icon(
              onPressed: () => _openAll(context),
              icon: Icon(Icons.bookmarks_outlined, size: 14, color: p.accent),
              label: Text('全部收藏',
                  style: TextStyle(fontSize: 11.5, color: p.accent)),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (all.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: p.border),
            ),
            child: Row(
              children: [
                Icon(Icons.star_border, size: 15, color: p.textDisabled),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '还没有收藏网页 · 网页页点地址栏右上角「⋮」→ 收藏本页',
                    style: TextStyle(fontSize: 11.5, color: p.textDisabled),
                  ),
                ),
              ],
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: p.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: <Widget>[
                for (var i = 0; i < items.length; i++) ...<Widget>[
                  if (i > 0) Divider(height: 1, color: p.border),
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.fromLTRB(12, 0, 2, 0),
                    leading: SiteIcon(
                      url: items[i].url,
                      iconUrl: items[i].iconUrl,
                      size: 20,
                      radius: 5,
                    ),
                    title: Text(
                      items[i].displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: p.text),
                    ),
                    subtitle: Text(
                      items[i].isUncategorized
                          ? items[i].host
                          : '${items[i].host} · ${items[i].categoryLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: p.textFaint),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (items[i].quickAccess)
                          Icon(Icons.bolt, size: 14, color: p.accent),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: '移除收藏',
                          icon: Icon(Icons.close, size: 15, color: p.textFaint),
                          onPressed: () => favorites.remove(items[i].url),
                        ),
                      ],
                    ),
                    onTap: () => onOpen(items[i].url),
                  ),
                ],
              ],
            ),
          ),
        if (all.length > items.length)
          InkWell(
            onTap: () => _openAll(context),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: p.surfaceAlt,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: p.border),
              ),
              child: Row(
                children: [
                  Icon(Icons.bookmarks_outlined, size: 15, color: p.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '更多 · 查看全部 ${all.length} 个网页收藏',
                      style: TextStyle(fontSize: 12, color: p.textSub),
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 16, color: p.textFaint),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 首页「最近浏览」：按访问时间倒序展示；右上角进入「全部历史」，
/// 多选与批量删除在独立历史页完成。
class _HistorySection extends StatelessWidget {
  const _HistorySection({required this.onOpen});

  final void Function(String) onOpen;

  static String _time(DateTime t) {
    final now = DateTime.now();
    final hm = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
    if (now.year == t.year && now.month == t.month && now.day == t.day) {
      return '今天 $hm';
    }
    return '${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')} $hm';
  }

  /// 进入独立历史页；页内可多选批量删除，返回时把选中地址交给浏览器打开。
  Future<void> _openAllHistory(BuildContext context) async {
    final url = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const HistoryPage()),
    );
    if (url != null && context.mounted) onOpen(url);
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final history = context.watch<HistoryState>();
    final items = history.items.take(5).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('最近浏览', style: TextStyle(fontSize: 13, color: p.textFaint)),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _openAllHistory(context),
              icon: Icon(Icons.list_alt, size: 14, color: p.accent),
              label: Text('全部历史',
                  style: TextStyle(fontSize: 11.5, color: p.accent)),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text('还没有浏览记录',
                style: TextStyle(fontSize: 11.5, color: p.textDisabled)),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: p.border),
            ),
            child: Column(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: p.border),
                  InkWell(
                    onTap: () => onOpen(items[i].url),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 9),
                      child: Row(
                        children: [
                          Icon(Icons.history, size: 15, color: p.textFaint),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  items[i].displayTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style:
                                      TextStyle(fontSize: 12.5, color: p.text),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  items[i].displayHost,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 10.5, color: p.textFaint),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _time(items[i].visitedAt),
                            style:
                                TextStyle(fontSize: 10, color: p.textDisabled),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        // 「更多」展开框：跳转到独立单页浏览历史
        InkWell(
          onTap: () => _openAllHistory(context),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: p.surfaceAlt,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: p.border),
            ),
            child: Row(
              children: [
                Icon(Icons.unfold_more, size: 15, color: p.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '更多 · 查看全部浏览历史',
                    style: TextStyle(fontSize: 12, color: p.textSub),
                  ),
                ),
                Icon(Icons.chevron_right, size: 16, color: p.textFaint),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 长按网页视频后出现的浮标：只提供一个明确的手动接管入口。
///
/// [overlay] 为 true 时表示这条来自「点击后浮层播放」的捕获，
/// 文案换成「浮层视频已捕获」，让用户明白这次不是长按触发的。
class _VideoFloatEntry extends StatelessWidget {
  const _VideoFloatEntry({
    required this.overlay,
    required this.onOpen,
    required this.onDismiss,
  });

  final bool overlay;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Material(
      color: Colors.transparent,
      elevation: 6,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        decoration: BoxDecoration(
          color: p.isCyber ? p.surfaceAlt : const Color(0xFF172033),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: p.accent.withValues(alpha: 0.5)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 7, 6, 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              overlay ? Icons.picture_in_picture_alt : Icons.smart_display_outlined,
              size: 17,
              color: p.accent,
            ),
            const SizedBox(width: 7),
            GestureDetector(
              onTap: onOpen,
              child: Text(
                overlay ? '浮层视频已捕获' : '用 Nerelict 打开',
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 4),
            InkWell(
              customBorder: const CircleBorder(),
              onTap: onDismiss,
              child: const Padding(
                padding: EdgeInsets.all(5),
                child: Icon(Icons.close, size: 14, color: Colors.white54),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({
    required this.p,
    required this.label,
    required this.onTap,
    this.icon,
  });

  final AppPalette p;
  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: p.surfaceAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: p.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: p.accent),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(fontSize: 12, color: p.textSub),
            ),
          ],
        ),
      ),
    );
  }
}

void downloadFromMedia(
    BuildContext context, AppState state, SniffedMedia media) {
  // 优先用网页标题命名，URL 尾段通常是一串编号
  final pageTitle = media.pageTitle.trim();
  final title = (pageTitle.isNotEmpty && !pageTitle.startsWith('http'))
      ? pageTitle
      : media.suggestedName;

  state.selectResource(media.id);
  // 交给选流流程：多档清晰度会先让用户挑，单档 / 分片组则直接入队
  unawaited(startDownloadWithChoice(
    context,
    state,
    url: media.url,
    title: title,
    referer: media.pageUrl.isEmpty ? null : media.pageUrl,
    segments: media.needsSegmentDownload ? media.segmentUrls : null,
    headers: media.requestHeaders,
    doneHint: media.needsSegmentDownload
        ? '已将 ${media.segmentCount} 个分片加入下载'
        : '已加入下载队列',
  ));
}

/// 右上角「小闪电」：嗅探结果的唯一入口。
///
/// 底部横幅已移除，这里展示全部聚合结果；面板默认占 82% 并上拖到 95%，
/// 点条目可查看完整地址，播放/下载入口保持原样。
/// [onOpenPage] 用于打开跨域 iframe 播放器地址，继续在那一页里嗅探。
void showSniffedSheet(
  BuildContext pageContext,
  AppState state,
  Future<void> Function(SniffedMedia media) onPlay, {
  required void Function(String url) onOpenPage,
}) {
  final p = paletteOf(pageContext);

  // 播放器浮层始终置顶，会盖住底部弹窗：临时收成迷你小窗，不打断播放。
  final previousMode = state.playerMode;
  final hasPlayer = state.player != null;
  if (hasPlayer) state.setPlayerMode(PlayerMode.mini);

  showModalBottomSheet<void>(
    context: pageContext,
    backgroundColor: p.surface,
    showDragHandle: false,
    isScrollControlled: true,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(p.isCyber ? 4 : 18),
      ),
      side: p.isCyber
          ? BorderSide(color: p.accent.withValues(alpha: 0.45))
          : BorderSide.none,
    ),
    builder: (sheetContext) => FractionallySizedBox(
      heightFactor: 0.82,
      child: _SniffSheet(
        pageContext: pageContext,
        state: state,
        onPlay: onPlay,
        onOpenPage: onOpenPage,
        hasPlayer: hasPlayer,
      ),
    ),
  ).whenComplete(() {
    if (hasPlayer && state.player != null) {
      state.setPlayerMode(previousMode);
    }
  });
}

/// 嗅探资源分类：只用于面板分组与筛选，不改变聚合逻辑。
enum _SniffGroup {
  stream('视频 / M3U8'),
  audio('音频'),
  segments('分片');

  const _SniffGroup(this.label);
  final String label;
}

_SniffGroup _groupOf(SniffedMedia media) {
  if (media.kind == MediaKind.segmentGroup) return _SniffGroup.segments;
  final path = Uri.tryParse(media.url)?.path.toLowerCase() ?? '';
  if (RegExp(r'\.(mp3|m4a|aac|flac|ogg|wav|opus)$').hasMatch(path)) {
    return _SniffGroup.audio;
  }
  return _SniffGroup.stream;
}

/// 固定高度的嗅探结果面板：搜索 + 分类筛选 + 批量下载。
///
/// 之前是自由拖动的 DraggableScrollableSheet，高度每次都不一样；
/// 现在固定 82% 高度，头部的搜索与筛选常驻，列表只负责滚动。
class _SniffSheet extends StatefulWidget {
  const _SniffSheet({
    required this.pageContext,
    required this.state,
    required this.onPlay,
    required this.onOpenPage,
    required this.hasPlayer,
  });

  final BuildContext pageContext;
  final AppState state;
  final Future<void> Function(SniffedMedia media) onPlay;
  final void Function(String url) onOpenPage;
  final bool hasPlayer;

  @override
  State<_SniffSheet> createState() => _SniffSheetState();
}

class _SniffSheetState extends State<_SniffSheet> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  _SniffGroup? _group;

  /// 只看「点击后浮层播放」的捕获结果
  bool _overlayOnly = false;

  /// 是否展开疑似广告（默认折叠：列表顶部不再被广告占满）
  bool _showAds = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<SniffedMedia> _visible(List<SniffedMedia> all) {
    final q = _query.trim().toLowerCase();
    return all.where((m) {
      if (m.suspectAd && !_showAds) return false;
      if (_overlayOnly && !m.overlayPlay) return false;
      if (_group != null && _groupOf(m) != _group) return false;
      if (q.isEmpty) return true;
      return m.label.toLowerCase().contains(q) ||
          m.url.toLowerCase().contains(q) ||
          m.kindLabel.toLowerCase().contains(q) ||
          m.captureNote.toLowerCase().contains(q);
    }).toList();
  }

  void _downloadAll(List<SniffedMedia> items) {
    for (final m in items) {
      final pageTitle = m.pageTitle.trim();
      final title = (pageTitle.isNotEmpty && !pageTitle.startsWith('http'))
          ? pageTitle
          : m.suggestedName;
      widget.state.startDownload(
        url: m.url,
        title: title,
        referer: m.pageUrl.isEmpty ? null : m.pageUrl,
        segments: m.needsSegmentDownload ? m.segmentUrls : null,
        headers: m.requestHeaders,
      );
    }
    Navigator.of(context).pop();
    widget.state.showToast('已加入 ${items.length} 个下载任务');
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final all = widget.state.sniffed;
        final items = _visible(all);
        final hints = widget.state.clickHints;
        final overlayCount = all.where((m) => m.overlayPlay).length;
        final adCount = all.where((m) => m.suspectAd).length;
        final counts = <_SniffGroup, int>{
          for (final g in _SniffGroup.values)
            g: all.where((m) => _groupOf(m) == g).length,
        };
        final groups =
            _SniffGroup.values.where((g) => (counts[g] ?? 0) > 0).toList();

        return Column(
          children: <Widget>[
            _header(p, all, items),
            _toolbar(p, groups, counts, all.length, overlayCount, adCount),
            Expanded(
              child: Column(
                children: <Widget>[
                  if (hints.isNotEmpty) _hintCard(p, hints),
                  Expanded(
                    child: all.isEmpty
                        ? Center(
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 32),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Icon(Icons.radar_outlined,
                                      size: 40, color: p.textDisabled),
                                  const SizedBox(height: 12),
                                  Text(
                                    '还没有嗅探到视频资源',
                                    style: TextStyle(
                                        fontSize: 13, color: p.textFaint),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '先点一下页面里的视频封面，或点地址栏右侧的雷达图标手动嗅探',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        fontSize: 11.5, color: p.textDisabled),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : items.isEmpty
                            ? Center(
                                child: Text(
                                  _overlayOnly
                                      ? '还没有捕获到浮层播放的视频'
                                      : (adCount > 0 && !_showAds
                                          ? '只嗅探到 $adCount 个疑似广告，点「疑似广告」可查看'
                                          : '当前筛选下没有资源'),
                                  style: TextStyle(
                                      fontSize: 12.5, color: p.textFaint),
                                ),
                              )
                            : ListView.separated(
                                padding: EdgeInsets.only(
                                    bottom: widget.hasPlayer ? 140 : 20),
                                itemCount: items.length,
                                separatorBuilder: (_, __) =>
                                    Divider(height: 1, color: p.border),
                                itemBuilder: (context, i) =>
                                    _tile(context, p, items[i]),
                              ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _header(
      AppPalette p, List<SniffedMedia> all, List<SniffedMedia> items) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
      child: Row(
        children: <Widget>[
          Icon(Icons.bolt, color: p.accent, size: 19),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  all.isEmpty ? '嗅探资源' : '已聚合 ${all.length} 个资源',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '同一视频的分片与码率变体已合并，不重复列出',
                  style: TextStyle(fontSize: 10.5, color: p.textFaint),
                ),
              ],
            ),
          ),
          if (items.isNotEmpty)
            FilledButton.tonalIcon(
              onPressed: () => _downloadAll(items),
              icon: const Icon(Icons.download, size: 16),
              label: Text('全部下载 ${items.length}'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
          IconButton(
            tooltip: '清空嗅探结果',
            icon: Icon(Icons.delete_outline, size: 18, color: p.textFaint),
            onPressed: all.isEmpty ? null : widget.state.clearSniffed,
          ),
        ],
      ),
    );
  }

  Widget _toolbar(
    AppPalette p,
    List<_SniffGroup> groups,
    Map<_SniffGroup, int> counts,
    int total,
    int overlayCount,
    int adCount,
  ) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              color: p.surfaceAlt,
              borderRadius: BorderRadius.circular(p.isCyber ? 3 : 18),
              border: Border.all(color: p.border),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.search, size: 16, color: p.textFaint),
                const SizedBox(width: 7),
                Expanded(
                  child: TextField(
                    controller: _search,
                    onChanged: (v) => setState(() => _query = v),
                    style: TextStyle(fontSize: 12.5, color: p.text),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: '搜索资源名或地址',
                      hintStyle: TextStyle(fontSize: 12, color: p.textDisabled),
                    ),
                  ),
                ),
                if (_query.isNotEmpty)
                  InkWell(
                    onTap: () {
                      _search.clear();
                      setState(() => _query = '');
                    },
                    child: Icon(Icons.cancel, size: 14, color: p.textDisabled),
                  ),
              ],
            ),
          ),
        ),
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: <Widget>[
              _chip(p, '全部', total, _group == null,
                  () => setState(() => _group = null)),
              for (final g in groups)
                _chip(p, g.label, counts[g] ?? 0, _group == g,
                    () => setState(() => _group = g)),
              if (overlayCount > 0)
                _chip(
                  p,
                  '浮层捕获',
                  overlayCount,
                  _overlayOnly,
                  () => setState(() => _overlayOnly = !_overlayOnly),
                  icon: Icons.picture_in_picture_alt,
                ),
              if (adCount > 0)
                _chip(
                  p,
                  '疑似广告',
                  adCount,
                  _showAds,
                  () => setState(() => _showAds = !_showAds),
                  icon: Icons.report_gmailerrorred,
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _chip(
    AppPalette p,
    String label,
    int count,
    bool active,
    VoidCallback onTap, {
    IconData? icon,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            color: active ? p.accent.withValues(alpha: 0.16) : p.surfaceAlt,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: active ? p.accent.withValues(alpha: 0.55) : p.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...[
                Icon(icon, size: 12, color: active ? p.accent : p.textFaint),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? p.accent : p.textSub,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 10,
                  color: active ? p.accent : p.textDisabled,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 跨域 iframe 播放器：拿不到里面的视频地址，只能提供「打开它继续嗅探」。
  Widget _hintCard(AppPalette p, List<ClickSniffEvent> hints) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 8),
      decoration: BoxDecoration(
        color: p.surfaceAlt,
        borderRadius: BorderRadius.circular(p.isCyber ? 3 : 10),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.open_in_new, size: 14, color: p.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '跨域播放器 ${hints.length} 个 · 打开后可在那一页继续嗅探',
                  style: TextStyle(fontSize: 11.5, color: p.textSub),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          for (final h in hints.take(3))
            InkWell(
              onTap: () {
                Navigator.of(context).pop();
                widget.onOpenPage(h.url);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Text(
                  h.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: p.textFaint),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, AppPalette p, SniffedMedia m) {
    final agg = <String>[
      if (m.variantCount > 0) '${m.variantCount + 1} 个地址',
      if (m.segmentCount > 0) '${m.segmentCount} 个分片',
    ].join(' · ');
    final note = <String>[
      if (m.suspectAd) '疑似广告 · ${m.adReason}',
      // 鉴权头只在内存里、不落盘，这里只提示「带了头」，不暴露名字之外的内容
      if (m.requestHeaders.isNotEmpty) '已带鉴权头',
      m.captureNote,
    ].where((e) => e.isNotEmpty).join(' · ');
    return ListTile(
      dense: true,
      onTap: () => showFullMediaUrl(context, p, m),
      leading: Icon(
        m.suspectAd
            ? Icons.report_gmailerrorred
            : (m.overlayPlay
                ? Icons.picture_in_picture_alt
                : (m.isPlayable
                    ? Icons.playlist_play
                    : Icons.view_list_outlined)),
        size: 20,
        color: m.suspectAd ? p.textFaint : p.accent,
      ),
      title: Text(
        m.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 13, color: p.text),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            // 判定说明放最前：窄屏下副标题会被省略号截断，
            // 「疑似广告 · 路径段 /ads」必须第一眼就能看到
            '${note.isEmpty ? '' : '$note · '}'
            '${m.kindLabel} · ${m.source}${agg.isEmpty ? '' : ' · $agg'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: m.overlayPlay ? p.accent : p.textFaint,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            m.url,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: p.textDisabled),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (m.isPlayable || m.needsSegmentDownload)
            IconButton(
              tooltip: m.isPlayable ? '用 Nerelict 打开' : '用已嗅探的分片边下边播',
              icon: Icon(Icons.play_circle_outline, color: p.accent),
              onPressed: () {
                Navigator.of(context).pop();
                widget.onPlay(m);
              },
            ),
          IconButton(
            tooltip: '加入下载',
            icon: Icon(Icons.download, color: p.accent),
            onPressed: () {
              Navigator.of(context).pop();
              downloadFromMedia(widget.pageContext, widget.state, m);
            },
          ),
        ],
      ),
    );
  }
}

/// 点条目查看完整资源地址（可选择复制），避免列表里长 URL 被折叠。
void showFullMediaUrl(BuildContext context, AppPalette p, SniffedMedia media) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: p.surface,
      title:
          Text(media.kindLabel, style: TextStyle(fontSize: 15, color: p.text)),
      content: SingleChildScrollView(
        child: SelectableText(
          media.url,
          style: TextStyle(fontSize: 12, color: p.textSub, height: 1.5),
        ),
      ),
      actions: <Widget>[
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('完成'),
        ),
      ],
    ),
  );
}
