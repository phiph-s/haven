import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../devices.dart';
import '../model.dart';
import 'catalog.dart';

typedef _B = ModelBuilder;

const _frame = ColorZone('frame', 'Gestell', Mat.soft);
const _cushions = ColorZone('cushions', 'Polster', Mat.soft);
const _legs = ColorZone('legs', 'Füße', Mat.dark);
const _fronts = ColorZone('fronts', 'Fronten');
const _handles = ColorZone('handles', 'Griffe', Mat.metal);

/// Polstermöbel mit Lehne hinten (-y) und Armlehnen links und rechts:
/// Gestell, [seats] Sitz- und Rückenkissen, vier kurze Füße.
void _upholstered(_B b, double w, double d, double h, {int? seats}) {
  final feet = math.min(0.07, h * 0.09);
  final zb = h * 0.4; // Oberkante Gestell unter den Kissen
  final seatTop = h * 0.53;
  final armTop = h * 0.7;
  final arm = math.min(math.max(0.1, 0.11 * w), math.min(0.2, 0.32 * d));
  final back = math.min(0.2, 0.22 * d);
  final y0 = -d / 2;
  b.inZone(_legs.id, () {
    for (final sx in [-1.0, 1.0]) {
      for (final sy in [-1.0, 1.0]) {
        b.cylinder(
          sx * (w / 2 - 0.07),
          sy * (d / 2 - 0.07),
          0.022,
          0,
          feet,
          segments: 6,
          mat: Mat.dark,
        );
      }
    }
  });
  b.inZone(_frame.id, () {
    b.roundBox(
      -w / 2,
      y0,
      feet,
      w / 2,
      d / 2,
      zb,
      0.035,
      mat: Mat.soft,
      segments: 2,
    );
    b.roundBox(
      -w / 2,
      y0,
      zb - 0.01,
      w / 2,
      y0 + back,
      h,
      0.05,
      mat: Mat.soft,
      segments: 2,
    );
    for (final sx in [-1.0, 1.0]) {
      b.roundBox(
        sx * w / 2,
        y0,
        zb - 0.01,
        sx * (w / 2 - arm),
        d / 2,
        armTop,
        0.05,
        mat: Mat.soft,
        segments: 2,
      );
    }
  });
  b.inZone(_cushions.id, () {
    final inner = w - 2 * arm;
    final n = seats ?? math.max(1, (inner / 0.75).round());
    const gap = 0.012;
    for (var i = 0; i < n; i++) {
      final x0 = -w / 2 + arm + inner * i / n + (i == 0 ? 0.004 : gap / 2);
      final x1 =
          -w / 2 + arm + inner * (i + 1) / n - (i == n - 1 ? 0.004 : gap / 2);
      // Sitzkissen.
      b.roundBox(
        x0,
        y0 + back,
        zb,
        x1,
        d / 2 - 0.012,
        seatTop,
        0.04,
        mat: Mat.soft,
        segments: 2,
      );
      // Rückenkissen, leicht nach hinten geneigt.
      final cb = math.min(0.18, 0.2 * d);
      b.loft(
        _B.roundedRect(x0, y0 + back, x1, y0 + back + cb, 0.04, segments: 2),
        seatTop,
        _B.roundedRect(
          x0,
          y0 + back - 0.005,
          x1,
          y0 + back + cb * 0.7,
          0.04,
          segments: 2,
        ),
        h - 0.035,
        mat: Mat.soft,
      );
    }
  });
}

