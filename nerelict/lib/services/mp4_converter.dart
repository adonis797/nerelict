import 'package:flutter/services.dart';

/// 调用 Android 原生 MediaExtractor / MediaMuxer 做 TS -> MP4 转封装。
/// 不依赖 FFmpeg，也不重新编码，因此速度快且不损失画质。
class Mp4Converter {
  static const _channel = MethodChannel('com.nerelict/mp4');

  static Future<String> convert(String tsPath) async {
    try {
      final out =
          await _channel.invokeMethod<String>('convert', {'path': tsPath});
      if (out == null || out.isEmpty) {
        throw Exception('转换未返回输出文件');
      }
      return out;
    } on PlatformException catch (e) {
      // 把平台异常转成普通 Exception，上层状态管理不必依赖 flutter/services
      throw Exception(e.message ?? e.code);
    }
  }

  /// 用系统解码器读取产物信息，用于确认文件可解析
  static Future<Map<String, dynamic>> info(String path) async {
    final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'info',
      {'path': path},
    );
    return Map<String, dynamic>.from(res ?? {});
  }
}
