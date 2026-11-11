import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/web_favorite.dart';

/// 网页收藏：顺序由列表本身决定，支持拖动排序 / 拖动归类，
/// 支持自定义分类、编辑标题地址，以及把条目放进首页「快速访问」。
///
/// 与播放器内的视频收藏（FavoritesStore）相互独立：
/// 这里是「网页书签」，条目是页面地址，不参与下载与播放状态。
class WebFavoritesState extends ChangeNotifier {
  static const String storageKey = 'web_favorites_v1';
  static const String categoryKey = 'web_favorites_categories_v1';
  static const int maxItems = 100;

  /// 「未分类」用空字符串表示，不作为可编辑的分类名
  static const String uncategorized = '';

  final List<WebFavorite> _items = <WebFavorite>[];
  final List<String> _categories = <String>[];

  List<WebFavorite> get items => List.unmodifiable(_items);

  /// 用户建立的分类（不含「未分类」）
  List<String> get categories => List.unmodifiable(_categories);

  bool get isEmpty => _items.isEmpty;
  int get length => _items.length;

  /// 首页快速访问：最多 8 个，按收藏列表顺序
  List<WebFavorite> get quickAccessItems =>
      _items.where((e) => e.quickAccess).take(8).toList(growable: false);

  /// 页面上需要展示的分组顺序：自定义分类 + 实际出现但不在列表里的分类 + 未分类
  List<String> get groupOrder {
    final result = <String>[..._categories];
    for (final item in _items) {
      final c = item.category.trim();
      if (c.isEmpty) continue;
      if (!result.contains(c)) result.add(c);
    }
    result.add(uncategorized);
    return result;
  }

