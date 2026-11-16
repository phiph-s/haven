import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/theme/tokens.dart';
import '../../data/models/floor_plan.dart';

/// Stifte für Möbel: feine Linie, leichte Füllung, Details etwas leiser.
/// Wie die Skizzen in Entwurf 2 (`tx3`, halbe Deckkraft, 1,4 px).
@immutable
class FurnitureInk {
  const FurnitureInk({
    required this.line,
    required this.fill,
    required this.detail,
    this.width = 1.2,
  });

  /// Dezent für die Karte: unter Licht und Heatmap, in beiden Themes.
  factory FurnitureInk.map(HavenColors hv) => FurnitureInk(
    line: hv.tx3.withValues(alpha: hv.isDark ? 0.42 : 0.5),
    fill: hv.tx3.withValues(alpha: hv.isDark ? 0.07 : 0.06),
    detail: hv.tx3.withValues(alpha: hv.isDark ? 0.26 : 0.32),
  );

  /// Kräftiger im Editor („Einrichten“).
  factory FurnitureInk.editor(HavenColors hv) => FurnitureInk(
    line: hv.tx2.withValues(alpha: hv.isDark ? 0.75 : 0.8),
    fill: hv.tx3.withValues(alpha: hv.isDark ? 0.12 : 0.1),
    detail: hv.tx2.withValues(alpha: hv.isDark ? 0.45 : 0.5),
    width: 1.4,
  );

  /// Gewähltes Möbelstück bzw. Vorschau beim Ziehen.
  factory FurnitureInk.accent(HavenColors hv) => FurnitureInk(
    line: hv.acc,
    fill: hv.acc.withValues(alpha: 0.14),
    detail: hv.acc.withValues(alpha: 0.6),
    width: 1.6,
  );

  /// Für die Bibliothek (Vorschaubild).
  factory FurnitureInk.icon(HavenColors hv) => FurnitureInk(
    line: hv.tx2,
    fill: hv.tx3.withValues(alpha: 0.12),
    detail: hv.tx3,
    width: 1.3,
  );

  final Color line;
  final Color fill;
  final Color detail;
  final double width;

  @override
  bool operator ==(Object other) =>
      other is FurnitureInk &&
      other.line == line &&
      other.fill == fill &&
      other.detail == detail &&
      other.width == width;

  @override
  int get hashCode => Object.hash(line, fill, detail, width);
}

/// Zeichnet [f] auf [canvas]. [center] ist die Mitte in Pixeln, [scale]
/// Pixel je Zelle.
void paintFurniture(
  Canvas canvas,
  FloorFurniture f,
  Offset center,
  double scale,
  FurnitureInk ink,
) {
  final w = f.w * scale, h = f.h * scale;
  if (w < 1 || h < 1) return;
  canvas.save();
  canvas.translate(center.dx, center.dy);
  canvas.rotate(f.rotation * math.pi / 180);
  canvas.translate(-w / 2, -h / 2);
  paintFurnitureShape(canvas, f.kind, Size(w, h), ink);
  canvas.restore();
}

