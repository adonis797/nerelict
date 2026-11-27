import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/release_info.dart';
import 'app_log.dart';
import 'app_paths.dart';

/// 一次「检查更新」的结论。
enum UpdateStatus {
  /// 已是最新（或本地版本更高，例如自己编的包）
  upToDate,

  /// 发现了更新的版本
  available,

  /// 网络 / 限流 / 响应异常，什么都没查出来
  failed,
}

class UpdateCheck {
  const UpdateCheck({
    required this.status,
    this.info,
    this.message = '',
    this.checkedAt,
    this.fromCache = false,
  });

  final UpdateStatus status;
  final ReleaseInfo? info;
  final String message;

  /// 这条结论对应的检查时间：缓存命中时是上次真正请求的时间。
  final DateTime? checkedAt;

  /// true 表示命中了节流窗口，没有真的发请求。
  final bool fromCache;

  bool get hasUpdate => status == UpdateStatus.available;
}

/// 下载失败时抛这个，界面直接展示 [message]，不再包一层「未知错误」。
class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 更新源：从自己的 GitHub Release 读最新版本，并下载 APK。
///
/// 三条约束来自现实：
/// - 匿名 API 每小时只有 60 次，所以 6 小时内只查一次，结果落 prefs 复用；
/// - GitHub 在国内时通时不通，必须给出可读的失败原因，不能一直转圈；
/// - 只信 `asset.size` 做完整性校验，签名交给系统安装器拦（同包名换签名会直接拒装）。
class ReleaseFeed {
  ReleaseFeed({
    Dio? dio,
    this.currentVersion = '',
    this.resolveTempDir,
  })  : dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 10),
              followRedirects: true,
              maxRedirects: 6,
              headers: <String, dynamic>{
                // GitHub API 强制要求 UA，缺了直接 403
                'User-Agent': 'Nerelict/${currentVersion.isEmpty ? 'unknown' : currentVersion}',
                'Accept': 'application/vnd.github+json',
              },
            ));

  static const String repo = 'adonis797/nerelict';
  static const String latestUrl =
      'https://api.github.com/repos/$repo/releases/latest';
  static const String releasesUrl = 'https://github.com/$repo/releases';

  /// 节流窗口：6 小时内复用上次结论。
  static const Duration throttleWindow = Duration(hours: 6);

  static const String _kCacheKey = 'update_check_cache';
  static const String _kCheckMsKey = 'update_check_ms';

  final Dio dio;

  /// 当前版本（`0.4.14`）。由调用方传入——UI 层用的编译期常量最可靠，
  /// 也能避免这个服务依赖平台通道，方便脚本里直接构造。
  final String currentVersion;

  /// 下载目录解析：默认系统临时目录（Android 上就是应用 cache）。
  final Future<Directory> Function()? resolveTempDir;

  /// 检查更新。[force] 为 true 时跳过节流，用于用户手动再点一次。
  Future<UpdateCheck> check({bool force = false}) async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      // prefs 不可用（极少见）也不该让整个功能失效，只是没有节流与缓存
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final lastMs = prefs?.getInt(_kCheckMsKey) ?? 0;
    final cached = _readCache(prefs);

    if (!force &&
        cached != null &&
        withinThrottle(
          lastMs: lastMs,
          nowMs: nowMs,
          window: throttleWindow,
        )) {
      final checkedAt = DateTime.fromMillisecondsSinceEpoch(lastMs);
      return _decide(cached, checkedAt: checkedAt, fromCache: true);
    }

    try {
      logD('Update', 'check $latestUrl');
      final res = await dio.get<dynamic>(
        latestUrl,
        options: Options(
          responseType: ResponseType.json,
          // 4xx 要自己读 body 判断限流，不能让 dio 抛出去丢信息
          validateStatus: (_) => true,
          receiveTimeout: const Duration(seconds: 20),
        ),
      );
      final code = res.statusCode ?? 0;
      if (code == 403 || code == 429) {
        return const UpdateCheck(
          status: UpdateStatus.failed,
          message: 'GitHub 请求过于频繁，请过一会儿再试',
        );
      }
      if (code == 404) {
        return const UpdateCheck(
          status: UpdateStatus.failed,
          message: '更新源还没有发布记录',
        );
      }
      if (code != 200) {
        return UpdateCheck(
          status: UpdateStatus.failed,
          message: '检查更新失败（HTTP $code）',
        );
      }

      final info = parseReleaseJson(_asMap(res.data));
      if (info == null) {
        return const UpdateCheck(
          status: UpdateStatus.failed,
          message: '版本信息无法解析，请稍后再试',
        );
      }

      await _writeCache(prefs, info, nowMs);
      return _decide(
        info,
        checkedAt: DateTime.fromMillisecondsSinceEpoch(nowMs),
      );
    } on DioException catch (e) {
      logD('Update', 'check failed: ${e.type} ${e.message}');
      return UpdateCheck(
        status: UpdateStatus.failed,
        message: _netMessage(e),
      );
    } catch (e) {
      logD('Update', 'check error: $e');
      return const UpdateCheck(
        status: UpdateStatus.failed,
        message: '检查更新失败，请稍后再试',
      );
    }
  }

  /// 下载安装包到临时目录。
  ///
  /// [onProgress] 收到 0~1；[cancelToken] 用于用户中途取消。
  /// 有 `asset.size` 时校验落地体积，缺一段就重试一次——GitHub 的
  /// `objects.githubusercontent.com` 偶发截断，直接装会报「解析包错误」。
  Future<File> download(
    ReleaseInfo info, {
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final asset = info.asset;
    if (asset == null) {
      throw const UpdateException('这个版本没有提供安装包，只能去网页下载');
    }

    final dir = await (resolveTempDir?.call() ??
        Future<Directory>.value(Directory.systemTemp));
    final target = Directory(joinPath(dir.path, 'updates'));
    if (!await target.exists()) await target.create(recursive: true);
    final file = File(joinPath(target.path, 'update-${info.version}.apk'));

    for (var attempt = 0; attempt < 2; attempt++) {
      if (await file.exists()) await file.delete();
      try {
        await dio.download(
          asset.url,
          file.path,
          cancelToken: cancelToken,
          deleteOnError: true,
          options: Options(
            followRedirects: true,
            receiveTimeout: const Duration(minutes: 5),
          ),
          onReceiveProgress: (received, total) {
            final full = total > 0 ? total : asset.size;
            if (full > 0) {
              onProgress?.call((received / full).clamp(0.0, 1.0));
            }
          },
        );
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) throw const UpdateException('已取消下载');
        if (attempt == 1) throw UpdateException(_netMessage(e));
        continue;
      }

      final length = await file.length();
      if (asset.size <= 0 || length == asset.size) {
        onProgress?.call(1);
        logD('Update', 'downloaded ${file.path} ($length B)');
        return file;
      }
      logD('Update', 'size mismatch: $length != ${asset.size}, retry');
      if (attempt == 1) {
        throw UpdateException(
          '下载不完整（${formatBytes(length)} / ${asset.sizeLabel}），请重试',
        );
      }
    }
    throw const UpdateException('下载安装包失败，请稍后再试');
  }

  /// 清掉节流与缓存（调试用，或用户想立刻重新检查）。
  static Future<void> clearCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kCacheKey);
      await prefs.remove(_kCheckMsKey);
    } catch (_) {}
  }

  UpdateCheck _decide(
    ReleaseInfo info, {
    DateTime? checkedAt,
    bool fromCache = false,
  }) {
    final suffix = fromCache && checkedAt != null
        ? '（${_agoLabel(checkedAt)}检查的结果）'
        : '';
    if (info.prerelease) {
      // 预发布不催更新：用户装的是正式版就别被 beta 打扰
      return UpdateCheck(
        status: UpdateStatus.upToDate,
        info: info,
        message: '已是最新版本$suffix',
        checkedAt: checkedAt,
        fromCache: fromCache,
      );
    }
    final newer = isNewerVersion(info.version, currentVersion);
    if (!newer) {
      return UpdateCheck(
        status: UpdateStatus.upToDate,
        info: info,
        message: '已是最新版本$suffix',
        checkedAt: checkedAt,
        fromCache: fromCache,
      );
    }
    return UpdateCheck(
      status: UpdateStatus.available,
      info: info,
      message: info.hasAsset
          ? '发现新版本 ${info.version}'
          : '发现新版本 ${info.version}，但该版本没有安装包',
      checkedAt: checkedAt,
      fromCache: fromCache,
    );
  }

  static Map<String, dynamic> _asMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String && data.trim().isNotEmpty) {
      final decoded = jsonDecode(data);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    }
    return const <String, dynamic>{};
  }

  static ReleaseInfo? _readCache(SharedPreferences? prefs) {
    final raw = prefs?.getString(_kCacheKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return ReleaseInfo.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeCache(
    SharedPreferences? prefs,
    ReleaseInfo info,
    int nowMs,
  ) async {
    if (prefs == null) return;
    try {
      await prefs.setString(_kCacheKey, jsonEncode(info.toJson()));
      await prefs.setInt(_kCheckMsKey, nowMs);
    } catch (_) {}
  }

  static String _agoLabel(DateTime at) {
    final diff = DateTime.now().difference(at);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    return '${diff.inDays} 天前';
  }

  static String _netMessage(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接 GitHub 超时，请检查网络后重试';
      case DioExceptionType.connectionError:
        return '网络不可用，无法连接 GitHub';
      case DioExceptionType.badCertificate:
        return '证书校验失败，请检查网络环境';
      case DioExceptionType.cancel:
        return '已取消';
      default:
        final code = e.response?.statusCode;
        if (code != null) return '检查更新失败（HTTP $code）';
        return '网络异常，请稍后再试';
    }
  }
}
