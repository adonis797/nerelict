import 'package:flutter/services.dart';

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

  Future<bool> enterPip() async => await _call<bool>('enterPip') ?? false;

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
