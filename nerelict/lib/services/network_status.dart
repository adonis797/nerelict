import 'package:flutter/services.dart';

/// 网络类型探测：用于「仅 Wi-Fi 下载」门控。
///
/// 只判断当前默认网络是不是 Wi-Fi / 以太网，不读取 SSID、不需要定位权限。
class NetworkStatus {
  static const _channel = MethodChannel('com.nerelict/network');

  static Future<bool> isWifi() async {
    try {
      return await _channel.invokeMethod<bool>('isWifi') ?? false;
    } catch (_) {
      // 通道不可用时按「允许下载」处理，避免把任务永久卡住
      return true;
    }
  }
}
