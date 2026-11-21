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
    this.tint = 0.5,
  });

  /// Dezent für die Karte: unter Licht und Heatmap, in beiden Themes.
  factory FurnitureInk.map(HavenColors hv) => FurnitureInk(
    line: hv.tx3.withValues(alpha: hv.isDark ? 0.42 : 0.5),
    fill: hv.tx3.withValues(alpha: hv.isDark ? 0.07 : 0.06),
    detail: hv.tx3.withValues(alpha: hv.isDark ? 0.26 : 0.32),
    tint: hv.isDark ? 0.42 : 0.38,
  );

  /// Kräftiger im Editor („Einrichten“).
  factory FurnitureInk.editor(HavenColors hv) => FurnitureInk(
    line: hv.tx2.withValues(alpha: hv.isDark ? 0.75 : 0.8),
    fill: hv.tx3.withValues(alpha: hv.isDark ? 0.12 : 0.1),
    detail: hv.tx2.withValues(alpha: hv.isDark ? 0.45 : 0.5),
    width: 1.4,
    tint: hv.isDark ? 0.62 : 0.58,
  );

  /// Gewähltes Möbelstück bzw. Vorschau beim Ziehen.
  factory FurnitureInk.accent(HavenColors hv) => FurnitureInk(
    line: hv.acc,
    fill: hv.acc.withValues(alpha: 0.14),
    detail: hv.acc.withValues(alpha: 0.6),
    width: 1.6,
    tint: 0.4,
  );

  /// Für die Bibliothek (Vorschaubild).
  factory FurnitureInk.icon(HavenColors hv) => FurnitureInk(
    line: hv.tx2,
    fill: hv.tx3.withValues(alpha: 0.12),
    detail: hv.tx3,
    width: 1.3,
    tint: 0.75,
  );

  final Color line;
  final Color fill;
  final Color detail;
  final double width;

  /// Deckkraft eigener Möbelfarben (Farbzonen) in den Flächen: leise auf
  /// der Karte, kräftiger im Editor und in Vorschaubildern.
  final double tint;

  @override
  bool operator ==(Object other) =>
      other is FurnitureInk &&
      other.line == line &&
      other.fill == fill &&
      other.detail == detail &&
      other.width == width &&
      other.tint == tint;

  @override
  int get hashCode => Object.hash(line, fill, detail, width, tint);
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
  paintFurnitureShape(canvas, f.kind, Size(w, h), ink, colors: f.colors);
  canvas.restore();
}

