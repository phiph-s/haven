import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';

/// Kleiner Verlauf ohne Achsen: eine Linie, darunter ein sanfter Verlauf,
/// am Ende ein Punkt. Lücken ([null]) unterbrechen die Linie. Die Skala
/// passt sich den Werten an, bei einer flachen Linie sitzt sie mittig.
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    this.color,
    this.height = 72,
    this.semanticLabel,
  });

  final List<double?> values;
  final Color? color;
  final double height;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      label: semanticLabel ?? 'Verlauf',
      image: true,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _SparkPainter(values, color ?? hv.acc, hv.ln),
        ),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values, this.color, this.grid);
  final List<double?> values;
  final Color color;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    final known = [...values.nonNulls];
    final base = Paint()
      ..color = grid
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      base,
    );
    if (known.isEmpty || values.length < 2) return;
    var lo = known.reduce((a, b) => a < b ? a : b);
    var hi = known.reduce((a, b) => a > b ? a : b);
    if (hi - lo < 1e-9) {
      lo -= 1;
      hi += 1;
    }
    const padTop = 8.0;
    const padBottom = 6.0;
    final h = size.height - padTop - padBottom;
    Offset at(int i) => Offset(
      size.width * i / (values.length - 1),
      padTop + h * (1 - (values[i]! - lo) / (hi - lo)),
    );

    final line = Path();
    final fill = Path();
    var open = false;
    Offset? last;
    Offset? runStart;
    for (var i = 0; i < values.length; i++) {
      if (values[i] == null) {
        if (open && last != null && runStart != null) {
          fill
            ..lineTo(last.dx, size.height)
            ..lineTo(runStart.dx, size.height)
            ..close();
        }
        open = false;
        continue;
      }
      final p = at(i);
      if (!open) {
        line.moveTo(p.dx, p.dy);
        fill.moveTo(p.dx, p.dy);
        runStart = p;
        open = true;
      } else {
        line.lineTo(p.dx, p.dy);
        fill.lineTo(p.dx, p.dy);
      }
      last = p;
    }
    if (open && last != null && runStart != null) {
      fill
        ..lineTo(last.dx, size.height)
        ..lineTo(runStart.dx, size.height)
        ..close();
    }
    canvas.drawPath(
      fill,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), [
          color.withValues(alpha: 0.22),
          color.withValues(alpha: 0),
        ]),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    if (last != null) {
      canvas.drawCircle(last, 3.5, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.color != color ||
      old.grid != grid ||
      old.values.length != values.length ||
      !_same(old.values, values);

  static bool _same(List<double?> a, List<double?> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
