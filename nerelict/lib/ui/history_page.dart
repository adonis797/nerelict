import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/history_item.dart';
import '../state/app_state.dart';
import '../state/history_state.dart';
import 'app_theme.dart';

/// 时间排序：默认最新在前，可切换为最早在前。
enum _HistorySort { newest, oldest }

/// 日期筛选范围。
enum _DateRange { all, today, week, month, custom }

/// 独立的单页浏览历史「全部历史」。
///
/// 点条目把地址返回给浏览器页打开；右上角多选后支持逐条勾选、
/// 全选与批量删除。列表支持按时间正/倒序排列，并可按日期筛选。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  bool _selecting = false;
  final Set<String> _selected = <String>{};

  _HistorySort _sort = _HistorySort.newest;
  _DateRange _range = _DateRange.all;
  DateTime? _customDate;

  static String _hm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  static String _time(DateTime t) {
    final now = DateTime.now();
    if (_sameDay(t, now)) return '今天 ${_hm(t)}';
    if (_sameDay(t, now.subtract(const Duration(days: 1)))) {
      return '昨天 ${_hm(t)}';
    }
    if (now.year == t.year) {
      return '${t.month.toString().padLeft(2, '0')}-'
          '${t.day.toString().padLeft(2, '0')} ${_hm(t)}';
    }
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')} ${_hm(t)}';
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _dayLabel(DateTime day) {
    final now = DateTime.now();
    if (_sameDay(day, now)) return '今天';
    if (_sameDay(day, now.subtract(const Duration(days: 1)))) return '昨天';
    if (day.year == now.year) {
      return '${day.month.toString().padLeft(2, '0')} 月 '
          '${day.day.toString().padLeft(2, '0')} 日';
    }
    return '${day.year}-${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
  }

  bool _inRange(DateTime t) {
    final now = DateTime.now();
    switch (_range) {
      case _DateRange.all:
        return true;
      case _DateRange.today:
        return _sameDay(t, now);
      case _DateRange.week:
        return now.difference(t).inDays < 7 && !t.isAfter(now);
      case _DateRange.month:
        return now.difference(t).inDays < 30 && !t.isAfter(now);
      case _DateRange.custom:
        final day = _customDate;
        return day != null && _sameDay(t, day);
    }
  }

  String get _rangeLabel => switch (_range) {
        _DateRange.all => '全部时间',
        _DateRange.today => '今天',
        _DateRange.week => '近 7 天',
        _DateRange.month => '近 30 天',
        _DateRange.custom => _customDate == null
            ? '选择日期'
            : '${_customDate!.year}-'
                '${_customDate!.month.toString().padLeft(2, '0')}-'
                '${_customDate!.day.toString().padLeft(2, '0')}',
      };

  List<HistoryItem> _visible(List<HistoryItem> items) {
    final list = items.where((e) => _inRange(e.visitedAt)).toList();
    list.sort((a, b) => _sort == _HistorySort.newest
        ? b.visitedAt.compareTo(a.visitedAt)
        : a.visitedAt.compareTo(b.visitedAt));
    return list;
  }

  void _exitSelection() {
    if (!mounted) return;
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggle(String url) {
    setState(() {
      if (!_selected.add(url)) _selected.remove(url);
    });
  }

  void _toggleSelectAll(List<HistoryItem> items) {
    setState(() {
      if (_selected.length == items.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(items.map((e) => e.url));
      }
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _customDate ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
      helpText: '按日期筛选浏览历史',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _customDate = picked;
      _range = _DateRange.custom;
      _selected.clear();
    });
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final p = paletteOf(context);
    final count = _selected.length;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: p.surface,
            title: Text('删除历史记录',
                style: TextStyle(fontSize: 16, color: p.text)),
            content: Text('确定删除已选的 $count 条浏览历史吗？',
                style: TextStyle(fontSize: 12.5, color: p.textSub)),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text('取消', style: TextStyle(color: p.textFaint)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: kDanger),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    await context.read<HistoryState>().removeMany(_selected.toList());
    if (!mounted) return;
    _exitSelection();
    context.read<AppState>().showToast('已删除 $count 条浏览历史');
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final history = context.watch<HistoryState>();
    final List<HistoryItem> all = history.items;
    final List<HistoryItem> items = _visible(all);

    // 记录被删光后自动退出多选，避免留下空的选择栏
    if (_selecting && items.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _exitSelection());
    }

    // 扁平化成「日期分组头 + 条目」，便于 ListView 惰性构建
    final rows = <_Row>[];
    String? lastDay;
    for (final item in items) {
      final key = '${item.visitedAt.year}-${item.visitedAt.month}-${item.visitedAt.day}';
      if (key != lastDay) {
        rows.add(_Row.header(item.visitedAt));
        lastDay = key;
      }
      rows.add(_Row.item(item));
    }

    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        title: Text('全部历史${all.isEmpty ? '' : ' · ${all.length}'}',
            style: const TextStyle(fontSize: 17)),
        actions: <Widget>[
          if (items.isNotEmpty && _selecting) ...[
            IconButton(
              tooltip: _selected.length == items.length ? '取消全选' : '全选',
              icon: Icon(
                _selected.length == items.length
                    ? Icons.deselect
                    : Icons.select_all,
                size: 20,
              ),
              onPressed: () => _toggleSelectAll(items),
            ),
            IconButton(
              tooltip: '删除所选',
              icon: const Icon(Icons.delete_outline, size: 20),
              color: _selected.isEmpty ? p.textDisabled : kDanger,
              onPressed: _selected.isEmpty ? null : _deleteSelected,
            ),
          ] else if (all.isNotEmpty) ...[
            IconButton(
              tooltip: _sort == _HistorySort.newest ? '当前：最新在前' : '当前：最早在前',
              icon: Icon(
                _sort == _HistorySort.newest
                    ? Icons.sort_outlined
                    : Icons.sort,
                size: 20,
              ),
              onPressed: () => setState(() {
                _sort = _sort == _HistorySort.newest
                    ? _HistorySort.oldest
                    : _HistorySort.newest;
              }),
            ),
            IconButton(
              tooltip: '多选',
              icon: const Icon(Icons.checklist, size: 20),
              onPressed: () => setState(() => _selecting = true),
            ),
          ],
        ],
      ),
      body: Column(
        children: <Widget>[
          if (all.isNotEmpty) _buildFilterBar(p, items.length),
          Expanded(
            child: items.isEmpty
                ? _EmptyHistory(p: p, filtered: all.isNotEmpty)
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final row = rows[i];
                      final day = row.day;
                      if (day != null) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
                          child: Row(
                            children: <Widget>[
                              Icon(Icons.event_outlined,
                                  size: 13, color: p.accent),
                              const SizedBox(width: 6),
                              Text(
                                _dayLabel(day),
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: p.textFaint,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Divider(height: 1, color: p.border),
                              ),
                            ],
                          ),
                        );
                      }
                      final item = row.item!;
                      final checked = _selected.contains(item.url);
                      return ListTile(
                        dense: true,
                        selected: _selecting && checked,
                        selectedTileColor: kAccent.withValues(alpha: 0.08),
                        leading: _selecting
                            ? Checkbox(
                                value: checked,
                                onChanged: (_) => _toggle(item.url),
                                visualDensity: VisualDensity.compact,
                              )
                            : Icon(Icons.history, size: 18, color: p.textFaint),
                        title: Text(
                          item.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13.5, color: p.text),
                        ),
                        subtitle: Text(
                          '${item.displayHost} · ${_time(item.visitedAt)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: p.textFaint),
                        ),
                        trailing: _selecting
                            ? null
                            : Icon(Icons.chevron_right,
                                size: 17, color: p.textDisabled),
                        onTap: () {
                          if (_selecting) {
                            _toggle(item.url);
                          } else {
                            Navigator.of(context).pop(item.url);
                          }
                        },
                        onLongPress: () {
                          if (_selecting) {
                            _toggle(item.url);
                          } else {
                            setState(() {
                              _selecting = true;
                              _selected.add(item.url);
                            });
                          }
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: _selecting
          ? SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                decoration: BoxDecoration(
                  color: p.surface,
                  border: Border(top: BorderSide(color: p.border)),
                ),
                child: Row(
                  children: <Widget>[
                    Text(
                      '已选 ${_selected.length} 项',
                      style: TextStyle(fontSize: 12.5, color: p.textSub),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _exitSelection,
                      child: Text('取消',
                          style: TextStyle(color: p.textFaint)),
                    ),
                    FilledButton.icon(
                      onPressed: _selected.isEmpty ? null : _deleteSelected,
                      icon: const Icon(Icons.delete_outline, size: 17),
                      label: const Text('删除所选',
                          style: TextStyle(fontSize: 12.5)),
                      style: FilledButton.styleFrom(
                        backgroundColor: kDanger,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildFilterBar(AppPalette p, int count) {
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: <Widget>[
          _chip(p, '全部', _range == _DateRange.all,
              () => setState(() => _range = _DateRange.all)),
          _chip(p, '今天', _range == _DateRange.today,
              () => setState(() => _range = _DateRange.today)),
          _chip(p, '近 7 天', _range == _DateRange.week,
              () => setState(() => _range = _DateRange.week)),
          _chip(p, '近 30 天', _range == _DateRange.month,
              () => setState(() => _range = _DateRange.month)),
          _chip(
            p,
            _range == _DateRange.custom ? _rangeLabel : '选择日期',
            _range == _DateRange.custom,
            _pickDate,
            icon: Icons.calendar_today_outlined,
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 8),
            child: Text(
              '$count 条',
              style: TextStyle(fontSize: 10.5, color: p.textDisabled),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(
    AppPalette p,
    String label,
    bool active,
    VoidCallback onTap, {
    IconData? icon,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 7),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 7),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            color: active ? p.accent.withValues(alpha: 0.16) : p.surface,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: active ? p.accent.withValues(alpha: 0.55) : p.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...[
                Icon(icon,
                    size: 12, color: active ? p.accent : p.textFaint),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? p.accent : p.textSub,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 列表行：日期分组头或一条历史
class _Row {
  _Row.header(this.day) : item = null;
  _Row.item(this.item) : day = null;

  final DateTime? day;
  final HistoryItem? item;
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory({required this.p, required this.filtered});

  final AppPalette p;
  final bool filtered;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(filtered ? Icons.filter_alt_off_outlined : Icons.history,
              size: 52, color: p.textDisabled),
          const SizedBox(height: 12),
          Text(
            filtered ? '该时间范围内没有浏览记录' : '还没有浏览记录',
            style: TextStyle(color: p.textFaint, fontSize: 13),
          ),
          if (filtered) ...[
            const SizedBox(height: 6),
            Text('切换上方「全部」查看所有历史',
                style: TextStyle(fontSize: 11, color: p.textDisabled)),
          ],
        ],
      ),
    );
  }
}
