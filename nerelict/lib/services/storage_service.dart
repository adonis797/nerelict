import 'package:flutter/services.dart';

/// 用户自选下载位置：通过 Android 系统目录选择器（SAF）取得目录树授权，
/// 下载完成后把应用私有目录里的成品复制一份到该目录。
///
/// 下载流程本身仍写在应用私有目录，因此不需要任何存储权限，
/// 也不会因为用户选了外部目录而影响下载、续传或应用内播放。
class StorageService {
  static const _channel = MethodChannel('com.nerelict/storage');

  /// 返回 (uri, name)，用户取消时返回 null。
  static Future<({String uri, String name})?> pickDirectory() async {
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'pickDirectory',
      );
      final uri = res?['uri'];
      final name = res?['name'];
      if (uri is! String || uri.isEmpty) return null;
      return (
        uri: uri,
        name: (name is String && name.isNotEmpty) ? name : '已选目录',
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 把 [path] 导出到用户所选目录，返回是否成功。
  static Future<bool> exportFile({
    required String uri,
    required String path,
    required String name,
  }) async {
    try {
      final ok = await _channel.invokeMethod<bool>('exportFile', <String, dynamic>{
        'uri': uri,
        'path': path,
        'name': name,
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
