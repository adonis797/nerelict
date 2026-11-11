import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/player_request.dart' show PlayerMode;
import 'services/app_log.dart';
import 'services/screen_awake.dart';
import 'state/app_state.dart';
import 'state/history_state.dart';
import 'state/settings_state.dart';
import 'state/web_favorites_state.dart';
import 'ui/app_theme.dart';
import 'ui/browser_tab.dart';
import 'ui/cyber_backdrop.dart';
import 'ui/files_tab.dart';
import 'ui/player_page.dart';
import 'ui/settings_tab.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installGlobalErrorLogging();
  AppLog.instance.d('App', 'launch');
  final settings = SettingsState();
  await settings.load(); // 启动前载入，避免主题闪一下
  runApp(M8BrowserApp(settings: settings));
}

class M8BrowserApp extends StatelessWidget {
  const M8BrowserApp({super.key, required this.settings});

  final SettingsState settings;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsState>.value(value: settings),
        ChangeNotifierProvider(
          create: (_) => AppState(
            autoConvertMp4: () => settings.mp4Conversion,
            downloadConcurrency: () => settings.downloadConcurrency,
            wifiOnly: () => settings.wifiOnly,
            downloadRetries: () => settings.downloadRetries,
            resolveExportDir: () async {
              final prefs = await SharedPreferences.getInstance();
              return prefs.getString(SettingsState.kDownloadDirUri);
            },
            loadPlayerOffset: () async {
              final prefs = await SharedPreferences.getInstance();
              final dx = prefs.getDouble('player_offset_dx');
              final dy = prefs.getDouble('player_offset_dy');
              if (dx == null || dy == null) return null;
              return Offset(dx, dy);
            },
            savePlayerOffset: (offset) async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setDouble('player_offset_dx', offset.dx);
              await prefs.setDouble('player_offset_dy', offset.dy);
            },
          ),
        ),
        ChangeNotifierProvider(
          create: (_) {
            final history = HistoryState();
            history.load();
            return history;
          },
        ),
        ChangeNotifierProvider(
          create: (_) {
            final favorites = WebFavoritesState();
            favorites.load();
            return favorites;
          },
        ),
      ],
      child: Consumer<SettingsState>(
        builder: (context, s, _) => _ScreenAwake(
          enabled: s.keepScreenOn,
          child: MaterialApp(
            title: 'Nerelict',
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(s.themeMode),
            // builder 位于 Navigator 之上：浮层盖住页面、底部弹窗、SnackBar 与对话框，
            // 始终是当前应用里层级最高的内容。
            builder: (context, child) => Consumer<AppState>(
              builder: (context, appState, _) => _PlayerLayer(
                state: appState,
                navigator: child ?? const SizedBox.shrink(),
              ),
            ),
            home: const HomeScreen(),
          ),
        ),
      ),
    );
  }
}

/// 负责 MA8N浮层的定位与拖动。
///
/// 默认仍贴在底部（保持原布局）；用户从标题栏拖动后改用绝对定位，
/// 位置写入 SharedPreferences，关闭再打开、甚至重启应用都保持不变。
class _PlayerLayer extends StatefulWidget {
  const _PlayerLayer({required this.state, required this.navigator});

  final AppState state;
  final Widget navigator;

  @override
  State<_PlayerLayer> createState() => _PlayerLayerState();
}

class _PlayerLayerState extends State<_PlayerLayer> {
  /// 小窗贴边留白
  static const double _sideMargin = 8;

  /// 底部导航高度：小窗要避让，别盖住切换入口
  static const double _navBarHeight = 62;

  /// 面板顶部的安全间距（状态栏下沿再留一点）
  static const double _topInset = 6;
  final GlobalKey _panelKey = GlobalKey();

  Offset? _dragOffset;
  Offset? _dragStart;
  Offset _dragDelta = Offset.zero;
  double? _dragHeight;

