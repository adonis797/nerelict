import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/player_request.dart' show PlayerMode;
import '../services/file_manager.dart';
import '../state/app_state.dart';
import 'app_theme.dart';

/// 下载页的文件管理面板：查看信息 / 重命名 / 删除。
///
/// 所有写操作都走 AppState 的统一方法，保证任务引用、播放进度、收藏与
/// 本地视频列表一起更新；面板自身也在操作后重新读取磁盘元信息。
Future<void> showFileManagerSheet(
  BuildContext context, {
  required List<String> paths,
  required VoidCallback onChanged,
}) async {
  final state = context.read<AppState>();
  final p = paletteOf(context);

  // 播放器浮层始终置顶，会盖住底部弹窗：临时收成迷你小窗，不打断播放。
  final previousMode = state.playerMode;
  final hasPlayer = state.player != null;
  if (hasPlayer) state.setPlayerMode(PlayerMode.mini);

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: p.surface,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => _FileManagerSheet(
      paths: paths.toSet().toList(),
      onChanged: onChanged,
    ),
  );

  if (hasPlayer && state.player != null) {
    state.setPlayerMode(previousMode);
  }
}

class _FileManagerSheet extends StatefulWidget {
  const _FileManagerSheet({required this.paths, required this.onChanged});

  final List<String> paths;
  final VoidCallback onChanged;

  @override
  State<_FileManagerSheet> createState() => _FileManagerSheetState();
}

class _FileManagerSheetState extends State<_FileManagerSheet> {
  late List<String> _paths;
  List<ManagedFile> _files = <ManagedFile>[];
  bool _loading = true;
  String? _message;

