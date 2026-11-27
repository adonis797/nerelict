import 'dart:io';

import 'file_kinds.dart';
import 'storage_scanner.dart';

/// 全盘文件的常驻索引。
///
/// 为什么要有它：全盘扫描是「一次几秒、几千到上万个 stat」的活，之前把结果
/// 存在 `FilesTab` 的 State 里，页面一销毁（换标签、重建、返回）就重来一遍，
/// 用户看到的就是「每次切回来都在转圈」。
///
/// 这里的取舍：
/// - **结果常驻内存**，页面切换只是重新读一份已有列表，零 IO；
/// - **过期才扫**：[ttl] 之内直接返回上次结果，[markDirty] 可提前作废；
/// - **增量可见**：扫描过程中按节流频率把已扫到的部分推给界面，
///   有旧结果时用户几乎感觉不到在扫；
/// - **单飞**：同一时刻只跑一轮，重复调用共享同一个 Future，不会叠出几路扫描；
/// - **纯 Dart**：不依赖 Flutter，`tool/verify_*` 可以用 `dart run` 直接测。
class FileIndex {
  FileIndex._();

  static final FileIndex instance = FileIndex._();

  /// 上次扫描多久之后算过期。设得比较长：用户主动改了文件会走 [markDirty]，
  /// 这里只是兜底，防止外部（别的应用）新建的文件永远不出现。
  static const Duration ttl = Duration(minutes: 10);

  List<LocalFile> _files = const <LocalFile>[];
  bool _scanning = false;
  bool _truncated = false;
  bool _incomplete = false;
  int _errors = 0;
  DateTime? _scannedAt;
  int _revision = 0;
  bool _dirty = true;

  String? _root;
  List<String> _extraRoots = const <String>[];
  bool _cancel = false;
  Future<void>? _inflight;

  final List<void Function()> _listeners = <void Function()>[];

  /// 已扫到的文件（增量时是当前进度快照）
  List<LocalFile> get files => _files;
  bool get scanning => _scanning;
  bool get truncated => _truncated;
  bool get incomplete => _incomplete;
  int get errors => _errors;
  DateTime? get scannedAt => _scannedAt;

  /// 每次「整轮扫描落地」加一。界面用它判断列表是否需要重排。
  int get revision => _revision;

  /// 有没有拿到过结果（哪怕是空列表）。首次扫描前为 false。
  bool get hasResult => _scannedAt != null;

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  /// 文件系统里的东西变了（下载完成、删除、重命名）：下次进来重扫。
  void markDirty() {
    _dirty = true;
  }

  /// 该不该重新扫。
  bool get needsScan {
    if (_scannedAt == null) return true;
    if (_dirty) return true;
    return DateTime.now().difference(_scannedAt!) > ttl;
  }

  /// 确保有一份可用结果：不满足 [needsScan] 时立刻返回，不产生任何 IO。
  ///
  /// [root] 通常是 `/storage/emulated/0`；[extraRoots] 传应用下载目录
  /// （它在 `Android/data/...` 下，全盘遍历会跳过，必须单独补扫）。
  /// [force] 为 true 时忽略 TTL / dirty，用于菜单里的「重新扫描」。
  Future<void> ensureFresh({
    required String root,
    List<String> extraRoots = const <String>[],
    bool force = false,
  }) {
    final rootChanged = _root != root;
    _root = root;
    _extraRoots = extraRoots;
    if (rootChanged) _dirty = true;
    if (!force && !needsScan) return Future<void>.value();
    return _run();
  }

  Future<void> _run() {
    final running = _inflight;
    if (running != null) return running;
    final root = _root;
    if (root == null || root.isEmpty) return Future<void>.value();
    final future = _scan(root, _extraRoots);
    _inflight = future;
    return future.whenComplete(() => _inflight = null);
  }

  Future<void> _scan(String root, List<String> extraRoots) async {
    _scanning = true;
    _dirty = false;
    _cancel = false;
    _notify();

    final result = await scanAllStorage(
      root: root,
      extraRoots: extraRoots,
      cancel: () => _cancel,
      onChunk: (partial) {
        // 取消后别再往界面上推旧数据
        if (_cancel) return;
        _files = partial;
        _notify();
      },
    );

    _scanning = false;
    if (_cancel) {
      _cancel = false;
      _notify();
      return;
    }
    _files = result.files;
    _truncated = result.truncated;
    _incomplete = !result.complete;
    _errors = result.errors;
    _scannedAt = DateTime.now();
    _revision++;
    _notify();
  }

  /// 放弃当前这一轮（页面销毁、权限被收回时用）。已扫到的部分会保留。
  void cancel() {
    if (_scanning) _cancel = true;
  }

  /// 改名 / 删除之后就地更新索引里的那一条。
  ///
  /// 不重扫：真机上一轮全盘扫描要几秒，改个名字不该等它。
  /// [to] 为 null 表示删除。
  void applyMove(String from, String? to) {
    final index = _files.indexWhere((f) => f.path == from);
    if (index < 0) return;
    final next = _files.toList();
    if (to == null) {
      next.removeAt(index);
    } else {
      final old = next[index];
      final cut = to.lastIndexOf(Platform.pathSeparator);
      final name = cut >= 0 ? to.substring(cut + 1) : to;
      next[index] = LocalFile(
        path: to,
        name: name,
        size: old.size,
        modifiedAt: old.modifiedAt,
        kind: LocalFile.kindOf(name),
        isDir: old.isDir,
      );
    }
    _files = next;
    _notify();
  }

  /// 清空索引，下次访问必定重扫；用于「所有文件权限」状态变化。
  void reset() {
    _cancel = true;
    _files = const <LocalFile>[];
    _scannedAt = null;
    _truncated = false;
    _incomplete = false;
    _errors = 0;
    _dirty = true;
    _revision++;
    _notify();
  }
}
