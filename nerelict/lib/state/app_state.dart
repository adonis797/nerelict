import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:path_provider/path_provider.dart';

import '../models/download_task.dart';
import '../models/player_request.dart' show PlayerMode, PlayerRequest;
import '../models/sniffed_media.dart';
import '../services/app_log.dart';
import '../services/conversion_policy.dart';
import '../services/download_store.dart';
import '../services/favorites.dart';
import '../services/file_manager.dart';
import '../services/hls_downloader.dart';
import '../services/local_media_scanner.dart';
import '../services/mp4_converter.dart';
import '../services/network_status.dart';
import '../services/playback_memory.dart';
import '../services/resource_aggregator.dart';
import '../services/storage_service.dart';
import '../services/app_paths.dart';

class AppState extends ChangeNotifier {
  AppState({
    this.resolveExportDir,
    this.loadPlayerOffset,
    this.savePlayerOffset,
    this.autoConvertMp4,
    this.downloadConcurrency,
    this.wifiOnly,
    this.downloadRetries,
  }) {
    _downloader = HlsDownloader(
      resolveTempDir: _partsDir,
      resolveOutputDir: appDownloadDir,
    );
    // 切后台 / 被系统回收前再落盘一次，尽量不丢最后几秒的进度
    _lifecycle = AppLifecycleListener(
      onPause: _persistNow,
      onDetach: _persistNow,
    );
    _bootstrap();
  }

  late final AppLifecycleListener _lifecycle;

  /// 读取用户自选的下载位置（由 main.dart 注入，避免状态之间互相依赖）
  final Future<String?> Function()? resolveExportDir;

  /// 浮层拖动位置的持久化回调（由 main.dart 注入 SharedPreferences）
  final Future<Offset?> Function()? loadPlayerOffset;
  final Future<void> Function(Offset)? savePlayerOffset;

  /// 「下载完成后自动转 MP4」开关（由 main.dart 注入 SettingsState）
  final bool Function()? autoConvertMp4;

  /// 下载调度：并发上限 / 仅 Wi-Fi / 失败重试（同样由 SettingsState 注入）
  final int Function()? downloadConcurrency;
  final bool Function()? wifiOnly;
  final int Function()? downloadRetries;

  /// 分片临时目录：放在应用私有支持目录，而不是系统临时目录。
  /// 系统清理临时目录时不会连分片一起删掉，因此重启后仍能续传。
  Future<Directory> _partsDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(joinPath(base.path, 'parts'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _bootstrap() async {
    try {
      final saved = await loadPlayerOffset?.call();
      if (saved != null) {
        _playerOffset = saved;
        notifyListeners();
      }
    } catch (_) {}
    await _restoreTasks();
    await refreshLocalFiles();
    // 恢复任务之后再清理：活跃 / 暂停任务的 ss_* 目录要留着供续传
    unawaited(cleanupStaleParts());
    logD(
        'App',
        'bootstrap done: ${_tasks.length} tasks, '
            '${_localFiles.length} files');
    _resumeRecovered();
  }

  /// 启动时恢复上次未完成 / 已完成的下载任务。
  /// 已完成但产物已被删除的条目直接丢弃，避免出现「已完成但不可播放」。
  Future<void> _restoreTasks() async {
    List<DownloadTask> restored;
    try {
      restored = await _store.load();
    } catch (_) {
      restored = <DownloadTask>[];
    }
    if (restored.isEmpty) return;

    final keep = <DownloadTask>[];
    for (final task in restored) {
      if (task.status == TaskStatus.done) {
        final ok =
            await _fileExists(task.filePath) || await _fileExists(task.mp4Path);
        if (!ok) continue;
      }
      keep.add(task);
    }
    _tasks
      ..clear()
      ..addAll(keep);
    logD('Download', 'restored ${keep.length}/${restored.length} tasks');
    if (keep.isNotEmpty) notifyListeners();
  }

  static Future<bool> _fileExists(String? path) async {
    if (path == null || path.isEmpty) return false;
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  /// 恢复出来的「下载中」任务会被自动继续：分片已在磁盘上，
  /// 续传只补缺失的部分，不会从头再下一次。
  void _resumeRecovered() {
    // 只自动继续「上次正在下载」的任务；用户手动暂停的任务保持暂停
    final pending = _tasks
        .where((t) =>
            t.recovered && t.savedActive && t.status == TaskStatus.paused)
        .toList(growable: false);
    if (pending.isEmpty) return;
    // 等首帧渲染后再启动网络协程，避免启动阶段互相抢资源
    Timer(const Duration(milliseconds: 1200), () {
      for (final task in pending) {
        if (task.detached || task.status != TaskStatus.paused) continue;
        resumeTask(task);
      }
      showHint('已恢复 ${pending.length} 个未完成任务，正在继续下载');
    });
  }

  late final HlsDownloader _downloader;
  final DownloadStore _store = DownloadStore();

  final List<SniffedMedia> _sniffed = [];
  final List<DownloadTask> _tasks = [];
  final ResourceAggregator _aggregator = ResourceAggregator();

  Timer? _persistTimer;

  /// 任务状态落盘（合并 600ms 内的多次变化，避免每个分片都写一次文件）。
  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 600), _persistNow);
  }

