import 'dart:typed_data';

import 'package:flutter/material.dart';

enum SpectrumStyle { bars, curve }

class SpectrumPainter extends CustomPainter {
  const SpectrumPainter({
    required this.magnitudes,
    this.style = SpectrumStyle.bars,
    this.color = const Color(0xff63d6c6),
    this.opacity = .65,
    this.barCount = 32,
    this.glow = true,
  });

  final Float32List magnitudes;
  final SpectrumStyle style;
  final Color color;
  final double opacity;
  final int barCount;
  final bool glow;

  @override
  void paint(Canvas canvas, Size size) {
    if (magnitudes.isEmpty || size.isEmpty) return;
    final values = _bars();
    final paint = Paint()
      ..color = color.withOpacity(opacity.clamp(0, 1).toDouble());
    if (glow) {
      paint.maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      _paintShape(canvas, size, values, paint);
      paint.maskFilter = null;
    }
    _paintShape(canvas, size, values, paint);
  }

  List<double> _bars() {
    final count = barCount.clamp(1, magnitudes.length);
    return [
      for (var index = 0; index < count; index++)
        _value(magnitudes[(index * magnitudes.length / count).floor()]),
    ];
  }

  double _value(double db) => ((db + 80) / 80).clamp(0.015, 1).toDouble();

  void _paintShape(Canvas canvas, Size size, List<double> values, Paint paint) {
    switch (style) {
      case SpectrumStyle.bars:
        final gap = size.width / values.length * .18;
        final width = size.width / values.length - gap;
        for (var index = 0; index < values.length; index++) {
          final height = size.height * values[index];
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(
                  index * (width + gap), size.height - height, width, height),
              Radius.circular(width / 2),
            ),
            paint,
          );
        }
      case SpectrumStyle.curve:
        final path = Path()..moveTo(0, size.height);
        for (var index = 0; index < values.length; index++) {
          final x = (values.length == 1
                  ? 0
                  : index * size.width / (values.length - 1))
              .toDouble();
          final y = (size.height * (1 - values[index])).toDouble();
          if (index == 0) {
            path.lineTo(x, y);
          } else {
            final previousX =
                ((index - 1) * size.width / (values.length - 1)).toDouble();
            path.quadraticBezierTo((previousX + x) / 2, y, x, y);
          }
        }
        path.lineTo(size.width, size.height);
        path.close();
        canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant SpectrumPainter oldDelegate) =>
      oldDelegate.magnitudes != magnitudes ||
      oldDelegate.style != style ||
      oldDelegate.color != color ||
      oldDelegate.opacity != opacity ||
      oldDelegate.barCount != barCount;
}

class SpectrumView extends StatelessWidget {
  const SpectrumView(
      {super.key,
      required this.magnitudes,
      this.style = SpectrumStyle.bars,
      this.color,
      this.height = 64,
      this.barCount = 32});

  final Float32List magnitudes;
  final SpectrumStyle style;
  final Color? color;
  final double height;
  final int barCount;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: SpectrumPainter(
            magnitudes: magnitudes,
            style: style,
            color: color ?? Theme.of(context).colorScheme.primary,
            barCount: barCount,
          ),
        ),
      );
}