/// Zeichnet die Form [kind] in das Rechteck `(0, 0, size)`.
void paintFurnitureShape(
  Canvas canvas,
  String kind,
  Size size,
  FurnitureInk ink,
) {
  final w = size.width, h = size.height;
  final u = math.min(w, h);
  final sw = ink.width;
  final line = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = sw
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round
    ..color = ink.line;
  final detail = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = sw * 0.85
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round
    ..color = ink.detail;
  final fill = Paint()..color = ink.fill;

  void box(Rect r, double radius, {bool filled = true, Paint? stroke}) {
    final rr = RRect.fromRectAndRadius(r, Radius.circular(radius));
    if (filled) canvas.drawRRect(rr, fill);
    canvas.drawRRect(rr, stroke ?? line);
  }

  void seg(double x1, double y1, double x2, double y2, [Paint? p]) =>
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), p ?? detail);

  final all = Offset.zero & size;
  switch (kind) {
    case 'bed_double' || 'bed_single':
      box(all, 0.06 * u);
      final isDouble = kind == 'bed_double';
      final top = 0.05 * h, ph = 0.15 * h;
      if (isDouble) {
        final pw = 0.4 * w;
        box(
          Rect.fromLTWH(0.07 * w, top, pw, ph),
          0.3 * ph,
          filled: false,
          stroke: detail,
        );
        box(
          Rect.fromLTWH(w - 0.07 * w - pw, top, pw, ph),
          0.3 * ph,
          filled: false,
          stroke: detail,
        );
      } else {
        box(
          Rect.fromLTWH(0.14 * w, top, 0.72 * w, ph),
          0.3 * ph,
          filled: false,
          stroke: detail,
        );
      }
      // Decke mit umgeschlagener Kante.
      seg(0, 0.3 * h, w, 0.3 * h, line);
      seg(0, 0.38 * h, w, 0.38 * h);
      final fold = Path()
        ..moveTo(w, 0.72 * h)
        ..lineTo(0.72 * w, h)
        ..moveTo(w, 0.72 * h)
        ..lineTo(0.86 * w, 0.9 * h);
      canvas.drawPath(fold, detail);
    case 'nightstand':
      box(all, 0.12 * u);
      canvas.drawCircle(all.center, 0.24 * u, detail);
      canvas.drawCircle(all.center, 0.08 * u, detail);
    case 'wardrobe':
      box(all, 0.04 * u);
      final n = math.max(2, (w / math.max(h, 1)).round());
      for (var i = 1; i < n; i++) {
        seg(w * i / n, 0, w * i / n, h);
      }
      // Kleiderstange.
      seg(0.06 * w, 0.45 * h, 0.94 * w, 0.45 * h);
      for (var i = 0; i < n; i++) {
        final x = w * (i + 0.5) / n;
        seg(x - 0.05 * u, 0.82 * h, x + 0.05 * u, 0.82 * h, line);
      }
    case 'sofa':
      box(all, 0.14 * u);
      final arm = math.min(0.12 * w, 0.4 * h);
      final back = 0.28 * h;
      box(
        Rect.fromLTRB(arm, back, w - arm, h - 0.06 * h),
        0.1 * u,
        filled: false,
        stroke: detail,
      );
      seg(arm, back, arm, h - 0.06 * h);
      final n = math.max(2, ((w - 2 * arm) / (0.9 * h)).round());
      for (var i = 1; i < n; i++) {
        final x = arm + (w - 2 * arm) * i / n;
        seg(x, back, x, h - 0.06 * h);
      }
    case 'sofa_corner':
      final d = math.min(0.42 * u, 0.5 * math.min(w, h));
      final l = Path()
        ..moveTo(0, 0)
        ..lineTo(w, 0)
        ..lineTo(w, d)
        ..lineTo(d, d)
        ..lineTo(d, h)
        ..lineTo(0, h)
        ..close();
      canvas.drawPath(l, fill);
      canvas.drawPath(l, line);
      final b = 0.32 * d;
      final inner = Path()
        ..moveTo(w - 0.04 * w, b)
        ..lineTo(b, b)
        ..lineTo(b, h - 0.04 * h);
      canvas.drawPath(inner, detail);
      seg(d, b, d, d);
      seg(b, d, d, d);
      final nx = math.max(1, ((w - d) / (1.1 * d)).round());
      for (var i = 1; i <= nx; i++) {
        final x = d + (w - d) * i / (nx + 1);
        seg(x, b, x, d);
      }
      final ny = math.max(1, ((h - d) / (1.1 * d)).round());
      for (var i = 1; i <= ny; i++) {
        final y = d + (h - d) * i / (ny + 1);
        seg(b, y, d, y);
      }
    case 'armchair':
      box(all, 0.2 * u);
      final arm = 0.16 * w;
      final back = 0.26 * h;
      box(
        Rect.fromLTRB(arm, back, w - arm, h - 0.08 * h),
        0.14 * u,
        filled: false,
        stroke: detail,
      );
    case 'coffee_table':
      box(all, 0.2 * u);
      box(all.deflate(0.14 * u), 0.12 * u, filled: false, stroke: detail);
    case 'tv_board':
      box(all, 0.06 * u);
      box(
        Rect.fromLTWH(0.16 * w, 0.18 * h, 0.68 * w, 0.22 * h),
        0.1 * h,
        filled: false,
        stroke: line,
      );
      seg(0.04 * w, 0.72 * h, 0.96 * w, 0.72 * h);
    case 'rug':
      final rr = RRect.fromRectAndRadius(all, Radius.circular(0.04 * u));
      canvas.drawRRect(
        rr,
        Paint()..color = ink.fill.withValues(alpha: ink.fill.a * 1.4),
      );
      canvas.drawRRect(rr, detail);
      box(all.deflate(0.1 * u), 0.03 * u, filled: false, stroke: detail);
      // Fransen an den kurzen Seiten.
      final horizontal = w >= h;
      final n = ((horizontal ? h : w) / math.max(4.0, 0.08 * u)).floor();
      for (var i = 1; i < n; i++) {
        if (horizontal) {
          final y = h * i / n;
          seg(0, y, -0.05 * u, y);
          seg(w, y, w + 0.05 * u, y);
        } else {
          final x = w * i / n;
          seg(x, 0, x, -0.05 * u);
          seg(x, h, x, h + 0.05 * u);
        }
      }
    case 'plant':
      final c = all.center;
      final r = 0.5 * u;
      for (var i = 0; i < 7; i++) {
        final a = i * 2 * math.pi / 7 - math.pi / 2;
        final tip = c + Offset(math.cos(a), math.sin(a)) * r;
        final side = Offset(-math.sin(a), math.cos(a)) * (0.16 * u);
        final mid = c + Offset(math.cos(a), math.sin(a)) * (r * 0.55);
        final leaf = Path()
          ..moveTo(c.dx, c.dy)
          ..quadraticBezierTo((mid + side).dx, (mid + side).dy, tip.dx, tip.dy)
          ..quadraticBezierTo((mid - side).dx, (mid - side).dy, c.dx, c.dy);
        canvas.drawPath(leaf, fill);
        canvas.drawPath(leaf, detail);
      }
      canvas.drawCircle(c, 0.2 * u, Paint()..color = ink.fill);
      canvas.drawCircle(c, 0.2 * u, line);
    case 'shelf':
      box(all, 0.04 * u);
      final n = math.max(2, (w / math.max(h * 1.1, 1)).round());
      for (var i = 1; i < n; i++) {
        seg(w * i / n, 0, w * i / n, h);
      }
      seg(0, 0.5 * h, w, 0.5 * h);
    case 'dining_table':
      final t = Rect.fromLTRB(0.2 * w, 0.24 * h, 0.8 * w, 0.76 * h);
      final c = math.min(0.18 * h, 0.13 * w);
      final n = (t.width / (1.7 * c)).floor().clamp(1, 4);
      for (var i = 0; i < n; i++) {
        final x = t.left + t.width * (i + 0.5) / n - c / 2;
        box(Rect.fromLTWH(x, t.top - c * 1.05, c, c), 0.25 * c);
        box(Rect.fromLTWH(x, t.bottom + c * 0.05, c, c), 0.25 * c);
      }
      if (t.height > 1.6 * c) {
        box(
          Rect.fromLTWH(t.left - c * 1.05, t.center.dy - c / 2, c, c),
          0.25 * c,
        );
        box(
          Rect.fromLTWH(t.right + c * 0.05, t.center.dy - c / 2, c, c),
          0.25 * c,
        );
      }
      box(t, 0.08 * u);
    case 'kitchen_counter':
      box(all, 0.04 * u);
      final n = math.max(1, (w / math.max(h, 1)).round());
      for (var i = 1; i < n; i++) {
        seg(w * i / n, 0.86 * h, w * i / n, h);
      }
      seg(0, 0.86 * h, w, 0.86 * h);
    case 'stove':
      box(all, 0.06 * u);
      final r = 0.15 * u;
      for (final p in const [
        Offset(0.3, 0.3),
        Offset(0.7, 0.3),
        Offset(0.3, 0.7),
        Offset(0.7, 0.7),
      ]) {
        final at = Offset(p.dx * w, p.dy * h);
        canvas.drawCircle(at, r, detail);
        canvas.drawCircle(at, r * 0.45, detail);
      }
    case 'sink':
      box(all, 0.06 * u);
      final basin = Rect.fromLTRB(0.08 * w, 0.2 * h, 0.58 * w, 0.88 * h);
      box(basin, 0.18 * u, filled: false, stroke: line);
      canvas.drawCircle(basin.center, 0.05 * u, detail);
      seg(basin.center.dx, 0.06 * h, basin.center.dx, 0.2 * h, line);
      for (var i = 0; i < 4; i++) {
        final y = 0.28 * h + i * 0.15 * h;
        seg(0.66 * w, y, 0.92 * w, y);
      }
    case 'fridge':
      box(all, 0.06 * u);
      seg(0, 0.84 * h, w, 0.84 * h, line);
      seg(0.2 * w, 0.92 * h, 0.4 * w, 0.92 * h);
      seg(0.6 * w, 0.92 * h, 0.8 * w, 0.92 * h);
      seg(0.12 * w, 0.12 * h, 0.88 * w, 0.72 * h);
      seg(0.88 * w, 0.12 * h, 0.12 * w, 0.72 * h);
    case 'bathtub':
      box(all, 0.12 * u);
      final inner = all.deflate(0.1 * u);
      box(
        inner,
        0.42 * math.min(inner.width, inner.height),
        filled: false,
        stroke: line,
      );
      canvas.drawCircle(
        Offset(inner.left + 0.12 * inner.width, inner.center.dy),
        0.05 * u,
        detail,
      );
    case 'shower':
      box(all, 0.04 * u);
      final inner = all.deflate(0.07 * u);
      box(inner, 0.02 * u, filled: false, stroke: detail);
      seg(inner.left, inner.top, inner.right, inner.bottom);
      seg(inner.right, inner.top, inner.left, inner.bottom);
      canvas.drawCircle(all.center, 0.07 * u, line);
    case 'toilet':
      box(Rect.fromLTWH(0.04 * w, 0, 0.92 * w, 0.26 * h), 0.08 * u);
      final bowl = Rect.fromLTRB(0.12 * w, 0.22 * h, 0.88 * w, h);
      canvas.drawOval(bowl, fill);
      canvas.drawOval(bowl, line);
      canvas.drawOval(bowl.deflate(0.12 * u), detail);
    case 'washbasin':
      box(all, 0.12 * u);
      final bowl = Rect.fromLTRB(0.16 * w, 0.24 * h, 0.84 * w, 0.9 * h);
      canvas.drawOval(bowl, line);
      canvas.drawCircle(Offset(0.5 * w, 0.12 * h), 0.05 * u, detail);
      canvas.drawCircle(bowl.center, 0.04 * u, detail);
    case 'desk':
      box(all, 0.05 * u);
      box(
        Rect.fromLTWH(0.3 * w, 0.12 * h, 0.4 * w, 0.1 * h),
        0.05 * h,
        filled: false,
        stroke: line,
      );
      box(
        Rect.fromLTWH(0.36 * w, 0.48 * h, 0.28 * w, 0.16 * h),
        0.04 * h,
        filled: false,
        stroke: detail,
      );
    case 'office_chair':
      final c = all.center + Offset(0, 0.06 * h);
      canvas.drawCircle(c, 0.34 * u, fill);
      canvas.drawCircle(c, 0.34 * u, line);
      box(
        Rect.fromLTWH(0.18 * w, 0.02 * h, 0.64 * w, 0.18 * h),
        0.09 * h,
        stroke: line,
      );
      for (var i = 0; i < 5; i++) {
        final a = i * 2 * math.pi / 5 + math.pi / 2;
        seg(
          c.dx,
          c.dy,
          c.dx + math.cos(a) * 0.46 * u,
          c.dy + math.sin(a) * 0.46 * u,
        );
      }
    case 'door':
      // Angel unten links, Wand an der Unterkante, Blatt offen nach oben.
      final r = u;
      final hinge = Offset(0, h);
      final arc = Path()
        ..moveTo(hinge.dx, hinge.dy - r)
        ..arcToPoint(
          Offset(hinge.dx + r, hinge.dy),
          radius: Radius.circular(r),
        );
      final wedge = Path()
        ..moveTo(hinge.dx, hinge.dy)
        ..lineTo(hinge.dx, hinge.dy - r)
        ..arcToPoint(Offset(hinge.dx + r, hinge.dy), radius: Radius.circular(r))
        ..close();
      canvas.drawPath(
        wedge,
        Paint()..color = ink.fill.withValues(alpha: ink.fill.a * 0.7),
      );
      canvas.drawPath(arc, detail);
      final leaf = math.max(2.0, 0.07 * r);
      box(Rect.fromLTWH(0, h - r, leaf, r), leaf / 2, stroke: line);
      // Laibung (Wandöffnung).
      seg(0, h, r, h, line);
      seg(0, h - 0.06 * r, 0, h + 0.06 * r, line);
      seg(r, h - 0.06 * r, r, h + 0.06 * r, line);
    case 'window':
      box(all, 0.02 * u, stroke: line);
      seg(0, h / 2, w, h / 2, line);
      final n = math.max(1, (w / math.max(h * 4, 1)).round());
      for (var i = 1; i <= n; i++) {
        final x = w * i / (n + 1);
        seg(x, 0, x, h);
      }
    default:
      // Unbekannt (neuere App): schlichter Kasten mit Kreuz.
      box(all, 0.06 * u);
      seg(0.15 * w, 0.15 * h, 0.85 * w, 0.85 * h);
      seg(0.85 * w, 0.15 * h, 0.15 * w, 0.85 * h);
  }
}

