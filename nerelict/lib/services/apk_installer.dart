import 'package:flutter/services.dart';

import '../models/installer_status.dart';

export '../models/installer_status.dart';

class ApkInstaller {
  static const _channel = MethodChannel('com.nerelict/install');

  /// 探测静默安装能力（root 探测在原生侧带 3 秒超时）。
  static Future<InstallerCapability> capability() async {
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('capability');
      if (res == null) return InstallerCapability.unknown;
      return InstallerCapability.fromMap(res);
    } catch (_) {
      return InstallerCapability.unknown;
    }
  }

  /// 选择本应用的更新包并安装：能静默就静默，否则打开系统安装器。
  ///
  /// 只接受包名等于本应用的 APK，其它安装包会被拒绝。
  /// 系统安装页的确认由用户点击，或交给独立的「安装确认」Skill 处理。
  static Future<InstallResult> pickAndInstall() async {
    try {
      final res =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('pickAndInstall');
      if (res == null) return InstallResult.canceled;
      return InstallResult.fromMap(res);
    } on PlatformException catch (e) {
      return InstallResult(
        ok: false,
        mode: 'none',
        message: e.message ?? e.code,
      );
    } catch (_) {
      return const InstallResult(
        ok: false,
        mode: 'none',
        message: '当前平台不支持应用内安装',
      );
    }
  }

  /// 当前安装包版本（原生 PackageManager 读到的值）
  static Future<({String name, int code})> appVersion() async {
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('appVersion');
      final name = res?['versionName'];
      final code = res?['versionCode'];
      return (
        name: name is String ? name : '',
        code: code is int ? code : 0,
      );
    } catch (_) {
      return (name: '', code: 0);
    }
  }

  /// 安装指定路径的 APK（例如下载目录里的安装包）。
  static Future<InstallResult> install(String path, {bool silent = true}) async {
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'install',
        <String, dynamic>{'path': path, 'silent': silent},
      );
      if (res == null) return InstallResult.canceled;
      return InstallResult.fromMap(res);
    } on PlatformException catch (e) {
      return InstallResult(
        ok: false,
        mode: 'none',
        message: e.message ?? e.code,
      );
    }
  }

  /// 打开「安装未知应用」授权页
  static Future<void> openUnknownSourcesSettings() async {
    try {
      await _channel.invokeMethod<bool>('openUnknownSources');
    } catch (_) {}
  }
}
