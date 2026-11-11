import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/download_task.dart';
import 'app_paths.dart';

/// 下载任务落盘：把任务列表（地址、标题、进度、已完成分片、产物路径）
/// 写进应用私有目录，进程被杀 / 应用重启后仍能恢复并继续下载。
///
/// 与分片目录（parts/）分开保存：分片本身留在磁盘上，恢复时按分片复用。
class DownloadStore {
  DownloadStore({Future<File> Function()? resolveFile})
      : _resolveFile = resolveFile ?? defaultFile;

  final Future<File> Function() _resolveFile;

  /// 串行化写入：多个 `_persistNow()` 可能在同一秒内触发，若并发写同一个
  /// 临时文件会互相覆盖，甚至把未写完的 JSON 替换成正式文件而丢光任务记录。
  Future<void> _lastSave = Future<void>.value();
  int _tmpSeq = 0;

  static const int _version = 2;

  /// 应用私有目录下的任务状态文件（不随系统清理临时目录而丢失）
  static Future<File> defaultFile() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(joinPath(base.path, 'state'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(joinPath(dir.path, 'download_tasks.json'));
  }

  Future<List<DownloadTask>> load() async {
    try {
      final file = await _resolveFile();
      if (!await file.exists()) return <DownloadTask>[];
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return <DownloadTask>[];
      final decoded = jsonDecode(raw);
      final list = decoded is Map ? decoded['tasks'] : decoded;
      if (list is! List) return <DownloadTask>[];
      return list
          .map(DownloadTask.fromJson)
          .whereType<DownloadTask>()
          .toList(growable: false);
    } catch (_) {
      // 文件损坏或格式变化：按空列表处理，不影响启动
      return <DownloadTask>[];
    }
  }

  Future<void> save(Iterable<DownloadTask> tasks) {
    // 调用瞬间取快照：await 期间任务列表可能被增删，迭代时会抛并发修改异常
    final snapshot = List<DownloadTask>.of(tasks);
    final next = _lastSave.then((_) => _writeSnapshot(snapshot));
    // _writeSnapshot 内部吞掉异常，队列不会因一次失败而中断
    _lastSave = next;
    return next;
  }

  Future<void> _writeSnapshot(List<DownloadTask> snapshot) async {
    try {
      final file = await _resolveFile();
      final payload = <String, dynamic>{
        'version': _version,
        'tasks': snapshot
            .where((t) => !t.detached && t.status != TaskStatus.canceled)
            .map((t) => t.toJson())
            .toList(growable: false),
      };
      // 先写临时文件再替换，避免进程在写一半时被杀导致 JSON 损坏；
      // 临时文件名带序号，串行队列之外的异常写入也不会覆盖别人的中间产物。
      final tmp = File('${file.path}.${_tmpSeq++}.tmp');
      await tmp.writeAsString(jsonEncode(payload), flush: true);
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
    } catch (_) {
      // 持久化失败不阻塞下载
    }
  }
}