/// Vorschaubild eines Typs (Bibliothek): passt die Form mit Rand ein, das
/// Seitenverhältnis bleibt.
class FurnitureThumb extends StatelessWidget {
  const FurnitureThumb({
    super.key,
    required this.kind,
    this.size = 44,
    this.ink,
  });
  final String kind;
  final double size;
  final FurnitureInk? ink;

  @override
  Widget build(BuildContext context) {
    final t = furnitureType(kind);
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _ThumbPainter(
          kind: kind,
          w: t?.w ?? 1,
          h: t?.h ?? 1,
          ink: ink ?? FurnitureInk.icon(context.hv),
        ),
      ),
    );
  }
}

class _ThumbPainter extends CustomPainter {
  _ThumbPainter({
    required this.kind,
    required this.w,
    required this.h,
    required this.ink,
  });
  final String kind;
  final double w;
  final double h;
  final FurnitureInk ink;

  @override
  void paint(Canvas canvas, Size size) {
    final pad = size.shortestSide * 0.1;
    final s = math.min((size.width - 2 * pad) / w, (size.height - 2 * pad) / h);
    final sz = Size(w * s, h * s);
    canvas.save();
    canvas.translate(
      (size.width - sz.width) / 2,
      (size.height - sz.height) / 2,
    );
    paintFurnitureShape(canvas, kind, sz, ink);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ThumbPainter old) =>
      old.kind != kind || old.ink != ink || old.w != w || old.h != h;
}
