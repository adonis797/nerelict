import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 一条播放进度记忆（断点续播 / 下载页「继续观看」入口的数据源）。
class PlaybackRecord {
  const PlaybackRecord({
    required this.key,
    required this.url,
    required this.title,
    required this.positionMs,
    required this.durationMs,
    required this.speed,
    required this.updatedAt,
    required this.local,
    this.referer,
  });

  final String key;
  final String url;
  final String title;
  final int positionMs;
  final int durationMs;
  final double speed;
  final int updatedAt;
  final bool local;
  final String? referer;

  bool get resumable =>
      positionMs > 3000 &&
      (durationMs <= 0 || positionMs < durationMs * 0.95);

  String get progressText {
    String two(int n) => n.toString().padLeft(2, '0');
    final secs = positionMs ~/ 1000;
    return secs >= 3600
        ? '${two(secs ~/ 3600)}:${two((secs % 3600) ~/ 60)}:${two(secs % 60)}'
        : '${two(secs ~/ 60)}:${two(secs % 60)}';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'url': url,
        'title': title,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'speed': speed,
        'updatedAt': updatedAt,
        'local': local,
        if (referer != null) 'referer': referer,
      };

  static PlaybackRecord? fromJson(dynamic raw) {
    try {
      final m = Map<String, dynamic>.from(raw as Map);
      return PlaybackRecord(
        key: m['key'] as String? ?? '',
        url: m['url'] as String? ?? '',
        title: m['title'] as String? ?? '',
        positionMs: (m['positionMs'] as num?)?.toInt() ?? 0,
        durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
        speed: (m['speed'] as num?)?.toDouble() ?? 1.0,
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
        local: m['local'] as bool? ?? false,
        referer: m['referer'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 播放进度记忆：SharedPreferences 持久化，最多保留 50 条。
class PlaybackMemory {
  static const String kStorageKey = 'nerelict_playback_memory';

  /// 旧版键：首次读取时一次性搬到新键并删除旧键，避免换名后续播记录丢失。
  static const String kLegacyStorageKey = 'ma8_playback_memory';
  static bool _migrationDone = false;

  static Future<void> _migrate(SharedPreferences prefs) async {
    if (_migrationDone) return;
    _migrationDone = true;
    if (prefs.containsKey(kStorageKey)) return;
    final legacy = prefs.getString(kLegacyStorageKey);
    if (legacy == null) return;
    await prefs.setString(kStorageKey, legacy);
    await prefs.remove(kLegacyStorageKey);
  }

  Future<List<PlaybackRecord>> all() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _migrate(prefs);
      final raw = prefs.getString(kStorageKey);
      if (raw == null) return <PlaybackRecord>[];
      final list = (jsonDecode(raw) as List<dynamic>)
          .map(PlaybackRecord.fromJson)
          .whereType<PlaybackRecord>()
          .where((r) => r.key.isNotEmpty && r.url.isNotEmpty)
          .toList();
      list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return list;
    } catch (_) {
      return <PlaybackRecord>[];
    }
  }

  Future<PlaybackRecord?> get(String key) async {
    final items = await all();
    for (final r in items) {
      if (r.key == key) return r;
    }
    return null;
  }

  /// 最近一条可续播记录（下载页「继续观看」用）
  Future<PlaybackRecord?> latestResumable() async {
    final items = await all();
    for (final r in items) {
      if (r.resumable) return r;
    }
    return null;
  }

  Future<void> save(PlaybackRecord record) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final items = await all();
      items.removeWhere((r) => r.key == record.key);
      items.insert(0, record);
      if (items.length > 50) items.removeRange(50, items.length);
      await prefs.setString(
        kStorageKey,
        jsonEncode(items.map((r) => r.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<void> remove(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final items = await all();
      items.removeWhere((r) => r.key == key);
      await prefs.setString(
        kStorageKey,
        jsonEncode(items.map((r) => r.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kStorageKey);
      await prefs.remove(kLegacyStorageKey);
    } catch (_) {}
  }
}
