import 'package:flutter/services.dart';

/// 悬浮窗关掉时交回给 Flutter 播放器的状态。
class FloatingPlayback {
  const FloatingPlayback({required this.positionMs, required this.playing});

  final int positionMs;
  final bool playing;
}

/// 原生媒体能力通道（media_session 层）。
///
/// 对应 Kotlin 侧 PlayerPlatform.kt：MediaSession / 通知栏媒体控制、
/// 音频焦点、系统音量与亮度、屏幕方向、画中画、本地视频截帧、分享。
/// 所有调用都是「尽力而为」：设备不支持或权限缺失时返回安全默认值，
/// 不会让播放器崩掉。
class PlayerPlatform {
  PlayerPlatform._();

  static final PlayerPlatform instance = PlayerPlatform._();

  static const MethodChannel _channel =
      MethodChannel('com.nerelict/player');

  /// action: play / pause / rewind / forward / stop / seek
  void Function(String action, int positionMs)? onMediaAction;

  /// 系统画中画状态变化（进入 / 退出 PiP 窗口）。
  void Function(bool inPip)? onPipChanged;

  /// 用户点了悬浮窗右上角的 ×：应当结束整个播放会话。
  void Function()? onFloatingClosed;

  /// 悬浮窗自己播不了（防盗链 / 解码失败）：交回 Flutter 侧继续出声。
  void Function()? onFloatingFailed;

  bool _handlerRegistered = false;

