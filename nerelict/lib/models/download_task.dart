import 'dart:math';

import '../services/header_policy.dart';

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

  /// 音轨被拆成独立流时多出来的一条轨：下载完成后停在分轨状态，
  /// 必须再转封装一次才能得到「有声的 MP4」。
  bool get needsAudioMux =>
      audioPath != null && audioPath!.trim().isNotEmpty;

  /// 只有下载完成、且产物是 TS 或被拆成了两条轨时，转换按钮才有意义。
  /// 双轨情形下视频轨本身可能已经是 mp4（fMP4），所以不能只看扩展名。
  bool get canConvert =>
      status == TaskStatus.done &&
      filePath != null &&
      conversion != ConversionState.converting &&
      (needsAudioMux || filePath!.toLowerCase().endsWith('.ts'));

  /// 可在 Nerelict 里直接播放的成品（优先 MP4）
  String? get playablePath => mp4Path ?? filePath;

  /// 发现该源的页面地址，下载时作为 Referer 带上（很多 CDN 会校验）
  String? referer;

  /// 页面发起该请求时带的鉴权头（Authorization / X-*），下载时回放。
  ///
  /// 与 Cookie 的区别：Cookie 由 CookieStore 按站点实时读取、不落盘；
  /// 这里的头在页面上没有别的来源，只能随任务一起持久化，否则重启后续传
  /// 会退化成匿名请求，直接 403。已经过 HeaderPolicy 白名单过滤。
  Map<String, String> requestHeaders = const <String, String>{};

  /// 实际选中的码率（主播放列表时）
  String? variant;

  /// 用户选定码率的稳定标识（`带宽@分辨率`）。
  /// 用下标会出错：站点刷新播放列表后顺序可能变化，续传时按下标还原会选错档。
  String? variantKey;

  /// 该码率声明了哪些字幕（仅展示，不参与下载）
  String? subtitleNote;

  /// 独立音轨的子播放列表地址（`#EXT-X-MEDIA` 的 AUDIO 组带 URI）。
  /// 非空表示这次下载取了「视频轨 + 音轨」两条，转封装时才合成有声文件。
  String? audioUrl;

  /// 音轨的语言 / 名称，用于任务卡片说明是哪一条音轨
  String? audioName;

  /// 音轨分轨产物（合并后、转封装前的中间文件）
  String? audioPath;

  /// 档位被自动调整时的说明，例如「最高清晰度音轨独立，已自动改用 720p」。
  /// 让降级是可见的，而不是静默发生。
  String? variantNote;

  /// 播放列表里 #EXT-X-DISCONTINUITY 的处数。大于 0 表示时间轴中途跳变，
  /// 产物能播但时间戳不连续，转 MP4 后时长可能对不上。
  int discontinuities = 0;

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
        if (requestHeaders.isNotEmpty) 'headers': requestHeaders,
        'variant': variant,
        'variantKey': variantKey,
        'subtitleNote': subtitleNote,
        'variantNote': variantNote,
        'audioUrl': audioUrl,
        'audioName': audioName,
        'audioPath': audioPath,
        'discontinuities': discontinuities,
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
    final savedHeaders = raw['headers'];
    if (savedHeaders is Map) {
      final clean = <String, String>{};
      for (final entry in savedHeaders.entries) {
        final name = entry.key;
        final value = entry.value;
        if (name is String && value is String) clean[name] = value;
      }
      // 磁盘上的内容可能是旧版本或被手工改过的，重新过一遍白名单
      task.requestHeaders = HeaderPolicy.sanitize(clean);
    }
    task.variant = raw['variant'] is String ? raw['variant'] as String : null;
    task.variantKey =
        raw['variantKey'] is String ? raw['variantKey'] as String : null;
    task.subtitleNote =
        raw['subtitleNote'] is String ? raw['subtitleNote'] as String : null;
    task.variantNote =
        raw['variantNote'] is String ? raw['variantNote'] as String : null;
    // 旧任务没有这三个字段：按 null 恢复，续传时重新解析主播放列表再补上
    task.audioUrl =
        raw['audioUrl'] is String ? raw['audioUrl'] as String : null;
    task.audioName =
        raw['audioName'] is String ? raw['audioName'] as String : null;
    task.audioPath =
        raw['audioPath'] is String ? raw['audioPath'] as String : null;
    task.discontinuities = asInt(raw['discontinuities']);
    task.isLive = raw['isLive'] == true;
    final segs = raw['segments'];
    if (segs is List) {
      final list = segs.whereType<String>().toList();
      if (list.isNotEmpty) task.segments = list;
    }
    return task;
  }
}
