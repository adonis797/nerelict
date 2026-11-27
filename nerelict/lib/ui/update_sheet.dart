import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/release_info.dart';
import '../services/apk_installer.dart';
import '../services/open_external.dart';
import '../services/release_feed.dart';
import '../state/app_state.dart';
import 'app_theme.dart';

/// 错误提示色：三套主题（深色 / 浅色 / 赛博）里都要读得出来，所以不走主题变量。
const Color _kErrorColor = Color(0xFFE06C6C);

/// 设置 → 关于里的「检查更新」一行。
///
/// 只在用户点的时候请求：GitHub 匿名 API 每小时 60 次，设置页被反复打开
/// 很容易把额度耗光，所以进入页面不做任何后台轮询。
class UpdateTile extends StatefulWidget {
  const UpdateTile({
    super.key,
    required this.p,
    required this.currentVersion,
  });

  final AppPalette p;

  /// 编译期版本号（与 pubspec 同步），避免依赖平台通道。
  final String currentVersion;

  @override
  State<UpdateTile> createState() => _UpdateTileState();
}

class _UpdateTileState extends State<UpdateTile> {
  bool _checking = false;
  UpdateCheck? _result;

  Future<void> _check({bool force = false}) async {
    if (_checking) return;
    final app = context.read<AppState>();
    setState(() => _checking = true);

    final feed = ReleaseFeed(currentVersion: widget.currentVersion);
    final result = await feed.check(force: force);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _result = result;
    });

    switch (result.status) {
      case UpdateStatus.available:
        await _openSheet(feed, result);
      case UpdateStatus.upToDate:
        // 命中节流时给一个「重新检查」，否则用户会以为按钮没反应
        if (result.fromCache) {
          app.showToast(
            result.message,
            actionLabel: '重新检查',
            onAction: () => _check(force: true),
          );
        } else {
          app.showToast(result.message);
        }
      case UpdateStatus.failed:
        app.showToast(result.message, duration: const Duration(seconds: 3));
    }
  }

  Future<void> _openSheet(ReleaseFeed feed, UpdateCheck result) async {
    final info = result.info;
    if (info == null) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: widget.p.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _UpdateSheet(
        feed: feed,
        info: info,
        currentVersion: widget.currentVersion,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    final result = _result;
    final hasUpdate = result?.status == UpdateStatus.available;

    Widget trailing;
    if (_checking) {
      trailing = SizedBox(
        width: 15,
        height: 15,
        child: CircularProgressIndicator(strokeWidth: 2, color: p.accent),
      );
    } else if (hasUpdate) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            'v${result!.info?.version ?? ''}',
            style: TextStyle(fontSize: 12, color: p.accent),
          ),
        ],
      );
    } else if (result?.status == UpdateStatus.upToDate) {
      trailing = Text(
        '已是最新',
        style: TextStyle(fontSize: 12, color: p.textFaint),
      );
    } else {
      trailing = Text(
        'v${widget.currentVersion}',
        style: TextStyle(fontSize: 12, color: p.textFaint),
      );
    }

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: Icon(Icons.system_update_outlined, size: 19, color: p.accent),
      title: Text(
        '检查更新',
        style: TextStyle(
          fontSize: 13,
          color: hasUpdate ? p.accent : p.text,
        ),
      ),
      trailing: trailing,
      onTap: _checking ? null : () => _check(),
    );
  }
}

/// 更新详情：说明 + 体积 + 下载并安装。
///
/// 下载中关掉弹层会取消下载（[CancelToken] 在 dispose 里触发），
/// 不做后台静默下载——用户看不见的流量消耗比「懒得重下」更烦人。
class _UpdateSheet extends StatefulWidget {
  const _UpdateSheet({
    required this.feed,
    required this.info,
    required this.currentVersion,
  });

