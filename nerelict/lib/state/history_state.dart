import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/history_item.dart';

/// 浏览历史：按访问时间倒序保存，持久化到 SharedPreferences。
class HistoryState extends ChangeNotifier {
  static const storageKey = 'browse_history_v1';
  static const maxItems = 200;

  final List<HistoryItem> _items = <HistoryItem>[];

  List<HistoryItem> get items => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _items
            ..clear()
            ..addAll(decoded.map(HistoryItem.fromJson).whereType<HistoryItem>());
          _sort();
        }
      }
    } catch (_) {
      // 读取失败按空历史处理，不影响启动
    }
    notifyListeners();
  }

  Future<void> add(String url, String title) async {
    final u = url.trim();
    if (!u.startsWith('http://') && !u.startsWith('https://')) return;
    // 同一地址只保留最近一次访问
    _items.removeWhere((e) => e.url == u);
    _items.insert(
      0,
      HistoryItem(url: u, title: title.trim(), visitedAt: DateTime.now()),
    );
    if (_items.length > maxItems) _items.removeRange(maxItems, _items.length);
    notifyListeners();
    await _persist();
  }

  /// 批量删除（历史页多选）：按 url 精确移除，其余记录顺序不变。
  Future<void> removeMany(Iterable<String> urls) async {
    final targets = urls.toSet();
    if (targets.isEmpty) return;
    final before = _items.length;
    _items.removeWhere((e) => targets.contains(e.url));
    if (_items.length == before) return;
    notifyListeners();
    await _persist();
  }

  /// 清空全部历史
  Future<void> clearAll() async {
    if (_items.isEmpty) return;
    _items.clear();
    notifyListeners();
    await _persist();
  }

  void _sort() =>
      _items.sort((a, b) => b.visitedAt.compareTo(a.visitedAt));

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        storageKey,
        jsonEncode(_items.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }
}
