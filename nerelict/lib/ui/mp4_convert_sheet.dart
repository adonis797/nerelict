import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/download_task.dart' show ConversionState;
import '../state/app_state.dart';
import 'app_theme.dart';

/// 下载页的独立「MP4 转换」入口。
///
/// 与设置里的「下载完成后自动转换」互不影响：这里可以对下载目录里
/// 任何一个 TS 文件做转封装，支持多选与「转换后删除原 TS」。
Future<void> showMp4ConvertSheet(BuildContext context) {
  final state = context.read<AppState>();
  final p = paletteOf(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: p.surface,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const _Mp4Sheet(),
    ),
  );
}

class _Mp4Sheet extends StatefulWidget {
  const _Mp4Sheet();

  @override
  State<_Mp4Sheet> createState() => _Mp4SheetState();
}

class _Mp4SheetState extends State<_Mp4Sheet> {
  final Set<String> _selected = <String>{};
  final Map<String, String> _errors = <String, String>{};
  bool _deleteSource = true;
  bool _running = false;
  String? _current;
  int _doneCount = 0;

  static String _name(String path) => path.split(RegExp(r'[/\\]')).last;

  static String _size(int bytes) {
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

  /// 所有可转换的 TS：任务产物 + 下载目录里的 .ts（去重）
  List<({String path, int size})> _candidates(AppState state) {
    final map = <String, int>{};
    for (final task in state.tasks) {
      final path = task.filePath;
      if (path == null) continue;
      if (!path.toLowerCase().endsWith('.ts')) continue;
      if (task.conversion == ConversionState.converting) continue;
      map[path] = task.bytes;
    }
    for (final f in state.localFiles) {
      if (!f.path.toLowerCase().endsWith('.ts')) continue;
      map[f.path] = f.size;
    }
    final list = map.entries.map((e) => (path: e.key, size: e.value)).toList()
      ..sort((a, b) => _name(a.path).compareTo(_name(b.path)));
    return list;
  }

  Future<void> _run(AppState state, List<({String path, int size})> all) async {
    final targets = all.where((e) => _selected.contains(e.path)).toList();
    if (targets.isEmpty) return;
    setState(() {
      _running = true;
      _doneCount = 0;
      _errors.clear();
    });
    for (final item in targets) {
      if (!mounted) return;
      setState(() => _current = item.path);
      try {
        await state.convertLocalFile(item.path, deleteSource: _deleteSource);
        if (!mounted) return;
        setState(() => _doneCount++);
      } catch (e) {
        if (!mounted) return;
        final msg = e.toString().replaceFirst('Exception: ', '');
        setState(() {
          _errors[item.path] =
              msg.length > 90 ? '${msg.substring(0, 90)}…' : msg;
        });
      }
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _current = null;
      _selected.removeWhere((p) => !_errors.containsKey(p));
    });
    final failed = _errors.length;
    state.showToast(failed == 0
        ? '已转换 $_doneCount 个文件为 MP4'
        : '转换完成 $_doneCount 个，失败 $failed 个');
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final state = context.watch<AppState>();
    final all = _candidates(state);

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.78,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 2),
              child: Row(
                children: <Widget>[
                  Icon(Icons.movie_creation_outlined,
                      size: 18, color: p.accent),
                  const SizedBox(width: 8),
                  Text(
                    'MP4 转换',
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      color: p.text,
                    ),
                  ),
                  const Spacer(),
                  if (all.isNotEmpty && !_running)
                    TextButton(
                      onPressed: () => setState(() {
                        if (_selected.length == all.length) {
                          _selected.clear();
                        } else {
                          _selected.addAll(all.map((e) => e.path));
                        }
                      }),
                      child: Text(
                        _selected.length == all.length ? '取消全选' : '全选',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '无重编码转封装，仅支持 H.264 / HEVC + AAC 的 TS；'
                  '转换前会校验产物可解码，失败不会留下坏文件。',
                  style: TextStyle(fontSize: 11, color: p.textFaint, height: 1.45),
                ),
              ),
            ),
            if (all.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 30),
                child: Column(
                  children: <Widget>[
                    Icon(Icons.inbox_outlined, size: 40, color: p.textDisabled),
                    const SizedBox(height: 10),
                    Text('下载目录里没有需要转换的 TS 文件',
                        style: TextStyle(fontSize: 12.5, color: p.textFaint)),
                  ],
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  itemCount: all.length,
                  separatorBuilder: (_, __) => Divider(height: 1, color: p.border),
                  itemBuilder: (context, i) {
                    final item = all[i];
                    final selected = _selected.contains(item.path);
                    final error = _errors[item.path];
                    final running = _running && _current == item.path;
                    return ListTile(
                      dense: true,
                      enabled: !_running,
                      leading: Checkbox(
                        value: selected,
                        visualDensity: VisualDensity.compact,
                        onChanged: _running
                            ? null
                            : (_) => setState(() {
                                  if (!_selected.add(item.path)) {
                                    _selected.remove(item.path);
                                  }
                                }),
                      ),
                      title: Text(
                        _name(item.path),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: p.text),
                      ),
                      subtitle: Text(
                        error != null
                            ? '转换失败：$error'
                            : 'TS 视频 · ${_size(item.size)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: error != null ? kDanger : p.textFaint,
                        ),
                      ),
                      trailing: running
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : null,
                    );
                  },
                ),
              ),
            SwitchListTile(
              dense: true,
              value: _deleteSource,
              onChanged:
                  _running ? null : (v) => setState(() => _deleteSource = v),
              title: Text('转换后删除原 TS',
                  style: TextStyle(fontSize: 12.5, color: p.text)),
              subtitle: Text(
                '只保留 MP4，避免同一视频占两份空间',
                style: TextStyle(fontSize: 10.5, color: p.textFaint),
              ),
              secondary: Icon(Icons.delete_outline, size: 18, color: p.textFaint),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: (_running || _selected.isEmpty)
                      ? null
                      : () => _run(state, all),
                  icon: _running
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.autorenew, size: 18),
                  label: Text(
                    _running
                        ? '正在转换 ${_doneCount + 1}/${_selected.length}'
                        : '开始转换（${_selected.length}）',
                    style: const TextStyle(fontSize: 13),
                  ),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 11),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
