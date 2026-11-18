import 'dart:math' as math;

import '../model.dart';
import 'catalog.dart';

/// Türfugen und Griffe als Linien auf der Front (+y) eines Korpus der Höhe
/// [top]. Keine Geometrie, nur angedeutet.
void _doorLines(
  ModelBuilder b,
  double w,
  double d,
  double top, {
  int doors = 1,
}) {
  final f = d / 2;
  for (var i = 0; i < doors; i++) {
    final x0 = -w / 2 + w * i / doors, x1 = -w / 2 + w * (i + 1) / doors;
    // Fugen als Rahmen der Türfront.
    b.polyline([
      V3(x0 + 0.01, f, 0.08),
      V3(x1 - 0.01, f, 0.08),
      V3(x1 - 0.01, f, top - 0.04),
      V3(x0 + 0.01, f, top - 0.04),
    ], closed: true);
    // Griff als kurze senkrechte Linie nahe der Mitte.
    final hx = i.isEven ? x1 - 0.06 : x0 + 0.06;
    b.line(V3(hx, f, top - 0.2), V3(hx, f, top - 0.08));
  }
}

/// 3D-Modelle der Kategorie „kitchen“.
final Map<String, FurnitureSpec> kitchenModels = {
  // 2D: Platte in der Mitte (20-80 % x 24-76 %), Stühle an den langen Seiten
  // oben und unten, bei genug Tiefe auch an den Stirnseiten.
  'dining_table': FurnitureSpec(
    height: 0.9,
    build: (b, w, d, h) {
      const topZ = 0.75, plate = 0.04;
      final tx0 = -w * 0.3, tx1 = w * 0.3, ty0 = -d * 0.26, ty1 = d * 0.26;
      // Tischplatte und vier Beine.
      b.box(tx0, ty0, topZ - plate, tx1, ty1, topZ);
      const l = 0.06, o = 0.05;
      for (final x in [tx0 + o, tx1 - o - l]) {
        for (final y in [ty0 + o, ty1 - o - l]) {
          b.box(x, y, 0, x + l, y + l, topZ - plate);
        }
      }
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
    build: (b, w, d, h) {
      b.box(-w / 2, -d / 2, 0, w / 2, d / 2, h);
      // Türen etwa alle 0,6 m (wie im Symbol: Breite / Tiefe).
      _doorLines(
        b,
        w,
        d,
        h,
        doors: math.max(1, (w / math.max(d, 0.3)).round()),
      );
    },
  ),
  // 2D: vier Kochstellen (Ring + innerer Ring) im Raster 30/70 %.
  'stove': FurnitureSpec(
    height: 0.9,
    build: (b, w, d, h) {
      // Korpus 2 mm unter h, damit die Linien auf der Platte nicht flimmern.
      b.box(-w / 2, -d / 2, 0, w / 2, d / 2, h - 0.002);
      // Kochfeld: vier Ringe als Linien auf der Platte.
      final r = 0.15 * math.min(w, d);
      for (final fx in [0.3, 0.7]) {
        for (final fy in [0.3, 0.7]) {
          final cx = (fx - 0.5) * w, cy = (fy - 0.5) * d;
          b.ellipseLines(cx, cy, r, r, h);
          b.ellipseLines(cx, cy, r * 0.45, r * 0.45, h, segments: 12);
        }
      }
      // Backofenfenster und Griffstange als Linien an der Front.
      final f = d / 2;
      b.polyline([
        V3(-w / 2 + 0.07, f, 0.2),
        V3(w / 2 - 0.07, f, 0.2),
        V3(w / 2 - 0.07, f, h - 0.17),
        V3(-w / 2 + 0.07, f, h - 0.17),
      ], closed: true);
      b.line(V3(-w / 2 + 0.1, f, h - 0.1), V3(w / 2 - 0.1, f, h - 0.1));
    },
  ),
  // 2D: Becken links (8-58 % x 20-88 %), Hahn oben an der Rückseite,
  // Abtropfrillen rechts.
  'sink': FurnitureSpec(
    height: 0.9,
    build: (b, w, d, h) {
      // Korpus 2 mm unter h, damit die Linien auf der Platte nicht flimmern.
      b.box(-w / 2, -d / 2, 0, w / 2, d / 2, h - 0.002);
      final bx0 = -w / 2 + 0.08 * w, bx1 = -w / 2 + 0.58 * w;
      final by0 = -d / 2 + 0.2 * d, by1 = -d / 2 + 0.88 * d;
      // Becken und Abfluss als Linien auf der Platte.
      b.rectLines(bx0, by0, bx1, by1, h);
      final cx = (bx0 + bx1) / 2;
      b.ellipseLines(cx, (by0 + by1) / 2, 0.03, 0.03, h, segments: 10);
      // Hahn: kurze Linie hinter dem Becken.
      b.line(V3(cx, -d / 2 + 0.06 * d, h), V3(cx, by0, h));
      // Abtropfrillen rechts.
      for (var i = 0; i < 4; i++) {
        final y = -d / 2 + (0.3 + i * 0.15) * d;
        b.line(V3(w * 0.16, y, h), V3(w * 0.42, y, h));
      }
      _doorLines(b, w, d, h, doors: math.max(1, (w / 0.5).round()));
    },
  ),
  // 2D: Rahmen, Gefrierfach-Linie nahe der Front (+y), zwei Griffe.
  'fridge': FurnitureSpec(
    height: 1.8,
    build: (b, w, d, h) {
      b.box(-w / 2, -d / 2, 0, w / 2, d / 2, h);
      final f = d / 2;
      // Fuge zwischen Gefrier- (unten) und Kühlteil, senkrechte Griffe.
      final split = h * 0.32;
      b.line(V3(-w / 2, f, split), V3(w / 2, f, split));
      final hx = w / 2 - 0.07;
      b.line(V3(hx, f, split + 0.06), V3(hx, f, split + 0.4));
      b.line(V3(hx, f, split - 0.36), V3(hx, f, split - 0.06));
    },
  ),
};
