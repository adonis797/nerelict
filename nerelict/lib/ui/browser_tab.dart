import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../models/player_request.dart' show PlayerMode;
import '../models/sniffed_media.dart';
import '../services/player_probe_js.dart';
import '../services/sniffer_js.dart';
import '../services/video_float_js.dart';
import '../state/app_state.dart';
import '../state/history_state.dart';
import '../state/settings_state.dart';
import '../state/web_favorites_state.dart';
import '../ui/app_theme.dart';
import '../ui/history_page.dart';
import '../ui/neon_progress_bar.dart';
import '../ui/site_icon.dart';
import '../ui/web_favorites_page.dart';
import '../ui/widgets/app_menu.dart';

/// 地址栏右上角三点菜单的动作
enum _UrlMenuAction { favorite, sniff, favorites }

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

  /// 当前页面里已经处理过的视频地址，避免关闭 MA8N后反复接管
  final Set<String> _handled = <String>{};

  /// 网页视频长按后出现的「用 MA8N打开」浮标
  String? _floatUrl;
  String _floatPage = '';
  String _floatTitle = '';

  Color? _appliedWebBg;

  @override
  void initState() {
    super.initState();
    _state = context.read<AppState>();
    _state.addBackInterceptor(_handleSystemBack);

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
      ..setNavigationDelegate(
        NavigationDelegate(
          // 只放行 http/https，拦掉 intent://、baiduboxapp:// 这类 App 深链
          onNavigationRequest: (request) {
            final url = request.url;
            if (url.startsWith('http://') || url.startsWith('https://')) {
              return NavigationDecision.navigate;
            }
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
            _handled.clear(); // 新页面重新开始自动接管
            // 离开上一页：清空该页的嗅探资源、选中项、播放浮层与临时数据
            _state.resetPageResources();
            _floatUrl = null;
            setState(() {
              _loading = true;
              _syncUrl(url);
            });
            _inject();
          },
          onPageFinished: (url) async {
            if (!mounted) return;
            setState(() {
              _loading = false;
              _progress = 1;
              _syncUrl(url);
            });
            _inject();
            _refreshNavState();
            // 记录浏览历史（非 http/https 地址由 HistoryState 自行过滤）
            try {
              final title = await _controller.getTitle();
              if (mounted) {
                await context.read<HistoryState>().add(url, title ?? '');
              }
            } catch (_) {}
          },
          onUrlChange: (change) {
            final url = change.url;
            if (url != null && mounted) _syncUrl(url);
          },
          onWebResourceError: (err) {
            if (!mounted || err.isForMainFrame != true) return;
            setState(() => _loading = false);
            _toast('页面加载失败：${err.description}');
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
    _state.removeBackInterceptor(_handleSystemBack);
    // 页面卸载：同样清空本页资源与播放状态（销毁阶段不再通知监听者）
    _state.resetPageResources(notify: false);
    _handled.clear();
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

  /// 三支注入脚本合并成一次通道调用：相比串行三次往返，
  /// 页面首帧前的空窗更短；任一支脚本异常也不会影响其他两支。
  String get _injectedScript => <String>[
        kSniffJs,
        kPlayerProbeJs,
        kVideoFloatJs
      ].map((s) => 'try{\n$s\n}catch(e){}\n').join();

  Future<void> _inject() async {
    try {
      await _controller.runJavaScript(_injectedScript);
    } catch (_) {
      // 页面可能禁止执行脚本，忽略
    }
  }

  /// 网页里检测到可播放视频 -> 在当前页面上打开 MA8N浮层。
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
      if (_handled.contains(url)) return;
      _handled.add(url);

      final page = (data['page'] as String?) ?? '';
      final title = (data['title'] as String?) ?? '';

      // 先暂停网页里的 <video>，避免和 MA8N同时出声
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
    // 只有 M3U8 播放列表能直接播放；分片组作为整体下载
    if (!media.isPlayable) return;
    _state.selectResource(media.id);
    try {
      await _controller.runJavaScript(kPauseWebVideosJs);
    } catch (_) {}
    if (!mounted) return;
    _state.openPlayer(
      url: media.url,
      title: media.pageTitle,
      referer: media.pageUrl.startsWith('http') ? media.pageUrl : null,
    );
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
      });
    } catch (_) {}
  }

  Future<void> _openFloatPlayer() async {
    final url = _floatUrl;
    if (url == null) return;
    final page = _floatPage;
    final title = _floatTitle;
    setState(() => _floatUrl = null);
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

  void _open(String input) {
    final text = input.trim();
    if (text.isEmpty) return;

    Uri uri;
    final looksLikeUrl = !text.contains(' ') && text.contains('.');
    if (looksLikeUrl) {
      uri = Uri.parse(text.contains('://') ? text : 'https://$text');
    } else {
      // 搜索引擎由「设置」决定，默认 Google；只影响之后发起的搜索
      final engine = context.read<SettingsState>().searchEngine;
      uri = Uri.parse(engine.searchUrl(text));
    }
    _controller.loadRequest(uri);
    setState(() {
      _hasPage = true;
      _urlCtrl.text = uri.toString();
      _currentUrl = uri.toString();
    });
  }

  /// 右上角手动嗅探：对当前页面主动重新扫描一次。
  /// 复用同一套上报/聚合逻辑，已有资源不会重复出现。
  Future<void> _manualSniff() async {
    try {
      await _controller.runJavaScript(kSniffJs);
      await _controller.runJavaScript(kManualSniffJs);
    } catch (_) {}
    if (!mounted) return;
    _toast('已重新嗅探当前页，点 ⚡ 查看资源');
  }

  void _goHome() {
    // 回首页前先停掉网页里的声音，避免 WebView 移出树后仍在后台播放
    unawaited(_controller.runJavaScript(kPauseWebVideosJs).catchError((_) {}));
    setState(() {
      _hasPage = false;
      _canGoBack = false;
      _currentUrl = null;
      _urlCtrl.clear();
      _loading = false;
      _progress = 1;
    });
  }

  /// 系统返回：先回退网页，退无可退时回首页；首页交还给 HomeScreen 处理。
  Future<bool> _handleSystemBack() async {
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
                          onOpen: _openFloatPlayer,
                          onDismiss: () => setState(() => _floatUrl = null),
                        ),
                      ),
                  ],
                )
              else
                _StartPage(onOpen: _open),
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
            onPressed: _hasPage ? () => _controller.reload() : null,
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
            onPressed: () => showSniffedSheet(context, _state, _openPlayer),
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
                      value: _UrlMenuAction.favorites,
                      label: '全部网页收藏',
                      icon: Icons.bookmarks_outlined,
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
      case _UrlMenuAction.favorites:
        final url = await Navigator.of(context).push<String>(
          MaterialPageRoute<String>(builder: (_) => const WebFavoritesPage()),
        );
        if (url != null && mounted) _open(url);
        break;
    }
  }
}

