import 'dart:math' as math;

import '../model.dart';
import 'catalog.dart';

/// Gemeinsamer Bettaufbau: Rahmen, Matratze und Kopfteil als Blöcke; Kissen
/// und Deckenfalte nur als Linien auf der Matratze. Kopfende oben (-y).
void _bed(ModelBuilder b, double w, double d, double h, {required bool dbl}) {
  final hw = w / 2, hd = d / 2;
  final mz = h * 0.58; // Liegefläche
  const rail = 0.06;
  // Kopfteil über die ganze Breite.
  b.box(-hw, -hd, 0, hw, -hd + rail, h);
  // Bett als ein Block: kein abgesetzter Unterbau, damit die Draufsicht
  // nur einen Umriss zeigt.
  b.box(-hw, -hd + rail, 0, hw, hd, mz, mat: Mat.soft);
  // Kissen als Rechtecke auf der Liegefläche (der Renderer hebt Linien
  // selbst leicht von der Fläche ab).
  final ph = math.min(0.35, d * 0.16);
  final py0 = -hd + rail + 0.05;
  const g = 0.08;
  if (dbl) {
    b.rectLines(-hw + g, py0, -g / 2, py0 + ph, mz);
    b.rectLines(g / 2, py0, hw - g, py0 + ph, mz);
  } else {
    b.rectLines(-hw + g, py0, hw - g, py0 + ph, mz);
  }
  // Deckenkante quer ab 35 % der Tiefe.
  final fy = -hd + 0.35 * d;
  b.line(V3(-hw, fy, mz), V3(hw, fy, mz));
}

/// 3D-Modelle der Kategorie „sleep“.
final Map<String, FurnitureSpec> sleepModels = {
  // Doppelbett: Kopfteil 0,9 m, Liegefläche bei ca. 0,52 m.
  'bed_double': FurnitureSpec(
    height: 0.9,
    build: (b, w, d, h) => _bed(b, w, d, h, dbl: true),
  ),
  // Einzelbett: ein breites Kissen.
  'bed_single': FurnitureSpec(
    height: 0.85,
    build: (b, w, d, h) => _bed(b, w, d, h, dbl: false),
  ),
  // Ein Korpus; Schubladenfuge und Griffe vorn (+y), Kreis auf der Platte.
  'nightstand': FurnitureSpec(
    height: 0.5,
    build: (b, w, d, h) {
      final hw = w / 2, hd = d / 2;
      b.box(-hw, -hd, 0, hw, hd, h);
      final mid = h * 0.5;
      b.line(V3(-hw, hd, mid), V3(hw, hd, mid));
      for (final z in [h * 0.25, h * 0.75]) {
        b.line(V3(-w * 0.15, hd, z), V3(w * 0.15, hd, z));
      }
      b.ellipseLines(0, 0, 0.24 * math.min(w, d), 0.24 * math.min(w, d), h);
    },
  ),
  // Ein Korpus; Türfugen vorn (+y), Griffstriche und Kleiderstange oben.
  'wardrobe': FurnitureSpec(
    height: 2.0,
    build: (b, w, d, h) {
      final hw = w / 2, hd = d / 2;
      b.box(-hw, -hd, 0, hw, hd, h - 0.002);
      final n = math.max(2, (w / math.max(d, 1)).round());
      for (var i = 1; i < n; i++) {
        final x = -hw + w * i / n;
        b.line(V3(x, hd, 0.05), V3(x, hd, h - 0.05));
      }
      // Griffe: kurze senkrechte Striche neben jeder Fuge.
      for (var i = 1; i < n; i++) {
        final x = -hw + w * i / n;
        for (final s in [-1.0, 1.0]) {
          b.line(
            V3(x + s * 0.04, hd, h * 0.45),
            V3(x + s * 0.04, hd, h * 0.55),
          );
        }
      }
      // Kleiderstange wie im 2D-Symbol.
      b.line(
        V3(-hw + 0.06 * w, -hd + 0.45 * d, h),
        V3(hw - 0.06 * w, -hd + 0.45 * d, h),
      );
    },
  ),
};