  /// 播放面板在本次播放会话内的位置：
  /// 新视频默认贴着页面顶部，拖动后保持到本次播放结束（不跨视频持久化）。
  Offset? _panelOffset;
  String? _playerKey;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_syncPlayerSession);
    _playerKey = _currentPlayerKey;
  }

  @override
  void dispose() {
    widget.state.removeListener(_syncPlayerSession);
    super.dispose();
  }

  String? get _currentPlayerKey {
    final player = widget.state.player;
    return player == null ? null : '${player.url}_${player.local}';
  }

  /// 换了视频就回到顶部：避免上一个视频拖到半屏的位置影响新视频。
  /// 这里只改字段不 setState，AppState 的同一次通知已会让本层重建。
  void _syncPlayerSession() {
    final key = _currentPlayerKey;
    if (key == _playerKey) return;
    _playerKey = key;
    _panelOffset = null;
    _dragOffset = null;
    _dragStart = null;
    _dragDelta = Offset.zero;
  }

  void _onPanStart(DragStartDetails _) {
    final box = _panelKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    _dragHeight = box.size.height;
    _dragStart = box.localToGlobal(Offset.zero);
    _dragDelta = Offset.zero;
    _dragOffset = _dragStart;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final start = _dragStart;
    if (start == null) return;
    final size = MediaQuery.of(context).size;
    final mini = widget.state.playerMode == PlayerMode.mini;
    // 累加每帧位移：直接拿单帧 delta 叠加会「只动一下再回弹」
    _dragDelta += details.delta;
    final next = Offset(
      start.dx + _dragDelta.dx,
      start.dy + _dragDelta.dy,
    );
    setState(() {
      _dragOffset = mini ? _clampMini(next, size) : _clampPanel(next, size);
    });
  }

  void _onPanEnd(DragEndDetails _) {
    final offset = _dragOffset;
    if (offset == null) return;
    final size = MediaQuery.of(context).size;
    if (widget.state.playerMode == PlayerMode.mini) {
      final snapped = _clampMini(offset, size);
      // 迷你小窗：松手后贴到最近的一侧，避免停在屏幕中间挡内容
      final left = _sideMargin;
      final right = size.width - _miniWidth - _sideMargin;
      final snapRight = offset.dx + _miniWidth / 2 >= size.width / 2;
      widget.state.setPlayerOffset(
        Offset(snapRight ? right : left, snapped.dy),
      );
    } else {
      // 面板铺满两侧，只能上下移动；位置只在本次播放会话内保留
      _panelOffset = _clampPanel(offset, size);
    }
    setState(() {
      _dragOffset = null;
      _dragStart = null;
      _dragDelta = Offset.zero;
    });
  }

  /// 小窗可拖动范围：避开状态栏、底部导航与系统手势条。
  Offset _clampMini(Offset offset, Size size) {
    final media = MediaQuery.of(context);
    final minX = _sideMargin;
    final maxX = size.width - _miniWidth - _sideMargin;
    final minY = media.padding.top + 6;
    final maxY =
        size.height - media.padding.bottom - _navBarHeight - _miniHeight - 6;
    return Offset(
      offset.dx.clamp(minX, maxX < minX ? minX : maxX),
      offset.dy.clamp(minY, maxY < minY ? minY : maxY),
    );
  }

  /// 面板可拖动范围：左右铺满，所以只约束纵向，避免盖住状态栏/导航栏。
  Offset _clampPanel(Offset offset, Size size) {
    final media = MediaQuery.of(context);
    final height = _dragHeight ?? 320;
    final minY = media.padding.top + _topInset;
    final maxY =
        (size.height - media.padding.bottom - _navBarHeight - height - 6)
            .clamp(minY, size.height);
    return Offset(0, offset.dy.clamp(minY, maxY));
  }

  static const double _miniWidth = 212;
  static const double _miniHeight = 160;

  @override
  Widget build(BuildContext context) {
    final player = widget.state.player;
    final mode = widget.state.playerMode;
    // 小窗用持久化位置；面板只用本次会话的位置（默认顶部）
    final offset = _dragOffset ??
        (mode == PlayerMode.mini ? widget.state.playerOffset : _panelOffset);
    final size = MediaQuery.of(context).size;
    final media = MediaQuery.of(context);
    final hint = widget.state.hint;
    final p = paletteOf(context);

    final children = <Widget>[widget.navigator];

    if (player != null) {
      final panel = SizedBox(
        key: _panelKey,
        child: PlayerPanel(
          key: ValueKey('${player.url}_${player.local}'),
          request: player,
          onClose: widget.state.closePlayer,
          onDragStart: _onPanStart,
          onDragUpdate: _onPanUpdate,
          onDragEnd: _onPanEnd,
        ),
      );

      // 三种形态共用同一个 PlayerPanel 实例与播放内核：切换形态不会重建控制器。
      final Widget positioned;
      switch (mode) {
        case PlayerMode.fullscreen:
          positioned = Positioned.fill(child: panel);
          break;
        case PlayerMode.mini:
          final dockBottom = media.padding.bottom + _navBarHeight;
          final left = offset?.dx ?? size.width - _miniWidth - _sideMargin;
          final top = offset?.dy ??
              size.height - dockBottom - _miniHeight - _sideMargin;
          positioned = AnimatedPositioned(
            // 拖动时跟手（零动画），松手贴边时给一个短过渡
            duration: _dragOffset == null
                ? const Duration(milliseconds: 220)
                : Duration.zero,
            curve: Curves.easeOutCubic,
            left:
                left.clamp(_sideMargin, size.width - _miniWidth - _sideMargin),
            top: top.clamp(
              media.padding.top + 6,
              size.height -
                  media.padding.bottom -
                  _navBarHeight -
                  _miniHeight -
                  6,
            ),
            width: _miniWidth,
            child: panel,
          );
          break;
        case PlayerMode.panel:
          // 默认贴住页面顶部、左右铺满；拖动只改变纵向位置
          final minTop = media.padding.top + _topInset;
          final top = (offset?.dy ?? minTop).clamp(
            minTop,
            size.height - media.padding.bottom - _navBarHeight - 120,
          );
          positioned = Positioned(
            left: 0,
            right: 0,
            top: top,
            child: panel,
          );
      }
      children.add(positioned);
    }

    // 悬停提示位于最上层：播放器浮层、页面、底部弹窗都盖不住它。
    if (hint != null) {
      children.add(Positioned(
        left: 0,
        right: 0,
        bottom: player == null ? 92 : 104,
        child: IgnorePointer(
          child: Center(
            child: _HintToast(
              text: hint,
              actionLabel: widget.state.hintAction,
              onAction: widget.state.hintActionTap,
              duration: widget.state.hintDuration,
              token: widget.state.hintToken,
              palette: p,
              onExpired: widget.state.clearHint,
            ),
          ),
        ),
      ));
    }

    return Stack(children: children);
  }
}

