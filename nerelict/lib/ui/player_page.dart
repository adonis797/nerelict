import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../models/player_request.dart';
import '../services/favorites.dart';
import '../services/hls_parser.dart' show HlsVariant;
import '../services/media_source.dart';
import '../services/playback_memory.dart';
import '../services/player_core.dart';
import '../services/player_platform.dart';
import '../services/streaming_proxy.dart';
import '../state/app_state.dart';
import '../state/settings_state.dart';
import 'app_theme.dart';

enum _MoreAction {
  pip,
  cast,
  snapshot,
  share,
  favorite,
  favorites,
  loop,
  lock,
  clearMemory,
}

/// MA8N：浮层 / 全屏 / 迷你小窗三态共用同一个播放内核。
///
/// 位置与置顶层级由 material app builder 里的 _PlayerLayer 负责；
/// 本组件只处理播放、交互与不同形态下的布局。
class PlayerPanel extends StatefulWidget {
  const PlayerPanel({
    super.key,
    required this.request,
    required this.onClose,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
  });

  final PlayerRequest request;
  final VoidCallback onClose;

  /// 仅标题栏响应拖动，视频画面与播放控件仍按原方式交互
  final GestureDragStartCallback? onDragStart;
  final GestureDragUpdateCallback? onDragUpdate;
  final GestureDragEndCallback? onDragEnd;

  @override
  State<PlayerPanel> createState() => _PlayerPanelState();
}

class _PlayerPanelState extends State<PlayerPanel> {
  late final MediaSource _source;
  late final SettingsState _settings;
  final PlaybackMemory _memory = PlaybackMemory();
  final FavoritesStore _favorites = FavoritesStore();

  PlayerCore? _core;
  String? _error;
  MediaProbe _probe = const MediaProbe(isMaster: false, hasDrm: false);

  double _speed = 1.0;
  double _volume = 1.0;
  double _brightness = 0.5;
  bool _looping = false;
  bool _favorite = false;
  bool _locked = false;
  bool _controlsVisible = true;
  bool _usingProxy = false;

  String? _hint;
  String? _subtitleName;
  Duration? _seekTarget;
  Duration _seekBase = Duration.zero;

  List<VideoTrack> _videoTracks = <VideoTrack>[];
  List<VideoAudioTrack> _audioTracks = <VideoAudioTrack>[];

  Timer? _tick;
  Timer? _hideTimer;
  Timer? _hintTimer;
  final TextEditingController _subtitleCtrl = TextEditingController();

  /// 浮层内嵌面板（倍速 / 画质 / 音轨 / 字幕 / 截图 / 收藏）。
  /// 不用 Navigator 弹窗，避免被「始终置顶」的播放器自己盖住。
  Widget? _inlinePanel;