  void _persistNow() {
    _persistTimer?.cancel();
    _persistTimer = null;
    unawaited(_store.save(_tasks));
  }

  // ---- 下载调度：并发上限 / 仅 Wi-Fi / 失败自动重试 ----
  bool _pumping = false;
  Timer? _wifiTimer;
  Timer? _retryTimer;
  bool? _wifiValue;
  DateTime _wifiCheckedAt = DateTime.fromMillisecondsSinceEpoch(0);

  int get _concurrency => (downloadConcurrency?.call() ?? 2).clamp(1, 3);
  bool get _wifiOnly => wifiOnly?.call() ?? false;
  int get _retryLimit => (downloadRetries?.call() ?? 1).clamp(0, 3);

  Future<bool> _isOnWifi({bool force = false}) async {
    final fresh =
        DateTime.now().difference(_wifiCheckedAt) < const Duration(seconds: 8);
    if (!force && _wifiValue != null && fresh) return _wifiValue!;
    final value = await NetworkStatus.isWifi();
    _wifiValue = value;
    _wifiCheckedAt = DateTime.now();
    return value;
  }

  DownloadTask? _nextQueued() {
    final now = DateTime.now();
    // 列表是「新任务在前」，倒序即先来先下
    for (final task in _tasks.reversed) {
      if (task.detached || task.status != TaskStatus.queued) continue;
      if (_running.containsKey(task.id)) continue;
      final at = task.retryAt;
      if (at != null && at.isAfter(now)) continue;
      return task;
    }
    return null;
  }

