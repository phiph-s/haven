import 'dart:math' as math;

import '../model.dart';
import 'catalog.dart';

const _frame = ColorZone('frame', 'Bettgestell');
const _bedding = ColorZone('bedding', 'Bettdecke', Mat.soft);
const _pillows = ColorZone('pillows', 'Kissen', Mat.soft);
const _fronts = ColorZone('fronts', 'Fronten');
const _handles = ColorZone('handles', 'Griffe', Mat.metal);

/// Gemeinsamer Bettaufbau: Gestell mit Kopfteil, Matratze, Kissen und eine
/// Decke über dem unteren Teil (ihre Kante ist die Falte). Kopfende oben
/// (-y).
void _bed(ModelBuilder b, double w, double d, double h, {required bool dbl}) {
  final hw = w / 2, hd = d / 2;
  final frameTop = h * 0.36; // Oberkante Gestell
  final mz = h * 0.58; // Liegefläche
  const head = 0.07;
  // Kopfteil über die ganze Breite, Gestell als Rahmen.
  b.roundBox(-hw, -hd, 0, hw, -hd + head, h, 0.02, segments: 2);
  b.box(-hw, -hd + head, 0.06, hw, hd, frameTop);
  // Matratze etwas eingerückt.
  b.inZone(_bedding.id, () {
    b.roundBox(
      -hw + 0.02,
      -hd + head,
      frameTop,
      hw - 0.02,
      hd - 0.02,
      mz,
      0.05,
      mat: Mat.soft,
      segments: 2,
    );
    // Decke ab 35 % der Tiefe, etwas über die Matratze hinaus.
    final fy = -hd + 0.35 * d;
    b.roundBox(
      -hw + 0.005,
      fy,
      mz - 0.1,
      hw - 0.005,
      hd - 0.005,
      mz + 0.035,
      0.05,
      mat: Mat.soft,
      segments: 2,
    );
  });
  // Kissen als flache Polster auf der Liegefläche.
  final ph = math.min(0.4, d * 0.17);
  final py0 = -hd + head + 0.04;
  const g = 0.07;
  b.inZone(_pillows.id, () {
    void pillow(double x0, double x1) => b.roundBox(
      x0,
      py0,
      mz,
      x1,
      py0 + ph,
      mz + 0.09,
      0.06,
      mat: Mat.soft,
      segments: 2,
    );
    if (dbl) {
      pillow(-hw + g, -g / 3);
      pillow(g / 3, hw - g);
    } else {
      pillow(-hw + g, hw - g);
    }
  });
}

/// 3D-Modelle der Kategorie „sleep“.
final Map<String, FurnitureSpec> sleepModels = {
  // Doppelbett: Kopfteil 0,9 m, Liegefläche bei ca. 0,52 m.
  'bed_double': FurnitureSpec(
    height: 0.9,
    zones: const [_frame, _bedding, _pillows],
    build: (b, w, d, h) => _bed(b, w, d, h, dbl: true),
  ),
  // Einzelbett: ein breites Kissen.
  'bed_single': FurnitureSpec(
    height: 0.85,
    zones: const [_frame, _bedding, _pillows],
    build: (b, w, d, h) => _bed(b, w, d, h, dbl: false),
  ),
  // Ein Korpus; Schubladenfuge und Griffe vorn (+y), Kreis auf der Platte.
  'nightstand': FurnitureSpec(
    height: 0.5,
    zones: const [kBodyZone, _handles],
    build: (b, w, d, h) {
      final hw = w / 2, hd = d / 2;
      b.box(-hw, -hd, 0, hw, hd - 0.016, h);
      final mid = h * 0.5;
      b.line(V3(-hw, hd - 0.016, mid), V3(hw, hd - 0.016, mid));
      b.inZone(_handles.id, () {
        for (final z in [h * 0.25, h * 0.75]) {
          b.box(
            -w * 0.12,
            hd - 0.016,
            z - 0.006,
            w * 0.12,
            hd,
            z + 0.006,
            mat: Mat.metal,
          );
        }
      });
      b.ellipseLines(0, 0, 0.24 * math.min(w, d), 0.24 * math.min(w, d), h);
    },
  ),
  // Ein Korpus; Türfugen vorn (+y), Griffstriche und Kleiderstange oben.
  'wardrobe': FurnitureSpec(
    height: 2.0,
    zones: const [kBodyZone, _fronts, _handles],
    build: (b, w, d, h) {
      final hw = w / 2, hd = d / 2;
      const f = 0.036; // Fronten und Griffe vor dem Korpus
      b.box(-hw, -hd, 0, hw, hd - f, h - 0.002);
      final n = math.max(2, (w / math.max(d, 1)).round());
      // Türen als flache Fronten, Griffe senkrecht neben jeder Fuge.
      for (var i = 0; i < n; i++) {
        final x0 = -hw + w * i / n + 0.003, x1 = -hw + w * (i + 1) / n - 0.003;
        b.inZone(_fronts.id, () {
          b.box(x0, hd - f, 0.06, x1, hd - 0.018, h - 0.03);
        });
        b.inZone(_handles.id, () {
          final x = i.isEven ? x1 - 0.05 : x0 + 0.05;
          b.box(
            x - 0.008,
            hd - 0.018,
            h * 0.42,
            x + 0.008,
            hd,
            h * 0.58,
            mat: Mat.metal,
          );
        });
      }
      // Kleiderstange wie im 2D-Symbol.
      b.line(
        V3(-hw + 0.06 * w, -hd + 0.45 * d, h),
        V3(hw - 0.06 * w, -hd + 0.45 * d, h),
      );
    },
  ),
};
