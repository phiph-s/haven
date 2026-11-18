import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../model.dart';
import 'catalog.dart';

/// Körper enden minimal unter der Linienhöhe, damit die Linien in der
/// Draufsicht nicht im Tiefenpuffer verschwinden.
const _lift = 0.002;

/// Abgerundetes Rechteck als geschlossener Linienzug auf Höhe [z].
void _roundedRectLines(
  ModelBuilder b,
  double x0,
  double y0,
  double x1,
  double y1,
  double r,
  double z,
) {
  const n = 5; // Segmente je Ecke
  final pts = <V3>[];
  // Eckmittelpunkte und Startwinkel, im Uhrzeigersinn ab oben links.
  final corners = [
    (x0 + r, y0 + r, math.pi),
    (x1 - r, y0 + r, 1.5 * math.pi),
    (x1 - r, y1 - r, 0.0),
    (x0 + r, y1 - r, 0.5 * math.pi),
  ];
  for (final (cx, cy, a0) in corners) {
    for (var i = 0; i <= n; i++) {
      final a = a0 + math.pi / 2 * i / n;
      pts.add(V3(cx + r * math.cos(a), cy + r * math.sin(a), z));
    }
  }
  b.polyline(pts, closed: true);
}

/// 3D-Modelle der Kategorie „bath“.
final Map<String, FurnitureSpec> bathModels = {
  // 2D: Wanne mit Innenrand, Abfluss links in der Mitte.
  'bathtub': FurnitureSpec(
    height: 0.55,
    build: (b, w, d, h) {
      // Ein Block; die Wannenöffnung nur als Linie auf der Oberseite.
      b.box(-w / 2, -d / 2, 0, w / 2, d / 2, h - _lift);
      final t = math.min(0.08, math.min(w, d) * 0.12);
      final r = math.min(w - 2 * t, d - 2 * t) * 0.3;
      _roundedRectLines(b, -w / 2 + t, -d / 2 + t, w / 2 - t, d / 2 - t, r, h);
      // Abfluss links.
      final rd = math.min(0.03, d * 0.05);
      b.ellipseLines(-w / 2 + t + 0.12 * (w - 2 * t), 0, rd, rd, h);
    },
  ),
  // 2D: Tasse mit Kreuz (Diagonalen) und Abfluss in der Mitte.
  'shower': FurnitureSpec(
    height: 2.0,
    build: (b, w, d, h) {
      final tray = math.min(0.08, h * 0.05);
      // Flache Tasse mit Abfluss.
      b.box(-w / 2, -d / 2, 0, w / 2, d / 2, tray - _lift);
      final rd = math.min(w, d) * 0.06;
      b.ellipseLines(0, 0, rd, rd, tray);
      // Glaswände an den beiden offenen Seiten (unten und rechts im Plan).
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
    },
  ),
  // 2D: Spülkasten am oberen Rand (y negativ), Becken als Oval darunter.
  'toilet': FurnitureSpec(
    height: 0.8,
    build: (b, w, d, h) {
      final bowlTop = h * 0.5;
      final tankD = d * 0.26;
      // Spülkasten an der Wand.
      b.box(-w * 0.46, -d / 2, 0, w * 0.46, -d / 2 + tankD, h);
      // Becken als niedriger Block, Sitz als Ellipse auf der Oberseite.
      final cy = -d / 2 + tankD + (d - tankD) / 2;
      final rx = w * 0.38, ry = (d - tankD) / 2;
      b.prism(
        [
          for (var i = 0; i < 16; i++)
            Offset(
              rx * math.cos(2 * math.pi * i / 16),
              cy + ry * math.sin(2 * math.pi * i / 16),
            ),
        ],
        0,
        bowlTop,
      );
      b.ellipseLines(0, cy, rx * 0.8, ry * 0.8, bowlTop);
    },
  ),
  // 2D: Rechteck, Ovalbecken, Hahn oben, Abfluss in der Beckenmitte.
  // Wandmontiert: Oberkante bei 0,8 m.
  'washbasin': FurnitureSpec(
    height: 0.2,
    elevation: 0.65,
    build: (b, w, d, h) {
      // Eine Platte; Becken als Ellipse auf der Oberseite.
      b.box(-w / 2, -d / 2, 0, w / 2, d / 2, h - _lift);
      final cy = -d / 2 + 0.24 * d + (0.66 * d) / 2;
      b.ellipseLines(0, cy, w * 0.34, d * 0.33, h);
      final rd = math.min(w, d) * 0.04;
      b.ellipseLines(0, cy, rd, rd, h);
    },
  ),
};
