import '../models/download_task.dart';

/// 是否可以对该任务执行 MP4 转封装。
///
/// 纯 Dart，便于不依赖 Flutter 运行环境做验证。
/// 与设置开关无关：设置只控制「下载完成后自动转换」，
/// 下载页的 MP4 转换入口始终可用。
bool canStartConversion({required DownloadTask task}) => task.canConvert;
