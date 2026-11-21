import 'dart:math' as math;

import '../model.dart';

// Gemeinsame Bauteile der Möbel: Korpus mit Fronten, Stuhl, Beine. Lokales
// System wie im Katalog (Front +y, Rückseite/Wand -y, Boden z = 0).

const ColorZone kFrontsZone = ColorZone('fronts', 'Fronten');
const ColorZone kHandlesZone = ColorZone('handles', 'Griffe', Mat.metal);
const ColorZone kKnobsZone = ColorZone('handles', 'Knöpfe', Mat.metal);
const ColorZone kTopZone = ColorZone('top', 'Platte');
const ColorZone kLegsZone = ColorZone('legs', 'Beine');
const ColorZone kFrameZone = ColorZone('frame', 'Gestell');
const ColorZone kSeatZone = ColorZone('seat', 'Sitz');
const ColorZone kWorktopZone = ColorZone('worktop', 'Arbeitsplatte');

/// Griff einer Front.
enum Grip {
  /// Waagerechte Leiste oben auf der Front (Schubladen, Unterschränke).
  bar,

  /// Senkrechte Stange an der Öffnungsseite (Türen, Hochschränke).
  pole,

  /// Runder Knopf in der Mitte (Kommode, Nachttisch).
  knob,

  /// Waagerechte Leiste unten (Oberschränke, die man von unten greift).
  low,

  /// Grifflos.
  none,
}

/// Tiefe vor dem Korpus, die Fronten und Griffe brauchen.
double frontDepth(Grip g) => g == Grip.none ? 0.018 : 0.034;

/// Korpus mit Fronten: [cols] × [rows] Fronten (Anteile der Höhe von unten,
/// z. B. `[0, 0.5, 1]`), Griffe [grip] (Zone `handles`), Fronten in Zone
/// `fronts`, der Korpus in der aktuellen Zone. Von [z0] bis [z1]; mit
/// [plinth] auf einem zurückgesetzten Sockel, mit [legs] auf vier Füßen.
/// [overhang]: Deckplatte steht vorn und seitlich etwas über.
void cabinet(
  ModelBuilder b,
  double w,
  double d,
  double z0,
  double z1, {
  int cols = 1,
  List<double> rows = const [0, 1],
  Grip grip = Grip.bar,
  double plinth = 0,
  double legs = 0,
  bool overhang = false,
  bool topPlate = true,
}) {
  final f = frontDepth(grip);
  final yFront = d / 2 - f; // Vorderkante des Korpus
  final bodyZone = b.zone;
  var zb = z0;
  if (legs > 0) {
    for (final sx in [-1.0, 1.0]) {
      for (final sy in [-1.0, 1.0]) {
        b.box(
          sx * (w / 2 - 0.04) - 0.018,
          sy * (d / 2 - f - 0.05) - 0.018,
          z0,
          sx * (w / 2 - 0.04) + 0.018,
          sy * (d / 2 - f - 0.05) + 0.018,
          z0 + legs,
        );
      }
    }
    zb += legs;
  } else if (plinth > 0) {
    b.box(
      -w / 2 + 0.01,
      -d / 2 + 0.01,
      z0,
      w / 2 - 0.01,
      yFront - 0.05,
      z0 + plinth,
    );
    zb += plinth;
  }
  final plate = topPlate ? 0.022 : 0.0;
  final o = overhang ? 0.012 : 0.0;
  b.box(-w / 2 + o, -d / 2, zb, w / 2 - o, yFront, z1 - plate);
  if (topPlate) {
    b.box(-w / 2, -d / 2, z1 - plate, w / 2, yFront + (overhang ? f : 0), z1);
  }
  // Fronten mit schmalen Fugen.
  const gap = 0.005;
  final fx0 = -w / 2 + o + 0.003, fx1 = w / 2 - o - 0.003;
  final fz0 = zb + 0.006, fz1 = z1 - plate - 0.005;
  for (var c = 0; c < cols; c++) {
    final x0 = fx0 + (fx1 - fx0) * c / cols + (c == 0 ? 0 : gap / 2);
    final x1 =
        fx0 + (fx1 - fx0) * (c + 1) / cols - (c == cols - 1 ? 0 : gap / 2);
    for (var r = 0; r + 1 < rows.length; r++) {
      final za = fz0 + (fz1 - fz0) * rows[r] + (r == 0 ? 0 : gap / 2);
      final ze =
          fz0 +
          (fz1 - fz0) * rows[r + 1] -
          (r == rows.length - 2 ? 0 : gap / 2);
      b.zone = kFrontsZone.id;
      b.box(x0, yFront, za, x1, yFront + 0.018, ze);
      b.zone = kHandlesZone.id;
      final y0 = yFront + 0.018, y1 = d / 2;
      final cx = (x0 + x1) / 2;
      final hw = math.min(0.08, (x1 - x0) * 0.22);
      switch (grip) {
        case Grip.bar:
          b.box(
            cx - hw,
            y0,
            ze - 0.05,
            cx + hw,
            y1,
            ze - 0.036,
            mat: Mat.metal,
          );
        case Grip.low:
          b.box(
            cx - hw,
            y0,
            za + 0.03,
            cx + hw,
            y1,
            za + 0.044,
            mat: Mat.metal,
          );
        case Grip.pole:
          // An der Öffnungsseite: Paare öffnen zur Mitte.
          final left = cols == 1 ? false : c.isOdd;
          final x = left ? x0 + 0.05 : x1 - 0.05;
          final hz = math.min(0.18, (ze - za) * 0.3);
          final mz = za + (ze - za) * (ze - za > 1.2 ? 0.45 : 0.6);
          b.box(x - 0.007, y0, mz - hz, x + 0.007, y1, mz + hz, mat: Mat.metal);
        case Grip.knob:
          discY(
            b,
            cx,
            (za + ze) / 2,
            0.016,
            y0,
            y1,
            mat: Mat.metal,
            segments: 8,
          );
        case Grip.none:
          break;
      }
    }
  }
  b.zone = bodyZone;
}