/// 原生起始页：不加载任何远端首页，避免被 App 深链劫持
class _StartPage extends StatelessWidget {
  const _StartPage({required this.onOpen});

  final void Function(String) onOpen;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 44, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [p.accent, p.accentAlt],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.bolt, color: Colors.white, size: 26),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Nerelict',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: p.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '浏览网页 · 视频接管 · 嗅探下载',
                    style: TextStyle(fontSize: 12, color: p.textFaint),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 22),
          // 首页居中搜索框：输入即用设置里的搜索引擎，也可直接输入网址
          _HomeSearchBox(onSubmit: onOpen),
          const SizedBox(height: 26),
          _Step(
            p: p,
            index: '1',
            title: '打开视频页面',
            desc: '在上方地址栏输入网址，或点下面的快速访问',
          ),
          _Step(
            p: p,
            index: '2',
            title: '自动接管播放',
            desc: '检测到可播放视频时在当前页打开 MA8N，支持 HLS / MP4',
          ),
          _Step(
            p: p,
            index: '3',
            title: '下载与 MP4',
            desc: '播放器内一键下载（不跳页）；完成后自动转 MP4 并清理原 TS，也可在「文件」页手动批量转换',
          ),
          const SizedBox(height: 20),
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
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: p.border),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 15, color: p.textFaint),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '自动接管、浅色主题、MP4 转换都可以在「设置」里开关。'
                    '下载位置也可在「设置」中自由选择。',
                    style: TextStyle(
                      fontSize: 11,
                      color: p.textFaint,
                      height: 1.5,
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
}

/// 首页居中搜索框：霓虹渐变描边 + 聚焦光晕，提交后走与地址栏同一条打开逻辑。
class _HomeSearchBox extends StatefulWidget {
  const _HomeSearchBox({required this.onSubmit});

  final void Function(String) onSubmit;

  @override
  State<_HomeSearchBox> createState() => _HomeSearchBoxState();
}

