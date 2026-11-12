import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 播放器内「收藏」的一条记录。
class FavoriteItem {
  const FavoriteItem({
    required this.url,
    required this.title,
    required this.addedAt,
    required this.local,
    this.referer,
  });

  final String url;
  final String title;
  final int addedAt;
  final bool local;
  final String? referer;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'title': title,
        'addedAt': addedAt,
        'local': local,
        if (referer != null) 'referer': referer,
      };

  static FavoriteItem? fromJson(dynamic raw) {
    try {
      final m = Map<String, dynamic>.from(raw as Map);
      return FavoriteItem(
        url: m['url'] as String? ?? '',
        title: m['title'] as String? ?? '',
        addedAt: (m['addedAt'] as num?)?.toInt() ?? 0,
        local: m['local'] as bool? ?? false,
        referer: m['referer'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 收藏只在 Nerelict 内读写，不改动首页 / 下载页 / 历史页的既有布局。
class FavoritesStore {
  static const String kStorageKey = 'nerelict_player_favorites';

  /// 旧版键：首次读取时一次性搬到新键并删除旧键，避免换名后收藏丢失。
  static const String kLegacyStorageKey = 'ma8_player_favorites';
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

  Future<List<FavoriteItem>> all() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _migrate(prefs);
      final raw = prefs.getString(kStorageKey);
      if (raw == null) return <FavoriteItem>[];
      final items = (jsonDecode(raw) as List<dynamic>)
          .map(FavoriteItem.fromJson)
          .whereType<FavoriteItem>()
          .where((e) => e.url.isNotEmpty)
          .toList();
      items.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      return items;
    } catch (_) {
      return <FavoriteItem>[];
    }
  }

  Future<bool> contains(String url) async =>
      (await all()).any((e) => e.url == url);

  Future<void> _write(List<FavoriteItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      kStorageKey,
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }

  /// 文件被删除时清掉指向它的收藏，避免留下打不开的条目。
  Future<void> removeUrl(String url) async {
    try {
      final items = await all();
      items.removeWhere((e) => e.url == url);
      await _write(items);
    } catch (_) {}
  }

  /// 文件重命名时同步更新收藏地址与标题。
  Future<void> retarget(String oldUrl, String newUrl, String newTitle) async {
    try {
      final items = await all();
      var changed = false;
      for (var i = 0; i < items.length; i++) {
        if (items[i].url != oldUrl) continue;
        items[i] = FavoriteItem(
          url: newUrl,
          title: newTitle,
          addedAt: items[i].addedAt,
          local: items[i].local,
          referer: items[i].referer,
        );
        changed = true;
      }
      if (changed) await _write(items);
    } catch (_) {}
  }

  Future<void> toggle(FavoriteItem item) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final items = await all();
      final index = items.indexWhere((e) => e.url == item.url);
      if (index >= 0) {
        items.removeAt(index);
      } else {
        items.insert(0, item);
      }
      if (items.length > 100) items.removeRange(100, items.length);
      await prefs.setString(
        kStorageKey,
        jsonEncode(items.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }
}
