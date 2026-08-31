import 'package:flutter/material.dart';

class LyricWord {
  const LyricWord(this.text, this.start, this.end);

  final String text;
  final Duration start;
  final Duration end;
}

class KaraokeLine {
  const KaraokeLine({required this.words, this.translation});

  final List<LyricWord> words;
  final String? translation;
}

class KaraokeLineView extends StatelessWidget {
  const KaraokeLineView(
      {super.key,
      required this.line,
      required this.position,
      this.style,
      this.highlightColor,
      this.translationStyle});

  final KaraokeLine line;
  final Duration position;
  final TextStyle? style;
  final Color? highlightColor;
  final TextStyle? translationStyle;

  @override
  Widget build(BuildContext context) {
    final baseStyle = style ??
        Theme.of(context).textTheme.headlineSmall ??
        const TextStyle(fontSize: 24);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: (baseStyle.fontSize ?? 24) * 1.5,
          child: CustomPaint(
            painter: KaraokeLinePainter(
                line: line,
                position: position,
                style: baseStyle,
                highlightColor:
                    highlightColor ?? Theme.of(context).colorScheme.primary),
          ),
        ),
        if (line.translation != null)
          Text(line.translation!,
              style: translationStyle ??
                  baseStyle.copyWith(
                      fontSize: (baseStyle.fontSize ?? 24) * .72,
                      color: Colors.white70)),
      ],
    );
  }
}

class KaraokeLinePainter extends CustomPainter {
  const KaraokeLinePainter(
      {required this.line,
      required this.position,
      required this.style,
      required this.highlightColor});

  final KaraokeLine line;
  final Duration position;
  final TextStyle style;
  final Color highlightColor;

  @override
  void paint(Canvas canvas, Size size) {
    final text = line.words.map((word) => word.text).join();
    final painter = TextPainter(
        text: TextSpan(
            text: text,
            style: style.copyWith(color: style.color ?? Colors.white)),
        textDirection: TextDirection.ltr)
      ..layout(maxWidth: size.width);
    final offset = Offset(
        (size.width - painter.width) / 2, (size.height - painter.height) / 2);
    painter.paint(canvas, offset);
    var cursor = 0.0;
    for (final word in line.words) {
      final wordPainter = TextPainter(
          text: TextSpan(text: word.text, style: style),
          textDirection: TextDirection.ltr)
        ..layout();
      final progress = word.end <= word.start
          ? (position >= word.end ? 1 : 0)
          : ((position - word.start).inMicroseconds /
                  (word.end - word.start).inMicroseconds)
              .clamp(0, 1)
              .toDouble();
      if (progress > 0) {
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(
            offset.dx + cursor, 0, wordPainter.width * progress, size.height));
        final highlighted = TextPainter(
            text: TextSpan(
                text: word.text,
                style: style.copyWith(color: highlightColor, shadows: [
                  Shadow(color: highlightColor.withOpacity(.7), blurRadius: 12)
                ])),
            textDirection: TextDirection.ltr)
          ..layout();
        highlighted.paint(canvas, Offset(offset.dx + cursor, offset.dy));
        canvas.restore();
      }
      cursor += wordPainter.width;
    }
  }

  @override
  bool shouldRepaint(covariant KaraokeLinePainter oldDelegate) =>
      oldDelegate.line != line ||
      oldDelegate.position != position ||
      oldDelegate.style != style ||
      oldDelegate.highlightColor != highlightColor;
}