  /// 调度循环：把排队任务按并发上限放进运行槽位
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_running.length < _concurrency) {
        final task = _nextQueued();
        if (task == null) break;
        if (_wifiOnly && !await _isOnWifi()) {
          logD('Download', 'waiting for wifi: ${task.id}');
          _armWifiTimer();
          break;
        }
        task.retryAt = null;
        _running[task.id] = _runTask(
          task,
          resume: task.bytes > 0 || task.doneSegments > 0,
        );
        notifyListeners();
      }
    } finally {
      _pumping = false;
    }
    _armRetryTimer();
  }

  /// 仅 Wi-Fi 时被挡住：隔一会儿重新探测网络，连上 Wi-Fi 后自动继续
  void _armWifiTimer() {
    if (_wifiTimer?.isActive ?? false) return;
    _wifiTimer = Timer(const Duration(seconds: 6), () {
      _wifiTimer = null;
      _wifiValue = null; // 强制重新探测
      unawaited(_pump());
    });
  }

  /// 有任务处于「重试冷却」时，到点再调度一次
  void _armRetryTimer() {
    DateTime? earliest;
    for (final t in _tasks) {
      final at = t.retryAt;
      if (at == null || t.status != TaskStatus.queued) continue;
      if (earliest == null || at.isBefore(earliest)) earliest = at;
    }
    _retryTimer?.cancel();
    if (earliest == null) return;
    final delay = earliest.difference(DateTime.now());
    _retryTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () => unawaited(_pump()),
    );
  }

  /// 失败后按设置自动重试：退避 2s / 4s / 6s，次数用尽就保持失败态
  void _scheduleRetryIfNeeded(DownloadTask task) {
    if (task.detached) return;
    if (task.status == TaskStatus.done) {
      task.retryCount = 0;
      return;
    }
    if (task.status != TaskStatus.failed) return;
    if (task.retryCount >= _retryLimit) return;
    task.retryCount++;
    task.error = null;
    task.status = TaskStatus.queued;
    final seconds = 2 * task.retryCount;
    task.retryAt = DateTime.now().add(Duration(seconds: seconds));
    logW('Download', 'retry ${task.id} #${task.retryCount} in ${seconds}s');
    notifyListeners();
  }

  // ---- 统一的轻提示（替代散落的 SnackBar）：可自动消失、可点 ×、可带一个动作 ----
  String? _hint;
  int _hintToken = 0;
  String? _hintAction;
  VoidCallback? _hintActionTap;
  Duration _hintDuration = const Duration(milliseconds: 1600);

  String? get hint => _hint;
  int get hintToken => _hintToken;
  String? get hintAction => _hintAction;
  VoidCallback? get hintActionTap => _hintActionTap;
  Duration get hintDuration => _hintDuration;

  /// 轻提示：默认 1.6 秒自动消失，可点 × 立即关闭。
  /// 带 [actionLabel] 时停留更久一点，方便用户点到动作。
  void showToast(
    String text, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
  }) {
    _hint = text;
    _hintAction = actionLabel;
    _hintActionTap = onAction;
    _hintDuration = duration ??
        (actionLabel == null
            ? const Duration(milliseconds: 1600)
            : const Duration(milliseconds: 2600));
    _hintToken++;
    logD('Toast', text);
    notifyListeners();
  }

  /// 兼容旧调用
  void showHint(String text) => showToast(text);

  /// 错误提示：除了展示原因，附带「复制」动作，方便把完整错误贴出来。
  void showError(String message, {Object? detail, Duration? duration}) {
    final full = detail == null ? message : '$message\n$detail';
    showToast(
      message,
      actionLabel: '复制',
      duration: duration ?? const Duration(seconds: 4),
      onAction: () {
        Clipboard.setData(ClipboardData(text: full));
      },
    );
  }

  void clearHint(int token) {
    if (token != _hintToken) return; // 已有更新的提示，不要误清
    if (_hint == null) return;
    _hint = null;
    _hintAction = null;
    _hintActionTap = null;
    notifyListeners();
  }

  /// 本页当前选中的资源（离开页面时一并清空）
  String? _selectedUrl;

  // ---- 浮层拖动位置 ----
  /// null 表示使用默认底部位置；拖动后固定到该左上角坐标
  Offset? _playerOffset;
  Offset? get playerOffset => _playerOffset;

  void setPlayerOffset(Offset offset) {
    _playerOffset = offset;
    notifyListeners();
    savePlayerOffset?.call(offset);
  }

  // ---- 下载目录里的文件（视频 / 音频 / 图片 / 文档 / 压缩包 / 其他） ----
  List<LocalFile> _localFiles = <LocalFile>[];
  List<LocalFile> get localFiles => List.unmodifiable(_localFiles);

  /// 扫描序号：下载完成、转换结束、清理任务、切回页面都会触发重扫。
  /// 只接受最新一次的结果，避免慢的旧扫描把列表回退成「文件还没出现」的快照。
  int _scanSeq = 0;
  bool _disposed = false;

  /// 上次扫描是否不完整（目录枚举或读取出错）。此时保留旧列表，
  /// 不让「部分结果」把已经显示出来的文件抹掉，并由界面给出提示。
  bool _lastScanIncomplete = false;
  bool get lastScanIncomplete => _lastScanIncomplete;

  Future<void> refreshLocalFiles() async {
    final seq = ++_scanSeq;
    final scan = await scanLocalFilesDetailed();
    if (_disposed || seq != _scanSeq) return;
    if (!scan.complete) {
      _lastScanIncomplete = true;
      logW('Files', 'scan incomplete: ${scan.errors} item(s) unreadable');
      notifyListeners();
      return;
    }
    _lastScanIncomplete = false;
    _localFiles = scan.files;
    notifyListeners();
  }

  /// 清理孤儿分片目录：保留所有未结束任务的目录，
  /// 其余（崩溃强杀、旧版本残留）全部删除，返回目录数与释放字节数。
  Future<({int dirs, int bytes})> cleanupStaleParts() async {
    final active = <String>{
      for (final task in _tasks)
        if (!task.detached && !task.status.isFinished) task.id,
    };
    return _downloader.cleanupStaleParts(active);
  }

  // ---- 下载文件管理：文件、任务、进度记忆、收藏、列表一次性同步 ----

  /// 重命名成品文件，返回新路径；任务引用与所有派生数据同步更新。
  Future<String> renameDownloadedFile(String path, String newName) async {
    final next = await FileManager.rename(path, newName);
    if (next == path) return path;
    for (final task in _tasks) {
      if (task.filePath == path) task.filePath = next;
      if (task.mp4Path == path) task.mp4Path = next;
    }
    await _syncFileSideStores(path, next);
    _closePlayerIfPlaying(path);
    await refreshLocalFiles();
    _persistNow();
    return next;
  }

  /// 删除单个成品文件（文件管理面板的单条操作）。
  Future<void> deleteDownloadedFile(String path) =>
      deleteDownloadedFiles(<String>[path]);

  /// 批量删除（文件管理多选）：文件、任务引用、进度记忆、收藏与列表
  /// 一次性同步；单个文件失败不阻塞其余文件，最后把第一个错误抛给界面。
  Future<void> deleteDownloadedFiles(Iterable<String> paths) async {
    final targets = paths.where((e) => e.trim().isNotEmpty).toSet().toList();
    if (targets.isEmpty) return;

    FileManagerException? firstError;
    for (final path in targets) {
      try {
        await FileManager.delete(path);
      } on FileManagerException catch (e) {
        firstError ??= e;
        continue;
      }
      // 若某个已完成任务因此没有任何文件，则一并移除，
      // 避免留下「已完成 / 可播放」但文件不存在的状态不一致条目。
      final orphan = <DownloadTask>[];
      for (final task in _tasks) {
        if (task.filePath == path) task.filePath = null;
        if (task.mp4Path == path) {
          task.mp4Path = null;
          task.conversion = ConversionState.idle;
          task.conversionError = null;
          task.mp4Info = null;
        }
        if (task.status == TaskStatus.done &&
            task.filePath == null &&
            task.mp4Path == null) {
          task.detached = true;
          task.cancelRequested = true;
          orphan.add(task);
        }
      }
      for (final task in orphan) {
        _tasks.remove(task);
      }
      await _syncFileSideStores(path, null);
      _closePlayerIfPlaying(path);
    }
    await refreshLocalFiles();
    _persistNow();
    if (firstError != null) throw firstError;
  }

  Future<void> _syncFileSideStores(String oldPath, String? nextPath) async {
    final memory = PlaybackMemory();
    final record = await memory.get('file:$oldPath');
    if (record != null) {
      await memory.remove('file:$oldPath');
      if (nextPath != null) {
        await memory.save(PlaybackRecord(
          key: 'file:$nextPath',
          url: nextPath,
          title: _baseName(nextPath),
          positionMs: record.positionMs,
          durationMs: record.durationMs,
          speed: record.speed,
          updatedAt: record.updatedAt,
          local: true,
          referer: record.referer,
        ));
      }
    }
    final favorites = FavoritesStore();
    if (nextPath == null) {
      await favorites.removeUrl(oldPath);
    } else {
      await favorites.retarget(oldPath, nextPath, _baseName(nextPath));
    }
  }

  String _baseName(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  void _closePlayerIfPlaying(String path) {
    final current = _player;
    if (current != null && current.local && current.url == path) {
      // 正在播放的文件已被改名/删除，关闭浮层避免指向失效地址
      _player = null;
      _playerMode = PlayerMode.panel;
      playerClosedAt = DateTime.now();
    }
  }

  /// 每个任务正在执行的下载协程，用于「继续」前等待旧协程彻底退出
  final Map<String, Future<void>> _running = <String, Future<void>>{};

  /// 当前页面最后一次发现的源，用于底部横幅
  SniffedMedia? _latest;

  List<SniffedMedia> get sniffed => List.unmodifiable(_sniffed);
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  SniffedMedia? get latest => _latest;
  String? get selectedUrl => _selectedUrl;

  int get activeCount => _tasks.where((t) => t.status.isActive).length;

  // ---- MA8N浮层：不跳转路由，保持当前页面不变 ----
  PlayerRequest? _player;
  PlayerRequest? get player => _player;

  PlayerMode _playerMode = PlayerMode.panel;
  PlayerMode get playerMode => _playerMode;

  void setPlayerMode(PlayerMode mode) {
    if (_playerMode == mode) return;
    logD('Player', 'mode -> ${mode.name}');
    _playerMode = mode;
    notifyListeners();
  }

  /// 上次关闭浮层的时间，避免返回网页后被同一个视频反复接管
  DateTime? playerClosedAt;

  void openPlayer({
    required String url,
    String title = '',
    String? referer,
    bool local = false,
  }) {
    _player = PlayerRequest(
      url: url,
      title: title,
      referer: referer,
      local: local,
    );
    _playerMode = PlayerMode.panel;
    notifyListeners();
  }

  /// 下载页 / 历史页的「继续观看」：从进度记忆恢复一次播放。
  void resumePlayback({
    required String url,
    String title = '',
    String? referer,
    bool local = false,
  }) =>
      openPlayer(url: url, title: title, referer: referer, local: local);

  void closePlayer() {
    if (_player == null && _playerMode == PlayerMode.panel) return;
    logD('Player', 'close (mode=${_playerMode.name})');
    _player = null;
    _playerMode = PlayerMode.panel;
    playerClosedAt = DateTime.now();
    notifyListeners();
  }

  // ---- 返回键分发 ----
  //
  // 页面各自注册拦截器（浏览器处理网页回退，下载页先收筛选），
  // 由 HomeScreen 统一按「播放器 → 当前标签页 → 页面拦截器 → 双击退出」的顺序处理，
  // 避免多个 PopScope 争抢返回事件。
  final List<Future<bool> Function()> _backInterceptors =
      <Future<bool> Function()>[];

  void addBackInterceptor(Future<bool> Function() interceptor) {
    if (!_backInterceptors.contains(interceptor)) {
      _backInterceptors.add(interceptor);
    }
  }

  void removeBackInterceptor(Future<bool> Function() interceptor) {
    _backInterceptors.remove(interceptor);
  }

  /// 依次询问页面能否消费返回；返回 true 表示已处理。
  Future<bool> handleBack() async {
    for (final interceptor in _backInterceptors.reversed.toList()) {
      if (await interceptor()) return true;
    }
    return false;
  }

  /// 底部导航当前页：播放器下载后可以直接切到「下载」
  int _tabIndex = 0;
  int get tabIndex => _tabIndex;

  void setTab(int index) {
    if (index < 0 || index > 2 || _tabIndex == index) return;
    final leavingBrowser = _tabIndex == 0 && index != 0;
    logD(
        'Tab',
        '$_tabIndex -> $index (mode=${_playerMode.name}, '
            'player=${_player != null})');
    _tabIndex = index;
    if (leavingBrowser) {
      // 浮层 / 全屏 / 迷你播放器都挂在全局 _PlayerLayer 上，与浏览器页是否
      // 可见无关。切页只清本页嗅探数据，播放会话与进度必须保留，
      // 否则从浏览器切到「文件 / 设置」会把正在播放的视频直接销毁。
      resetPageResources(keepPlayer: true);
      return;
    }
    notifyListeners();
  }

  /// 选中某个资源（播放 / 统一下载前调用），离开页面时自动清空
  void selectResource(String url) {
    if (_selectedUrl == url) return;
    _selectedUrl = url;
    notifyListeners();
  }

  /// 离开当前网页 / 页面卸载时调用，避免上一页数据残留到后续页面。
  ///
  /// [keepPlayer] 为 true 时保留当前播放会话（迷你小窗在切页、换页时都不该被关掉）。
  void resetPageResources({bool notify = true, bool keepPlayer = false}) {
    _resetPageData(keepPlayer: keepPlayer);
    if (notify) notifyListeners();
  }

  void _resetPageData({bool keepPlayer = false}) {
    _aggregator.clear();
    _sniffed.clear();
    _latest = null;
    _selectedUrl = null;
    // 迷你小窗视为后台播放：任何一次页面重置都不应顶掉它
    if (keepPlayer || _playerMode == PlayerMode.mini) {
      logD('Page', 'reset kept player (mode=${_playerMode.name})');
      return;
    }
    logD('Page', 'reset closed player');
    _player = null;
    _playerMode = PlayerMode.panel;
    playerClosedAt = null;
  }

  /// WebView 侧嗅探回调：先规范化去重 / 变体聚合 / 分片聚合，再更新列表
  void onSniffMessage(String raw) {
    try {
      final Map<String, dynamic> data = jsonDecode(raw) as Map<String, dynamic>;
      final url = (data['url'] as String?)?.trim();
      if (url == null || url.isEmpty) return;
      final changed = _aggregator.accept(
        url: url,
        kind: (data['kind'] as String?) ?? 'playlist',
        page: (data['page'] as String?) ?? '',
        source: (data['from'] as String?) ?? 'unknown',
        title: (data['title'] as String?) ?? '',
        parent: data['parent'] as String?,
      );
      if (!changed) return;
      _sniffed
        ..clear()
        ..addAll(_aggregator.items);
      _latest = _sniffed.isEmpty ? null : _sniffed.first;
      notifyListeners();
    } catch (_) {
      // 忽略非法消息
    }
  }

  void clearSniffed() {
    _aggregator.clear();
    _sniffed.clear();
    _latest = null;
    _selectedUrl = null;
    notifyListeners();
  }

  void dismissBanner() {
    _latest = null;
    notifyListeners();
  }

  /// 从嗅探结果或手动输入发起下载
  DownloadTask startDownload({
    required String url,
    String? title,
    String? referer,
    List<String>? segments,
  }) {
    final task = DownloadTask(
      id: DownloadTask.newId(),
      url: url,
      title: (title == null || title.trim().isEmpty) ? 'video' : title.trim(),
    )
      ..referer = referer
      ..segments = segments;

    _tasks.insert(0, task);
    logD('Download', 'enqueue ${task.id} ${task.url}');
    notifyListeners();
    _persistNow();

    unawaited(_pump());
    return task;
  }

  Future<void> _runTask(DownloadTask task, {bool resume = false}) async {
    try {
      await _downloader.run(
        task,
        onUpdate: () {
          if (task.detached) return;
          notifyListeners();
          // 进度落盘做节流：崩溃 / 杀进程后能恢复到最接近的分片位置
          _schedulePersist();
        },
        isCanceled: () => task.cancelRequested,
        resume: resume,
      );
      logD(
          'Download',
          'task ${task.id} -> ${task.status.name}'
              '${task.error == null ? '' : ' err=${task.error}'}');
      if (!task.detached && task.status == TaskStatus.done) {
        if (task.isLive) {
          showToast('直播流只保存了当前片段，可能不是完整视频',
              duration: const Duration(seconds: 4));
        }
        await _autoConvertIfEnabled(task);
        // 原生转换 / 导出都是 await 点，期间用户可能点了「清除已完成」。
        // 任务脱离后立刻收手，不再导出、不再重扫、不再弹提示。
        if (task.detached) return;
        await _exportIfNeeded(task);
        if (task.detached) return;
        await refreshLocalFiles();
      }
    } finally {
      _running.remove(task.id);
      _scheduleRetryIfNeeded(task);
      if (!task.detached) notifyListeners();
      _persistNow();
      unawaited(_pump());
    }
  }

  /// 设置里开启「一键转换为 MP4」时：下载完成即刻转封装，
  /// 成功后删除 M3U8 合并出来的 TS 源文件，只保留 MP4。
  Future<void> _autoConvertIfEnabled(DownloadTask task) async {
    if (task.detached) return;
    final enabled = autoConvertMp4?.call() ?? false;
    if (!enabled || !task.canConvert) return;
    await convertToMp4(task, deleteSource: true, automatic: true);
  }

  /// 暂停单个任务：立刻掐断在途请求，保留临时分片与当前进度。
  /// 其他任务的协程持有各自的 CancelToken，互不影响。
  void pauseTask(DownloadTask task) {
    if (!task.status.isActive) return;
    task.pauseRequested = true;
    // 立刻收敛状态：旧协程要等网络请求被中断才退出，在那之前用户点
    // 「继续」会因 status 还不是 paused 而被静默忽略，按钮也一直显示暂停。
    task.status = TaskStatus.paused;
    logD('Download', 'pause ${task.id}');
    _downloader.interrupt(task.id);
    notifyListeners();
    _persistNow();
    unawaited(_pump());
  }

  /// 继续单个任务：等旧协程退出后，以续传模式重新跑。
  Future<void> resumeTask(DownloadTask task) async {
    if (task.resumeRequested) return;
    if (task.status != TaskStatus.paused && !task.pauseRequested) return;
    // 等待期间防重入：连续点「继续」只排队一次，避免产生多个续传协程。
    task.resumeRequested = true;
    try {
      final previous = _running[task.id];
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // 旧协程收尾失败不应挡住恢复，下面按当前状态决定是否继续
        }
      }
      if (task.detached || task.status != TaskStatus.paused) return;

      task.pauseRequested = false;
      task.cancelRequested = false;
      task.error = null;
      task.status = TaskStatus.queued;
      task.retryAt = null;
      task.retryCount = 0;
      logD('Download', 'resume ${task.id}');
      notifyListeners();
      unawaited(_pump());
    } finally {
      task.resumeRequested = false;
    }
  }

  /// 「全部继续」：一次性恢复所有暂停中的任务
  Future<void> resumeAllPaused() async {
    final paused = _tasks.where((t) => t.status == TaskStatus.paused).toList();
    for (final task in paused) {
      await resumeTask(task);
    }
  }

  int get pausedCount =>
      _tasks.where((t) => t.status == TaskStatus.paused).length;

  /// 删除任务：先标记脱离、立刻中断网络并从列表移除，再通知 UI。
  /// 后台协程即使还没结束，也不会再刷新界面或写回状态，因此不会卡住/残留。
  void removeTask(DownloadTask task) {
    task.detached = true;
    task.cancelRequested = true;
    logD('Download', 'remove ${task.id}');
    _downloader.interrupt(task.id);
    unawaited(_downloader.discardParts(task.id));
    _tasks.remove(task);
    notifyListeners();
    _persistNow();
    unawaited(_pump());
  }

  /// 兼容旧调用：正在下载时的「×」也是删除（立即移除任务）
  void cancelTask(DownloadTask task) => removeTask(task);

  void clearFinished() {
    // 已结束任务的后台协程可能还在做「自动转 MP4 / 导出」：先让它们脱离，
    // 否则清理后还会写回已移除任务的状态、弹提示、继续往外部目录导出。
    for (final task in _tasks.where((t) => t.status.isFinished)) {
      task.detached = true;
      task.cancelRequested = true;
    }
    _tasks.removeWhere((t) => t.status.isFinished);
    notifyListeners();
    _persistNow();
    // 清掉任务记录后重扫一次，确保对应的成品立即出现在「文件」列表里
    unawaited(refreshLocalFiles());
    // 顺带清掉这些任务可能遗留的临时分片目录
    unawaited(cleanupStaleParts());
  }

  /// 转封装并校验产物：系统解码器读不出时长/画面时判定失败，
  /// 避免把「转换成功但打不开」的文件交给播放器。
  Future<String> _convertAndVerify(String sourcePath) async {
    final path = await Mp4Converter.convert(sourcePath);
    Map<String, dynamic> info = const <String, dynamic>{};
    try {
      info = await Mp4Converter.info(path);
    } catch (_) {}
    final ms = info['durationMs'];
    final duration = ms is int ? ms : 0;
    final width = info['width'] is int ? info['width'] as int : 0;
    final hasFrame = info['hasFrame'] == true;
    final hasVideo = width > 0 || hasFrame;
    final ok = duration > 0 && (!hasVideo || hasFrame);
    if (!ok) {
      // 产物不可解码：删掉，避免留在下载目录里变成「坏文件」
      try {
        await File(path).delete();
      } catch (_) {}
      throw Exception('转换产物无法解码，请稍后重试或重新下载');
    }
    return path;
  }

  String _describeMp4(Map<String, dynamic> info) {
    final w = info['width'];
    final h = info['height'];
    final ms = info['durationMs'];
    final seconds = (ms is int ? ms : 0) ~/ 1000;
    final parts = <String>[
      if (w is int && w > 0 && h is int && h > 0) '$w×$h',
      if (seconds > 0) '${seconds}s',
      if (info['hasAudio'] == true) '含音轨',
      if (info['hasFrame'] == true) '可解码',
    ];
    return parts.join(' · ');
  }

  /// 转换为 MP4。
  ///
  /// [deleteSource] 为 true 时（下载完成后自动转换）删除 TS 源文件，
  /// 最终只保留一个 MP4；手动转换时源文件保留，可随时重试。
  Future<void> convertToMp4(
    DownloadTask task, {
    bool deleteSource = false,
    bool automatic = false,
  }) async {
    if (task.detached || !canStartConversion(task: task)) return;

    final source = task.filePath;
    if (source == null) return;

    task.conversion = ConversionState.converting;
    task.conversionError = null;
    notifyListeners();
    _persistNow();

    try {
      logD('Convert', 'start ${task.id} $source');
      final path = await _convertAndVerify(source);
      // 原生转换是 await 点，期间任务可能已被「清除已完成」移除。
      // 此时不再写回状态 / 删源 / 导出 / 弹提示；产物留在下载目录，
      // 用户仍能在「文件」页看到它。
      if (task.detached) return;
      logD('Convert', 'done ${task.id} -> $path');
      task.mp4Path = path;
      task.conversion = ConversionState.done;
      try {
        task.mp4Info = _describeMp4(await Mp4Converter.info(path));
      } catch (_) {
        task.mp4Info = null;
      }

      if (deleteSource) {
        // 自动转换：只留 MP4，删掉 M3U8 合并出的 TS
        try {
          if (await File(source).exists()) await File(source).delete();
          if (task.filePath == source) task.filePath = null;
        } catch (_) {
          // 删除失败就保留源文件，不影响 MP4 可用
        }
      }
      await _exportIfNeeded(task, path: path);
      if (task.detached) return;
      await refreshLocalFiles();
      if (task.detached) return;
      if (automatic) {
        showHint(deleteSource ? '已自动转换为 MP4，源文件已清理' : '已自动转换为 MP4');
      }
    } catch (e) {
      if (task.detached) return;
      logE('Convert', 'failed ${task.id}', e);
      task.conversion = ConversionState.failed;
      final msg = e.toString().replaceFirst('Exception: ', '');
      task.conversionError =
          msg.length > 120 ? '${msg.substring(0, 120)}…' : msg;
      if (automatic) {
        showError('自动转换为 MP4 失败', detail: msg);
      }
    }
    if (task.detached) return;
    notifyListeners();
    _persistNow();
  }

  /// 下载页「MP4 转换」独立入口：转换下载目录里任意一个 TS 文件。
  /// 返回产物路径；失败时抛出可直接展示的错误信息。
  Future<String> convertLocalFile(
    String path, {
    bool deleteSource = false,
  }) async {
    final out = await _convertAndVerify(path);
    if (deleteSource) {
      try {
        if (await File(path).exists()) await File(path).delete();
      } catch (_) {}
    }
    // 若该文件属于某个任务，同步任务上的转换结果
    for (final task in _tasks) {
      if (task.filePath == path) {
        task.mp4Path = out;
        task.conversion = ConversionState.done;
        task.conversionError = null;
        try {
          task.mp4Info = _describeMp4(await Mp4Converter.info(out));
        } catch (_) {}
        if (deleteSource) task.filePath = null;
      }
    }
    await refreshLocalFiles();
    notifyListeners();
    _persistNow();
    return out;
  }

  /// 下载/转换完成后，若用户选了自定义位置，再导出一份。
  /// 应用私有目录里的原件始终保留，保证应用内直接播放可用。
  Future<void> _exportIfNeeded(DownloadTask task, {String? path}) async {
    if (task.detached) return;
    final uri = await resolveExportDir?.call();
    // 读取导出位置也是 await 点，期间任务可能已被清除
    if (task.detached) return;
    final src = path ?? task.filePath;
    if (uri == null || uri.isEmpty || src == null) return;
    final name = src.split(Platform.pathSeparator).last;
    final ok = await StorageService.exportFile(uri: uri, path: src, name: name);
    if (!task.detached) {
      task.exported = ok;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _persistTimer?.cancel();
    _wifiTimer?.cancel();
    _retryTimer?.cancel();
    _persistNow();
    _lifecycle.dispose();
    super.dispose();
  }
}
