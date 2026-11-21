import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../devices.dart';
import '../model.dart';
import 'catalog.dart';
import 'parts.dart';

typedef _B = ModelBuilder;

const _frame = ColorZone('frame', 'Gestell', Mat.soft);
const _cushions = ColorZone('cushions', 'Polster', Mat.soft);
const _feet = ColorZone('legs', 'Füße', Mat.dark);

/// Vier (oder mehr) kurze runde Füße an den Punkten [at], Höhe [h].
void _feetAt(_B b, Iterable<Offset> at, double h) {
  b.inZone(_feet.id, () {
    for (final p in at) {
      b.cylinder(p.dx, p.dy, 0.022, 0, h, segments: 6, mat: Mat.dark);
    }
  });
}

/// Polsterkissen [x0]…[x1] × [y0]…[y1] von [z0] bis [z1] (Zone wie gesetzt).
void _pad(
  _B b,
  double x0,
  double y0,
  double x1,
  double y1,
  double z0,
  double z1, {
  double r = 0.04,
}) => b.roundBox(x0, y0, z0, x1, y1, z1, r, mat: Mat.soft, segments: 2);

/// [n] Kissen nebeneinander entlang x zwischen [x0] und [x1].
void _padsX(
  _B b,
  int n,
  double x0,
  double x1,
  double y0,
  double y1,
  double z0,
  double z1,
) {
  const gap = 0.012;
  for (var i = 0; i < n; i++) {
    final a = x0 + (x1 - x0) * i / n + (i == 0 ? 0.004 : gap / 2);
    final e = x0 + (x1 - x0) * (i + 1) / n - (i == n - 1 ? 0.004 : gap / 2);
    _pad(b, a, y0, e, y1, z0, z1);
  }
}

