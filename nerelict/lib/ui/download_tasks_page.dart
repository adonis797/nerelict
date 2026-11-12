import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/download_task.dart';
import '../state/app_state.dart';
import 'app_theme.dart';
import 'file_manager_sheet.dart';

/// 「下载」分支：队列、暂停/继续、失败重试与已完成记录都在这里。
///
/// 从「文件」页顶部菜单进入；文件列表只展示下载目录，本页只管理任务，
/// 两者分开后，已完成的文件不会再被任务卡片“藏起来”。
class DownloadTasksPage extends StatelessWidget {
  const DownloadTasksPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final p = paletteOf(context);
    final tasks = state.tasks;
    final running = tasks.where((t) => !t.status.isFinished).toList();
    final finished = tasks.where((t) => t.status.isFinished).toList();

    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        title: const Text('下载', style: TextStyle(fontSize: 17)),
        actions: <Widget>[
          if (state.pausedCount > 0)
            IconButton(
              tooltip: '全部继续（${state.pausedCount} 个已暂停）',
              icon: const Icon(Icons.play_circle_outline, size: 20),
              onPressed: state.resumeAllPaused,
            ),
          if (finished.isNotEmpty)
            IconButton(
              tooltip: '清除已完成',
              icon: const Icon(Icons.cleaning_services_outlined, size: 20),
              onPressed: () {
                final count = finished.length;
                state.clearFinished();
                state.showToast('已清除 $count 个已结束任务，文件仍保留在「文件」页');
              },
            ),
          // 扫把仍是「清除已完成」；残留分片清理放这里，避免两个扫把混淆
          PopupMenuButton<String>(
            tooltip: '更多操作',
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (value) async {
              if (value != 'cleanup') return;
              final result = await state.cleanupStaleParts();
              if (!context.mounted) return;
              if (result.dirs == 0) {
                state.showToast('没有需要清理的临时分片');
              } else {
                final mb = result.bytes / (1024 * 1024);
                state.showToast(
                  '已清理 ${result.dirs} 个残留目录，释放 ${mb.toStringAsFixed(1)} MB',
                );
              }
            },
            itemBuilder: (context) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'cleanup',
                child: Text('清理残留临时分片'),
              ),
            ],
          ),
        ],
      ),
      body: tasks.isEmpty
          ? _DownloadEmpty(
              p: p,
              onBrowse: () {
                Navigator.of(context).pop();
                state.setTab(0);
              },
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
              children: <Widget>[
                if (running.isNotEmpty) ...<Widget>[
                  _SectionLabel(
                    p: p,
                    icon: Icons.downloading,
                    text: '进行中 · ${running.length}',
                  ),
                  for (final task in running)
                    _TaskCard(
                      task: task,
                      state: state,
                      onFilesChanged: state.refreshLocalFiles,
                    ),
                ],
                if (finished.isNotEmpty) ...<Widget>[
                  _SectionLabel(
                    p: p,
                    icon: Icons.check_circle_outline,
                    text: '已结束 · ${finished.length}',
                  ),
                  for (final task in finished)
                    _TaskCard(
                      task: task,
                      state: state,
                      onFilesChanged: state.refreshLocalFiles,
                    ),
                ],
              ],
            ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({
    required this.p,
    required this.icon,
    required this.text,
  });

  final AppPalette p;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 15, color: p.accent),
          const SizedBox(width: 7),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: p.textFaint,
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadEmpty extends StatelessWidget {
  const _DownloadEmpty({required this.p, required this.onBrowse});

  final AppPalette p;
  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.cloud_download_outlined, size: 54, color: p.textDisabled),
          const SizedBox(height: 14),
          Text('还没有下载任务', style: TextStyle(color: p.textFaint)),
          const SizedBox(height: 6),
          Text(
            '在「浏览器」里播放视频后点「下载当前视频」\n完成后文件会出现在「文件」页',
            textAlign: TextAlign.center,
            style: TextStyle(color: p.textFaint, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: onBrowse,
            icon: const Icon(Icons.travel_explore, size: 17),
            label: const Text('去浏览器嗅探'),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.task,
    required this.state,
    required this.onFilesChanged,
  });

  final DownloadTask task;
  final AppState state;
  final VoidCallback onFilesChanged;

  Color get _statusColor => switch (task.status) {
        TaskStatus.done => kSuccess,
        TaskStatus.failed => kDanger,
        TaskStatus.canceled => Colors.grey,
        TaskStatus.paused => Colors.orangeAccent,
        _ => kAccent,
      };

  @override
  Widget build(BuildContext context) {
    final active = task.status.isActive;
    final paused = task.status == TaskStatus.paused;
    final done = task.status == TaskStatus.done;
    final p = paletteOf(context);

    // 转换入口始终可用（设置里的开关只决定「下载完成后自动转换」）
    final showConvert = task.canConvert;

    final playable = task.playablePath;

    final card = Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.border),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  task.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _statusColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  task.status.label,
                  style: TextStyle(fontSize: 11, color: _statusColor),
                ),
              ),
              if (task.filePath != null || task.mp4Path != null)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '文件信息 / 重命名 / 删除',
                  icon: Icon(Icons.folder_open_outlined,
                      size: 18, color: p.textFaint),
                  onPressed: () => showFileManagerSheet(
                    context,
                    paths: <String>[
                      if (task.filePath != null) task.filePath!,
                      if (task.mp4Path != null) task.mp4Path!,
                    ],
                    onChanged: onFilesChanged,
                  ),
                ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '删除任务',
                icon: Icon(Icons.delete_outline, size: 18, color: p.textFaint),
                onPressed: () => state.removeTask(task),
              ),
            ],
          ),
          if (active || paused || done) ...[
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: done ? 1 : task.progress,
                minHeight: 5,
                backgroundColor: p.progressTrack,
                valueColor: AlwaysStoppedAnimation(
                  done ? _statusColor : kAccent,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  task.progressText,
                  style: TextStyle(fontSize: 11, color: p.textFaint),
                ),
                const Spacer(),
                if (task.isLive)
                  Text(
                    '直播片段 · 可能不完整',
                    style: TextStyle(fontSize: 10.5, color: kAccent),
                  ),
                if (task.isLive && task.variant != null)
                  const SizedBox(width: 8),
                if (task.variant != null)
                  Text(
                    task.variant!,
                    style: TextStyle(fontSize: 11, color: p.textFaint),
                  ),
              ],
            ),
          ],
          if (task.status == TaskStatus.failed && task.error != null) ...[
            const SizedBox(height: 6),
            Text(
              task.error!,
              style: const TextStyle(fontSize: 11.5, color: kDanger),
            ),
          ],
          if (done && playable != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    task.exported ? '已保存 · 已同步到所选位置' : '已保存',
                    style: TextStyle(fontSize: 11, color: p.textFaint),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => showFileManagerSheet(
                    context,
                    paths: <String>[
                      if (task.filePath != null) task.filePath!,
                      if (task.mp4Path != null) task.mp4Path!,
                    ],
                    onChanged: onFilesChanged,
                  ),
                  icon: const Icon(Icons.folder_open_outlined, size: 16),
                  label: const Text('文件'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                TextButton.icon(
                  onPressed: () => state.openPlayer(
                    url: playable,
                    title: task.title,
                    local: true,
                  ),
                  icon: const Icon(Icons.play_circle_outline, size: 17),
                  label: const Text('Nerelict 播放'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ],
          if (showConvert) ...[
            const SizedBox(height: 6),
            if (task.conversion == ConversionState.converting)
              Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '正在转换为 MP4…',
                    style: TextStyle(fontSize: 11.5, color: p.textSub),
                  ),
                ],
              )
            else if (task.conversion == ConversionState.done &&
                task.mp4Path != null)
              Text(
                '转换完成 · ${task.mp4Info ?? '可用 Nerelict 播放'}',
                style: const TextStyle(fontSize: 11, color: kSuccess),
              )
            else ...[
              if (task.conversion == ConversionState.failed &&
                  task.conversionError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '转换失败：${task.conversionError}',
                    style: const TextStyle(fontSize: 11, color: kDanger),
                  ),
                ),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: () => state.convertToMp4(task),
                  icon: const Icon(Icons.movie_creation_outlined, size: 18),
                  label: Text(
                    task.conversion == ConversionState.failed
                        ? '重试转换为 MP4'
                        : '一键转换为 MP4',
                  ),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ],
          ],
          if (active || paused) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                if (active)
                  OutlinedButton.icon(
                    onPressed: () => state.pauseTask(task),
                    icon: const Icon(Icons.pause_circle_outline, size: 17),
                    label: const Text('暂停'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                  ),
                if (paused)
                  FilledButton.tonalIcon(
                    onPressed: () => state.resumeTask(task),
                    icon: const Icon(Icons.play_arrow, size: 17),
                    label: const Text('继续下载'),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                  ),
                const Spacer(),
                Text(
                  paused ? '进度已保留' : '仅影响此任务',
                  style: TextStyle(fontSize: 10.5, color: p.textDisabled),
                ),
              ],
            ),
          ],
        ],
      ),
    );

    final canToggle = task.status.isActive || task.status == TaskStatus.paused;
    return Dismissible(
      key: ValueKey<String>('download_task_${task.id}'),
      direction: DismissDirection.horizontal,
      background: _SwipeHint(
        alignment: Alignment.centerLeft,
        color: canToggle ? kAccent : p.textDisabled,
        icon: paused ? Icons.play_arrow : Icons.pause,
        label: paused ? '继续' : '暂停',
      ),
      secondaryBackground: _SwipeHint(
        alignment: Alignment.centerRight,
        color: kDanger,
        icon: Icons.delete_outline,
        label: '删除',
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          // 右滑只做暂停/继续，不真正移除，松手后卡片回弹。
          // 暂停请求尚未收敛时也算「已暂停」，否则连滑两下会重复暂停。
          if (task.pauseRequested || task.status == TaskStatus.paused) {
            state.resumeTask(task);
          } else if (task.status.isActive) {
            state.pauseTask(task);
          } else {
            state.showToast('该任务已结束，左滑可删除');
          }
          return false;
        }
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: p.surface,
            title: Text('删除任务', style: TextStyle(fontSize: 16, color: p.text)),
            content: Text(
              '「${task.title}」将从列表移除，已下载的文件保留在下载目录。',
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
        );
        return ok ?? false;
      },
      onDismissed: (_) => state.removeTask(task),
      child: card,
    );
  }
}

/// 左滑删除 / 右滑暂停时的底层色块提示。
class _SwipeHint extends StatelessWidget {
  const _SwipeHint({
    required this.alignment,
    required this.color,
    required this.icon,
    required this.label,
  });

  final Alignment alignment;
  final Color color;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      alignment: alignment,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 19, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