  bool _selecting = false;
  final Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    _paths = List<String>.of(widget.paths);
    _reload();
  }

  Future<void> _reload() async {
    final list = <ManagedFile>[];
    for (final path in _paths) {
      final file = await FileManager.inspect(path);
      if (file != null) list.add(file);
    }
    if (!mounted) return;
    setState(() {
      _files = list;
      _loading = false;
      // 已删除 / 改名的条目不能继续留在选择集合里
      _selected.removeWhere(
          (p) => !list.any((f) => f.path == p));
      if (_files.isEmpty) {
        _selecting = false;
        _selected.clear();
      }
    });
  }

  void _exitSelection() {
    if (!mounted) return;
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggleSelect(String path) {
    setState(() {
      if (!_selected.add(path)) _selected.remove(path);
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selected.length == _files.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_files.map((e) => e.path));
      }
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
            title: Text('批量删除',
                style: TextStyle(fontSize: 16, color: p.text)),
            content: Text(
              '确定删除已选的 $count 个文件吗？\n'
              '仅关联这些文件的下载任务会一并移除，导出的副本不受影响。',
              style: TextStyle(fontSize: 12.5, color: p.textSub, height: 1.5),
            ),
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
    final targets = _selected.toList();
    try {
      await _state.deleteDownloadedFiles(targets);
      _paths.removeWhere(targets.contains);
      widget.onChanged();
      _selected.clear();
      _selecting = false;
      await _reload();
      _flash('已删除 $count 个文件，任务与列表状态已同步');
    } on FileManagerException catch (e) {
      _flash(e.message);
      await _reload();
    } catch (e) {
      _flash('批量删除失败：$e');
      await _reload();
    }
  }

  void _flash(String text) {
    if (!mounted) return;
    setState(() => _message = text);
  }

  AppState get _state => context.read<AppState>();

  Future<void> _info(ManagedFile file) async {
    final p = paletteOf(context);
    final linked = _state.tasks
        .where((t) => t.filePath == file.path || t.mp4Path == file.path)
        .length;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface,
        title: Text('文件信息', style: TextStyle(fontSize: 16, color: p.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _InfoLine('名称', file.name, p),
            _InfoLine('类型', file.typeLabel, p),
            _InfoLine('大小', file.sizeText, p),
            _InfoLine('修改时间', file.dateText, p),
            _InfoLine('播放', file.isPlayable ? '可由 MA8N播放' : '不支持直接播放', p),
            _InfoLine('关联任务', linked > 0 ? '$linked 个' : '无（独立文件）', p),
          ],
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(ManagedFile file) async {
    final p = paletteOf(context);
    final dot = file.name.lastIndexOf('.');
    final initial = dot > 0 ? file.name.substring(0, dot) : file.name;
    final ctrl = TextEditingController(text: initial);
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface,
        title: Text('重命名文件', style: TextStyle(fontSize: 16, color: p.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('扩展名 ${file.extension.isEmpty ? '（无）' : file.extension} 会自动保留，避免播放失效',
                style: TextStyle(fontSize: 11, color: p.textFaint)),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              autofocus: true,
              style: TextStyle(fontSize: 13, color: p.text),
              decoration: const InputDecoration(isDense: true),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消', style: TextStyle(color: p.textFaint)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final value = input?.trim() ?? '';
    ctrl.dispose();
    if (value.isEmpty || !mounted) return;
    try {
      final next = await _state.renameDownloadedFile(file.path, value);
      final index = _paths.indexOf(file.path);
      if (index >= 0) _paths[index] = next;
      widget.onChanged();
      await _reload();
      _flash('已重命名，任务与列表状态已同步');
    } on FileManagerException catch (e) {
      _flash(e.message);
    } catch (e) {
      _flash('重命名失败：$e');
    }
  }

  Future<void> _delete(ManagedFile file) async {
    final p = paletteOf(context);
    final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: p.surface,
            title: Text('删除文件', style: TextStyle(fontSize: 16, color: p.text)),
            content: Text(
              '确定删除「${file.name}」吗？\n'
              '仅关联该文件的下载任务会一并移除，导出的副本不受影响。',
              style: TextStyle(fontSize: 12.5, color: p.textSub, height: 1.5),
            ),
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
    if (!confirm || !mounted) return;
    try {
      await _state.deleteDownloadedFile(file.path);
      _paths.remove(file.path);
      widget.onChanged();
      await _reload();
      _flash('已删除，列表与任务状态已同步');
    } on FileManagerException catch (e) {
      _flash(e.message);
    } catch (e) {
      _flash('删除失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.72,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.folder_open_outlined,
                        size: 18, color: kAccent),
                    const SizedBox(width: 8),
                    Text(
                      '文件管理 · ${_files.length}',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                      ),
                    ),
                    const Spacer(),
                    if (_files.isNotEmpty)
                      TextButton(
                        onPressed: () {
                          if (_selecting) {
                            _exitSelection();
                          } else {
                            setState(() => _selecting = true);
                          }
                        },
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          _selecting ? '取消' : '多选',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
              if (_message != null)
                Container(
                  width: double.infinity,
                  color: kAccent.withValues(alpha: 0.12),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 7),
                  child: Text(
                    _message!,
                    style: const TextStyle(fontSize: 11.5, color: kAccent),
                  ),
                ),
              Divider(height: 1, color: p.border),
              Flexible(
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : _files.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              '没有可管理的文件',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12.5, color: p.textFaint),
                            ),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            padding: const EdgeInsets.only(bottom: 20),
                            itemCount: _files.length,
                            separatorBuilder: (_, __) =>
                                Divider(height: 1, color: p.border),
                            itemBuilder: (_, i) => _row(_files[i], p),
                          ),
              ),
              if (_selecting)
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: p.border)),
                  ),
                  child: Row(
                    children: <Widget>[
                      Text(
                        '已选 ${_selected.length} 项',
                        style: TextStyle(fontSize: 12, color: p.textSub),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _toggleSelectAll,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          _selected.length == _files.length ? '取消全选' : '全选',
                          style: TextStyle(fontSize: 12, color: p.textFaint),
                        ),
                      ),
                      FilledButton.icon(
                        onPressed:
                            _selected.isEmpty ? null : _deleteSelected,
                        icon: const Icon(Icons.delete_outline, size: 16),
                        label: const Text('删除',
                            style: TextStyle(fontSize: 12)),
                        style: FilledButton.styleFrom(
                          backgroundColor: kDanger,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(ManagedFile file, AppPalette p) {
    final checked = _selected.contains(file.path);
    return ListTile(
      dense: true,
      selected: _selecting && checked,
      selectedTileColor: kAccent.withValues(alpha: 0.08),
      contentPadding: EdgeInsets.fromLTRB(_selecting ? 4 : 16, 6, 8, 6),
      leading: _selecting
          ? Checkbox(
              value: checked,
              onChanged: (_) => _toggleSelect(file.path),
              visualDensity: VisualDensity.compact,
            )
          : Icon(
              file.isPlayable
                  ? Icons.video_file_outlined
                  : Icons.insert_drive_file_outlined,
              size: 21,
              color: kAccent,
            ),
      title: Text(
        file.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 13, color: p.text),
      ),
      subtitle: Text(
        '${file.typeLabel} · ${file.sizeText} · ${file.dateText}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 10.5, color: p.textFaint),
      ),
      trailing: _selecting
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '查看文件信息',
                  icon: Icon(Icons.info_outline, size: 18, color: p.textSub),
                  onPressed: () => _info(file),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '重命名',
                  icon: Icon(Icons.drive_file_rename_outline,
                      size: 18, color: p.textSub),
                  onPressed: () => _rename(file),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '删除文件',
                  icon:
                      const Icon(Icons.delete_outline, size: 18, color: kDanger),
                  onPressed: () => _delete(file),
                ),
              ],
            ),
      onTap: _selecting ? () => _toggleSelect(file.path) : null,
      onLongPress: _selecting
          ? null
          : () {
              setState(() {
                _selecting = true;
                _selected.add(file.path);
              });
            },
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine(this.label, this.value, this.p);

  final String label;
  final String value;
  final AppPalette p;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 68,
              child: Text(label,
                  style: TextStyle(fontSize: 12, color: p.textFaint)),
            ),
            Expanded(
              child: Text(value,
                  style: TextStyle(fontSize: 12.5, color: p.text)),
            ),
          ],
        ),
      );
}