  PlayerMode _lastMode = PlayerMode.panel;
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);
  bool _completedSaved = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _settings = context.read<SettingsState>();
    _source = MediaSource.parse(
      url: widget.request.url,
      title: widget.request.title,
      referer: widget.request.referer,
      local: widget.request.local,
    );
    _speed = _settings.playerSpeed;
    _init();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mode = context.read<AppState>().playerMode;
    if (mode == _lastMode) return;
    _lastMode = mode;
    PlayerPlatform.instance.setOrientation(
      mode == PlayerMode.fullscreen ? 'landscape' : 'auto',
    );
    if (mode == PlayerMode.fullscreen) _showControls();
  }

  Future<void> _init() async {
    if (!_source.supported) {
      _fail(_source.unsupportedReason!);
      return;
    }
    try {
      // 起播不再等 m3u8 探测：探测与内核初始化并行，先出画面再补全码率信息。
      // 同一地址的探测结果有短缓存，重复打开时几乎零成本。
      final cached = cachedProbe(_source);
      if (cached != null) _probe = cached;
      final probeFuture =
          (cached == null && _source.kind == MediaKind.hls && !_source.local)
              ? probePlaylist(_source)
              : Future<MediaProbe>.value(_probe);

      Duration? resumeAt;
      if (_settings.playerAutoResume) {
        final record = await _memory.get(_source.memoryKey);
        if (record != null && record.resumable) {
          resumeAt = Duration(milliseconds: record.positionMs);
        }
      }

      String? playbackUrl;
      if (_settings.playerStreamingCache &&
          !_source.local &&
          _source.kind == MediaKind.hls) {
        try {
          playbackUrl = await StreamingProxy.instance.playbackUrl(_source);
          _usingProxy = true;
        } catch (_) {
          // 代理启动失败直接回退直连，不影响播放
          playbackUrl = null;
        }
      }

      final core = await VideoPlayerCore.create(
        source: _source,
        playbackUrl: playbackUrl,
        initialSpeed: _speed,
        resumeAt: resumeAt,
      );
      if (_disposed) {
        await core.dispose();
        return;
      }
      _core = core;
      core.values.addListener(_onValue);
      setState(() {});

      // 画面已就绪后再收探测结果（失败也只是少一份码率列表）
      _probe = await probeFuture;

      await _preparePlatform();
      await _loadTracks();
      _favorite = await _favorites.contains(_source.url);
      if (mounted) setState(() {});

      if (resumeAt != null) _toast('已从 ${_fmt(resumeAt)} 继续播放');
      if (_probe.hasDrm) {
        _toast('检测到加密流，系统解码器可能不支持播放');
      }
      _showGestureTipIfNeeded();
      _tick = Timer.periodic(const Duration(seconds: 2), (_) {
        if (_disposed) return;
        _saveMemory();
        _publishSession();
      });
      _showControls();
    } catch (e) {
      _fail(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _preparePlatform() async {
    final platform = PlayerPlatform.instance;
    _brightness = await platform.getBrightness();
    _volume = await platform.getVolume();
    await platform.keepScreenOn(true);
    await platform.setOrientation(
      _lastMode == PlayerMode.fullscreen ? 'landscape' : 'auto',
    );
    if (_settings.playerMediaControls) {
      platform.onMediaAction = _onMediaAction;
      await platform.enableMediaControls(true);
      await platform.ensureNotificationPermission();
      _publishSession();
    }
  }

  Future<void> _loadTracks() async {
    final core = _core;
    if (core == null) return;
    // 两条查询互不依赖，并行取回，减少起播后的等待
    final results = await Future.wait<Object>(<Future<Object>>[
      core.videoTracks(),
      core.audioTracks(),
    ]);
    if (!mounted) return;
    setState(() {
      _videoTracks = results[0] as List<VideoTrack>;
      _audioTracks = results[1] as List<VideoAudioTrack>;
    });
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() => _error =
        message.length > 160 ? '${message.substring(0, 160)}…' : message);
  }

  void _onValue() {
    final core = _core;
    if (core == null || _disposed) return;
    final v = core.values.value;
    if (v.duration > Duration.zero &&
        v.position >= v.duration - const Duration(milliseconds: 300) &&
        !_completedSaved) {
      _completedSaved = true;
      _saveMemory(finished: true);
    }
  }

  Future<void> _saveMemory({bool finished = false}) async {
    final core = _core;
    if (core == null) return;
    final now = DateTime.now();
    if (!finished && now.difference(_lastSave) < const Duration(seconds: 5)) {
      return;
    }
    _lastSave = now;
    await _memory.save(
      PlaybackRecord(
        key: _source.memoryKey,
        url: widget.request.url,
        title: _source.displayTitle,
        positionMs: finished ? 0 : core.position.inMilliseconds,
        durationMs: core.duration.inMilliseconds,
        speed: _speed,
        updatedAt: now.millisecondsSinceEpoch,
        local: _source.local,
        referer: _source.referer,
      ),
    );
  }

  void _publishSession() {
    if (!_settings.playerMediaControls) return;
    final core = _core;
    if (core == null) return;
    PlayerPlatform.instance.updateSession(
      title: _source.displayTitle,
      playing: core.isPlaying,
      positionMs: core.position.inMilliseconds,
      durationMs: core.duration.inMilliseconds,
      speed: _speed,
    );
  }

  void _onMediaAction(String action, int positionMs) {
    final core = _core;
    if (core == null) return;
    switch (action) {
      case 'play':
        core.play();
        break;
      case 'pause':
        core.pause();
        break;
      case 'toggle':
        core.isPlaying ? core.pause() : core.play();
        break;
      case 'forward':
        core.seekTo(core.position + const Duration(seconds: 10));
        break;
      case 'rewind':
        core.seekTo(core.position - const Duration(seconds: 10));
        break;
      case 'seek':
        core.seekTo(Duration(milliseconds: positionMs));
        break;
      case 'stop':
        // 系统侧 stop（通知栏被滑掉、音频焦点被抢、会话被停）不应该把迷你小窗顶掉：
        // 小窗是「后台播放」形态，这里只暂停；浮层形态才按关闭处理。
        if (context.read<AppState>().playerMode == PlayerMode.mini) {
          core.pause();
          break;
        }
        widget.onClose();
        return;
    }
    _showControls();
  }

  void _showControls() {
    if (!mounted) return;
    setState(() => _controlsVisible = true);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || _locked) return;
      final core = _core;
      if (core?.isPlaying ?? false) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _toggleControls() {
    if (_controlsVisible) {
      setState(() => _controlsVisible = false);
      _hideTimer?.cancel();
    } else {
      _showControls();
    }
  }

  void _togglePlay() {
    final core = _core;
    if (core == null) return;
    core.isPlaying ? core.pause() : core.play();
    _showControls();
  }

  @override
  void dispose() {
    _disposed = true;
    _tick?.cancel();
    _hideTimer?.cancel();
    _hintTimer?.cancel();
    _subtitleCtrl.dispose();
    _core?.values.removeListener(_onValue);
    _saveMemory();
    final platform = PlayerPlatform.instance;
    platform.onMediaAction = null;
    platform.enableMediaControls(false);
    platform.clearSession();
    platform.keepScreenOn(false);
    platform.setOrientation('auto');
    platform.abandonAudioFocus();
    _core?.dispose();
    super.dispose();
  }

  String get _displayTitle => _source.displayTitle;

  void _toast(String message) {
    if (!mounted) return;
    setState(() => _hint = message);
    _hintTimer?.cancel();
    _hintTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted && _hint == message) setState(() => _hint = null);
    });
  }

  void _openInline(Widget panel) {
    if (!mounted) return;
    setState(() => _inlinePanel = panel);
  }

  void _closeInline() {
    if (!mounted) return;
    setState(() => _inlinePanel = null);
  }

  Widget _inlineOverlay() {
    final p = paletteOf(context);
    return Positioned.fill(
      child: GestureDetector(
        onTap: _closeInline,
        child: Container(
          color: Colors.black.withValues(alpha: 0.62),
          alignment: Alignment.center,
          child: GestureDetector(
            onTap: () {},
            child: Container(
              margin: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: p.border),
              ),
              child: _inlinePanel ?? const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
  }

  // ---- 播放动作 ----

  void _download() {
    final state = context.read<AppState>();
    final title = _displayTitle;
    state.startDownload(
      url: widget.request.url,
      title: title,
      referer: _source.referer,
    );
    // 不切页、不关闭播放器：只在底部给一个约 0.5 秒的悬停提示
    state.showHint('已加入下载队列');
  }

  Future<void> _setSpeed(double value) async {
    await _core?.setSpeed(value);
    _speed = value;
    await _settings.setPlayerSpeed(value);
    if (mounted) setState(() {});
    _showControls();
  }

  /// 统一的内嵌选择面板：限高 + 可滚动，且始终在置顶浮层之内。
  void _openMenu(String title, List<Widget> rows) {
    _openInline(_InlineCard(
      title: title,
      onClose: _closeInline,
      children: rows,
    ));
  }

  void _showSpeedSheet() {
    _openMenu(
      '播放倍速',
      <Widget>[
        for (final s in kPlaybackSpeeds)
          ListTile(
            dense: true,
            title: Text(formatSpeed(s),
                style: TextStyle(fontSize: 13, color: paletteOf(context).text)),
            trailing: _speed == s
                ? const Icon(Icons.check, color: kAccent, size: 18)
                : null,
            onTap: () {
              _closeInline();
              _setSpeed(s);
            },
          ),
      ],
    );
  }

  void _showQualitySheet() {
    final p = paletteOf(context);
    final items = <_Choice<VideoTrack?>>[
      const _Choice<VideoTrack?>('自动（自适应）', null),
      for (final t in _videoTracks)
        _Choice<VideoTrack?>(
          '${videoTrackLabel(t)}${t.isSelected ? ' · 当前' : ''}',
          t,
        ),
    ];
    if (items.length == 1 && _probe.variants.length < 2) {
      _toast('当前内核未提供可选画质');
      return;
    }
    _openMenu(
      '清晰度 / 画质',
      <Widget>[
        for (final c in items)
          ListTile(
            dense: true,
            title: Text(c.label, style: TextStyle(fontSize: 13, color: p.text)),
            onTap: () {
              _closeInline();
              _core?.selectVideoTrack(c.value);
            },
          ),
        if (_probe.variants.length > 1) ...[
          Divider(height: 1, color: p.border),
          _SheetTitle('播放列表码率', p),
          for (final v in _probe.variants)
            ListTile(
              dense: true,
              title:
                  Text(v.label, style: TextStyle(fontSize: 13, color: p.text)),
              onTap: () {
                _closeInline();
                _openVariant(v);
              },
            ),
        ],
      ],
    );
  }

  void _openVariant(HlsVariant variant) {
    _saveMemory();
    context.read<AppState>().openPlayer(
          url: variant.uri.toString(),
          title: widget.request.title,
          referer: widget.request.referer,
        );
    _toast('已切换到所选码率');
  }

  void _showAudioSheet() {
    final p = paletteOf(context);
    if (_audioTracks.isEmpty) {
      _toast('当前视频没有可切换的音轨');
      return;
    }
    _openMenu(
      '音轨',
      <Widget>[
        for (final t in _audioTracks)
          ListTile(
            dense: true,
            title: Text(
              '${audioTrackLabel(t)}${t.isSelected ? ' · 当前' : ''}',
              style: TextStyle(fontSize: 13, color: p.text),
            ),
            onTap: () {
              _closeInline();
              _core?.selectAudioTrack(t.id);
              Future.delayed(const Duration(milliseconds: 600), _loadTracks);
            },
          ),
      ],
    );
  }

  void _showSubtitleDialog() {
    final p = paletteOf(context);
    _openInline(_InlineCard(
      title: '外挂字幕',
      onClose: _closeInline,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: Text('支持 SRT / WebVTT 的网络地址或本机文件路径',
              style: TextStyle(fontSize: 11.5, color: p.textFaint)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: TextField(
            controller: _subtitleCtrl,
            style: TextStyle(fontSize: 12.5, color: p.text),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'https://…/subtitle.srt',
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (_subtitleName != null)
                TextButton(
                  onPressed: () async {
                    _closeInline();
                    await _core?.clearSubtitle();
                    if (mounted) setState(() => _subtitleName = null);
                    _toast('已关闭字幕');
                  },
                  child: const Text('关闭字幕', style: TextStyle(fontSize: 12)),
                ),
              TextButton(
                onPressed: _closeInline,
                child: Text('取消',
                    style: TextStyle(fontSize: 12, color: p.textFaint)),
              ),
              FilledButton(
                onPressed: () => _loadSubtitleInput(_subtitleCtrl.text.trim()),
                child: const Text('加载', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      ],
    ));
  }

  Future<void> _loadSubtitleInput(String input) async {
    _closeInline();
    if (input.isEmpty) return;
    try {
      final String content;
      if (input.toLowerCase().startsWith('http')) {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 8);
        final req = await client.getUrl(Uri.parse(input));
        final resp = await req.close().timeout(const Duration(seconds: 10));
        content = await resp.transform(utf8.decoder).join();
        client.close(force: true);
      } else {
        content = await File(input).readAsString();
      }
      await _core?.setSubtitle(content, input);
      if (mounted) {
        setState(() => _subtitleName = input.split(RegExp(r'[/\\]')).last);
      }
      _toast('字幕已加载');
    } catch (e) {
      _toast('字幕加载失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  /// 右上角唯一的三点菜单：收纳全部播放增强操作。
  /// 用内嵌面板而不是系统弹窗，避免被置顶的播放器自身遮挡。
  void _showMoreMenu() {
    final p = paletteOf(context);
    Widget row(String label, IconData icon, VoidCallback onTap,
        {Color? color}) {
      return ListTile(
        dense: true,
        leading: Icon(icon, size: 18, color: color ?? p.textSub),
        title: Text(label, style: TextStyle(fontSize: 12.5, color: p.text)),
        onTap: () {
          _closeInline();
          onTap();
        },
      );
    }

    _openMenu(
      '更多',
      <Widget>[
        row(
            _favorite ? '取消收藏' : '收藏当前视频',
            _favorite ? Icons.favorite : Icons.favorite_border,
            () => _onMore(_MoreAction.favorite),
            color: _favorite ? kAccent : null),
        row('我的收藏', Icons.video_library_outlined,
            () => _onMore(_MoreAction.favorites)),
        Divider(height: 1, color: p.border),
        row(_looping ? '关闭循环播放' : '循环播放', Icons.repeat,
            () => _onMore(_MoreAction.loop),
            color: _looping ? kAccent : null),
        row('系统画中画', Icons.picture_in_picture_outlined,
            () => _onMore(_MoreAction.pip)),
        row('投屏设置', Icons.cast_outlined, () => _onMore(_MoreAction.cast)),
        row('截取当前画面', Icons.photo_camera_outlined,
            () => _onMore(_MoreAction.snapshot)),
        row('分享', Icons.share_outlined, () => _onMore(_MoreAction.share)),
        Divider(height: 1, color: p.border),
        row('锁定控件', Icons.lock_outline, () => _onMore(_MoreAction.lock)),
        row('清除播放进度', Icons.restart_alt,
            () => _onMore(_MoreAction.clearMemory)),
      ],
    );
  }

  Future<void> _onMore(_MoreAction action) async {
    switch (action) {
      case _MoreAction.pip:
        final ok = await PlayerPlatform.instance.enterPip();
        if (!ok) _toast('当前设备或系统版本不支持画中画');
        break;
      case _MoreAction.cast:
        final ok = await PlayerPlatform.instance.openCastSettings();
        if (!ok) _toast('未找到系统投屏设置，此版本未接入投屏设备发现');
        break;
      case _MoreAction.snapshot:
        await _snapshot();
        break;
      case _MoreAction.share:
        final text = _source.local
            ? '${_source.displayTitle} · 来自 Nerelict MA8N'
            : '${_source.displayTitle}\n${widget.request.url}';
        await PlayerPlatform.instance.shareText(text);
        break;
      case _MoreAction.favorite:
        await _favorites.toggle(FavoriteItem(
          url: _source.url,
          title: _source.displayTitle,
          addedAt: DateTime.now().millisecondsSinceEpoch,
          local: _source.local,
          referer: _source.referer,
        ));
        _favorite = await _favorites.contains(_source.url);
        if (mounted) setState(() {});
        _toast(_favorite ? '已加入收藏' : '已取消收藏');
        break;
      case _MoreAction.favorites:
        await _showFavorites();
        break;
      case _MoreAction.loop:
        _looping = !_looping;
        await _core?.setLooping(_looping);
        _toast(_looping ? '已开启循环播放' : '已关闭循环播放');
        break;
      case _MoreAction.lock:
        setState(() {
          _locked = true;
          _controlsVisible = false;
        });
        break;
      case _MoreAction.clearMemory:
        await _memory.remove(_source.memoryKey);
        _toast('已清除本视频的播放进度');
        break;
    }
  }

  Future<void> _snapshot() async {
    if (!_source.local) {
      _toast('网络流暂不支持画面截图，下载到本地后可截取');
      return;
    }
    final path = await PlayerPlatform.instance.captureFrame(
      _source.raw,
      _core?.position.inMilliseconds ?? 0,
    );
    if (!mounted) return;
    if (path == null) {
      _toast('当前画面无法截取');
      return;
    }
    _openInline(_InlineCard(
      title: '画面截图',
      onClose: _closeInline,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(File(path), fit: BoxFit.contain),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: Text('已保存到应用图片目录，不展示完整路径',
              style:
                  TextStyle(fontSize: 11, color: paletteOf(context).textFaint)),
        ),
      ],
    ));
  }

  Future<void> _showFavorites() async {
    final items = await _favorites.all();
    if (!mounted) return;
    final p = paletteOf(context);
    _openMenu(
      '我的收藏 · ${items.length}',
      <Widget>[
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text('还没有收藏视频',
                style: TextStyle(fontSize: 12, color: p.textFaint)),
          )
        else
          for (final item in items)
            ListTile(
              dense: true,
              leading: const Icon(Icons.favorite, size: 17, color: kAccent),
              title: Text(item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: p.text)),
              onTap: () {
                _closeInline();
                context.read<AppState>().openPlayer(
                      url: item.url,
                      title: item.title,
                      referer: item.referer,
                      local: item.local,
                    );
              },
            ),
      ],
    );
  }

  // ---- 手势 ----

  Widget _gestureLayer(double width, double height) {
    if (!_settings.playerGestures || _locked || _core == null) {
      return const SizedBox.shrink();
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _toggleControls,
      onDoubleTapDown: (d) => _doubleTapPosition = d.localPosition,
      onDoubleTap: () => _handleDoubleTap(width),
      onLongPressStart: (_) => _longPressSpeed(true),
      onLongPressEnd: (_) => _longPressSpeed(false),
      onHorizontalDragStart: (_) {
        _seekBase = _core!.position;
        _seekTarget = _seekBase;
      },
      onHorizontalDragUpdate: (d) {
        final delta = (d.delta.dx / (width < 1 ? 1 : width)) * 90;
        final maxMs = _core!.duration.inMilliseconds;
        var ms =
            (_seekTarget ?? _seekBase).inMilliseconds + (delta * 1000).round();
        ms = ms.clamp(0, maxMs > 0 ? maxMs : ms);
        setState(() {
          _seekTarget = Duration(milliseconds: ms);
          _hint = '快进至 ${_fmt(_seekTarget!)}';
        });
      },
      onHorizontalDragEnd: (_) async {
        final target = _seekTarget;
        _seekTarget = null;
        setState(() => _hint = null);
        if (target != null) await _core?.seekTo(target);
        _showControls();
      },
      onHorizontalDragCancel: () {
        _seekTarget = null;
        if (mounted) setState(() => _hint = null);
      },
      onVerticalDragStart: (d) {
        _verticalIsLeft = d.localPosition.dx < width / 2;
      },
      onVerticalDragUpdate: (d) {
        final delta = -d.delta.dy / (height < 1 ? 1 : height);
        if (_verticalIsLeft) {
          _brightness = (_brightness + delta).clamp(0.02, 1.0);
          PlayerPlatform.instance.setBrightness(_brightness);
          setState(() => _hint = '亮度 ${(_brightness * 100).round()}%');
        } else {
          _volume = (_volume + delta).clamp(0.0, 1.0);
          PlayerPlatform.instance.setVolume(_volume);
          setState(() => _hint = '音量 ${(_volume * 100).round()}%');
        }
      },
      onVerticalDragEnd: (_) {
        if (mounted) setState(() => _hint = null);
        _showControls();
      },
      onVerticalDragCancel: () {
        if (mounted) setState(() => _hint = null);
      },
    );
  }

  bool _verticalIsLeft = true;
  double _speedBeforeLongPress = 1.0;
  Offset? _doubleTapPosition;

  /// 双击分区：左 1/3 快退、右 1/3 快进、中间暂停/播放。
  /// 比原来「整块双击=暂停」更符合视频应用习惯，也避免想快进时误暂停。
  void _handleDoubleTap(double width) {
    final pos = _doubleTapPosition;
    if (pos == null || width <= 0) {
      _togglePlay();
      return;
    }
    if (pos.dx < width / 3) {
      _seekBy(const Duration(seconds: -10));
    } else if (pos.dx > width * 2 / 3) {
      _seekBy(const Duration(seconds: 10));
    } else {
      _togglePlay();
    }
  }

  void _seekBy(Duration delta) {
    final core = _core;
    if (core == null) return;
    var target = core.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    final total = core.duration;
    if (total > Duration.zero && target > total) target = total;
    core.seekTo(target);
    _toast(delta.isNegative ? '快退 10 秒' : '快进 10 秒');
    _showControls();
  }

  /// 首次进入播放器时提示一次手势用法（学会后写入设置，不再打扰）。
  void _showGestureTipIfNeeded() {
    if (!_settings.playerGestures || _settings.gestureTipSeen) return;
    const message = '双击左右两侧快退 / 快进 10 秒，双击中间暂停';
    _toast(message);
    _hintTimer?.cancel();
    _hintTimer = Timer(const Duration(milliseconds: 4200), () {
      if (mounted && _hint == message) setState(() => _hint = null);
    });
    unawaited(_settings.markGestureTipSeen());
  }

  void _longPressSpeed(bool start) {
    if (start) {
      _speedBeforeLongPress = _speed;
      _core?.setSpeed(2.0);
      setState(() => _hint = '2.0x 倍速中');
    } else {
      _core?.setSpeed(_speedBeforeLongPress);
      if (mounted) setState(() => _hint = null);
    }
  }

  // ---- 构建 ----

  @override
  Widget build(BuildContext context) {
    final mode = context.select<AppState, PlayerMode>((s) => s.playerMode);
    if (mode == PlayerMode.mini) return _buildMini();
    if (mode == PlayerMode.fullscreen) return _buildFullscreen();
    return _buildPanel();
  }

  Widget _buildMini() {
    final core = _core;
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white24, width: 0.6),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: widget.onDragStart,
              onPanUpdate: widget.onDragUpdate,
              onPanEnd: widget.onDragEnd,
              child: SizedBox(
                height: 26,
                child: Row(
                  children: [
                    const SizedBox(width: 6),
                    const Icon(Icons.drag_indicator,
                        size: 14, color: Colors.white54),
                    const Spacer(),
                    InkWell(
                      onTap: () => context
                          .read<AppState>()
                          .setPlayerMode(PlayerMode.panel),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6),
                        child: Icon(Icons.open_in_full,
                            size: 14, color: Colors.white70),
                      ),
                    ),
                    InkWell(
                      onTap: widget.onClose,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6),
                        child:
                            Icon(Icons.close, size: 14, color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            AspectRatio(
              aspectRatio: core == null ? 16 / 9 : core.aspectRatio,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                // 小窗双击画面直接还原成浮层，比去点 14px 的图标快得多
                onDoubleTap: () =>
                    context.read<AppState>().setPlayerMode(PlayerMode.panel),
                child: Stack(
                  children: [
                    if (core != null)
                      Positioned.fill(child: core.videoWidget())
                    else
                      const Center(
                        child: CircularProgressIndicator(color: kAccent),
                      ),
                    Center(
                      child: IconButton(
                        iconSize: 30,
                        icon: Icon(
                          core?.isPlaying ?? false
                              ? Icons.pause_circle_outline
                              : Icons.play_circle_outline,
                          color: Colors.white70,
                        ),
                        onPressed: _togglePlay,
                      ),
                    ),
                    if (core != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: _MiniProgress(core: core),
                      ),
                    if (core != null)
                      Positioned(
                        top: 5,
                        right: 6,
                        child: IgnorePointer(
                          child: _MiniBuffering(core: core),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFullscreen() {
    final core = _core;
    return Material(
      color: Colors.black,
      child: Stack(
        children: [
          if (core != null)
            Center(
              child: AspectRatio(
                aspectRatio: core.aspectRatio,
                child: core.videoWidget(),
              ),
            )
          else
            Center(child: _status()),
          if (core != null)
            Positioned.fill(
                child: _gestureLayerFor(MediaQuery.of(context).size)),
          if (_locked)
            Positioned(
              top: 20,
              left: 20,
              child: _roundButton(
                  Icons.lock_open,
                  () => setState(() {
                        _locked = false;
                        _controlsVisible = true;
                      })),
            )
          else ...[
            if (_controlsVisible)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black54,
                  padding: EdgeInsets.only(
                    top: MediaQuery.of(context).padding.top + 6,
                    bottom: 8,
                    left: 10,
                    right: 10,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => context
                            .read<AppState>()
                            .setPlayerMode(PlayerMode.panel),
                      ),
                      Expanded(
                        child: Text(
                          _displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13),
                        ),
                      ),
                      if (!_source.local)
                        IconButton(
                          tooltip: '下载当前视频',
                          icon: const Icon(Icons.download_for_offline_outlined,
                              color: Colors.white, size: 20),
                          onPressed: _download,
                        ),
                      IconButton(
                        tooltip: '迷你小窗',
                        icon: const Icon(Icons.picture_in_picture_alt,
                            color: Colors.white, size: 20),
                        onPressed: () => context
                            .read<AppState>()
                            .setPlayerMode(PlayerMode.mini),
                      ),
                      IconButton(
                        tooltip: '更多播放功能',
                        icon: const Icon(Icons.more_vert,
                            color: Colors.white, size: 20),
                        onPressed: _showMoreMenu,
                      ),
                      IconButton(
                        tooltip: '关闭',
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: widget.onClose,
                      ),
                    ],
                  ),
                ),
              ),
            if (_controlsVisible && core != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _controlsBar(core, full: true),
              ),
          ],
          if (_hint != null) Center(child: _hintChip(_hint!)),
          if (_inlinePanel != null) _inlineOverlay(),
        ],
      ),
    );
  }

  Widget _gestureLayerFor(Size size) => _gestureLayer(size.width, size.height);

  Widget _buildPanel() {
    final p = paletteOf(context);
    final core = _core;
    final size = MediaQuery.of(context).size;

    // 面板默认贴合布局：左右铺满、底部贴住导航栏，因此只用上方圆角
    const panelRadius = BorderRadius.vertical(top: Radius.circular(16));

    // 半透明玻璃拟态：底色与描边跟随主题（赛博主题是洋红描边的深紫玻璃）
    final glassTint = p.glass;
    final glassBorder = p.glassBorder;

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          ConstrainedBox(
            // 顶部标题栏（含关闭按钮）永远在可视区内，竖屏视频只收窄不撑高。
            constraints: BoxConstraints(maxHeight: size.height * 0.72),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: panelRadius,
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(
                        alpha: p.isCyber
                            ? 0.55
                            : (p.brightness == Brightness.dark ? 0.34 : 0.20)),
                    blurRadius: 22,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: panelRadius,
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                  child: Container(
                    decoration: BoxDecoration(
                      color: glassTint,
                      borderRadius: panelRadius,
                      border: Border.all(color: glassBorder, width: 0.9),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _titleBar(p),
                        if (core != null)
                          _panelVideo(core)
                        else
                          Container(
                            color: Colors.black,
                            height: 180,
                            child: Center(child: _status()),
                          ),
                        _panelActions(p),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_inlinePanel != null) _inlineOverlay(),
        ],
      ),
    );
  }

  Widget _titleBar(AppPalette p) {
    // 标题栏即拖动把手：面板默认贴顶，可上下拖动到任意位置
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: widget.onDragStart,
      onPanUpdate: widget.onDragUpdate,
      onPanEnd: widget.onDragEnd,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 4, 2, 4),
        decoration: BoxDecoration(
          // 玻璃面上的霓虹反光，只做很淡的一层；赛博主题更明显
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              p.accentAlt.withValues(alpha: p.isCyber ? 0.20 : 0.10),
              Colors.transparent,
              p.accent.withValues(alpha: p.isCyber ? 0.18 : 0.08),
            ],
            stops: const <double>[0.0, 0.55, 1.0],
          ),
          border: Border(
            bottom: BorderSide(
              color: p.isCyber
                  ? p.accent.withValues(alpha: 0.30)
                  : Colors.white.withValues(alpha: 0.07),
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.smart_display_outlined, color: p.accent, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: p.textSub,
                ),
              ),
            ),
            if (!_source.local)
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '下载当前视频',
                icon: const Icon(Icons.download_for_offline_outlined,
                    size: 20, color: kAccent),
                onPressed: _download,
              ),
            // 小窗：与下方控制条的全屏按钮分工，不再重复放大入口
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '迷你小窗',
              icon: Icon(Icons.picture_in_picture_alt_outlined,
                  size: 19, color: p.textSub),
              onPressed: () =>
                  context.read<AppState>().setPlayerMode(PlayerMode.mini),
            ),
            // 唯一的三点菜单：所有播放增强集中在这里，右上角收纳
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '更多播放功能',
              icon: Icon(Icons.more_vert, size: 19, color: p.textSub),
              onPressed: _showMoreMenu,
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close, size: 19, color: p.textSub),
              tooltip: '关闭 MA8N',
              onPressed: widget.onClose,
            ),
          ],
        ),
      ),
    );
  }

  Widget _panelVideo(PlayerCore core) {
    const maxVideoHeight = 230.0;
    return Container(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final ar = core.aspectRatio;
          // 全宽是浮层宽度，与视频比例无关：进度条与控制层永远用这个宽度。
          final fullWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.of(context).size.width - 24;
          final naturalHeight = fullWidth / ar;
          final height =
              naturalHeight > maxVideoHeight ? maxVideoHeight : naturalHeight;
          final videoWidth = (height * ar).clamp(0.0, fullWidth);
          return SizedBox(
            height: height,
            width: double.infinity,
            child: Stack(
              children: [
                // 画面按原始比例居中，竖屏时两侧留黑；
                // 控制层是 Stack 的兄弟节点，不再被 videoWidth 压缩。
                Center(
                  child: SizedBox(
                    width: videoWidth,
                    height: height,
                    child: core.videoWidget(),
                  ),
                ),
                Positioned.fill(child: _gestureLayer(fullWidth, height)),
                if (_locked)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: _roundButton(
                        Icons.lock_open,
                        () => setState(() {
                              _locked = false;
                              _controlsVisible = true;
                            })),
                  )
                else if (_controlsVisible)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _controlsBar(core, full: false),
                  ),
                if (_hint != null) Center(child: _hintChip(_hint!)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _controlsBar(PlayerCore core, {required bool full}) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: core.values,
      builder: (context, value, _) {
        const timeStyle = TextStyle(
          fontSize: 11,
          color: Colors.white,
          fontWeight: FontWeight.w600,
          shadows: <Shadow>[Shadow(color: Colors.black87, blurRadius: 3)],
        );
        final durationText =
            value.duration.inMilliseconds > 0 ? _fmt(value.duration) : '--:--';
        return Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Colors.black87],
            ),
          ),
          padding: EdgeInsets.fromLTRB(10, full ? 34 : 18, 10, full ? 12 : 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 时长信息独占一整行：不参与横向滚动，也不会被视频比例裁切
              Row(
                children: <Widget>[
                  Text('已播 ${_fmt(value.position)}', style: timeStyle),
                  const Spacer(),
                  Text('时长 $durationText', style: timeStyle),
                ],
              ),
              const SizedBox(height: 4),
              // 进度条铺满浮层宽度，与画面宽高比无关
              core.progressWidget(),
              const SizedBox(height: 2),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.replay_10,
                          color: Colors.white, size: 20),
                      onPressed: () => core
                          .seekTo(value.position - const Duration(seconds: 10)),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: full ? 34 : 28,
                      icon: Icon(
                        value.isPlaying
                            ? Icons.pause_circle
                            : Icons.play_circle,
                        color: Colors.white,
                      ),
                      onPressed: _togglePlay,
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.forward_10,
                          color: Colors.white, size: 20),
                      onPressed: () => core
                          .seekTo(value.position + const Duration(seconds: 10)),
                    ),
                    const SizedBox(width: 6),
                    _textChip(formatSpeed(_speed), _showSpeedSheet),
                    _textChip('画质', _showQualitySheet),
                    _textChip('音轨', _showAudioSheet),
                    _textChip('字幕', _showSubtitleDialog),
                    if (full)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '退出全屏',
                        icon: const Icon(Icons.fullscreen_exit,
                            color: Colors.white, size: 20),
                        onPressed: () => context
                            .read<AppState>()
                            .setPlayerMode(PlayerMode.panel),
                      )
                    else
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '全屏',
                        icon: const Icon(Icons.fullscreen,
                            color: Colors.white, size: 20),
                        onPressed: () => context
                            .read<AppState>()
                            .setPlayerMode(PlayerMode.fullscreen),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _panelActions(AppPalette p) {
    final core = _core;
    // 只展示真正有用的状态提示；画质档位 / 音轨数量不再在这里显示
    final status = _source.local ? '' : _statusLine();
    if (status.isEmpty && !(core == null && _error != null)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (status.isNotEmpty)
            Text(
              status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: p.textSub),
            ),
          if (core == null && _error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'MA8N无法直接播放该内容：$_error',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10.5, color: kDanger),
              ),
            ),
        ],
      ),
    );
  }

  String _statusLine() {
    final parts = <String>[
      if (_probe.hasDrm) '检测到加密标记',
      if (_usingProxy) '边下边播缓存已启用',
      if (_subtitleName != null) '字幕 · $_subtitleName',
    ];
    return parts.join(' · ');
  }

  Widget _status() {
    if (_error != null) {
      return _PlayerError(message: _error!);
    }
    return const Center(child: CircularProgressIndicator(color: kAccent));
  }

  Widget _textChip(String label, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              label,
              style: const TextStyle(fontSize: 10.5, color: Colors.white),
            ),
          ),
        ),
      );

  Widget _hintChip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(text,
            style: const TextStyle(color: Colors.white, fontSize: 12.5)),
      );

  Widget _roundButton(IconData icon, VoidCallback onTap) => Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Icon(icon, size: 17, color: Colors.white),
          ),
        ),
      );

  String _fmt(Duration d) => formatDuration(d);
}