  final ReleaseFeed feed;
  final ReleaseInfo info;
  final String currentVersion;

  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> {
  final CancelToken _cancel = CancelToken();

  bool _downloading = false;
  bool _expanded = false;
  double _progress = 0;
  int _lastPct = -1;
  String? _error;

  /// 已下好的安装包。授权「安装未知应用」后重试时直接复用它，
  /// 不再把 20 MB 重新拉一遍——用户被踢去授权页是正常流程。
  File? _ready;

  @override
  void dispose() {
    // 页面销毁即放弃下载：没人接收结果还继续跑就是纯浪费
    if (!_cancel.isCancelled) _cancel.cancel('sheet disposed');
    super.dispose();
  }

  /// 已下载且体积对得上才算可复用；下载途中断掉的文件不能拿来装。
  Future<bool> _reuseReady() async {
    final file = _ready;
    if (file == null) return false;
    if (!await file.exists()) return false;
    final size = widget.info.asset?.size ?? 0;
    if (size > 0 && await file.length() != size) return false;
    return true;
  }

  Future<void> _start() async {
    final app = context.read<AppState>();
    setState(() {
      _downloading = true;
      _progress = _ready == null ? 0 : 1;
      _lastPct = -1;
      _error = null;
    });

    try {
      var file = _ready;
      if (!await _reuseReady()) {
        file = await widget.feed.download(
          widget.info,
          cancelToken: _cancel,
          onProgress: (value) {
            if (!mounted) return;
            // 回调是按网络 chunk 触发的，按 1% 粒度落地，否则每帧都在重建
            final pct = (value * 100).floor();
            if (pct == _lastPct) return;
            _lastPct = pct;
            setState(() => _progress = value);
          },
        );
        _ready = file;
      }
      if (!mounted || file == null) return;

      setState(() => _downloading = false);
      final result = await ApkInstaller.install(file.path);
      if (!mounted) return;

      if (result.ok) {
        app.showToast('${result.modeLabel}：${result.message}');
        // 静默安装已经生效，覆盖安装后进程会被重启，弹层留着没意义
        if (result.silent) Navigator.of(context).maybePop();
      } else {
        setState(() => _error = result.message);
        app.showToast(result.message, duration: const Duration(seconds: 3));
      }
    } on UpdateException catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = '安装失败：$e';
      });
    }
  }

  void _openReleasePage() {
    final url = widget.info.htmlUrl;
    if (url.isEmpty) return;
    OpenExternal.open(url).then((ok) {
      if (!ok && mounted) {
        context
            .read<AppState>()
            .showToast('没有可打开网页的应用，请手动访问 $url',
                duration: const Duration(seconds: 3));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final info = widget.info;
    final asset = info.asset;
    final notes = info.plainNotes;
    final maxHeight = MediaQuery.of(context).size.height * 0.82;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '发现新版本',
                          style: TextStyle(fontSize: 12, color: p.textSub),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'v${info.version}',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                            color: p.text,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      asset == null ? '无安装包' : asset.sizeLabel,
                      style: TextStyle(fontSize: 12, color: p.textFaint),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '当前版本 v${widget.currentVersion}',
                style: TextStyle(fontSize: 12, color: p.textFaint),
              ),
              const SizedBox(height: 14),
              if (notes.isNotEmpty) ...<Widget>[
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  decoration: BoxDecoration(
                    color: p.surfaceAlt,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: p.border),
                  ),
                  // 高度跟着内容走：之前固定 240 会把文字裁在半行，
                  // 展开后交给外层滚动，按钮始终能滚到
                  child: Text(
                    _expanded || notes.length <= 300
                        ? notes
                        : '${notes.substring(0, 300).trimRight()}…',
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.6,
                      color: p.textSub,
                    ),
                  ),
                ),
                if (notes.length > 300)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => setState(() => _expanded = !_expanded),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 2, vertical: 4),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        _expanded ? '收起' : '展开全文',
                        style: TextStyle(fontSize: 12, color: p.accent),
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
              ],
              if (_error != null) ...<Widget>[
                Text(
                  _error!,
                  style: const TextStyle(fontSize: 12, color: _kErrorColor),
                ),
                const SizedBox(height: 10),
              ],
              if (_downloading) ...<Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: _progress == 0 ? null : _progress,
                    minHeight: 4,
                    backgroundColor: p.progressTrack,
                    valueColor: AlwaysStoppedAnimation<Color>(p.accent),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Text(
                      _progress == 0
                          ? '正在连接…'
                          : '正在下载 ${(_progress * 100).floor()}%',
                      style: TextStyle(fontSize: 12, color: p.textSub),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () {
                        if (!_cancel.isCancelled) _cancel.cancel('user');
                        Navigator.of(context).maybePop();
                      },
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        '取消',
                        style: TextStyle(fontSize: 12, color: p.textSub),
                      ),
                    ),
                  ],
                ),
              ] else
                SizedBox(
                  height: 46,
                  child: FilledButton(
                    onPressed: asset == null ? _openReleasePage : _start,
                    style: FilledButton.styleFrom(
                      backgroundColor: p.accent,
                      foregroundColor: p.onAccent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text(
                      asset == null
                          ? '在 GitHub 上查看'
                          : (_ready != null
                              ? '继续安装'
                              : (_error == null ? '下载并安装' : '重试下载')),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              if (asset != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  '安装包不会自动校验签名：与旧版本签名不同时系统会拒绝覆盖安装。',
                  style: TextStyle(fontSize: 11, color: p.textFaint),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