/// Niedriges Board mit Fronten und Griffen (Front +y): Sockel, Korpus,
/// überstehende Platte, [doors] Türen nebeneinander.
void _board(_B b, double w, double d, double h, {int? doors}) {
  final plinth = math.min(0.1, h * 0.2);
  const top = 0.022;
  final y1 = d / 2 - 0.034; // Korpusfront, Türen und Griffe davor
  // Füße, Korpus und Platte.
  for (final sx in [-1.0, 1.0]) {
    for (final sy in [-1.0, 1.0]) {
      b.box(
        sx * (w / 2 - 0.04) - 0.02,
        sy * (d / 2 - 0.06) - 0.02,
        0,
        sx * (w / 2 - 0.04) + 0.02,
        sy * (d / 2 - 0.06) + 0.02,
        plinth,
      );
    }
  }
  b.box(-w / 2 + 0.005, -d / 2 + 0.005, plinth, w / 2 - 0.005, y1, h - top);
  b.roundBox(-w / 2, -d / 2, h - top, w / 2, d / 2, h, 0.008);
  final n = doors ?? math.max(2, (w / 0.55).round());
  const gap = 0.006;
  for (var i = 0; i < n; i++) {
    final x0 = -w / 2 + 0.005 + (w - 0.01) * i / n + gap / 2;
    final x1 = -w / 2 + 0.005 + (w - 0.01) * (i + 1) / n - gap / 2;
    b.inZone(_fronts.id, () {
      b.box(x0, y1, plinth + 0.008, x1, y1 + 0.016, h - top - 0.006);
    });
    // Griffleiste oben, mittig auf der Tür.
    b.inZone(_handles.id, () {
      final cx = (x0 + x1) / 2, hw = math.min(0.07, (x1 - x0) * 0.25);
      b.box(
        cx - hw,
        y1 + 0.016,
        h - top - 0.06,
        cx + hw,
        y1 + 0.032,
        h - top - 0.046,
        mat: Mat.metal,
      );
    });
  }
}

/// Ein Blatt als gebogener Streifen (zweiseitige Platten): vom Ansatz
/// [base] in Richtung [angle] (Bogenmaß, auf dem Plan), [len] lang, bis
/// [width] breit, steigt mit [rise] und hängt an der Spitze um [droop].
void _leaf(
  _B b,
  V3 base,
  double angle,
  double len,
  double width,
  double rise,
  double droop,
) {
  final dir = V3(math.cos(angle), math.sin(angle), 0);
  final side = V3(-math.sin(angle), math.cos(angle), 0);
  // Querschnitte: Abstand, Breite; Höhe steigt und hängt zur Spitze.
  double lift(double t) => rise * (1 - (1 - t) * (1 - t)) - droop * t * t * t;
  final secs = [
    for (final (t, wf) in const [
      (0.0, 0.0),
      (0.18, 0.62),
      (0.45, 1.0),
      (0.75, 0.78),
      (1.0, 0.0),
    ])
      (t, wf, lift(t)),
  ];
  V3 at(double t, double z) => base + dir * (len * t) + V3(0, 0, z);
  for (var i = 0; i + 1 < secs.length; i++) {
    final (t0, w0, z0) = secs[i];
    final (t1, w1, z1) = secs[i + 1];
    final a = at(t0, z0), c = at(t1, z1);
    final s0 = side * (width * w0 / 2), s1 = side * (width * w1 / 2);
    if (w0 == 0) {
      b.panel([a, c - s1, c + s1], mat: Mat.green);
    } else if (w1 == 0) {
      b.panel([a - s0, c, a + s0], mat: Mat.green);
    } else {
      b.panel([a - s0, c - s1, c + s1, a + s0], mat: Mat.green);
    }
  }
}

