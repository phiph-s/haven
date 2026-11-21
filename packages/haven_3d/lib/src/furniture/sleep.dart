import 'dart:math' as math;

import '../model.dart';
import 'catalog.dart';
import 'parts.dart';

const _frame = ColorZone('frame', 'Bettgestell');
const _bedding = ColorZone('bedding', 'Bettdecke', Mat.soft);
const _pillows = ColorZone('pillows', 'Kissen', Mat.soft);

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
    againstWall: true,
    zones: const [_frame, _bedding, _pillows],
    build: (b, w, d, h) => _bed(b, w, d, h, dbl: true),
  ),
  // Einzelbett: ein breites Kissen.
  'bed_single': FurnitureSpec(
    height: 0.85,
    againstWall: true,
    zones: const [_frame, _bedding, _pillows],
    build: (b, w, d, h) => _bed(b, w, d, h, dbl: false),
  ),
  // Zwei Schubladen mit Knöpfen, überstehende Platte; 2D: Kreis (Lampe).
  'nightstand': FurnitureSpec(
    height: 0.5,
    againstWall: true,
    zones: const [kBodyZone, kFrontsZone, kKnobsZone],
    build: (b, w, d, h) {
      cabinet(
        b,
        w,
        d,
        0,
        h,
        rows: const [0, 0.5, 1],
        grip: Grip.knob,
        legs: 0.08,
        overhang: true,
      );
      b.zone = null;
      b.ellipseLines(0, 0, 0.24 * math.min(w, d), 0.24 * math.min(w, d), h);
    },
  ),
  // Kommode: drei Schubladenreihen (bei Breite zwei Spalten), Knöpfe.
  'dresser': FurnitureSpec(
    height: 0.85,
    againstWall: true,
    zones: const [kBodyZone, kFrontsZone, kKnobsZone],
    build: (b, w, d, h) => cabinet(
      b,
      w,
      d,
      0,
      h,
      cols: w > 0.8 ? 2 : 1,
      rows: const [0, 0.36, 0.68, 1],
      grip: Grip.knob,
      plinth: 0.06,
      overhang: true,
    ),
  ),
  // Kleiderschrank: Sockel, Türen etwa alle 50 cm mit Stangengriffen,
  // Kleiderstange als Linie oben (wie im 2D-Symbol).
  'wardrobe': FurnitureSpec(
    height: 2.0,
    againstWall: true,
    zones: const [kBodyZone, kFrontsZone, kHandlesZone],
    build: (b, w, d, h) {
      final n = math.max(2, (w / 0.5).round());
      cabinet(b, w, d, 0, h - 0.002, cols: n, grip: Grip.pole, plinth: 0.07);
      b.line(
        V3(-w / 2 + 0.06 * w, -d / 2 + 0.45 * d, h - 0.002),
        V3(w / 2 - 0.06 * w, -d / 2 + 0.45 * d, h - 0.002),
      );
    },
  ),
  // Garderobe: Wandpaneel mit Hutablage und Haken, zwei Jacken, darunter
  // eine Bank mit Sitzkissen.
  'coat_rack': FurnitureSpec(
    height: 1.85,
    againstWall: true,
    zones: const [
      ColorZone('body', 'Paneel und Bank'),
      ColorZone('cushion', 'Sitzkissen', Mat.soft),
      ColorZone('coats', 'Jacken', Mat.soft),
      ColorZone('hooks', 'Haken', Mat.metal),
    ],
    build: (b, w, d, h) {
      final y0 = -d / 2;
      // Paneel und Hutablage.
      b.roundBox(
        -w / 2,
        y0,
        0.95,
        w / 2,
        y0 + 0.022,
        h - 0.06,
        0.02,
        segments: 2,
      );
      b.box(-w / 2, y0, h - 0.03, w / 2, y0 + math.min(0.28, d * 0.75), h);
      b.box(-w / 2 + 0.02, y0, h - 0.06, -w / 2 + 0.04, y0 + 0.2, h - 0.03);
      b.box(w / 2 - 0.04, y0, h - 0.06, w / 2 - 0.02, y0 + 0.2, h - 0.03);
      // Bank über die ganze Tiefe.
      const seat = 0.45;
      b.box(-w / 2, y0, seat - 0.03, w / 2, d / 2, seat);
      for (final sx in [-1.0, 1.0]) {
        b.box(
          sx * (w / 2 - 0.01) - 0.01,
          y0,
          0,
          sx * (w / 2 - 0.01) + 0.01,
          d / 2,
          seat - 0.03,
        );
      }
      b.box(-w / 2 + 0.02, y0 + 0.02, 0.08, w / 2 - 0.02, d / 2 - 0.02, 0.1);
      b.inZone('cushion', () {
        b.roundBox(
          -w / 2 + 0.02,
          y0 + 0.02,
          seat,
          w / 2 - 0.02,
          d / 2 - 0.02,
          seat + 0.05,
          0.04,
          mat: Mat.soft,
          segments: 2,
        );
      });
      // Haken, an zwei davon Jacken.
      final n = math.max(2, (w / 0.22).round());
      for (var i = 0; i < n; i++) {
        final x = -w / 2 + w * (i + 0.5) / n;
        b.inZone('hooks', () {
          b.box(
            x - 0.01,
            y0 + 0.022,
            1.52,
            x + 0.01,
            y0 + 0.08,
            1.54,
            mat: Mat.metal,
          );
        });
        final cw = math.min(0.17, math.min(x + w / 2, w / 2 - x) - 0.01);
        if ((i == 0 || i == n - 2) && cw > 0.06) {
          b.inZone('coats', () {
            b.loft(
              ModelBuilder.roundedRect(
                x - cw,
                y0 + 0.03,
                x + cw,
                y0 + 0.17,
                0.05,
                segments: 2,
              ),
              0.98,
              ModelBuilder.roundedRect(
                x - cw * 0.6,
                y0 + 0.04,
                x + cw * 0.6,
                y0 + 0.12,
                0.04,
                segments: 2,
              ),
              1.52,
              mat: Mat.soft,
            );
          });
        }
      }
    },
  ),
};
