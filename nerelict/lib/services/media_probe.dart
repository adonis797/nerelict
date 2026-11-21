import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_paths.dart';
import 'local_media_scanner.dart';
import 'media_meta.dart';

/// 按需补齐本地文件的元数据（时长 / 分辨率 / 清单分片），并做持久缓存。
///
/// 三条设计约束：
///
/// 1. **不进扫描循环**：扫描只 stat；解码与读清单都慢，放在用户滚动到可见时再补。
/// 2. **按 `path + size + mtime` 缓存**：同名文件被覆盖或改名后必须重算，
///    否则会拿旧时长去配新文件。
/// 3. **拿不到就说拿不到**：解码失败标 `failed`，不返回空值让 UI 显示成「—」，
///    因为「0 秒」和「读不出」对用户是两件事。
class MediaProbe {
  MediaProbe._();

  static final MediaProbe instance = MediaProbe._();

  static const MethodChannel _channel = MethodChannel('com.nerelict/media');
  static const String _prefsKey = 'nerelict_media_meta_v1';

  /// 清单最多读这么多字节：正常 m3u8 远小于它，超了说明不是清单。
  static const int _playlistReadLimit = 256 * 1024;

  /// 单次最多核对多少个本地分片：长剧分成千段时不能让 UI 卡住。
  static const int _maxSegmentChecks = 240;

  /// 缓存条数上限，超出按插入顺序淘汰最旧的。
  static const int _maxEntries = 400;

  final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};
  final Map<String, Future<MediaMeta?>> _inflight = <String, Future<MediaMeta?>>{};
  bool _loaded = false;

  /// 同步读缓存；尺寸或修改时间变了就当作没有（返回 null 触发重新探测）。
  MediaMeta? peek(LocalFile file) {
    final hit = _cache[file.path];
    if (hit == null) return null;
    if (hit.size != file.size ||
        hit.modifiedMs != file.modifiedAt.millisecondsSinceEpoch) {
      return null;
    }
    return hit.meta;
  }

  /// 探测一个文件；不支持的类型直接返回 null，不做无意义的解码。
  Future<MediaMeta?> probe(LocalFile file) async {
    await _ensureLoaded();
    final cached = peek(file);
    if (cached != null) return cached;

    final pending = _inflight[file.path];
    if (pending != null) return pending;

    final future = _probeOnce(file);
    _inflight[file.path] = future;
    try {
      final meta = await future;
      if (meta != null) {
        _store(file, meta);
      }
      return meta;
    } finally {
      _inflight.remove(file.path);
    }
  }

  Future<MediaMeta?> _probeOnce(LocalFile file) async {
    try {
      if (isPlaylistName(file.name)) return await _probePlaylist(file);
      if (file.kind == LocalFileKind.video) return await _probeVideo(file);
      return null;
    } catch (_) {
      return const MediaMeta(failed: true, note: '读取失败');
    }
  }

  /// 清单：只读文本，数分片，再核对同目录里有没有对应文件。
  Future<MediaMeta?> _probePlaylist(LocalFile file) async {
    final f = File(file.path);
    final bytes = await f.openRead(0, _playlistReadLimit).fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    final text = utf8.decode(bytes, allowMalformed: true);
    final summary = parsePlaylistText(text);
    if (!summary.valid) {
      return const MediaMeta(isPlaylist: true, failed: true, note: '不是有效清单');
    }

    // 分片是相对路径时才能核对本地是否存在；绝对地址说明这是在线清单，无从核对
    final dir = f.parent;
    var checks = 0;
    var missing = 0;
    var remote = 0;
    for (final uri in summary.uris) {
      if (checks >= _maxSegmentChecks) break;
      if (uri.startsWith('http://') || uri.startsWith('https://')) {
        remote++;
        continue;
      }
      if (uri.contains('://')) continue;
      checks++;
      final name = uri.split('?').first.split('#').first;
      if (name.isEmpty) continue;
      final target = File(joinPath(dir.path, name));
      if (!await target.exists()) missing++;
    }

    final note = remote > 0 && summary.uris.isEmpty
        ? '远程分片'
        : (remote > 0 && checks == 0 ? '远程分片' : '');
    return MediaMeta(
      isPlaylist: true,
      segments: summary.segments,
      missingSegments: missing,
      encrypted: summary.encrypted,
      isMaster: summary.isMaster,
      note: note,
    );
  }

  /// 普通视频：交给原生 `MediaMetadataRetriever`，拿不到就标失败。
  Future<MediaMeta?> _probeVideo(LocalFile file) async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'probe',
        <String, dynamic>{'path': file.path},
      );
      if (raw == null) return const MediaMeta(failed: true, note: '读不出元数据');
      final ms = (raw['durationMs'] as num?)?.toInt() ?? 0;
      final w = (raw['width'] as num?)?.toInt() ?? 0;
      final h = (raw['height'] as num?)?.toInt() ?? 0;
      if (ms <= 0 && w <= 0 && h <= 0) {
        return const MediaMeta(failed: true, note: '读不出元数据');
      }
      return MediaMeta(
        duration: ms > 0 ? Duration(milliseconds: ms) : null,
        width: w > 0 ? w : null,
        height: h > 0 ? h : null,
      );
    } on MissingPluginException {
      // 主机端脚本没有原生层：当作不支持，不写负缓存
      return null;
    } catch (_) {
      return const MediaMeta(failed: true, note: '解码失败');
    }
  }

  void _store(LocalFile file, MediaMeta meta) {
    _cache[file.path] = _CacheEntry(
      size: file.size,
      modifiedMs: file.modifiedAt.millisecondsSinceEpoch,
      meta: meta,
    );
    while (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    _scheduleSave();
  }

  /// 文件名变了、文件删了之后，把失效的缓存条目清掉（避免无限增长）。
  void retainOnly(Set<String> livePaths) {
    if (_cache.isEmpty) return;
    final stale = _cache.keys.where((p) => !livePaths.contains(p)).toList();
    if (stale.isEmpty) return;
    for (final p in stale) {
      _cache.remove(p);
    }
    _scheduleSave();
  }

  bool _saveScheduled = false;

  void _scheduleSave() {
    if (_saveScheduled) return;
    _saveScheduled = true;
    // 缓存是「下次启动更快」的优化，写盘晚一点、合并一次即可
    Future<void>.delayed(const Duration(seconds: 2), () async {
      _saveScheduled = false;
      await _save();
    });
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        final v = entry.value;
        if (v is! Map) continue;
        final meta = v['meta'];
        if (meta is! Map) continue;
        _cache[entry.key as String] = _CacheEntry(
          size: (v['size'] as num?)?.toInt() ?? -1,
          modifiedMs: (v['mtime'] as num?)?.toInt() ?? -1,
          meta: MediaMeta.fromJson(Map<String, dynamic>.from(meta)),
        );
      }
    } catch (_) {
      // 缓存坏了就当没有，不影响功能
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final out = <String, dynamic>{};
      for (final e in _cache.entries) {
        out[e.key] = <String, dynamic>{
          'size': e.value.size,
          'mtime': e.value.modifiedMs,
          'meta': e.value.meta.toJson(),
        };
      }
      await prefs.setString(_prefsKey, jsonEncode(out));
    } catch (_) {}
  }
}

class _CacheEntry {
  const _CacheEntry({
    required this.size,
    required this.modifiedMs,
    required this.meta,
  });

  final int size;
  final int modifiedMs;
  final MediaMeta meta;
}
