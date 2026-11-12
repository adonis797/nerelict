import 'dart:math';

enum TaskStatus {
  queued,
  parsing,
  downloading,
  merging,
  paused,
  done,
  failed,
  canceled,
}

/// 「一键转换为 mp4」的状态
enum ConversionState { idle, converting, done, failed }

extension TaskStatusLabel on TaskStatus {
  String get label => switch (this) {
        TaskStatus.queued => '排队中',
        TaskStatus.parsing => '解析中',
        TaskStatus.downloading => '下载中',
        TaskStatus.merging => '合并中',
        TaskStatus.paused => '已暂停',
        TaskStatus.done => '已完成',
        TaskStatus.failed => '失败',
        TaskStatus.canceled => '已取消',
      };

  /// 正在占用网络/写入资源的任务。暂停不算 active，可以独立挂起。
  bool get isActive =>
      this == TaskStatus.queued ||
      this == TaskStatus.parsing ||
      this == TaskStatus.downloading ||
      this == TaskStatus.merging;

  bool get isFinished =>
      this == TaskStatus.done ||
      this == TaskStatus.failed ||
      this == TaskStatus.canceled;
}

class DownloadTask {
  DownloadTask({
    required this.id,
    required this.url,
    required this.title,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String url;
  final String title;
  final DateTime createdAt;

  TaskStatus status = TaskStatus.queued;

  /// 总/已完成分片数
  int totalSegments = 0;
  int doneSegments = 0;

  /// 0..1，用于进度条
  double progress = 0;

  /// 已写入字节数
  int bytes = 0;

  String? filePath;
  String? error;

  /// 分片组资源：一组已聚合的分片 URL，作为单个下载对象按序下载合并
  List<String>? segments;

  /// 转换产物（仅在开启「一键转换为 mp4」并手动执行后才有值）
  String? mp4Path;
  ConversionState conversion = ConversionState.idle;
  String? conversionError;
  String? mp4Info;

  /// 成品是否已另外同步到用户自选的下载位置（不展示具体路径）
  bool exported = false;

  /// 只有下载完成且产物是 TS 时，转换按钮才有意义
  bool get canConvert =>
      status == TaskStatus.done &&
      filePath != null &&
      filePath!.toLowerCase().endsWith('.ts') &&
      conversion != ConversionState.converting;

  /// 可在 Nerelict 里直接播放的成品（优先 MP4）
  String? get playablePath => mp4Path ?? filePath;

  /// 发现该源的页面地址，下载时作为 Referer 带上（很多 CDN 会校验）
  String? referer;

  /// 实际选中的码率（主播放列表时）
  String? variant;

  /// 播放列表没有 #EXT-X-ENDLIST：本次只保存了当前窗口的片段，并非完整视频。
  /// 下载页与完成提示据此明确告知用户，避免误以为拿到了完整录像。
  bool isLive = false;

  /// 由下载器置位，用于中断
  bool cancelRequested = false;

  /// 暂停中：中断在途请求但保留临时分片，恢复时继续下载
  bool pauseRequested = false;

  /// 任务已从列表移除：后台协程不得再刷新 UI
  bool detached = false;

  /// 正在等旧协程退出以便续传：防止暂停后连续点「继续」产生多个续传协程。
  /// 纯运行期标志，不持久化。
  bool resumeRequested = false;

  /// 本次启动时从磁盘恢复的任务（仅用于界面提示，不持久化）
  bool recovered = false;

  /// 恢复时该任务原本正在下载（用于决定是否自动续传，不持久化）
  bool savedActive = false;

  /// 已自动重试次数（持久化，避免重启后无限重试）
  int retryCount = 0;

  /// 重试/排队的最早开始时间（运行期调度用，不持久化）
  DateTime? retryAt;

  String get sizeText {
    if (bytes <= 0) return '—';
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
  }

  String get progressText {
    if (status == TaskStatus.done) return sizeText;
    if (status == TaskStatus.paused) {
      return totalSegments == 0
          ? '已暂停 · 可继续'
          : '已暂停 · $doneSegments / $totalSegments 分片';
    }
    if (totalSegments == 0) return '—';
    return '$doneSegments / $totalSegments 分片';
  }

  static String newId() {
    final r = Random();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    return '${stamp}_${r.nextInt(1 << 20)}';
  }

  /// 落盘用：只保存恢复任务所必需的字段。
  /// 网络协程相关的 [cancelRequested] / [pauseRequested] / [detached] 不持久化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'url': url,
        'title': title,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'status': status.name,
        'total': totalSegments,
        'done': doneSegments,
        'progress': progress,
        'bytes': bytes,
        'filePath': filePath,
        'mp4Path': mp4Path,
        'conversion': conversion.name,
      'retryCount': retryCount,
        'conversionError': conversionError,
        'mp4Info': mp4Info,
        'exported': exported,
        'referer': referer,
        'variant': variant,
        'isLive': isLive,
        'segments': segments,
      };

  /// 从磁盘恢复：下载中的任务一律降级为「已暂停」，
  /// 由启动流程决定是否自动继续，避免恢复瞬间并发抢带宽。
  static DownloadTask? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final url = raw['url'];
    if (id is! String || id.isEmpty) return null;
    if (url is! String || url.isEmpty) return null;

    final created = raw['createdAt'];
    final task = DownloadTask(
      id: id,
      url: url,
      title: raw['title'] is String && (raw['title'] as String).isNotEmpty
          ? raw['title'] as String
          : 'video',
      createdAt: created is int && created > 0
          ? DateTime.fromMillisecondsSinceEpoch(created)
          : DateTime.now(),
    );

    final saved = TaskStatus.values.firstWhere(
      (e) => e.name == raw['status'],
      orElse: () => TaskStatus.paused,
    );
    task.savedActive = saved.isActive;
    task.status = saved.isActive ? TaskStatus.paused : saved;
    task.retryCount = (raw['retryCount'] is int) ? raw['retryCount'] as int : 0;
    task.recovered = true;

    int asInt(Object? v) => v is int ? v : 0;
    double asDouble(Object? v) => v is num ? v.toDouble() : 0;

    task.totalSegments = asInt(raw['total']);
    task.doneSegments = asInt(raw['done']);
    task.progress = asDouble(raw['progress']).clamp(0.0, 1.0);
    task.bytes = asInt(raw['bytes']);
    task.filePath = raw['filePath'] is String ? raw['filePath'] as String : null;
    task.mp4Path = raw['mp4Path'] is String ? raw['mp4Path'] as String : null;
    task.conversion = ConversionState.values.firstWhere(
      (e) => e.name == raw['conversion'],
      orElse: () => ConversionState.idle,
    );
    if (task.conversion == ConversionState.converting) {
      // 上次转换被进程退出打断，恢复后允许重新触发
      task.conversion = ConversionState.idle;
    }
    task.conversionError = raw['conversionError'] is String
        ? raw['conversionError'] as String
        : null;
    task.mp4Info = raw['mp4Info'] is String ? raw['mp4Info'] as String : null;
    task.exported = raw['exported'] == true;
    task.referer = raw['referer'] is String ? raw['referer'] as String : null;
    task.variant = raw['variant'] is String ? raw['variant'] as String : null;
    task.isLive = raw['isLive'] == true;
    final segs = raw['segments'];
    if (segs is List) {
      final list = segs.whereType<String>().toList();
      if (list.isNotEmpty) task.segments = list;
    }
    return task;
  }
}
