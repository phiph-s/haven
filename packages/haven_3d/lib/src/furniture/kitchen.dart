import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../model.dart';
import 'catalog.dart';
import 'parts.dart';

typedef _B = ModelBuilder;

/// Dicke der Arbeitsplatte.
const double _top = 0.035;

const _base3 = [kBodyZone, kFrontsZone, kWorktopZone, kHandlesZone];

/// Unterschrank der Küche (Front +y): Sockel, Korpus, [doors] Fronten mit
/// Griffleisten (oder Schubladen [rows]), Arbeitsplatte bis [h] über die
/// ganze Tiefe ([worktop] `false`: ohne, z. B. wenn ein Becken sie bildet).
void _base(
  _B b,
  double w,
  double d,
  double h, {
  required int doors,
  bool worktop = true,
  List<double> rows = const [0, 1],
}) {
  cabinet(
    b,
    w,
    d,
    0,
    h - _top,
    cols: doors,
    rows: rows,
    plinth: 0.1,
    topPlate: false,
  );
  if (worktop) {
    b.inZone(kWorktopZone.id, () {
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
      ColorZone('frame', 'Stuhlgestell'),
      ColorZone('seat', 'Sitze'),
    ],
    build: (b, w, d, h) {
      const topZ = 0.75, plate = 0.035;
      final tw = w * 0.6, td = d * 0.52;
      b.roundBox(
        -tw / 2,
        -td / 2,
        topZ - plate,
        tw / 2,
        td / 2,
        topZ,
        0.03,
        segments: 2,
      );
      b.inZone('legs', () {
        tableLegs(b, tw, td, topZ - plate, leg: 0.05, inset: 0.06);
        // Zarge unter der Platte.
        const m = 0.08;
        b.box(
          -tw / 2 + m,
          -td / 2 + m,
          topZ - plate - 0.07,
          tw / 2 - m,
          td / 2 - m,
          topZ - plate,
        );
      });
      // Stühle, Lehne außen.
      final c = math.min(0.18 * d, 0.13 * w).clamp(0.0, 0.46).toDouble();
      if (c < 0.2) return;
      final n = (tw / (1.7 * c)).floor().clamp(1, 4);
      for (var i = 0; i < n; i++) {
        final x = -tw / 2 + tw * (i + 0.5) / n;
        diningChair(b, x, -td / 2 - c * 0.45, c, c, turn: 0);
        diningChair(b, x, td / 2 + c * 0.45, c, c, turn: math.pi);
      }
      if (td > 1.6 * c) {
        diningChair(b, -tw / 2 - c * 0.45, 0, c, c, turn: -math.pi / 2);
        diningChair(b, tw / 2 + c * 0.45, 0, c, c, turn: math.pi / 2);
      }
    },
  ),
  // Einzelner Stuhl, Lehne oben (-y) wie in 2D.
  'dining_chair': FurnitureSpec(
    height: 0.86,
    zones: const [kFrameZone, kSeatZone],
    build: (b, w, d, h) =>
        diningChair(b, 0, 0, w, d, seatZ: h * 0.53, backZ: h),
  ),
  // 2D: Rahmen, Türfugen im oberen Streifen der Unterkante (Front = +y).
  'kitchen_counter': FurnitureSpec(
    height: 0.9,
    againstWall: true,
    zones: _base3,
    build: (b, w, d, h) =>
        _base(b, w, d, h, doors: math.max(1, (w / 0.6).round())),
  ),
  // Oberschrank: hängt an der Wand (Unterkante 1,45 m), Griffe unten.
  'wall_cabinet': FurnitureSpec(
    height: 0.7,
    elevation: 1.45,
    wallHung: true,
    zones: const [kBodyZone, kFrontsZone, kHandlesZone],
    build: (b, w, d, h) => cabinet(
      b,
      w,
      d,
      0,
      h,
      cols: math.max(1, (w / 0.5).round()),
      grip: Grip.low,
    ),
  ),
  // Arbeitsplatte allein (über Geräten oder Unterschränken), Oberkante
  // 0,9 m.
  'worktop': FurnitureSpec(
    height: 0.04,
    elevation: 0.86,
    againstWall: true,
    zones: const [kWorktopZone],
    build: (b, w, d, h) => b.box(-w / 2, -d / 2, 0, w / 2, d / 2, h),
  ),
  // 2D: vier Kochstellen (Ring + innerer Ring) im Raster 30/70 %.
  'stove': FurnitureSpec(
    height: 0.9,
    againstWall: true,
    zones: _base3,
    build: (b, w, d, h) {
      // Platte knapp tiefer, das Kochfeld liegt bündig darauf. Unten eine
      // Schublade, darüber der Backofen mit Fenster.
      _base(b, w, d, h - 0.006, doors: 1, rows: const [0, 0.22, 1]);
      b.zone = null;
      final yf = d / 2 - frontDepth(Grip.bar) + 0.018;
      final z0 = 0.1 + (h - _top - 0.1) * 0.22 + 0.06;
      b.box(
        -w / 2 + 0.07,
        yf,
        z0,
        w / 2 - 0.07,
        yf + 0.003,
        h - _top - 0.12,
        mat: Mat.screen,
      );
      // Kochfeld: dunkle Glasplatte, Ringe als Linien.
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
  // Geschirrspüler unter der Arbeitsplatte: eine Front, Leiste oben.
  'dishwasher': FurnitureSpec(
    height: 0.9,
    againstWall: true,
    zones: _base3,
    build: (b, w, d, h) {
      _base(b, w, d, h, doors: 1);
      b.zone = null;
      final yf = d / 2 - frontDepth(Grip.bar) + 0.018;
      b.box(
        -w / 2 + 0.01,
        yf,
        h - _top - 0.075,
        w / 2 - 0.01,
        yf + 0.003,
        h - _top - 0.012,
        mat: Mat.dark,
      );
    },
  ),
  // 2D: Becken links (8-58 % x 20-88 %), Hahn oben an der Rückseite,
  // Abtropfrillen rechts. Das Becken ist in die Arbeitsplatte eingelassen.
  'sink': FurnitureSpec(
    height: 0.9,
    againstWall: true,
    zones: const [..._base3, ColorZone('tap', 'Armatur', Mat.metal)],
    build: (b, w, d, h) {
      _base(b, w, d, h, doors: math.max(1, (w / 0.5).round()), worktop: false);
      final bx0 = -w / 2 + 0.08 * w, bx1 = -w / 2 + 0.58 * w;
      final by0 = -d / 2 + 0.2 * d, by1 = -d / 2 + 0.88 * d;
      final cx = (bx0 + bx1) / 2, cy = (by0 + by1) / 2;
      b.inZone(kWorktopZone.id, () {
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
      b.zone = null;
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
  // Mülleimer mit Tretdeckel: Eimer, flacher Deckel, Pedal vorn.
  'waste_bin': FurnitureSpec(
    height: 0.65,
    zones: const [
      ColorZone('body', 'Eimer', Mat.metal),
      ColorZone('lid', 'Deckel', Mat.dark),
    ],
    build: (b, w, d, h) {
      final rx = w / 2 - 0.01, ry = d / 2 - 0.035;
      b.ellipsoid(
        0,
        -0.025,
        rx,
        ry,
        0,
        h - 0.04,
        bottomScale: 0.9,
        segments: 18,
        mat: Mat.metal,
      );
      b.inZone('lid', () {
        b.ellipsoid(
          0,
          -0.025,
          rx + 0.005,
          ry + 0.005,
          h - 0.04,
          h - 0.02,
          segments: 18,
          mat: Mat.dark,
        );
        b.ellipsoid(
          0,
          -0.025,
          rx * 0.8,
          ry * 0.8,
          h - 0.02,
          h,
          bottomScale: 1.2,
          segments: 18,
          mat: Mat.dark,
        );
        b.box(-0.05, ry - 0.04, 0.01, 0.05, d / 2, 0.035, mat: Mat.dark);
      });
    },
  ),
  // 2D: Rahmen, Gefrierfach-Linie nahe der Front (+y), zwei Griffe.
  // Mit Türkontakt offen (`b.open`): Tür an der Angel links 90° aufgeklappt,
  // innen ein helles Fach.
  'fridge': FurnitureSpec(
    height: 1.8,
    againstWall: true,
    zones: const [kBodyZone, kHandlesZone],
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
      b.inZone(kHandlesZone.id, () {
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
