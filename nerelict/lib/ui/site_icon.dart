import 'package:flutter/material.dart';

import 'app_theme.dart';

/// 网站图标：优先用收藏时自动识别到的 <link rel="icon">，
/// 其次尝试站点根目录的 favicon.ico / apple-touch-icon.png，
/// 全部失败时退化成「首字母 + 主题色」的色块，不会出现破图。
class SiteIcon extends StatefulWidget {
  const SiteIcon({
    super.key,
    required this.url,
    this.iconUrl,
    this.size = 18,
    this.radius = 4,
  });

  final String url;
  final String? iconUrl;
  final double size;
  final double radius;

  @override
  State<SiteIcon> createState() => _SiteIconState();
}

class _SiteIconState extends State<SiteIcon> {
  int _index = 0;
  List<String>? _candidates;
  bool _failed = false;

  @override
  void didUpdateWidget(covariant SiteIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.iconUrl != widget.iconUrl) {
      _index = 0;
      _candidates = null;
      _failed = false;
    }
  }

  List<String> get _urls => _candidates ??= _buildCandidates();

  List<String> _buildCandidates() {
    final base = Uri.tryParse(widget.url);
    final host = base?.host ?? '';
    final scheme = base?.scheme ?? 'https';
    final list = <String>[];

    void add(String? raw) {
      if (raw == null) return;
      var s = raw.trim();
      if (s.isEmpty) return;
      if (s.startsWith('//')) {
        s = '$scheme:$s';
      } else if (s.startsWith('/')) {
        if (host.isEmpty) return;
        s = '$scheme://$host$s';
      } else if (!s.startsWith('http')) {
        return;
      }
      if (!list.contains(s)) list.add(s);
    }

    add(widget.iconUrl);
    if (host.isNotEmpty) {
      add('$scheme://$host/favicon.ico');
      add('$scheme://$host/apple-touch-icon.png');
    }
    return list;
  }

  String get _letter {
    final host = Uri.tryParse(widget.url)?.host ?? '';
    final clean = host.replaceFirst(RegExp(r'^www\.'), '');
    return clean.isEmpty ? '?' : clean.substring(0, 1).toUpperCase();
  }

  Color _hashColor(AppPalette p) {
    const palette = <Color>[
      kAccent,
      Color(0xFF7C5CFF),
      Color(0xFF3DDC97),
      Color(0xFFF5A524),
      Color(0xFFEE5A9B),
    ];
    final host = Uri.tryParse(widget.url)?.host ?? '';
    final hash = host.codeUnits.fold<int>(0, (a, b) => (a * 31 + b) & 0x7fffffff);
    return palette[hash % palette.length];
  }

  void _next() {
    // errorBuilder 里不能直接 setState，放到下一帧
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_index + 1 < _urls.length) {
        setState(() => _index++);
      } else {
        setState(() => _failed = true);
      }
    });
  }

  Widget _fallback(AppPalette p) {
    return Container(
      width: widget.size,
      height: widget.size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: _hashColor(p).withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      child: Text(
        _letter,
        style: TextStyle(
          fontSize: widget.size * 0.55,
          fontWeight: FontWeight.w700,
          color: _hashColor(p),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    if (_failed || _urls.isEmpty) return _fallback(p);
    final url = _urls[_index.clamp(0, _urls.length - 1)];
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: Image.network(
        url,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) {
          _next();
          return _fallback(p);
        },
      ),
    );
  }
}