/// [n] Kissen hintereinander entlang y zwischen [y0] und [y1].
void _padsY(
  _B b,
  int n,
  double y0,
  double y1,
  double x0,
  double x1,
  double z0,
  double z1,
) {
  const gap = 0.012;
  for (var i = 0; i < n; i++) {
    final a = y0 + (y1 - y0) * i / n + (i == 0 ? 0.004 : gap / 2);
    final e = y0 + (y1 - y0) * (i + 1) / n - (i == n - 1 ? 0.004 : gap / 2);
    _pad(b, x0, a, x1, e, z0, z1);
  }
}

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
  _feetAt(b, [
    for (final sx in [-1.0, 1.0])
      for (final sy in [-1.0, 1.0])
        Offset(sx * (w / 2 - 0.07), sy * (d / 2 - 0.07)),
  ], feet);
  b.inZone(_frame.id, () {
    _pad(b, -w / 2, y0, w / 2, d / 2, feet, zb, r: 0.035);
    _pad(b, -w / 2, y0, w / 2, y0 + back, zb - 0.01, h, r: 0.05);
    for (final sx in [-1.0, 1.0]) {
      _pad(
        b,
        sx * w / 2,
        y0,
        sx * (w / 2 - arm),
        d / 2,
        zb - 0.01,
        armTop,
        r: 0.05,
      );
    }
  });
  b.inZone(_cushions.id, () {
    final inner = w - 2 * arm;
    final n = seats ?? math.max(1, (inner / 0.75).round());
    _padsX(
      b,
      n,
      -w / 2 + arm,
      w / 2 - arm,
      y0 + back,
      d / 2 - 0.012,
      zb,
      seatTop,
    );
    // Rückenkissen, leicht nach hinten geneigt.
    final cb = math.min(0.18, 0.2 * d);
    const gap = 0.012;
    for (var i = 0; i < n; i++) {
      final x0 = -w / 2 + arm + inner * i / n + (i == 0 ? 0.004 : gap / 2);
      final x1 =
          -w / 2 + arm + inner * (i + 1) / n - (i == n - 1 ? 0.004 : gap / 2);
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

/// Ecksofa: Schenkel oben (volle Breite) und links (volle Tiefe), Lehnen
/// außen (-y und -x), Armlehnen an den Schenkelenden.
void _cornerSofa(_B b, double w, double d, double h) {
  final t = math.min(0.42 * math.max(w, d), 0.5 * math.min(w, d));
  final feet = math.min(0.07, h * 0.09);
  final zb = h * 0.4, seatTop = h * 0.53, armTop = h * 0.7;
  final back = math.min(0.2, 0.24 * t);
  final arm = math.min(0.18, 0.2 * t);
  final x0 = -w / 2, y0 = -d / 2;
  _feetAt(b, [
    Offset(x0 + 0.07, y0 + 0.07),
    Offset(w / 2 - 0.07, y0 + 0.07),
    Offset(w / 2 - 0.07, y0 + t - 0.07),
    Offset(x0 + 0.07, d / 2 - 0.07),
    Offset(x0 + t - 0.07, d / 2 - 0.07),
    Offset(x0 + t - 0.07, y0 + t - 0.07),
  ], feet);
  b.inZone(_frame.id, () {
    b.prism(
      [
        Offset(x0, y0),
        Offset(w / 2, y0),
        Offset(w / 2, y0 + t),
        Offset(x0 + t, y0 + t),
        Offset(x0 + t, d / 2),
        Offset(x0, d / 2),
      ],
      feet,
      zb,
      mat: Mat.soft,
    );
    _pad(b, x0, y0, w / 2, y0 + back, zb - 0.01, h, r: 0.05);
    _pad(b, x0, y0, x0 + back, d / 2, zb - 0.01, h, r: 0.05);
    _pad(b, w / 2 - arm, y0, w / 2, y0 + t, zb - 0.01, armTop, r: 0.05);
    _pad(b, x0, d / 2 - arm, x0 + t, d / 2, zb - 0.01, armTop, r: 0.05);
  });
  b.inZone(_cushions.id, () {
    // Oberer Schenkel mit Eckkissen, linker Schenkel darunter.
    final lx = w / 2 - arm - (x0 + back);
    final nx = math.max(1, (lx / 0.8).round());
    _padsX(b, nx, x0 + back, w / 2 - arm, y0 + back, y0 + t, zb, seatTop);
    final ly = d / 2 - arm - (y0 + t);
    if (ly > 0.2) {
      _padsY(
        b,
        math.max(1, (ly / 0.8).round()),
        y0 + t,
        d / 2 - arm,
        x0 + back,
        x0 + t,
        zb,
        seatTop,
      );
    }
    // Rückenkissen entlang beider Lehnen.
    final cb = math.min(0.17, 0.2 * t);
    _padsX(
      b,
      nx,
      x0 + back + cb,
      w / 2 - arm,
      y0 + back,
      y0 + back + cb,
      seatTop,
      h - 0.04,
    );
    final ry = d / 2 - arm - (y0 + back);
    _padsY(
      b,
      math.max(1, (ry / 0.8).round()),
      y0 + back,
      d / 2 - arm,
      x0 + back,
      x0 + back + cb,
      seatTop,
      h - 0.04,
    );
  });
}

/// Niedriges Board (Front +y): Füße, Korpus, Fronten mit Griffleisten.
void _board(_B b, double w, double d, double h, {int? doors}) => cabinet(
  b,
  w,
  d,
  0,
  h,
  cols: doors ?? math.max(2, (w / 0.55).round()),
  legs: math.min(0.1, h * 0.2),
);

/// Offenes Regal: Seiten, Deckel, Boden auf Sockel, dünne Rückwand (Zone
/// `back`) und [rows] Fächer. Liefert die Oberkanten der Böden.
List<double> _openShelf(_B b, double w, double d, double h, int rows) {
  const t = 0.02, plinth = 0.06;
  b.box(-w / 2, -d / 2, 0, -w / 2 + t, d / 2, h);
  b.box(w / 2 - t, -d / 2, 0, w / 2, d / 2, h);
  b.box(-w / 2 + t, -d / 2, h - t, w / 2 - t, d / 2, h);
  b.box(-w / 2 + t, -d / 2 + 0.02, 0, w / 2 - t, d / 2 - 0.02, plinth);
  final tops = <double>[];
  for (var i = 0; i < rows; i++) {
    final z = plinth + (h - t - plinth) * i / rows;
    b.box(-w / 2 + t, -d / 2 + 0.012, z, w / 2 - t, d / 2, z + t);
    tops.add(z + t);
  }
  b.inZone('back', () {
    b.box(-w / 2 + t, -d / 2, plinth, w / 2 - t, -d / 2 + 0.012, h - t);
  });
  return tops;
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
    againstWall: true,
    zones: const [_frame, _cushions, _feet],
    build: (b, w, d, h) => _upholstered(b, w, d, h),
  ),
  // 2D: L-Form, Schenkel oben (volle Breite) und links (volle Tiefe).
  'sofa_corner': FurnitureSpec(
    height: 0.85,
    againstWall: true,
    zones: const [_frame, _cushions, _feet],
    build: _cornerSofa,
  ),
  // 2D: Quadrat mit Lehne oben und zwei Armlehnen.
  'armchair': FurnitureSpec(
    height: 0.85,
    zones: const [_frame, _cushions, _feet],
    build: (b, w, d, h) => _upholstered(b, w, d, h, seats: 1),
  ),
  // 2D: Platte mit abgesetztem Innenrahmen (Ablage darunter).
  'coffee_table': FurnitureSpec(
    height: 0.42,
    zones: const [kTopZone, ColorZone('legs', 'Gestell und Ablage')],
    build: (b, w, d, h) {
      const top = 0.035;
      final r = math.min(0.06, 0.12 * math.min(w, d));
      b.roundBox(-w / 2, -d / 2, h - top, w / 2, d / 2, h, r, segments: 3);
      b.inZone('legs', () {
        final leg = math.min(0.04, 0.08 * math.min(w, d));
        tableLegs(b, w, d, h - top, leg: leg, inset: 0.035);
        // Ablage zwischen den Beinen.
        final m = 0.035 + leg;
        b.box(-w / 2 + m, -d / 2 + m, 0.1, w / 2 - m, d / 2 - m, 0.118);
      });
    },
  ),
  // Runder Beistelltisch auf einer Säule mit Tellerfuß.
  'side_table': FurnitureSpec(
    height: 0.52,
    zones: const [kTopZone, ColorZone('legs', 'Fuß')],
    build: (b, w, d, h) {
      final rx = w / 2, ry = d / 2;
      b.ellipsoid(0, 0, rx, ry, h - 0.025, h, segments: 20);
      b.inZone('legs', () {
        final r = math.min(rx, ry);
        b.cylinder(0, 0, 0.022, 0.012, h - 0.025, segments: 8);
        b.ellipsoid(0, 0, r * 0.55, r * 0.55, 0, 0.012, segments: 16);
      });
    },
  ),
  // Lowboard / Sideboard: Füße, Korpus, Fronten mit Griffleisten.
  'sideboard': FurnitureSpec(
    height: 0.55,
    againstWall: true,
    zones: const [kBodyZone, kFrontsZone, kHandlesZone],
    build: _board,
  ),
  // Alt (bis 0.9.26): Board mit Fernseher als ein Möbelstück. Heute sind
  // Board und Fernseher (Gerät) getrennt; alte Pläne zeigen hier beides.
  // Die Höhe schließt den Fernseher ein.
  'tv_board': FurnitureSpec(
    height: 1.0,
    againstWall: true,
    zones: const [kBodyZone, kFrontsZone, kHandlesZone, ...kTvZones],
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
  // Dünne Platte am Boden mit gerundeten Ecken und Randlinie.
  'rug': FurnitureSpec(
    height: 0.015,
    zones: const [ColorZone('rug', 'Teppich', Mat.rug)],
    build: (b, w, d, h) {
      final r = math.min(0.05, 0.1 * math.min(w, d));
      b.roundBox(
        -w / 2,
        -d / 2,
        0,
        w / 2,
        d / 2,
        h,
        r,
        mat: Mat.rug,
        segments: 2,
      );
      final m = 0.08 * math.min(w, d);
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
  // Topfpflanze als runder Busch: Topf mit Rand und Erde, kurzer Stamm,
  // eine Krone aus weichen Laubballen (ohne Kanten, von oben eine ruhige,
  // runde Form; die Blattrosette zeichnet 2D).
  'plant': FurnitureSpec(
    height: 1.0,
    zones: const [
      ColorZone('plant', 'Pflanze', Mat.green),
      ColorZone('pot', 'Topf'),
    ],
    build: (b, w, d, h) {
      final rx = w / 2, ry = d / 2;
      final r = math.min(rx, ry);
      final potH = math.min(0.36, 0.32 * h);
      final pr = 0.55 * r;
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
      final g = h - potH;
      b.cylinder(
        0,
        0,
        0.018,
        potH - 0.02,
        potH + g * 0.4,
        segments: 6,
        mat: Mat.green,
      );
      // Unten drei Ballen im Kreis, darüber die Hauptkrone, oben eine
      // kleine Kuppe.
      for (var i = 0; i < 3; i++) {
        final a = i * 2 * math.pi / 3 + 0.4;
        b.blob(
          rx * 0.38 * math.cos(a),
          ry * 0.38 * math.sin(a),
          potH + g * 0.36,
          rx * 0.6,
          ry * 0.6,
          g * 0.26,
          mat: Mat.green,
        );
      }
      b.blob(
        0,
        0,
        potH + g * 0.58,
        rx * 0.86,
        ry * 0.86,
        g * 0.3,
        mat: Mat.green,
      );
      b.blob(
        rx * 0.12,
        -ry * 0.1,
        potH + g * 0.8,
        rx * 0.5,
        ry * 0.5,
        g * 0.2,
        mat: Mat.green,
      );
    },
  ),
  // Offenes Regal mit Rückwand und Fächern.
  'shelf': FurnitureSpec(
    height: 1.8,
    againstWall: true,
    zones: const [kBodyZone, ColorZone('back', 'Rückwand')],
    build: (b, w, d, h) =>
        _openShelf(b, w, d, h, math.max(3, (h / 0.38).round())),
  ),
  // Bücherregal: offenes Regal, in jedem Fach ein paar Bücherreihen.
  'bookcase': FurnitureSpec(
    height: 2.0,
    againstWall: true,
    zones: const [
      kBodyZone,
      ColorZone('back', 'Rückwand'),
      ColorZone('books', 'Bücher', Mat.soft),
    ],
    build: (b, w, d, h) {
      final rows = math.max(3, (h / 0.36).round());
      final tops = _openShelf(b, w, d, h, rows);
      const t = 0.02;
      final inner = w - 2 * t;
      b.zone = 'books';
      for (var i = 0; i < tops.length; i++) {
        final z = tops[i];
        final next = i + 1 < tops.length ? tops[i + 1] - t : h - t;
        final room = next - z;
        if (room < 0.12) continue;
        // Zwei, drei Reihen verschieden hoher Bücher, eine Lücke.
        final groups = [
          (0.04, 0.34, 0.78),
          (0.38, 0.62, 0.66),
          if (i.isEven) (0.7, 0.92, 0.84) else (0.75, 0.86, 0.58),
        ];
        for (final (a, e, hf) in groups) {
          final x0 = -w / 2 + t + inner * a, x1 = -w / 2 + t + inner * e;
          final bz = z + room * hf;
          b.box(x0, -d / 2 + 0.03, z, x1, d / 2 - 0.03, bz, mat: Mat.soft);
          // Buchrücken als Linien.
          final n = ((x1 - x0) / 0.035).floor();
          for (var k = 1; k < n; k++) {
            final x = x0 + (x1 - x0) * k / n;
            b.line(
              V3(x, d / 2 - 0.03, z + 0.01),
              V3(x, d / 2 - 0.03, bz - 0.01),
            );
          }
        }
      }
    },
  ),
};