/// 浮层内的通用选择面板：限高、可滚动，不受 Navigator 层级影响。
class _InlineCard extends StatelessWidget {
  const _InlineCard({
    required this.title,
    required this.onClose,
    required this.children,
  });

  final String title;
  final VoidCallback onClose;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.5,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 4, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.close, size: 17, color: p.textFaint),
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: p.border),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _Choice<T> {
  const _Choice(this.label, this.value);

  final String label;
  final T value;
}

class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.text, this.p);

  final String text;
  final AppPalette p;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            text,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
        ),
      );
}

class _PlayerError extends StatelessWidget {
  const _PlayerError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: Colors.orangeAccent, size: 30),
          const SizedBox(height: 8),
          const Text(
            'MA8N无法直接播放该内容',
            style: TextStyle(color: Colors.white, fontSize: 12.5),
          ),
          const SizedBox(height: 5),
          Text(
            message.length > 120 ? '${message.substring(0, 120)}…' : message,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: const TextStyle(color: Colors.white54, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

/// 迷你小窗底部的细进度条：显示缓冲与播放进度，点击可快速定位。
/// 之前小窗只有播放/暂停，切到别的页再回来时看不出播到哪。
class _MiniProgress extends StatelessWidget {
  const _MiniProgress({required this.core});

  final PlayerCore core;

  @override
  Widget build(BuildContext context) {
    final accent = paletteOf(context).accent;
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: core.values,
      builder: (context, value, _) {
        final total = value.duration.inMilliseconds;
        final played = total <= 0
            ? 0.0
            : (value.position.inMilliseconds / total).clamp(0.0, 1.0);
        final buffered = total <= 0 || value.buffered.isEmpty
            ? played
            : (value.buffered.last.end.inMilliseconds / total)
                .clamp(played, 1.0);
        return LayoutBuilder(
          builder: (context, constraints) {
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) {
                if (total <= 0) return;
                final frac = (details.localPosition.dx / constraints.maxWidth)
                    .clamp(0.0, 1.0);
                core.seekTo(Duration(milliseconds: (total * frac).round()));
              },
              child: SizedBox(
                height: 14,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Stack(
                    children: <Widget>[
                      Container(height: 3, color: Colors.white24),
                      FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: buffered,
                        child: Container(height: 3, color: Colors.white38),
                      ),
                      FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: played,
                        child: Container(height: 3, color: accent),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// 小窗缓冲指示：只在真正等待数据时出现，避免一直闪一个转圈。
class _MiniBuffering extends StatelessWidget {
  const _MiniBuffering({required this.core});

  final PlayerCore core;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: core.values,
      builder: (context, value, _) {
        if (!value.isBuffering) return const SizedBox.shrink();
        return Container(
          width: 18,
          height: 18,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(9),
          ),
          child: const CircularProgressIndicator(
            strokeWidth: 1.8,
            valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
          ),
        );
      },
    );
  }
}
