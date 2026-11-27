import 'package:flutter/material.dart';

import '../services/hls_downloader.dart' show isDirectMediaUrl;
import '../services/hls_parser.dart';
import '../state/app_state.dart';
import 'app_theme.dart';

/// 下载前选择清晰度。
///
/// 旧行为是「主播放列表一律取带宽最高的一档」，遇到站点把 4K 放在最高档、
/// 或者音轨被拆成独立流时，用户拿到的不是想要的那一份，而且没有任何选择权。
/// 这里在入队前探测一次主播放列表：有多档就让他选，只有一档或不是主列表
/// 就照旧直接下载，不额外打扰。
Future<void> startDownloadWithChoice(
  BuildContext context,
  AppState state, {
  required String url,
  required String title,
  String? referer,
  List<String>? segments,
  Map<String, String> headers = const <String, String>{},
  String doneHint = '已加入下载队列',
}) async {
  // 分片组已经把内容定死了，直链也没有码率可选，两者都不该弹选择
  final uri = Uri.tryParse(url);
  final preselected = segments != null && segments.isNotEmpty;
  if (preselected || (uri != null && isDirectMediaUrl(uri))) {
    state.startDownload(
      url: url,
      title: title,
      referer: referer,
      segments: segments,
      headers: headers,
    );
    state.showHint(
      preselected ? '已将 ${segments.length} 个分片加入下载' : doneHint,
    );
    return;
  }

  final master =
      await _probeWithLoading(context, state, url, referer, headers: headers);
  if (!context.mounted) return;

  // 探测失败 / 只有一档：不打断流程，按原来的默认档位直接下
  if (master == null || master.variants.length < 2) {
    state.startDownload(
      url: url,
      title: title,
      referer: referer,
      headers: headers,
    );
    state.showHint(doneHint);
    return;
  }

  final picked = await showVariantSheet(context, master, state: state);
  if (picked == null || !context.mounted) return;

  state.startDownload(
    url: url,
    title: title,
    referer: referer,
    variantKey: picked.key,
    variantLabel: picked.label,
    headers: headers,
  );
  state.showHint('已加入下载 · ${picked.label}');
}

/// 探测期间给一个轻量遮罩：主播放列表通常几十毫秒就能拿到，
/// 但弱网下不能让用户点完没有任何反馈。
///
/// 遮罩至少显示 [minVisibleMs]，避免探测过快时闪一下白光；
/// 探测本身超过 [timeout] 就当作没有可选档位，继续走默认下载。
Future<HlsMasterPlaylist?> _probeWithLoading(
  BuildContext context,
  AppState state,
  String url,
  String? referer, {
  Map<String, String> headers = const <String, String>{},
  Duration timeout = const Duration(seconds: 12),
  int minVisibleMs = 320,
}) async {
  final p = paletteOf(context);
  final navigator = Navigator.of(context, rootNavigator: true);
  var closed = false;
  void closeOverlay() {
    if (closed) return;
    closed = true;
    if (navigator.canPop()) navigator.pop();
  }

  final overlay = showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (ctx) => PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: p.surface,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: p.accent,
                ),
              ),
              const SizedBox(width: 14),
              Text(
                '正在读取清晰度…',
                style: TextStyle(fontSize: 13, color: p.text),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  HlsMasterPlaylist? result;
  final started = DateTime.now();
  try {
    result = await state
        .probeDownloadOptions(url, referer: referer, headers: headers)
        .timeout(timeout, onTimeout: () => null);
  } catch (_) {
    result = null;
  } finally {
    // 遮罩显示时间补足下限，再关闭
    final shown = DateTime.now().difference(started).inMilliseconds;
    if (shown < minVisibleMs) {
      await Future<void>.delayed(Duration(milliseconds: minVisibleMs - shown));
    }
    if (context.mounted) closeOverlay();
    await overlay;
  }
  return result;
}

/// 展示码率档位。用户取消返回 null（调用方不入队）。
Future<HlsVariant?> showVariantSheet(
  BuildContext context,
  HlsMasterPlaylist master, {
  AppState? state,
}) {
  final p = paletteOf(context);
  // 上次下载选过哪一档：同一站点再下时多半还想选它，标出来省一次判断
  String? lastKey;
  if (state != null) {
    for (final t in state.tasks) {
      if (t.variantKey != null && t.variantKey!.isNotEmpty) {
        lastKey = t.variantKey;
        break;
      }
    }
  }
  return showModalBottomSheet<HlsVariant>(
    context: context,
    backgroundColor: p.surface,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => _VariantSheet(
      master: master,
      lastKey: lastKey,
    ),
  );
}

class _VariantSheet extends StatelessWidget {
  const _VariantSheet({required this.master, this.lastKey});

  final HlsMasterPlaylist master;
  final String? lastKey;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final maxHeight = MediaQuery.of(context).size.height * 0.7;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '选择清晰度',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '共 ${master.variants.length} 档，选定后开始下载',
                  style: TextStyle(fontSize: 12, color: p.textSub),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: p.border),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: master.variants.length,
              separatorBuilder: (_, __) =>
                  Divider(height: 1, color: p.border, indent: 20, endIndent: 20),
              itemBuilder: (ctx, i) {
                final v = master.variants[i];
                final separateAudio = master.separateAudioFor(v);
                final subtitles = master.subtitlesFor(v);
                final isLast = lastKey != null && v.key == lastKey;

                final notes = <String>[
                  v.bandwidthLabel,
                  if (separateAudio.isNotEmpty) '音轨独立，会一并下载后合并',
                  if (subtitles.isNotEmpty) '字幕 ${subtitles.length} 条',
                  if (isLast) '上次选择',
                ];

                return ListTile(
                  dense: true,
                  title: Text(
                    v.resolution ?? v.bandwidthLabel,
                    style: TextStyle(fontSize: 14, color: p.text),
                  ),
                  subtitle: Text(
                    notes.join(' · '),
                    style: TextStyle(fontSize: 12, color: p.textSub),
                  ),
                  trailing: i == 0
                      ? Text(
                          '最高',
                          style: TextStyle(fontSize: 11, color: p.accent),
                        )
                      : (isLast
                          ? Icon(Icons.check, size: 16, color: p.accent)
                          : null),
                  onTap: () => Navigator.of(context).pop(v),
                );
              },
            ),
          ),
          Divider(height: 1, color: p.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
            child: Text(
              '音轨独立成流的档位会把音轨一起下载，下载完成后自动合并成有声的 MP4，'
              '不会得到没声音的文件。',
              style: TextStyle(fontSize: 11, color: p.textFaint, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