  void _ensureHandler() {
    if (_handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'mediaAction') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        onMediaAction?.call(
          (args['action'] as String?) ?? 'play',
          (args['positionMs'] as num?)?.toInt() ?? 0,
        );
      } else if (call.method == 'pipChanged') {
        onPipChanged?.call(call.arguments == true);
      } else if (call.method == 'floatingClosed') {
        onFloatingClosed?.call();
      } else if (call.method == 'floatingFailed') {
        onFloatingFailed?.call();
      }
      return null;
    });
  }

  Future<T?> _call<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _void(String method, [Map<String, dynamic>? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // 旧版本原生层没有该能力
    } on PlatformException {
      // 设备/系统版本不支持
    } catch (_) {}
  }

  Future<bool> get available async => await _call<bool>('ping') ?? false;

  /// 打开/关闭通知栏媒体控制。仅在用户开启「媒体通知控制」时调用。
  Future<void> enableMediaControls(bool enabled) async {
    _ensureHandler();
    await _void('enableMediaControls', <String, dynamic>{
      'enabled': enabled,
    });
  }

  Future<void> updateSession({
    required String title,
    required bool playing,
    required int positionMs,
    required int durationMs,
    required double speed,
  }) =>
      _void('updateSession', <String, dynamic>{
        'title': title,
        'playing': playing,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'speed': speed,
      });

  Future<void> clearSession() => _void('clearSession');

  Future<bool> ensureNotificationPermission() async =>
      await _call<bool>('ensureNotificationPermission') ?? false;

  Future<void> requestAudioFocus() => _void('requestAudioFocus');

  Future<void> abandonAudioFocus() => _void('abandonAudioFocus');

  Future<double> getVolume() async =>
      (await _call<double>('getVolume') ?? 0.5).clamp(0.0, 1.0);

  Future<void> setVolume(double value) =>
      _void('setVolume', <String, dynamic>{'value': value.clamp(0.0, 1.0)});

  Future<double> getBrightness() async =>
      (await _call<double>('getBrightness') ?? 0.5).clamp(0.02, 1.0);

  Future<void> setBrightness(double value) => _void(
        'setBrightness',
        <String, dynamic>{'value': value.clamp(0.02, 1.0)},
      );

  Future<void> setOrientation(String mode) =>
      _void('setOrientation', <String, dynamic>{'mode': mode});

  Future<void> keepScreenOn(bool enabled) =>
      _void('keepScreenOn', <String, dynamic>{'enabled': enabled});

  Future<bool> pipSupported() async =>
      await _call<bool>('pipSupported') ?? false;

  /// 手动进入画中画（播放器菜单里的「画中画」）。
  Future<bool> enterPip({double? aspectRatio}) async {
    _ensureHandler();
    return await _call<bool>('enterPip', <String, dynamic>{
          if (aspectRatio != null && aspectRatio.isFinite && aspectRatio > 0)
            'aspect': aspectRatio,
        }) ??
        false;
  }

  /// 后台播放保活：有播放器时挂 `mediaPlayback` 前台服务。
  ///
  /// 切到后台后进程仍是前台优先级，ExoPlayer 的解码与音频继续，不会被系统冻结。
  /// 这不是画中画：后台看不到画面（系统限制），但进度与声音不断，回到应用后
  /// 小窗与播放位置原样继续。关闭播放器时必须关掉，否则会留下常驻通知。
  Future<void> keepAlive(bool enabled) =>
      _void('keepAlive', <String, dynamic>{'enabled': enabled});

  // ---- 后台悬浮窗（SYSTEM_ALERT_WINDOW） ----

  /// 系统能否加悬浮窗（Android 6.0+）。
  Future<bool> overlaySupported() async =>
      await _call<bool>('overlaySupported') ?? false;

  /// 「显示在其他应用上层」是否已授权。只能由用户在系统设置里开。
  Future<bool> hasOverlayPermission() async =>
      await _call<bool>('hasOverlayPermission') ?? false;

  /// 跳到系统设置页授权；返回**当前**是否已授权（首次调用通常为 false，
  /// 需要等用户回来后再查一次）。
  Future<bool> requestOverlayPermission() async =>
      await _call<bool>('requestOverlayPermission') ?? false;

  /// 打开后台悬浮窗并按给定进度起播。
  ///
  /// [url] 与前台播放器指向同一个地址（本机回环代理或 `file://` 本地文件），
  /// [kind] 用于选择媒体源类型（`hls` / `dash`，其余交给后缀推断）。
  Future<bool> showFloating({
    required String url,
    required String kind,
    required Map<String, String> headers,
    required int positionMs,
    required bool playing,
    required double aspectRatio,
    required double speed,
    required String title,
  }) async {
    _ensureHandler();
    return await _call<bool>('showFloating', <String, dynamic>{
          'url': url,
          'kind': kind,
          'headers': headers,
          'positionMs': positionMs,
          'playing': playing,
          'aspect': aspectRatio.isFinite && aspectRatio > 0
              ? aspectRatio
              : 16.0 / 9.0,
          'speed': speed,
          'title': title,
        }) ??
        false;
  }

  /// 关闭悬浮窗，返回交回给 Flutter 播放器的进度与播放状态。
  Future<FloatingPlayback?> hideFloating() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('hideFloating');
      if (raw is Map) {
        return FloatingPlayback(
          positionMs: (raw['positionMs'] as num?)?.toInt() ?? 0,
          playing: raw['playing'] == true,
        );
      }
    } on MissingPluginException {
      // 旧版原生层没有悬浮窗
    } catch (_) {}
    return null;
  }

  /// 悬浮窗当前是否在显示（原生侧为准）。
  Future<bool> floatingActive() async =>
      await _call<bool>('floatingActive') ?? false;

  /// 只对本地文件可用；网络流返回 null（边界限制里已说明）。
  Future<String?> captureFrame(String path, int positionMs) async =>
      _call<String>('captureFrame', <String, dynamic>{
        'path': path,
        'positionMs': positionMs,
      });

  Future<bool> shareText(String text) async =>
      await _call<bool>('shareText', <String, dynamic>{'text': text}) ?? false;

  /// 未接入投屏设备发现，降级为打开系统投屏设置页。
  Future<bool> openCastSettings() async =>
      await _call<bool>('openCastSettings') ?? false;
}
