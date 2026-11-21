import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../model.dart';
import 'catalog.dart';

typedef _B = ModelBuilder;

const _fronts = ColorZone('fronts', 'Fronten');
const _worktop = ColorZone('worktop', 'Arbeitsplatte');
const _handles = ColorZone('handles', 'Griffe', Mat.metal);

/// Dicke der Arbeitsplatte.
const double _top = 0.035;

/// Unterschrank der Küche (Front +y): Sockel, Korpus, [doors] Fronten mit
/// Griffleisten, Arbeitsplatte bis [h] ([worktop] `false`: ohne Platte,
/// z. B. wenn ein Becken sie bildet).
void _base(
  _B b,
  double w,
  double d,
  double h, {
  required int doors,
  bool worktop = true,
  bool drawers = false,
}) {
  const plinth = 0.1;
  final y1 = d / 2 - 0.04; // Korpusfront unter der überstehenden Platte
  b.box(-w / 2, -d / 2, 0, w / 2, y1 - 0.05, plinth);
  b.box(-w / 2, -d / 2, plinth, w / 2, y1, h - _top);
  const gap = 0.004;
  for (var i = 0; i < doors; i++) {
    final x0 = -w / 2 + w * i / doors + gap / 2;
    final x1 = -w / 2 + w * (i + 1) / doors - gap / 2;
    // Schubladen: drei Fronten übereinander, sonst eine Tür.
    final rows = drawers ? [0.0, 0.45, 0.72, 1.0] : [0.0, 1.0];
    for (var r = 0; r + 1 < rows.length; r++) {
      final z0 = plinth + 0.004 + (h - _top - plinth - 0.01) * rows[r];
      final z1 = plinth + (h - _top - plinth - 0.01) * rows[r + 1] - 0.002;
      b.inZone(_fronts.id, () {
        b.box(x0, y1, z0, x1, y1 + 0.018, z1);
      });
      b.inZone(_handles.id, () {
        final cx = (x0 + x1) / 2, hw = math.min(0.1, (x1 - x0) * 0.3);
        b.box(
          cx - hw,
          y1 + 0.018,
          z1 - 0.045,
          cx + hw,
          y1 + 0.034,
          z1 - 0.033,
          mat: Mat.metal,
        );
      });
    }
  }
  if (worktop) {
    b.inZone(_worktop.id, () {
      b.box(-w / 2, -d / 2, h - _top, w / 2, d / 2, h);
    });
  }
}

/// Punkt in Richtung [a] (Bogenmaß) von ([cx], [cy]) auf dem Rechteck.
Offset _onRect(
  double cx,
  double cy,
  double x0,
  double y0,
  double x1,
  double y1,
  double a,
) {
  final c = math.cos(a), s = math.sin(a);
  var t = double.infinity;
  if (c.abs() > 1e-9) t = math.min(t, ((c > 0 ? x1 : x0) - cx) / c);
  if (s.abs() > 1e-9) t = math.min(t, ((s > 0 ? y1 : y0) - cy) / s);
  return Offset(cx + c * t, cy + s * t);
}

/// Punkt in Richtung [a] von ([cx], [cy]) auf der Superellipse.
Offset _onSuper(
  double cx,
  double cy,
  double rx,
  double ry,
  double p,
  double a,
) {
  final c = math.cos(a), s = math.sin(a);
  final r = math.pow(
    math.pow((c / rx).abs(), p) + math.pow((s / ry).abs(), p),
    -1 / p,
  );
  return Offset(cx + c * r, cy + s * r);
}

/// Arbeitsplatte [x0]…[x1] × [y0]…[y1] mit eingelassenem Becken um
/// ([cx], [cy]) mit Halbachsen [rx], [ry] und Tiefe [depth].
void _sinkTop(
  _B b,
  double x0,
  double y0,
  double x1,
  double y1,
  double cx,
  double cy,
  double rx,
  double ry,
  double h, {
  double depth = 0.16,
}) {
  // Richtungen: gleichmäßig plus die vier Ecken der Platte (bleiben spitz).
  final angles = <double>[
    for (var i = 0; i < 28; i++) 2 * math.pi * (i + 0.5) / 28,
    for (final (x, y) in [(x1, y0), (x1, y1), (x0, y1), (x0, y0)])
      (math.atan2(y - cy, x - cx) + 2 * math.pi) % (2 * math.pi),
  ]..sort();
  b.basin(
    [for (final a in angles) _onRect(cx, cy, x0, y0, x1, y1, a)],
    [for (final a in angles) _onSuper(cx, cy, rx, ry, 6, a)],
    h - _top,
    h,
    floor: [
      for (final a in angles) _onSuper(cx, cy, rx - 0.015, ry - 0.015, 5, a),
    ],
    zFloor: h - depth,
  );
}