class _HomeSearchBoxState extends State<_HomeSearchBox> {
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!mounted) return;
      setState(() => _focused = _focus.hasFocus);
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    _focus.unfocus();
    widget.onSubmit(text);
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final engine = context.watch<SettingsState>().searchEngine;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(1.2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: _focused
                  ? const <Color>[kNeonCyan, Color(0xFF7C5CFF), kNeonMagenta]
                  : <Color>[
                      p.border,
                      p.border,
                    ],
            ),
            boxShadow: _focused
                ? <BoxShadow>[
                    BoxShadow(
                      color: kNeonCyan.withValues(alpha: 0.30),
                      blurRadius: 18,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Container(
            height: 48,
            padding: const EdgeInsets.only(left: 15, right: 7),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(27),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.search,
                  size: 18,
                  color: _focused ? kNeonCyan : p.textFaint,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _focus,
                    textInputAction: TextInputAction.search,
                    textAlignVertical: TextAlignVertical.center,
                    autocorrect: false,
                    style: TextStyle(fontSize: 13.5, color: p.text),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: '搜索或输入网址 · ${engine.label}',
                      hintStyle: TextStyle(fontSize: 13, color: p.textFaint),
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                InkWell(
                  onTap: _submit,
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: <Color>[kNeonCyan, kNeonMagenta],
                      ),
                    ),
                    child: const Icon(Icons.arrow_forward,
                        size: 17, color: Colors.white),
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
class _VideoFloatEntry extends StatelessWidget {
  const _VideoFloatEntry({required this.onOpen, required this.onDismiss});

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
            Icon(Icons.smart_display_outlined, size: 17, color: p.accent),
            const SizedBox(width: 7),
            GestureDetector(
              onTap: onOpen,
              child: const Text(
                '用 MA8N打开',
                style: TextStyle(
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

class _Step extends StatelessWidget {
  const _Step({
    required this.p,
    required this.index,
    required this.title,
    required this.desc,
  });

  final AppPalette p;
  final String index;
  final String title;
  final String desc;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
            child: Text(
              index,
              style: TextStyle(
                fontSize: 11,
                color: p.accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  desc,
                  style: TextStyle(
                    fontSize: 12,
                    color: p.textFaint,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
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
  state.startDownload(
    url: media.url,
    title: title,
    referer: media.pageUrl.isEmpty ? null : media.pageUrl,
    segments: media.needsSegmentDownload ? media.segmentUrls : null,
  );
  // 同样只给悬停提示：不打断当前网页与播放
  state.showHint(media.needsSegmentDownload
      ? '已将 ${media.segmentCount} 个分片加入下载'
      : '已加入下载队列');
}

/// 右上角「小闪电」：嗅探结果的唯一入口。
///
/// 底部横幅已移除，这里展示全部聚合结果；面板默认占 62% 并可上拖到 95%，
/// 点条目可查看完整地址，播放/下载入口保持原样。
void showSniffedSheet(
  BuildContext pageContext,
  AppState state,
  Future<void> Function(SniffedMedia media) onPlay,
) {
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
    required this.hasPlayer,
  });

  final BuildContext pageContext;
  final AppState state;
  final Future<void> Function(SniffedMedia media) onPlay;
  final bool hasPlayer;

  @override
  State<_SniffSheet> createState() => _SniffSheetState();
}

class _SniffSheetState extends State<_SniffSheet> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  _SniffGroup? _group;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<SniffedMedia> _visible(List<SniffedMedia> all) {
    final q = _query.trim().toLowerCase();
    return all.where((m) {
      if (_group != null && _groupOf(m) != _group) return false;
      if (q.isEmpty) return true;
      return m.label.toLowerCase().contains(q) ||
          m.url.toLowerCase().contains(q) ||
          m.kindLabel.toLowerCase().contains(q);
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
        final counts = <_SniffGroup, int>{
          for (final g in _SniffGroup.values)
            g: all.where((m) => _groupOf(m) == g).length,
        };
        final groups =
            _SniffGroup.values.where((g) => (counts[g] ?? 0) > 0).toList();

        return Column(
          children: <Widget>[
            _header(p, all, items),
            _toolbar(p, groups, counts, all.length),
            Expanded(
              child: all.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(Icons.radar_outlined,
                                size: 40, color: p.textDisabled),
                            const SizedBox(height: 12),
                            Text(
                              '还没有嗅探到视频资源',
                              style:
                                  TextStyle(fontSize: 13, color: p.textFaint),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '播放网页里的视频，或点地址栏右侧的雷达图标手动嗅探',
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
                            '当前筛选下没有资源',
                            style:
                                TextStyle(fontSize: 12.5, color: p.textFaint),
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
    VoidCallback onTap,
  ) {
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

  Widget _tile(BuildContext context, AppPalette p, SniffedMedia m) {
    final agg = <String>[
      if (m.variantCount > 0) '${m.variantCount + 1} 个地址',
      if (m.segmentCount > 0) '${m.segmentCount} 个分片',
    ].join(' · ');
    return ListTile(
      dense: true,
      onTap: () => showFullMediaUrl(context, p, m),
      leading: Icon(
        m.isPlayable ? Icons.playlist_play : Icons.view_list_outlined,
        size: 20,
        color: p.accent,
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
            '${m.kindLabel} · ${m.source}${agg.isEmpty ? '' : ' · $agg'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: p.textFaint),
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
          if (m.isPlayable)
            IconButton(
              tooltip: '用 MA8N打开',
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