/// Zeichnet die Form [kind] in das Rechteck `(0, 0, size)`. [colors] sind
/// eigene Farben je Farbzone (wie in 3D, siehe `FloorFurniture.colors`):
/// die zugehörigen Flächen werden darin leicht getönt ([FurnitureInk.tint]).
void paintFurnitureShape(
  Canvas canvas,
  String kind,
  Size size,
  FurnitureInk ink, {
  Map<String, Color> colors = const {},
}) {
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

  /// Füllung der Zone [zone]: eigene Farbe getönt, sonst die leise
  /// Standardfüllung ([plain] `false`: ohne eigene Farbe gar keine).
  Paint? zf(String zone, {bool plain = true}) {
    final c = colors[zone];
    if (c == null) return plain ? fill : null;
    return Paint()..color = c.withValues(alpha: ink.tint);
  }

  /// Linie in der Farbe der Zone [zone] (kräftig), sonst [base].
  Paint zoneStroke(String zone, [Paint? base]) {
    final c = colors[zone];
    final b0 = base ?? detail;
    if (c == null) return b0;
    return Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = b0.strokeWidth * 1.3
      ..strokeCap = StrokeCap.round
      ..color = Color.lerp(c, ink.line, 0.25)!;
  }

  void box(
    Rect r,
    double radius, {
    bool filled = true,
    Paint? stroke,
    String? zone,
  }) {
    final rr = RRect.fromRectAndRadius(r, Radius.circular(radius));
    final f = zone == null ? (filled ? fill : null) : zf(zone, plain: filled);
    if (f != null) canvas.drawRRect(rr, f);
    canvas.drawRRect(rr, stroke ?? line);
  }

  void oval(Rect r, {Paint? stroke, String? zone, bool filled = true}) {
    final f = zone == null ? (filled ? fill : null) : zf(zone, plain: filled);
    if (f != null) canvas.drawOval(r, f);
    canvas.drawOval(r, stroke ?? line);
  }

  void seg(double x1, double y1, double x2, double y2, [Paint? p]) =>
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), p ?? detail);

  final all = Offset.zero & size;
  // Korpusfarbe: bei Schränken ist der Korpus von oben die ganze Fläche.
  if (colors['body'] case final c? when _bodyTinted.contains(kind)) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(all, Radius.circular(0.04 * u)),
      Paint()..color = c.withValues(alpha: ink.tint),
    );
  }
  switch (kind) {
    case 'bed_double' || 'bed_single':
      box(all, 0.04 * u, zone: 'frame');
      // Matratze, Decke (untere zwei Drittel), Kissen oben.
      final mattress = Rect.fromLTRB(0.02 * w, 0.035 * h, 0.98 * w, 0.99 * h);
      box(mattress, 0.05 * u, filled: false, stroke: detail);
      final blanket = Rect.fromLTRB(0, 0.35 * h, w, h);
      box(blanket, 0.05 * u, zone: 'bedding', filled: false);
      final isDouble = kind == 'bed_double';
      final top = 0.06 * h, ph = 0.16 * h;
      final rects = isDouble
          ? [
              Rect.fromLTWH(0.07 * w, top, 0.41 * w, ph),
              Rect.fromLTWH(0.52 * w, top, 0.41 * w, ph),
            ]
          : [Rect.fromLTWH(0.1 * w, top, 0.8 * w, ph)];
      for (final r in rects) {
        box(r, 0.3 * ph, filled: false, stroke: detail, zone: 'pillows');
      }
      // Umschlag der Decke.
      seg(0, 0.42 * h, w, 0.42 * h);
    case 'nightstand':
      box(all, 0.1 * u);
      canvas.drawCircle(all.center, 0.24 * u, detail);
      seg(0.38 * w, h - 0.05 * h, 0.62 * w, h - 0.05 * h, line);
    case 'wardrobe':
      box(all, 0.03 * u);
      final n = math.max(2, (w / math.max(h, 1)).round());
      // Fronten als Streifen an der Vorderkante.
      final f = h - 0.08 * h;
      seg(0, f, w, f);
      for (var i = 1; i < n; i++) {
        seg(w * i / n, f, w * i / n, h);
      }
      // Kleiderstange.
      seg(0.06 * w, 0.45 * h, 0.94 * w, 0.45 * h);
    case 'sofa' || 'armchair':
      final chair = kind == 'armchair';
      box(all, (chair ? 0.16 : 0.12) * u, zone: 'frame');
      final arm = chair
          ? math.min(math.max(0.1, 0.11 * w), 0.32 * h)
          : math.min(math.max(0.11 * w, 0.0), 0.32 * h);
      final back = math.min(0.22 * h, 0.4 * w);
      final seat = Rect.fromLTRB(arm, back, w - arm, h - 0.03 * h);
      final n = chair
          ? 1
          : math.max(1, ((w - 2 * arm) / (0.75 / 0.5 * h * 0.5)).round());
      for (var i = 0; i < n; i++) {
        final x0 = seat.left + seat.width * i / n;
        final x1 = seat.left + seat.width * (i + 1) / n;
        box(
          Rect.fromLTRB(x0 + 1, seat.top, x1 - 1, seat.bottom),
          0.08 * u,
          filled: false,
          stroke: detail,
          zone: 'cushions',
        );
        seg(x0 + 2, back + 0.2 * h, x1 - 2, back + 0.2 * h);
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
      canvas.drawPath(l, zf('cushions') ?? fill);
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
    case 'side_table':
      oval(all.deflate(0.02 * u), zone: 'top');
      canvas.drawCircle(all.center, 0.08 * u, detail);
    case 'dresser':
      box(all, 0.04 * u);
      seg(0, 0.9 * h, w, 0.9 * h);
      final n = w > 1.6 * h ? 2 : 1;
      for (var i = 1; i < n; i++) {
        seg(w * i / n, 0.9 * h, w * i / n, h);
      }
      for (var i = 0; i < n; i++) {
        canvas.drawCircle(
          Offset(w * (i + 0.5) / n, 0.95 * h),
          0.035 * u,
          zoneStroke('handles', line),
        );
      }
    case 'coat_rack':
      // Bank über die ganze Fläche, Paneel an der Wand mit Haken, Jacken.
      box(all, 0.04 * u, zone: 'body');
      box(
        Rect.fromLTRB(0.03 * w, 0.06 * h, 0.97 * w, 0.94 * h),
        0.06 * u,
        filled: false,
        stroke: detail,
        zone: 'cushion',
      );
      seg(0, 0.06 * h, w, 0.06 * h, line);
      final n = math.max(2, (w / math.max(0.55 * h, 1)).round());
      for (var i = 0; i < n; i++) {
        canvas.drawCircle(
          Offset(w * (i + 0.5) / n, 0.12 * h),
          0.03 * u,
          zoneStroke('hooks'),
        );
      }
      for (final i in {0, n - 2}) {
        oval(
          Rect.fromCenter(
            center: Offset(w * (i + 0.5) / n, 0.28 * h),
            width: 0.7 * w / n,
            height: 0.36 * h,
          ),
          stroke: detail,
          zone: 'coats',
          filled: false,
        );
      }
    case 'coffee_table':
      box(all, 0.2 * u, zone: 'top');
      box(all.deflate(0.14 * u), 0.12 * u, filled: false, stroke: detail);
    case 'sideboard' || 'tv_board':
      box(all, 0.04 * u);
      // Fronten an der Vorderkante, Griffe davor.
      final f = h - 0.08 * h;
      final n = math.max(2, (w / math.max(h * 1.2, 1)).round());
      seg(0, f, w, f);
      for (var i = 1; i < n; i++) {
        seg(w * i / n, f, w * i / n, h);
      }
      for (var i = 0; i < n; i++) {
        final cx = w * (i + 0.5) / n;
        seg(cx - 0.06 * w / n * 2, h, cx + 0.06 * w / n * 2, h, line);
      }
      if (kind == 'tv_board') {
        // Alter Fernseher auf dem Board: Bildschirm als Leiste, Fuß davor.
        box(
          Rect.fromLTWH(0.15 * w, 0.22 * h, 0.7 * w, 0.1 * h),
          0.05 * h,
          stroke: line,
          zone: 'housing',
        );
        box(
          Rect.fromLTWH(0.42 * w, 0.14 * h, 0.16 * w, 0.42 * h),
          0.06 * h,
          filled: false,
          stroke: detail,
        );
      }
    case 'rug':
      final rr = RRect.fromRectAndRadius(all, Radius.circular(0.04 * u));
      canvas.drawRRect(
        rr,
        zf('rug', plain: false) ??
            (Paint()..color = ink.fill.withValues(alpha: ink.fill.a * 1.4)),
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
      // Runder Busch von oben (wie in 3D): äußere Krone als Wolke, innen
      // eine kleinere Kuppe.
      final c = all.center;
      final crown = _cloud(c, 0.48 * u, 7);
      canvas.drawPath(crown, zf('plant') ?? fill);
      canvas.drawPath(crown, line);
      canvas.drawPath(
        _cloud(c + Offset(0.06 * u, -0.05 * u), 0.24 * u, 5),
        detail,
      );
    case 'shelf' || 'bookcase':
      // Offenes Regal von oben: Seiten, Rückwand hinten (oben im Symbol).
      box(all, 0.03 * u);
      seg(0, 0.1 * h, w, 0.1 * h, zoneStroke('back'));
      final t = math.min(0.04 * w, 0.12 * h);
      seg(t, 0.1 * h, t, h);
      seg(w - t, 0.1 * h, w - t, h);
      if (kind == 'bookcase') {
        // Bücherreihen als Streifen.
        for (final (a, e) in const [(0.06, 0.36), (0.4, 0.62), (0.7, 0.92)]) {
          box(
            Rect.fromLTRB(a * w, 0.2 * h, e * w, 0.82 * h),
            0.02 * u,
            filled: false,
            stroke: detail,
            zone: 'books',
          );
        }
      }
    case 'dining_table':
      final t = Rect.fromLTRB(0.2 * w, 0.24 * h, 0.8 * w, 0.76 * h);
      final c = math.min(0.18 * h, 0.13 * w);
      final n = (t.width / (1.7 * c)).floor().clamp(1, 4);
      // Stuhl mit Lehne außen ([out]: Richtung vom Tisch weg).
      void chair(Rect r, Offset out) {
        box(r, 0.2 * c, zone: 'seat');
        final back =
            r.center + Offset(out.dx * r.width, out.dy * r.height) * 0.42;
        final along = Offset(out.dy.abs(), out.dx.abs()) * (0.42 * c);
        canvas.drawLine(back - along, back + along, zoneStroke('frame', line));
      }

      for (var i = 0; i < n; i++) {
        final x = t.left + t.width * (i + 0.5) / n - c / 2;
        chair(Rect.fromLTWH(x, t.top - c * 1.05, c, c), const Offset(0, -1));
        chair(Rect.fromLTWH(x, t.bottom + c * 0.05, c, c), const Offset(0, 1));
      }
      if (t.height > 1.6 * c) {
        chair(
          Rect.fromLTWH(t.left - c * 1.05, t.center.dy - c / 2, c, c),
          const Offset(-1, 0),
        );
        chair(
          Rect.fromLTWH(t.right + c * 0.05, t.center.dy - c / 2, c, c),
          const Offset(1, 0),
        );
      }
      box(t, 0.06 * u, zone: 'top');
    case 'dining_chair':
      box(
        Rect.fromLTRB(0.04 * w, 0.12 * h, 0.96 * w, h),
        0.14 * u,
        zone: 'seat',
      );
      box(
        Rect.fromLTRB(0.04 * w, 0, 0.96 * w, 0.1 * h),
        0.04 * u,
        zone: 'frame',
      );
    case 'wall_cabinet' || 'mirror_cabinet':
      // Hängt an der Wand: gestrichelt wie in Bauplänen, Türfugen vorn.
      final rr = RRect.fromRectAndRadius(all, Radius.circular(0.04 * u));
      canvas.drawRRect(rr, zf('body')!);
      _dashed(canvas, Path()..addRRect(rr), line, 0.12 * u + 2);
      final n = kind == 'mirror_cabinet'
          ? (w > 3 * h ? 2 : 1)
          : math.max(1, (w / math.max(h * 1.4, 1)).round());
      seg(0, 0.82 * h, w, 0.82 * h);
      for (var i = 1; i < n; i++) {
        seg(w * i / n, 0.82 * h, w * i / n, h);
      }
    case 'worktop':
      box(all, 0.02 * u, zone: 'worktop');
      seg(0, 0.9 * h, w, 0.9 * h);
    case 'dishwasher':
      box(all, 0.02 * u, zone: 'worktop');
      seg(0, 0.86 * h, w, 0.86 * h);
      // Körbe als Raster angedeutet.
      final inner = Rect.fromLTRB(0.14 * w, 0.14 * h, 0.86 * w, 0.74 * h);
      box(inner, 0.04 * u, filled: false, stroke: detail);
      for (var i = 1; i < 3; i++) {
        final x = inner.left + inner.width * i / 3;
        seg(x, inner.top, x, inner.bottom);
      }
    case 'waste_bin':
      final bin = Rect.fromLTRB(0.04 * w, 0, 0.96 * w, 0.86 * h);
      oval(bin, zone: 'body');
      oval(bin.deflate(0.1 * u), stroke: detail, zone: 'lid', filled: false);
      box(Rect.fromLTRB(0.38 * w, 0.84 * h, 0.62 * w, h), 0.03 * u);
    case 'kitchen_counter':
      box(all, 0.02 * u, zone: 'worktop');
      final n = math.max(1, (w / math.max(h, 1)).round());
      for (var i = 1; i < n; i++) {
        seg(w * i / n, 0.86 * h, w * i / n, h);
      }
      seg(0, 0.86 * h, w, 0.86 * h);
    case 'stove':
      box(all, 0.02 * u, zone: 'worktop');
      // Kochfeld als dunkle Glasplatte mit vier Ringen.
      final hob = Rect.fromLTRB(0.07 * w, 0.07 * h, 0.93 * w, 0.86 * h);
      box(hob, 0.03 * u, filled: false, stroke: detail);
      final r = 0.14 * u;
      for (final p in const [
        Offset(0.3, 0.28),
        Offset(0.7, 0.28),
        Offset(0.3, 0.66),
        Offset(0.7, 0.66),
      ]) {
        final at = Offset(p.dx * w, p.dy * h);
        canvas.drawCircle(at, r, detail);
        canvas.drawCircle(at, r * 0.45, detail);
      }
    case 'sink':
      box(all, 0.02 * u, zone: 'worktop');
      final basin = Rect.fromLTRB(0.08 * w, 0.2 * h, 0.58 * w, 0.88 * h);
      box(basin, 0.16 * u, filled: false, stroke: line);
      canvas.drawCircle(basin.center, 0.05 * u, detail);
      // Armatur hinter dem Becken, Auslauf übers Becken.
      canvas.drawCircle(Offset(basin.center.dx, 0.1 * h), 0.04 * u, line);
      seg(basin.center.dx, 0.1 * h, basin.center.dx, 0.4 * h, line);
      for (var i = 0; i < 4; i++) {
        final y = 0.3 * h + i * 0.15 * h;
        seg(0.66 * w, y, 0.92 * w, y);
      }
    case 'fridge':
      box(all, 0.06 * u);
      seg(0, 0.88 * h, w, 0.88 * h, line);
      seg(0.84 * w, 0.88 * h, 0.84 * w, h);
      seg(0.12 * w, 0.12 * h, 0.88 * w, 0.72 * h);
      seg(0.88 * w, 0.12 * h, 0.12 * w, 0.72 * h);
    case 'bathtub':
      box(all, 0.14 * u, zone: 'ceramic');
      final inner = all.deflate(0.11 * u);
      box(
        inner,
        0.42 * math.min(inner.width, inner.height),
        filled: false,
        stroke: line,
      );
      canvas.drawCircle(
        Offset(inner.left + 0.14 * inner.width, inner.center.dy),
        0.05 * u,
        detail,
      );
      seg(0.02 * w, h / 2, inner.left + 0.02 * w, h / 2, line);
    case 'shower':
      box(all, 0.04 * u, zone: 'tray');
      final inner = all.deflate(0.05 * u);
      box(inner, 0.02 * u, filled: false, stroke: detail);
      seg(inner.left, inner.top, inner.right, inner.bottom);
      seg(inner.right, inner.top, inner.left, inner.bottom);
      canvas.drawCircle(all.center, 0.07 * u, line);
      // Brausekopf an der Wand.
      canvas.drawCircle(Offset(w / 2, 0.3 * h), 0.12 * u, detail);
    case 'toilet':
      // Spülkasten an der Wand, Deckel hochgeklappt davor, Becken als Ei
      // (vorn schmaler) mit Sitz und Öffnung, wie in 3D.
      final tankD = 0.28 * h;
      final tank = Rect.fromLTWH(0.04 * w, 0, 0.92 * w, tankD);
      box(tank, 0.1 * u, zone: 'ceramic');
      box(
        Rect.fromLTWH(0.08 * w, tankD, 0.84 * w, 0.05 * h),
        0.02 * u,
        stroke: detail,
        zone: 'seat',
      );
      final cy = tankD + (h - tankD) / 2;
      final ry = (h - tankD) / 2;
      final seat = _egg(Offset(w / 2, cy), 0.48 * w, ry * 0.98);
      canvas.drawPath(seat, zf('seat')!);
      canvas.drawPath(seat, line);
      canvas.drawPath(
        _egg(Offset(w / 2, cy + 0.015 * h), 0.32 * w, ry * 0.68),
        detail,
      );
      canvas.drawCircle(tank.center, 0.06 * u, detail);

    case 'mirror':
      // Schmaler Rahmen an der Wand (oben), Glas als Linie davor.
      final bar = Rect.fromLTWH(0, 0, w, math.max(2.0, 0.3 * h));
      box(bar, 0.03 * u, zone: 'frame');
      seg(0.06 * w, bar.bottom + 0.12 * h, 0.94 * w, bar.bottom + 0.12 * h);
    case 'washing_machine':
      box(all, 0.06 * u, zone: 'body');
      seg(0, 0.9 * h, w, 0.9 * h);
      canvas.drawCircle(all.center, 0.3 * u, zoneStroke('door', line));
      canvas.drawCircle(all.center, 0.2 * u, detail);
    case 'washbasin':
      // Weiches Becken (Superellipse) mit Mulde, Armatur hinten.
      final outer = _squircle(all.center, w / 2, h / 2, 4.5);
      canvas.drawPath(outer, zf('ceramic')!);
      canvas.drawPath(outer, line);
      final back = 0.22 * h;
      final bowl = _squircle(
        Offset(w / 2, h / 2 + back / 2),
        w / 2 - 0.1 * w,
        h / 2 - back / 2 - 0.09 * h,
        3,
      );
      canvas.drawPath(bowl, line);
      canvas.drawCircle(
        Offset(w / 2, h / 2 + back / 2 + 0.03 * h),
        0.04 * u,
        detail,
      );
      final tap = zoneStroke('tap', line);
      canvas.drawCircle(Offset(0.5 * w, back / 2 + 0.01 * h), 0.05 * u, tap);
      seg(0.5 * w, back / 2, 0.5 * w, back + 0.18 * h, tap);
    case 'desk':
      box(all, 0.04 * u, zone: 'top');
      box(
        Rect.fromLTWH(0.3 * w, 0.12 * h, 0.4 * w, 0.06 * h),
        0.03 * h,
        stroke: line,
        zone: 'monitor',
      );
      box(
        Rect.fromLTWH(0.36 * w, 0.48 * h, 0.28 * w, 0.16 * h),
        0.04 * h,
        filled: false,
        stroke: detail,
      );
    case 'office_chair':
      final c = all.center + Offset(0, 0.06 * h);
      for (var i = 0; i < 5; i++) {
        final a = i * 2 * math.pi / 5 + math.pi / 2;
        seg(
          c.dx,
          c.dy,
          c.dx + math.cos(a) * 0.46 * u,
          c.dy + math.sin(a) * 0.46 * u,
        );
      }
      final seat = Rect.fromCircle(center: c, radius: 0.34 * u);
      oval(seat, zone: 'cushions');
      box(
        Rect.fromLTWH(0.18 * w, 0.02 * h, 0.64 * w, 0.12 * h),
        0.06 * h,
        stroke: line,
        zone: 'cushions',
      );
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
      box(
        Rect.fromLTWH(0, h - r, leaf, r),
        leaf / 2,
        stroke: line,
        zone: 'leaf',
      );
      // Laibung (Wandöffnung).
      seg(0, h, r, h, line);
      seg(0, h - 0.06 * r, 0, h + 0.06 * r, line);
      seg(r, h - 0.06 * r, r, h + 0.06 * r, line);
    case 'window':
      box(all, 0.02 * u, stroke: line, zone: 'frame');
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

/// Wolke aus [n] Bögen um [c] mit Radius [r] (Busch von oben).
Path _cloud(Offset c, double r, int n) {
  final path = Path();
  for (var i = 0; i <= n; i++) {
    final a = 2 * math.pi * i / n - math.pi / 2;
    final p = c + Offset(math.cos(a), math.sin(a)) * r;
    if (i == 0) {
      path.moveTo(p.dx, p.dy);
    } else {
      final m = 2 * math.pi * (i - 0.5) / n - math.pi / 2;
      final q = c + Offset(math.cos(m), math.sin(m)) * (r * 1.22);
      path.quadraticBezierTo(q.dx, q.dy, p.dx, p.dy);
    }
  }
  return path..close();
}

/// Ei-Form um [c] (Halbachsen [rx], [ry]), zur Unterseite (+y) schmaler:
/// Becken des WCs wie im 3D-Modell.
Path _egg(Offset c, double rx, double ry) {
  const n = 40;
  final path = Path();
  for (var i = 0; i < n; i++) {
    final a = 2 * math.pi * i / n;
    final y = math.sin(a);
    final x = math.cos(a) * (1 - 0.18 * y.clamp(0.0, 1.0));
    final p = c + Offset(x * rx, y * ry);
    i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
  }
  return path..close();
}

/// Superellipse um [c] (Exponent [e]: 2 Ellipse, größer eckiger).
Path _squircle(Offset c, double rx, double ry, double e) {
  const n = 48;
  double f(double v) => v.sign * math.pow(v.abs(), 2 / e).toDouble();
  final path = Path();
  for (var i = 0; i < n; i++) {
    final a = 2 * math.pi * i / n;
    final p = c + Offset(rx * f(math.cos(a)), ry * f(math.sin(a)));
    i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
  }
  return path..close();
}

/// [path] gestrichelt mit Strichlänge [dash].
void _dashed(Canvas canvas, Path path, Paint paint, double dash) {
  for (final m in path.computeMetrics()) {
    var d = 0.0;
    while (d < m.length) {
      canvas.drawPath(m.extractPath(d, math.min(d + dash, m.length)), paint);
      d += dash * 1.8;
    }
  }
}

/// Formen, deren Korpus (Zone `body`) von oben die ganze Fläche ist.
const _bodyTinted = {
  'nightstand',
  'wardrobe',
  'sideboard',
  'tv_board',
  'shelf',
  'bookcase',
  'fridge',
  'dresser',
};

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
