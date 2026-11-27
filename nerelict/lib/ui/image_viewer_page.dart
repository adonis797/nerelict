import 'dart:io';

import 'package:flutter/material.dart';

import '../services/file_kinds.dart';

/// 全屏图片浏览。
///
/// 只做三件事，不铺开成相册：左右翻页、双指缩放、点一下收起 / 唤回界面。
/// - 背景恒黑：图片浏览器的通用约定，浅色主题下也不会把照片衬得发灰；
/// - 缩放时禁用翻页：放大后横向拖动应该是「看图片的另一半」，
///   而不是把当前这张滑走——这是看图应用最容易做错的地方；
/// - 只读：这里不提供删除 / 分享，写操作仍集中在文件页的行菜单里。
class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({
    super.key,
    required this.files,
    this.initialIndex = 0,
  });

  /// 参与翻页的图片列表（调用方负责只传图片）
  final List<LocalFile> files;
  final int initialIndex;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final PageController _controller;
  late int _index;
  bool _chrome = true;

  /// 当前这张的缩放倍数。>1 时关闭翻页手势，避免「想平移却翻了页」。
  double _scale = 1;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.files.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  LocalFile get _current => widget.files[_index];

  void _toggleChrome() => setState(() => _chrome = !_chrome);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: PageView.builder(
              controller: _controller,
              physics: _scale > 1.01
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              itemCount: widget.files.length,
              onPageChanged: (i) => setState(() {
                _index = i;
                _scale = 1;
              }),
              itemBuilder: (context, i) => _ImagePage(
                file: widget.files[i],
                onTap: _toggleChrome,
                onScale: (s) {
                  if ((s - _scale).abs() < 0.01) return;
                  setState(() => _scale = s);
                },
              ),
            ),
          ),
          _TopBar(
            visible: _chrome,
            title: _current.name,
            index: _index,
            total: widget.files.length,
            onBack: () => Navigator.of(context).maybePop(),
          ),
          _BottomBar(visible: _chrome, file: _current),
        ],
      ),
    );
  }
}

class _ImagePage extends StatefulWidget {
  const _ImagePage({
    required this.file,
    required this.onTap,
    required this.onScale,
  });

  final LocalFile file;
  final VoidCallback onTap;
  final ValueChanged<double> onScale;

  @override
  State<_ImagePage> createState() => _ImagePageState();
}

class _ImagePageState extends State<_ImagePage> {
  final TransformationController _transform = TransformationController();

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  /// 真实缩放倍数只能从矩阵读：`ScaleUpdateDetails.scale` 是相对手势起点的
  /// 累积值，已经在 2 倍时再捏合会从 1.0 重新计数，拿它判断会误判成「没缩放」。
  void _reportScale() {
    final scale = _transform.value.getMaxScaleOnAxis();
    widget.onScale(scale < 1 ? 1 : scale);
  }

  void _toggleZoom() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    _transform.value = zoomed
        ? Matrix4.identity()
        : Matrix4.diagonal3Values(2.5, 2.5, 1);
    _reportScale();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      // 双击放大 / 还原：单手看细节比双指更顺手
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 1,
        maxScale: 5,
        clipBehavior: Clip.none,
        onInteractionEnd: (_) => _reportScale(),
        child: Center(
          child: Image.file(
            File(widget.file.path),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, error, stack) =>
                _BrokenImage(name: widget.file.name),
          ),
        ),
      ),
    );
  }
}

class _BrokenImage extends StatelessWidget {
  const _BrokenImage({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.broken_image_outlined,
              size: 44, color: Colors.white38),
          const SizedBox(height: 12),
          Text(
            '无法打开这张图片',
            style: const TextStyle(fontSize: 13, color: Colors.white70),
          ),
          const SizedBox(height: 6),
          Text(
            name,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Colors.white38),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.visible,
    required this.title,
    required this.index,
    required this.total,
    required this.onBack,
  });

  final bool visible;
  final String title;
  final int index;
  final int total;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 160),
        child: Container(
          padding: EdgeInsets.fromLTRB(4, top + 4, 12, 10),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[Color(0xCC000000), Color(0x00000000)],
            ),
          ),
          child: Row(
            children: <Widget>[
              IconButton(
                onPressed: onBack,
                tooltip: '返回',
                icon: const Icon(Icons.arrow_back, color: Colors.white, size: 22),
              ),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5, color: Colors.white),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${index + 1}/$total',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.visible, required this.file});

  final bool visible;
  final LocalFile file;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    return Align(
      alignment: Alignment.bottomCenter,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 160),
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(16, 12, 16, bottom + 12),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: <Color>[Color(0xCC000000), Color(0x00000000)],
              ),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${file.typeLabel} · ${file.sizeText}',
                    style: const TextStyle(fontSize: 11.5, color: Colors.white70),
                  ),
                ),
                const Text(
                  '双指缩放 · 左右滑动切换',
                  style: TextStyle(fontSize: 11, color: Colors.white38),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
