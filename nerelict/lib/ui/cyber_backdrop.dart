import 'package:flutter/material.dart';

import 'app_theme.dart';

/// 赛博朋克 2077 × 狂野美漫主题的背景装饰层。
///
/// 纯绘制、不参与命中测试：霓虹辉光 + 透视网格 + 扫描线 + 半调网点（美漫印刷感）。
/// 只在 `AppPalette.isCyber` 时工作，其他主题完全不绘制。
class CyberBackdrop extends StatelessWidget {
  const CyberBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    return const CustomPaint(painter: _CyberPainter(), size: Size.infinite);
  }
}

class _CyberPainter extends CustomPainter {
  const _CyberPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    // 1. 顶部洋红辉光 + 左下青色辉光
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(1.0, -0.9),
          radius: 1.1,
          colors: <Color>[
            kNeonMagenta.withValues(alpha: 0.22),
            kNeonMagenta.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromLTWH(0, 0, w, h)),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-1.1, 1.0),
          radius: 1.0,
          colors: <Color>[
            kNeonCyan.withValues(alpha: 0.14),
            kNeonCyan.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromLTWH(0, 0, w, h)),
    );

    // 2. 透视网格（地平线在 62% 处）
    final horizon = h * 0.62;
    final vanish = Offset(w / 2, horizon);
    final gridPaint = Paint()
      ..color = kNeonMagenta.withValues(alpha: 0.16)
      ..strokeWidth = 0.9;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, horizon, w, h - horizon));
    for (var i = -7; i <= 7; i++) {
      final bottomX = w / 2 + i * (w / 5.5);
      canvas.drawLine(vanish, Offset(bottomX, h), gridPaint);
    }
    final horizontalPaint = Paint()
      ..color = kNeonCyan.withValues(alpha: 0.13)
      ..strokeWidth = 0.9;
    for (var k = 1; k <= 10; k++) {
      final t = k / 10;
      final y = horizon + (h - horizon) * (t * t * 1.05);
      if (y > h) break;
      canvas.drawLine(Offset(0, y), Offset(w, y), horizontalPaint);
    }
    canvas.restore();

    // 地平线高光
    canvas.drawLine(
      Offset(0, horizon),
      Offset(w, horizon),
      Paint()
        ..shader = const LinearGradient(
          colors: <Color>[
            Color(0x0000E5FF),
            kNeonCyan,
            kNeonMagenta,
            Color(0x00FF2E88),
          ],
          stops: <double>[0.0, 0.3, 0.7, 1.0],
        ).createShader(Rect.fromLTWH(0, horizon, w, 1))
        ..strokeWidth = 1.2,
    );

    // 3. 美漫半调网点（左上区域，交错排列）
    final dotPaint = Paint()..color = kNeonCyan.withValues(alpha: 0.10);
    const step = 16.0;
    for (var y = 0.0; y < horizon; y += step) {
      final row = (y / step).round();
      final offsetX = row.isEven ? 0.0 : step / 2;
      for (var x = offsetX; x < w; x += step) {
        final fade = 1.0 - (y / horizon);
        if (fade <= 0.15) continue;
        canvas.drawCircle(
          Offset(x, y),
          1.1 + fade * 1.2,
          dotPaint..color = kNeonCyan.withValues(alpha: 0.085 * fade),
        );
      }
    }

    // 4. 扫描线（CRT 质感）
    final scanPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.16)
      ..strokeWidth = 1;
    for (var y = 0.0; y < h; y += 4) {
      canvas.drawLine(Offset(0, y), Offset(w, y), scanPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _CyberPainter oldDelegate) => false;
}