/// 约 0.5 秒后自动淡出的底部悬停提示。
class _HintToast extends StatefulWidget {
  const _HintToast({
    required this.text,
    required this.token,
    required this.palette,
    required this.onExpired,
    required this.duration,
    this.actionLabel,
    this.onAction,
  });

  final String text;
  final int token;
  final AppPalette palette;
  final void Function(int token) onExpired;
  final Duration duration;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  State<_HintToast> createState() => _HintToastState();
}

class _HintToastState extends State<_HintToast> {
  Timer? _timer;
  Timer? _fade;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _play();
  }

  @override
  void didUpdateWidget(covariant _HintToast oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.token != widget.token) _play();
  }

  void _play() {
    _timer?.cancel();
    _fade?.cancel();
    // 首次插帧后再显示，让淡入动画能跑起来
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _visible = true);
    });
    _timer = Timer(widget.duration, () => _dismiss());
  }

  void _dismiss() {
    if (!mounted) return;
    _timer?.cancel();
    setState(() => _visible = false);
    _fade?.cancel();
    _fade = Timer(const Duration(milliseconds: 160), () {
      if (mounted) widget.onExpired(widget.token);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fade?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final hasAction = widget.actionLabel != null;
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 24),
        padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
        decoration: BoxDecoration(
          color: p.isCyber
              ? p.surfaceAlt.withValues(alpha: 0.96)
              : const Color(0xF21B2230),
          borderRadius: BorderRadius.circular(p.isCyber ? 3 : 20),
          border: Border.all(
            color: p.isCyber
                ? p.accent.withValues(alpha: 0.65)
                : Colors.white.withValues(alpha: 0.10),
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.check_circle_outline,
              size: 15,
              color: p.isCyber ? p.accentAlt : const Color(0xFF7ED0A8),
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                widget.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: p.isCyber ? p.text : Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (hasAction) ...<Widget>[
              const SizedBox(width: 4),
              TextButton(
                onPressed: () {
                  widget.onAction?.call();
                  _dismiss();
                },
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                ),
                child: Text(
                  widget.actionLabel!,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: p.isCyber ? p.accent : const Color(0xFF8FD3FF),
                  ),
                ),
              ),
            ],
            const SizedBox(width: 2),
            InkWell(
              onTap: _dismiss,
              customBorder: const CircleBorder(),
              child: Padding(
                padding: const EdgeInsets.all(5),
                child: Icon(
                  Icons.close,
                  size: 14,
                  color: p.isCyber ? p.textFaint : Colors.white60,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 主界面：三页 IndexedStack + 底部导航，同时统一处理系统返回键。
///
/// 返回顺序：收播放器 → 回浏览器页 → 交给页面拦截器（网页回退 / 收起筛选）
/// → 首页再按一次退出。所有判断集中在一处，页面只注册自己的能力。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  DateTime? _lastBackAt;

  Future<void> _handleBack(AppState state) async {
    if (state.player != null) {
      // 全屏优先退回浮层；其余形态直接关闭播放
      if (state.playerMode == PlayerMode.fullscreen) {
        state.setPlayerMode(PlayerMode.panel);
      } else {
        state.closePlayer();
      }
      return;
    }
    if (state.tabIndex != 0) {
      state.setTab(0);
      return;
    }
    if (await state.handleBack()) return;

    final now = DateTime.now();
    if (_lastBackAt != null &&
        now.difference(_lastBackAt!) < const Duration(seconds: 2)) {
      await SystemNavigator.pop();
      return;
    }
    _lastBackAt = now;
    state.showToast('再按一次退出');
  }

  @override
  Widget build(BuildContext context) {
    final index = context.select<AppState, int>((s) => s.tabIndex);
    final active = context.select<AppState, int>((s) => s.activeCount);
    final state = context.read<AppState>();
    final p = paletteOf(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _handleBack(state);
      },
      child: Scaffold(
        body: Stack(
          children: <Widget>[
            // 赛博朋克主题的装饰底：霓虹辉光 + 透视网格 + 扫描线 + 半调网点
            if (p.isCyber)
              const Positioned.fill(
                child: IgnorePointer(child: CyberBackdrop()),
              ),
            IndexedStack(
              index: index,
              children: const [
                BrowserTab(),
                FilesTab(),
                SettingsTab(),
              ],
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          height: 62,
          backgroundColor: p.navBg,
          surfaceTintColor: Colors.transparent,
          indicatorColor: p.accent.withValues(alpha: p.isCyber ? 0.30 : 0.18),
          onDestinationSelected: state.setTab,
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.public_outlined),
              selectedIcon: Icon(Icons.public),
              label: '浏览器',
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: active > 0,
                label: Text('$active'),
                child: const Icon(Icons.folder_outlined),
              ),
              selectedIcon: Badge(
                isLabelVisible: active > 0,
                label: Text('$active'),
                child: const Icon(Icons.folder),
              ),
              label: '文件',
            ),
            const NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '设置',
            ),
          ],
        ),
      ),
    );
  }
}

/// 把「屏幕常亮」设置同步到原生窗口 flag：
/// 应用在前台时保持亮屏，切到后台由系统恢复正常息屏策略。
class _ScreenAwake extends StatefulWidget {
  const _ScreenAwake({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  State<_ScreenAwake> createState() => _ScreenAwakeState();
}

class _ScreenAwakeState extends State<_ScreenAwake> {
  @override
  void initState() {
    super.initState();
    ScreenAwake.setEnabled(widget.enabled);
  }

  @override
  void didUpdateWidget(covariant _ScreenAwake oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      ScreenAwake.setEnabled(widget.enabled);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