/// 3D-Modelle der Kategorie „kitchen“.
final Map<String, FurnitureSpec> kitchenModels = {
  // 2D: Platte in der Mitte (20-80 % x 24-76 %), Stühle an den langen Seiten
  // oben und unten, bei genug Tiefe auch an den Stirnseiten.
  'dining_table': FurnitureSpec(
    height: 0.9,
    zones: const [
      ColorZone('top', 'Tischplatte'),
      ColorZone('legs', 'Tischbeine'),
      ColorZone('chairs', 'Stühle'),
    ],
    build: (b, w, d, h) {
      const topZ = 0.75, plate = 0.04;
      final tx0 = -w * 0.3, tx1 = w * 0.3, ty0 = -d * 0.26, ty1 = d * 0.26;
      // Tischplatte und vier Beine.
      b.box(tx0, ty0, topZ - plate, tx1, ty1, topZ);
      const l = 0.06, o = 0.05;
      b.inZone('legs', () {
        for (final x in [tx0 + o, tx1 - o - l]) {
          for (final y in [ty0 + o, ty1 - o - l]) {
            b.box(x, y, 0, x + l, y + l, topZ - plate);
          }
        }
      });
      // Stühle: Sitzblock mit dünner Lehne außen.
      final c = math.min(0.18 * d, 0.13 * w).clamp(0.0, 0.46).toDouble();
      void chair(double cx, double cy, double nx, double ny) {
        // (nx, ny) zeigt vom Tisch weg; dort steht die Lehne.
        b.boxC(cx, cy, c, c, 0, 0.46);
        final bx = cx + nx * (c / 2 - 0.015), by = cy + ny * (c / 2 - 0.015);
        if (nx == 0) {
          b.box(bx - c / 2, by - 0.015, 0.46, bx + c / 2, by + 0.015, 0.88);
        } else {
          b.box(bx - 0.015, by - c / 2, 0.46, bx + 0.015, by + c / 2, 0.88);
        }
      }

      // Zu kleiner Platz (Randstreifen 0,24·d): keine Stühle.
      if (c < 0.2) return;
      b.zone = 'chairs';
      final n = ((tx1 - tx0) / (1.7 * c)).floor().clamp(1, 4);
      for (var i = 0; i < n; i++) {
        final x = tx0 + (tx1 - tx0) * (i + 0.5) / n;
        chair(x, ty0 - c * 0.55, 0, -1);
        chair(x, ty1 + c * 0.55, 0, 1);
      }
      if (ty1 - ty0 > 1.6 * c) {
        chair(tx0 - c * 0.55, 0, -1, 0);
        chair(tx1 + c * 0.55, 0, 1, 0);
      }
    },
  ),
  // 2D: Rahmen, Türfugen im oberen Streifen der Unterkante (Front = +y).
  'kitchen_counter': FurnitureSpec(
    height: 0.9,
    zones: const [kBodyZone, _fronts, _worktop, _handles],
    build: (b, w, d, h) =>
        _base(b, w, d, h, doors: math.max(1, (w / 0.6).round())),
  ),
  // 2D: vier Kochstellen (Ring + innerer Ring) im Raster 30/70 %.
  'stove': FurnitureSpec(
    height: 0.9,
    zones: const [kBodyZone, _fronts, _worktop, _handles],
    build: (b, w, d, h) {
      // Platte knapp tiefer, das Kochfeld liegt bündig darauf.
      _base(b, w, d, h - 0.006, doors: 1, drawers: true);
      // Kochfeld: dunkle Glasplatte, Ringe als Linien.
      b.zone = null;
      final m = math.min(0.04, 0.07 * math.min(w, d));
      b.box(
        -w / 2 + m,
        -d / 2 + m,
        h - 0.006,
        w / 2 - m,
        d / 2 - m - 0.02,
        h,
        mat: Mat.dark,
      );
      final r = 0.14 * math.min(w, d);
      for (final fx in [0.3, 0.7]) {
        for (final fy in [0.3, 0.7]) {
          final cx = (fx - 0.5) * w, cy = (fy - 0.5) * (d - 0.02) - 0.01;
          b.ellipseLines(cx, cy, r, r, h);
          b.ellipseLines(cx, cy, r * 0.45, r * 0.45, h, segments: 12);
        }
      }
    },
  ),
  // 2D: Becken links (8-58 % x 20-88 %), Hahn oben an der Rückseite,
  // Abtropfrillen rechts. Das Becken ist in die Arbeitsplatte eingelassen.
  'sink': FurnitureSpec(
    height: 0.9,
    zones: const [
      kBodyZone,
      _fronts,
      _worktop,
      _handles,
      ColorZone('tap', 'Armatur', Mat.metal),
    ],
    build: (b, w, d, h) {
      _base(b, w, d, h, doors: math.max(1, (w / 0.5).round()), worktop: false);
      final bx0 = -w / 2 + 0.08 * w, bx1 = -w / 2 + 0.58 * w;
      final by0 = -d / 2 + 0.2 * d, by1 = -d / 2 + 0.88 * d;
      final cx = (bx0 + bx1) / 2, cy = (by0 + by1) / 2;
      b.inZone(_worktop.id, () {
        _sinkTop(
          b,
          -w / 2,
          -d / 2,
          w / 2,
          d / 2,
          cx,
          cy,
          (bx1 - bx0) / 2,
          (by1 - by0) / 2,
          h,
        );
      });
      b.ellipseLines(cx, cy, 0.03, 0.03, h - 0.16, segments: 10);
      // Abtropfrillen rechts.
      for (var i = 0; i < 4; i++) {
        final y = -d / 2 + (0.3 + i * 0.15) * d;
        b.line(V3(w * 0.16, y, h), V3(w * 0.42, y, h));
      }
      // Armatur hinter dem Becken, Auslauf übers Becken.
      b.inZone('tap', () {
        final ty = -d / 2 + 0.06;
        b.cylinder(cx, ty, 0.022, h, h + 0.28, segments: 8, mat: Mat.metal);
        b.box(
          cx - 0.012,
          ty,
          h + 0.25,
          cx + 0.012,
          by0 + 0.12,
          h + 0.28,
          mat: Mat.metal,
        );
      });
    },
  ),
  // 2D: Rahmen, Gefrierfach-Linie nahe der Front (+y), zwei Griffe.
  // Mit Türkontakt offen (`b.open`): Tür an der Angel links 90° aufgeklappt,
  // innen ein helles Fach.
  'fridge': FurnitureSpec(
    height: 1.8,
    zones: const [kBodyZone, _handles],
    build: (b, w, d, h) {
      final f = d / 2;
      if (b.open == true) {
        const wall = 0.04;
        // Korpus ohne Front: Rückwand, Seiten, Boden, Decke.
        b.box(-w / 2, -f, 0, w / 2, -f + wall, h);
        b.box(-w / 2, -f, 0, -w / 2 + wall, f, h);
        b.box(w / 2 - wall, -f, 0, w / 2, f, h);
        b.box(-w / 2, -f, 0, w / 2, f, wall);
        b.box(-w / 2, -f, h - wall, w / 2, f, h);
        // Innen hell, mit zwei Böden.
        b.zone = null;
        b.box(
          -w / 2 + wall,
          -f + wall,
          wall,
          w / 2 - wall,
          f - 0.01,
          h - wall,
          mat: Mat.soft,
        );
        for (final z in [h * 0.45, h * 0.7]) {
          b.line(V3(-w / 2 + wall, f - 0.01, z), V3(w / 2 - wall, f - 0.01, z));
        }
        // Tür nach vorn aufgeklappt.
        b.zone = kBodyZone.id;
        b.box(-w / 2, f, 0.01, -w / 2 + 0.05, f + w - 0.02, h - 0.01);
        return;
      }
      final f0 = f - 0.025; // Griffe vor der Front
      b.roundBox(-w / 2, -d / 2, 0, w / 2, f0, h, 0.02, segments: 2);
      // Fuge zwischen Gefrier- (unten) und Kühlteil, senkrechte Griffe.
      final split = h * 0.32;
      b.line(V3(-w / 2, f0, split), V3(w / 2, f0, split));
      final hx = w / 2 - 0.07;
      b.inZone(_handles.id, () {
        b.box(
          hx - 0.01,
          f0,
          split + 0.06,
          hx + 0.01,
          f,
          split + 0.45,
          mat: Mat.metal,
        );
        b.box(
          hx - 0.01,
          f0,
          split - 0.3,
          hx + 0.01,
          f,
          split - 0.06,
          mat: Mat.metal,
        );
      });
    },
  ),
};