/// Esszimmerstuhl um ([cx], [cy]), Lehne zur Seite `-y` (vor dem Drehen),
/// um [turn] gedreht (Bogenmaß). Gestell in Zone `frame`, Sitz in `seat`.
void diningChair(
  ModelBuilder b,
  double cx,
  double cy,
  double w,
  double d, {
  double turn = 0,
  double seatZ = 0.46,
  double backZ = 0.86,
}) {
  final prev = b.zone;
  b.placed(V3(cx, cy, 0), turn, () {
    const leg = 0.032, t = 0.03;
    b.zone = kFrameZone.id;
    for (final sx in [-1.0, 1.0]) {
      for (final sy in [-1.0, 1.0]) {
        final x = sx * (w / 2 - leg / 2 - 0.01);
        final y = sy * (d / 2 - leg / 2 - 0.01);
        // Hinten bis zur Lehne hoch.
        b.boxC(x, y, leg, leg, 0, sy < 0 ? backZ : seatZ - t);
      }
    }
    // Lehne: Querholm oben und eine Mittelplatte.
    final by = -d / 2 + 0.01 + leg / 2;
    b.box(
      -w / 2 + 0.01,
      by - 0.012,
      backZ - 0.1,
      w / 2 - 0.01,
      by + 0.012,
      backZ,
    );
    b.zone = kSeatZone.id;
    b.roundBox(
      -w / 2,
      -d / 2,
      seatZ - t,
      w / 2,
      d / 2,
      seatZ,
      0.03,
      segments: 2,
    );
  });
  b.zone = prev;
}

/// Vier Beine ([leg] stark) unter einer Platte [w] × [d], [inset] vom Rand,
/// von 0 bis [z].
void tableLegs(
  ModelBuilder b,
  double w,
  double d,
  double z, {
  double leg = 0.045,
  double inset = 0.05,
  bool round = false,
}) {
  for (final sx in [-1.0, 1.0]) {
    for (final sy in [-1.0, 1.0]) {
      final x = sx * (w / 2 - inset - leg / 2);
      final y = sy * (d / 2 - inset - leg / 2);
      if (round) {
        b.cylinder(x, y, leg / 2, 0, z, segments: 8);
      } else {
        b.boxC(x, y, leg, leg, 0, z);
      }
    }
  }
}

/// Runde Scheibe in einer Ebene `y` = [y0] … [y1] (Bullauge, Knopf):
/// Mitte ([cx], [cz]), Radius [r].
void discY(
  ModelBuilder b,
  double cx,
  double cz,
  double r,
  double y0,
  double y1, {
  Mat mat = Mat.body,
  int segments = 18,
}) {
  final pts = [
    for (var i = 0; i < segments; i++)
      (
        cx + r * math.cos(2 * math.pi * i / segments),
        cz + r * math.sin(2 * math.pi * i / segments),
      ),
  ];
  b.face([for (final (x, z) in pts) V3(x, y1, z)], const V3(0, 1, 0), mat: mat);
  b.face(
    [for (final (x, z) in pts.reversed) V3(x, y0, z)],
    const V3(0, -1, 0),
    mat: mat,
  );
  for (var i = 0; i < segments; i++) {
    final (ax, az) = pts[i];
    final (bx, bz) = pts[(i + 1) % segments];
    final mx = (ax + bx) / 2 - cx, mz = (az + bz) / 2 - cz;
    b.face(
      [V3(ax, y0, az), V3(bx, y0, bz), V3(bx, y1, bz), V3(ax, y1, az)],
      V3(mx, 0, mz),
      mat: mat,
      smooth: true,
    );
  }
}

/// Front-Waschmaschine oder Trockner: Gehäuse, Bedienleiste, Bullauge.
void washer(ModelBuilder b, double w, double d, double h) {
  final yf = d / 2 - 0.03;
  b.roundBox(
    -w / 2,
    -d / 2,
    0,
    w / 2,
    yf,
    h,
    0.02,
    mat: Mat.ceramic,
    segments: 2,
  );
  b.zone = null;
  b.box(
    -w / 2 + 0.03,
    yf,
    h - 0.13,
    w / 2 - 0.03,
    yf + 0.008,
    h - 0.03,
    mat: Mat.dark,
  );
  discY(
    b,
    w / 2 - 0.1,
    h - 0.08,
    0.025,
    yf + 0.008,
    yf + 0.02,
    mat: Mat.metal,
    segments: 10,
  );
  b.zone = 'door';
  final r = math.min(0.36 * w, 0.32 * (h - 0.15));
  final cz = (h - 0.13) / 2 + 0.02;
  discY(b, 0, cz, r, yf, yf + 0.02, mat: Mat.metal, segments: 22);
  b.zone = null;
  discY(b, 0, cz, r * 0.72, yf + 0.02, d / 2, mat: Mat.screen, segments: 22);
}
