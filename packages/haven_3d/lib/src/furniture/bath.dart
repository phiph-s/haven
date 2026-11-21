import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../model.dart';
import 'catalog.dart';
import 'parts.dart';

typedef _B = ModelBuilder;

const _ceramic = ColorZone('ceramic', 'Keramik', Mat.ceramic);
const _tap = ColorZone('tap', 'Armatur', Mat.metal);

/// Armatur: Säule auf dem Rand bei ([x], [y]) ab [z], Auslauf nach `+y`
/// (zur Mitte des Beckens) mit Länge [reach].
void _faucet(_B b, double x, double y, double z, {double reach = 0.12}) {
  b.inZone(_tap.id, () {
    b.cylinder(x, y, 0.018, z, z + 0.11, segments: 8, mat: Mat.metal);
    b.box(
      x - 0.012,
      y,
      z + 0.085,
      x + 0.012,
      y + reach,
      z + 0.11,
      mat: Mat.metal,
    );
    // Hebel nach hinten.
    b.box(
      x - 0.006,
      y - 0.06,
      z + 0.11,
      x + 0.006,
      y,
      z + 0.122,
      mat: Mat.metal,
    );
  });
}

/// 3D-Modelle der Kategorie „bath“. Sanitärteile sind Hohlkörper aus
/// Keramik ([ModelBuilder.basin]): Rand, Mulde und Boden, damit man von
/// oben und schräg hineinsieht.
final Map<String, FurnitureSpec> bathModels = {
  // 2D: Wanne mit Innenrand, Abfluss links. Armatur an der Abflussseite.
  'bathtub': FurnitureSpec(
    againstWall: true,
    height: 0.56,
    zones: const [_ceramic, _tap],
    build: (b, w, d, h) {
      const rim = 0.07;
      final n = 32;
      final outer = _B.superellipse(
        0,
        0,
        w / 2,
        d / 2,
        exponent: 7,
        segments: n,
      );
      final inner = _B.superellipse(
        0.01,
        0,
        w / 2 - rim,
        d / 2 - rim,
        exponent: 3.4,
        segments: n,
      );
      final floor = _B.superellipse(
        0.04,
        0,
        (w / 2 - rim) * 0.82,
        (d / 2 - rim) * 0.7,
        exponent: 3,
        segments: n,
      );
      b.basin(
        outer,
        inner,
        0,
        h,
        floor: floor,
        zFloor: math.min(0.14, h * 0.3),
        mat: Mat.ceramic,
        smoothOuter: true,
      );
      // Abfluss links am Boden, Armatur links auf dem Rand.
      final rd = math.min(0.03, d * 0.05);
      b.ellipseLines(
        -w / 2 + rim + 0.14 * w,
        0,
        rd,
        rd,
        math.min(0.14, h * 0.3),
      );
      _faucet(b, -w / 2 + rim / 2 + 0.005, 0, h, reach: 0.09);
    },
  ),
  // 2D: Tasse mit Kreuz (Diagonalen) und Abfluss in der Mitte. Glaswände an
  // den offenen Seiten (+y, +x), Brause an der Wand (-y).
  'shower': FurnitureSpec(
    againstWall: true,
    height: 2.0,
    zones: const [ColorZone('tray', 'Duschtasse', Mat.ceramic), _tap],
    build: (b, w, d, h) {
      final tray = math.min(0.06, h * 0.04);
      final n = 24;
      b.basin(
        _B.superellipse(0, 0, w / 2, d / 2, exponent: 10, segments: n),
        _B.superellipse(
          0,
          0,
          w / 2 - 0.035,
          d / 2 - 0.035,
          exponent: 8,
          segments: n,
        ),
        0,
        tray,
        floor: _B.superellipse(
          0,
          0,
          w / 2 - 0.06,
          d / 2 - 0.06,
          exponent: 8,
          segments: n,
        ),
        zFloor: tray - 0.02,
        mat: Mat.ceramic,
      );
      final rd = math.min(w, d) * 0.05;
      b.ellipseLines(0, 0, rd, rd, tray - 0.02);
      // Glaswände an den offenen Seiten, oben eine schmale Schiene.
      b.panel([
        V3(-w / 2, d / 2, tray),
        V3(w / 2, d / 2, tray),
        V3(w / 2, d / 2, h),
        V3(-w / 2, d / 2, h),
      ], mat: Mat.glass);
      b.panel([
        V3(w / 2, -d / 2, tray),
        V3(w / 2, d / 2, tray),
        V3(w / 2, d / 2, h),
        V3(w / 2, -d / 2, h),
      ], mat: Mat.glass);
      b.inZone(_tap.id, () {
        b.box(-w / 2, d / 2 - 0.02, h - 0.025, w / 2, d / 2, h, mat: Mat.metal);
        b.box(
          w / 2 - 0.02,
          -d / 2,
          h - 0.025,
          w / 2,
          d / 2 - 0.02,
          h,
          mat: Mat.metal,
        );
        // Brausestange an der Wand, Kopf oben, Thermostat unten.
        final y = -d / 2 + 0.03;
        b.cylinder(0, y, 0.012, 0.9, h - 0.1, segments: 6, mat: Mat.metal);
        b.box(-0.01, y, h - 0.12, 0.01, y + 0.2, h - 0.1, mat: Mat.metal);
        b.cylinder(
          0,
          y + 0.22,
          0.11,
          h - 0.13,
          h - 0.11,
          segments: 16,
          mat: Mat.metal,
        );
        b.box(-0.12, -d / 2, 0.95, 0.12, -d / 2 + 0.06, 1.02, mat: Mat.metal);
      });
    },
  ),
  // 2D: Spülkasten am oberen Rand (Wand, -y), Becken mit Sitz davor, Deckel
  // hochgeklappt am Spülkasten.
  'toilet': FurnitureSpec(
    againstWall: true,
    height: 0.8,
    zones: const [_ceramic, ColorZone('seat', 'Sitz und Deckel', Mat.ceramic)],
    build: (b, w, d, h) {
      final tankD = math.min(0.2, d * 0.28);
      final y0 = -d / 2;
      final rimZ = h * 0.5; // Oberkante Becken ~0,4 m
      // Becken: Ei-Form vor dem Spülkasten, vorn schmaler.
      final cy = y0 + tankD + (d - tankD) / 2 - 0.01;
      final rx = w / 2 * 0.94, ry = (d - tankD) / 2 + 0.01;
      const n = 24;
      List<Offset> egg(double sx, double sy, {double dy = 0}) => [
        for (final p in _B.ellipse(0, 0, rx * sx, ry * sy, segments: n))
          // Vorn (+y) schmaler.
          Offset(
            p.dx * (1 - 0.18 * (p.dy / ry).clamp(0.0, 1.0)),
            p.dy + cy + dy,
          ),
      ];
      // Fuß: verjüngt vom Boden zum Becken.
      b.loft(
        egg(0.55, 0.62, dy: -0.03),
        0,
        egg(0.9, 0.9),
        rimZ * 0.55,
        mat: Mat.ceramic,
        smooth: true,
      );
      b.basin(
        egg(1, 1),
        egg(0.74, 0.76, dy: 0.015),
        rimZ * 0.55,
        rimZ,
        floor: egg(0.3, 0.32, dy: 0.04),
        zFloor: rimZ - 0.16,
        mat: Mat.ceramic,
        smoothOuter: true,
      );
      // Spülkasten auf dem hinteren Rand, mit Drücker.
      final tw = w * 0.92;
      b.roundBox(
        -tw / 2,
        y0,
        rimZ - 0.05,
        tw / 2,
        y0 + tankD,
        h,
        0.03,
        mat: Mat.ceramic,
      );
      b.box(
        -tw * 0.2,
        y0,
        0,
        tw * 0.2,
        y0 + tankD * 0.7,
        rimZ - 0.05,
        mat: Mat.ceramic,
      );
      b.zone = null;
      b.cylinder(
        0,
        y0 + tankD / 2,
        0.025,
        h,
        h + 0.008,
        segments: 10,
        mat: Mat.metal,
      );
      // Sitz als Ring auf dem Becken, Deckel hochgeklappt am Spülkasten.
      b.inZone('seat', () {
        b.basin(
          egg(1.01, 1.0),
          egg(0.68, 0.7, dy: 0.015),
          rimZ,
          rimZ + 0.025,
          mat: Mat.ceramic,
          smoothOuter: true,
        );
        final lidH = math.min(2 * ry * 0.92, h - rimZ - 0.06);
        b.roundBox(
          -rx * 0.95,
          y0 + tankD,
          rimZ + 0.03,
          rx * 0.95,
          y0 + tankD + 0.025,
          rimZ + 0.03 + lidH,
          0.06,
          mat: Mat.ceramic,
        );
      });
    },
  ),
  // 2D: Becken mit Armatur hinten (Wand, -y). Hängt an der Wand,
  // Oberkante bei 0,85 m.
  'washbasin': FurnitureSpec(
    height: 0.17,
    elevation: 0.68,
    wallHung: true,
    zones: const [_ceramic, _tap],
    build: (b, w, d, h) {
      const n = 24;
      final back = math.min(0.11, d * 0.24); // Rand mit Armatur
      b.basin(
        _B.superellipse(0, 0, w / 2, d / 2, exponent: 4.5, segments: n),
        _B.superellipse(
          0,
          back / 2 + 0.005,
          w / 2 - 0.05,
          d / 2 - back / 2 - 0.045,
          exponent: 3,
          segments: n,
        ),
        0,
        h,
        floor: _B.superellipse(
          0,
          back / 2 + 0.02,
          w * 0.22,
          d * 0.18,
          exponent: 2.2,
          segments: n,
        ),
        zFloor: math.max(0.03, h - 0.13),
        mat: Mat.ceramic,
        smoothOuter: true,
      );
      final rd = math.min(w, d) * 0.035;
      b.ellipseLines(0, back / 2 + 0.02, rd, rd, math.max(0.03, h - 0.13));
      _faucet(b, 0, -d / 2 + back / 2 + 0.005, h, reach: 0.11);
    },
  ),
  // Waschmaschine (Front +y): Gehäuse, Bedienleiste, Bullauge.
  'washing_machine': FurnitureSpec(
    height: 0.85,
    againstWall: true,
    zones: const [
      ColorZone('body', 'Gehäuse', Mat.ceramic),
      ColorZone('door', 'Tür', Mat.metal),
    ],
    build: washer,
  ),
  // Spiegel: hängt an der Wand (Unterkante 1,1 m), Rahmen mit Glas davor.
  'mirror': FurnitureSpec(
    height: 0.8,
    elevation: 1.1,
    wallHung: true,
    zones: const [ColorZone('frame', 'Rahmen')],
    build: (b, w, d, h) {
      final y0 = -d / 2;
      const t = 0.025, f = 0.03;
      b.roundBox(-w / 2, y0, 0, w / 2, y0 + t, h, 0.03, segments: 2);
      b.zone = null;
      b.box(
        -w / 2 + f,
        y0 + t,
        f,
        w / 2 - f,
        y0 + t + 0.004,
        h - f,
        mat: Mat.metal,
      );
      b.panel([
        V3(-w / 2 + f, y0 + t + 0.006, f),
        V3(w / 2 - f, y0 + t + 0.006, f),
        V3(w / 2 - f, y0 + t + 0.006, h - f),
        V3(-w / 2 + f, y0 + t + 0.006, h - f),
      ], mat: Mat.glass);
    },
  ),
  // Spiegelschrank über dem Waschbecken (Unterkante 1,15 m): zwei Türen
  // mit Spiegelfront.
  'mirror_cabinet': FurnitureSpec(
    height: 0.7,
    elevation: 1.15,
    wallHung: true,
    zones: const [kBodyZone, kFrontsZone],
    build: (b, w, d, h) {
      final n = w > 0.5 ? 2 : 1;
      b.shifted(
        const V3(0, -0.002, 0),
        () => cabinet(b, w, d - 0.004, 0, h, cols: n, grip: Grip.none),
      );
      b.zone = null;
      const g = 0.025;
      for (var i = 0; i < n; i++) {
        final x0 = -w / 2 + w * i / n + g, x1 = -w / 2 + w * (i + 1) / n - g;
        b.panel([
          V3(x0, d / 2 - 0.0005, g),
          V3(x1, d / 2 - 0.0005, g),
          V3(x1, d / 2 - 0.0005, h - g),
          V3(x0, d / 2 - 0.0005, h - g),
        ], mat: Mat.glass);
      }
    },
  ),
};