/// 3D-Modelle der Kategorie „living“.
///
/// Rückenlehnen liegen wie in 2D an der Oberkante (y = -d/2), bei der
/// Ecksofa-L zusätzlich an der linken Kante (x = -w/2). Fronten von
/// Schränken und Boards zeigen nach +y.
final Map<String, FurnitureSpec> livingModels = {
  // 2D: Rückenlehne oben, Armlehnen links und rechts, Sitzkissen dazwischen.
  'sofa': FurnitureSpec(
    height: 0.85,
    zones: const [_frame, _cushions, _legs],
    build: (b, w, d, h) => _upholstered(b, w, d, h),
  ),
  // 2D: L-Form, Schenkel oben (volle Breite) und links (volle Tiefe).
  'sofa_corner': FurnitureSpec(
    height: 0.85,
    zones: const [_frame, _cushions],
    build: (b, w, d, h) {
      final t = math.min(0.42 * math.max(w, d), 0.5 * math.min(w, d));
      final back = 0.32 * t;
      final seatTop = 0.5 * h;
      final armTop = 0.72 * h;
      final x0 = -w / 2, y0 = -d / 2;
      b.inZone(_cushions.id, () {
        // Sitzblock als L.
        b.prism(
          [
            Offset(x0, y0),
            Offset(w / 2, y0),
            Offset(w / 2, y0 + t),
            Offset(x0 + t, y0 + t),
            Offset(x0 + t, d / 2),
            Offset(x0, d / 2),
          ],
          0,
          seatTop,
          mat: Mat.soft,
        );
      });
      // Lehnen oben und links.
      b.box(x0, y0, seatTop, w / 2, y0 + back, h, mat: Mat.soft);
      b.box(x0, y0 + back, seatTop, x0 + back, d / 2, h, mat: Mat.soft);
      // Armlehnen an den Schenkelenden.
      b.box(
        w / 2 - back,
        y0 + back,
        seatTop,
        w / 2,
        y0 + t,
        armTop,
        mat: Mat.soft,
      );
      b.box(
        x0 + back,
        d / 2 - back,
        seatTop,
        x0 + t,
        d / 2,
        armTop,
        mat: Mat.soft,
      );
      // Kissenfugen: Eckkissen abgrenzen, Schenkel unterteilen.
      b.line(V3(x0 + t, y0 + back, seatTop), V3(x0 + t, y0 + t, seatTop));
      b.line(V3(x0 + back, y0 + t, seatTop), V3(x0 + t, y0 + t, seatTop));
      final nx = math.max(1, ((w - t) / (1.1 * t)).round());
      for (var i = 1; i < nx; i++) {
        final x = x0 + t + (w - t - back) * i / nx;
        b.line(V3(x, y0 + back, seatTop), V3(x, y0 + t, seatTop));
      }
      final ny = math.max(1, ((d - t) / (1.1 * t)).round());
      for (var i = 1; i < ny; i++) {
        final y = y0 + t + (d - t - back) * i / ny;
        b.line(V3(x0 + back, y, seatTop), V3(x0 + t, y, seatTop));
      }
    },
  ),
  // 2D: Quadrat mit Lehne oben und zwei Armlehnen.
  'armchair': FurnitureSpec(
    height: 0.85,
    zones: const [_frame, _cushions, _legs],
    build: (b, w, d, h) => _upholstered(b, w, d, h, seats: 1),
  ),
  // 2D: Platte mit abgesetztem Innenrahmen (Ablage).
  'coffee_table': FurnitureSpec(
    height: 0.42,
    zones: const [ColorZone('top', 'Platte'), ColorZone('legs', 'Beine')],
    build: (b, w, d, h) {
      const top = 0.04;
      final leg = math.min(0.05, 0.1 * math.min(w, d));
      b.box(-w / 2, -d / 2, h - top, w / 2, d / 2, h);
      b.inZone('legs', () {
        for (final sx in [-1, 1]) {
          for (final sy in [-1, 1]) {
            b.boxC(
              sx * (w / 2 - leg),
              sy * (d / 2 - leg),
              leg,
              leg,
              0,
              h - top,
            );
          }
        }
      });
      // Innenrahmen als Linie auf der Platte.
      final m = 0.14 * math.min(w, d);
      b.rectLines(-w / 2 + m, -d / 2 + m, w / 2 - m, d / 2 - m, h);
    },
  ),
  // Lowboard / Sideboard: Füße, Korpus, Fronten mit Griffleisten.
  'sideboard': FurnitureSpec(
    height: 0.55,
    zones: const [kBodyZone, _fronts, _handles],
    build: _board,
  ),
  // Alt (bis 0.9.26): Board mit Fernseher als ein Möbelstück. Heute sind
  // Board und Fernseher (Gerät) getrennt; alte Pläne zeigen hier beides.
  // Die Höhe schließt den Fernseher ein.
  'tv_board': FurnitureSpec(
    height: 1.0,
    zones: const [kBodyZone, _fronts, _handles, ...kTvZones],
    build: (b, w, d, h) {
      final bh = math.min(0.45, 0.8 * h); // Höhe des Boards
      _board(b, w, d, bh);
      final room = h - bh - 0.1; // Platz fürs Bild über Fuß und Rahmen
      if (room > 0.1) {
        final sw = math.min(0.7 * w, room * 16 / 9);
        b.shifted(V3(0, -d / 2 + 0.16, bh), () => buildTv(b, sw));
      }
    },
  ),
  // Dünne Platte am Boden mit Randlinie.
  'rug': FurnitureSpec(
    height: 0.02,
    zones: const [ColorZone('rug', 'Teppich', Mat.rug)],
    build: (b, w, d, h) {
      b.box(-w / 2, -d / 2, 0, w / 2, d / 2, h, mat: Mat.rug);
      final m = 0.1 * math.min(w, d);
      b.rectLines(
        -w / 2 + m,
        -d / 2 + m,
        w / 2 - m,
        d / 2 - m,
        h,
        mat: Mat.rug,
      );
    },
  ),
  // Topf mit Rand und Erde, darüber zwei Kränze gebogener Blätter (wie die
  // Blattrosette in 2D).
  'plant': FurnitureSpec(
    height: 1.2,
    zones: const [
      ColorZone('plant', 'Pflanze', Mat.green),
      ColorZone('pot', 'Topf'),
    ],
    build: (b, w, d, h) {
      final r = 0.5 * math.min(w, d);
      final potH = math.min(0.42, 0.3 * h);
      final pr = 0.62 * r;
      b.inZone('pot', () {
        b.cone(0, 0, pr * 0.78, pr, 0, potH - 0.03, segments: 14);
        b.cylinder(0, 0, pr * 1.05, potH - 0.03, potH, segments: 14);
      });
      b.zone = null;
      b.cylinder(
        0,
        0,
        pr * 0.95,
        potH - 0.025,
        potH - 0.012,
        segments: 14,
        mat: Mat.dark,
      );
      b.zone = 'plant';
      // Stiel und drei Kränze breiter, leicht hängender Blätter: unten
      // weit ausladend, oben kürzer und steiler (von oben eine Rosette wie
      // in 2D).
      final g = h - potH;
      b.cylinder(
        0,
        0,
        0.012,
        potH - 0.02,
        potH + g * 0.7,
        segments: 5,
        mat: Mat.green,
      );
      for (final (z0, n, len, rise, droop, turn) in [
        (0.02, 7, 0.99, 0.2, 0.2, 0.0),
        (0.22, 6, 0.95, 0.24, 0.16, 0.45),
        (0.44, 6, 0.8, 0.26, 0.12, 0.1),
        (0.66, 4, 0.6, 0.34, 0.05, 0.8),
      ]) {
        final base = V3(0, 0, potH + g * z0);
        for (var i = 0; i < n; i++) {
          final a = turn + i * 2 * math.pi / n;
          _leaf(b, base, a, r * len, r * len * 0.6, g * rise, g * droop);
        }
      }
    },
  ),
  // Hohes Regal: ein Korpus, Fachlinien auf der Vorderseite.
  'shelf': FurnitureSpec(
    height: 1.8,
    build: (b, w, d, h) {
      b.box(-w / 2, -d / 2, 0, w / 2, d / 2, h);
      // Fachböden als Linien auf der Front (y = +d/2).
      final rows = math.max(3, (h / 0.38).round());
      for (var i = 1; i < rows; i++) {
        final z = h * i / rows;
        b.line(V3(-w / 2, d / 2, z), V3(w / 2, d / 2, z));
      }
      // Senkrechte Teiler wie in 2D.
      final n = math.max(1, (w / math.max(d * 2.5, 0.01)).round());
      for (var i = 1; i < n; i++) {
        final x = -w / 2 + w * i / n;
        b.line(V3(x, d / 2, 0), V3(x, d / 2, h));
      }
    },
  ),
};
