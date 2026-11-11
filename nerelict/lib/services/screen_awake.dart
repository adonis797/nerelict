import 'package:flutter/services.dart';

/// 屏幕常亮：通过原生窗口 flag（FLAG_KEEP_SCREEN_ON）实现。
///
/// 只在应用窗口可见时生效，不需要 WAKE_LOCK 权限，也不会阻止用户按电源键锁屏。
/// 应用在前台时保持屏幕常亮，下载 / 转换 / 播放不会因为自动息屏被打断。
class ScreenAwake {
  static const _channel = MethodChannel('com.nerelict/screen');

  static Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<bool>('setKeepAwake', <String, dynamic>{
        'enabled': enabled,
      });
    } catch (_) {
      // 通道不可用（如桌面端调试）时静默跳过
    }
  }
}