  List<WebFavorite> itemsOf(String group) =>
      _items.where((e) => e.category.trim() == group.trim()).toList();

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _items
            ..clear()
            ..addAll(decoded.map(WebFavorite.fromJson).whereType<WebFavorite>());
          if (_items.length > maxItems) {
            _items.removeRange(maxItems, _items.length);
          }
        }
      }
      final cats = prefs.getStringList(categoryKey);
      if (cats != null) {
        _categories
          ..clear()
          ..addAll(cats.where((e) => e.trim().isNotEmpty));
      }
    } catch (_) {
      // 读取失败按空收藏处理，不影响启动
    }
    notifyListeners();
  }

  bool contains(String url) => _items.any((e) => e.url == url.trim());

  WebFavorite? find(String url) {
    final i = _items.indexWhere((e) => e.url == url.trim());
    return i < 0 ? null : _items[i];
  }

  /// 收藏 / 取消收藏，返回操作后是否处于已收藏状态。
  Future<bool> toggle({
    required String url,
    String title = '',
    String? iconUrl,
    String category = '',
  }) async {
    final u = url.trim();
    if (!u.startsWith('http://') && !u.startsWith('https://')) return false;
    final index = _items.indexWhere((e) => e.url == u);
    if (index >= 0) {
      _items.removeAt(index);
      notifyListeners();
      await _persist();
      return false;
    }
    _items.insert(
      0,
      WebFavorite(
        url: u,
        title: title.trim(),
        addedAt: DateTime.now().millisecondsSinceEpoch,
        category: category.trim(),
        iconUrl: iconUrl,
      ),
    );
    if (_items.length > maxItems) _items.removeLast();
    notifyListeners();
    await _persist();
    return true;
  }

  Future<void> remove(String url) async {
    final before = _items.length;
    _items.removeWhere((e) => e.url == url);
    if (_items.length == before) return;
    notifyListeners();
    await _persist();
  }

  /// 编辑：标题、地址、图标都可改。地址改成已存在的条目时合并（保留新标题）。
  Future<String?> updateItem({
    required String oldUrl,
    required String title,
    required String url,
    String? iconUrl,
  }) async {
    final index = _items.indexWhere((e) => e.url == oldUrl);
    if (index < 0) return '该收藏已不存在';
    final next = url.trim();
    if (!next.startsWith('http://') && !next.startsWith('https://')) {
      return '请填写 http/https 开头的地址';
    }
    final duplicate = _items.indexWhere((e) => e.url == next);
    if (duplicate >= 0 && duplicate != index) {
      return '该地址已在收藏中';
    }
    final item = _items[index];
    _items[index] = item.copyWith(
      url: next,
      title: title.trim(),
      iconUrl: (iconUrl == null || iconUrl.isEmpty) ? item.iconUrl : iconUrl,
    );
    notifyListeners();
    await _persist();
    return null;
  }

  /// 归类：把条目移入某个分类（空字符串 = 未分类）
  Future<void> moveToCategory(String url, String category) async {
    final index = _items.indexWhere((e) => e.url == url);
    if (index < 0) return;
    final target = category.trim();
    if (_items[index].category.trim() == target) return;
    _items[index] = _items[index].copyWith(category: target);
    notifyListeners();
    await _persist();
  }

  /// 拖动放置：可同时改分类与顺序（[beforeUrl] 为目标位置的前一条）。
  Future<void> dragTo({
    required String url,
    String? category,
    String? beforeUrl,
  }) async {
    final from = _items.indexWhere((e) => e.url == url);
    if (from < 0) return;
    if (beforeUrl == url) return;
    final item = _items.removeAt(from);
    final updated = category == null ? item : item.copyWith(category: category.trim());
    var index = beforeUrl == null
        ? _items.length
        : _items.indexWhere((e) => e.url == beforeUrl);
    if (index < 0) index = _items.length;
    _items.insert(index, updated);
    notifyListeners();
    await _persist();
  }

  Future<void> setQuickAccess(String url, bool value) async {
    final index = _items.indexWhere((e) => e.url == url);
    if (index < 0) return;
    if (_items[index].quickAccess == value) return;
    _items[index] = _items[index].copyWith(quickAccess: value);
    notifyListeners();
    await _persist();
  }

  Future<void> toggleQuickAccess(String url) async {
    final item = find(url);
    if (item == null) return;
    await setQuickAccess(url, !item.quickAccess);
  }

  /// 新建分类；重名时直接返回已存在的名字。
  Future<String> addCategory(String name) async {
    final n = name.trim();
    if (n.isEmpty) return '';
    if (_categories.contains(n)) return n;
    _categories.add(n);
    notifyListeners();
    await _persistCategories();
    return n;
  }

  Future<void> renameCategory(String oldName, String newName) async {
    final n = newName.trim();
    if (n.isEmpty || oldName == n) return;
    final i = _categories.indexOf(oldName);
    if (i >= 0) _categories[i] = n;
    for (var k = 0; k < _items.length; k++) {
      if (_items[k].category.trim() == oldName) {
        _items[k] = _items[k].copyWith(category: n);
      }
    }
    notifyListeners();
    await _persist();
    await _persistCategories();
  }

  /// 删除分类：条目回到「未分类」，不删除收藏本身。
  Future<void> removeCategory(String name) async {
    _categories.remove(name);
    for (var k = 0; k < _items.length; k++) {
      if (_items[k].category.trim() == name) {
        _items[k] = _items[k].copyWith(category: '');
      }
    }
    notifyListeners();
    await _persist();
    await _persistCategories();
  }

  /// ReorderableListView.onReorderItem 兼容接口：newIndex 已是移除旧项后的位置。
  Future<void> reorderAdjusted(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _items.length) return;
    final target = newIndex.clamp(0, _items.length - 1);
    if (target == oldIndex) return;
    final item = _items.removeAt(oldIndex);
    _items.insert(target, item);
    notifyListeners();
    await _persist();
  }

  Future<void> clear() async {
    if (_items.isEmpty) return;
    _items.clear();
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        storageKey,
        jsonEncode(_items.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<void> _persistCategories() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(categoryKey, _categories);
    } catch (_) {}
  }
}
