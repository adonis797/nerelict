import 'package:flutter/services.dart';

/// 「所有文件访问权限」的检查与引导。
///
/// 文件页要浏览整个内部存储，Android 11+ 只有 `MANAGE_EXTERNAL_STORAGE` 这一条路，
/// 而且**必须用户手动去系统设置里开**——应用自己弹不出来，也检测不到「点了取消」，
/// 只能在回到前台时重新查一次状态。
///
/// 这里刻意只做三件事：查状态、跳设置页、拿内部存储根路径。
/// 授权失败的一切后果都由调用方兜住（退回只看下载目录），不让整页不可用。
class StorageAccess {
  const StorageAccess._();

  static const MethodChannel _channel = MethodChannel('com.nerelict/storage');

  /// 是否已获得「所有文件访问权限」。低版本恒为 true。
  static Future<bool> hasAllFilesAccess() async {
    try {
      final ok = await _channel.invokeMethod<bool>('allFilesAccess');
      return ok ?? false;
    } catch (_) {
      // 主机端脚本或旧原生层没有这个方法：当作没有权限，退回下载目录
      return false;
    }
  }

  /// 打开系统的「所有文件访问权限」开关。返回 false 表示跳转失败。
  static Future<bool> openSettings() async {
    try {
      final ok = await _channel.invokeMethod<bool>('openAllFilesSettings');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 内部存储根目录（通常是 `/storage/emulated/0`）。
  static Future<String?> externalRoot() async {
    try {
      return await _channel.invokeMethod<String>('externalRoot');
    } catch (_) {
      return null;
    }
  }
}
