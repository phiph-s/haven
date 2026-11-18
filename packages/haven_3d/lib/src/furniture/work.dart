import 'dart:math' as math;

import '../model.dart';
import 'catalog.dart';

/// 3D-Modelle der Kategorie „work“.
final Map<String, FurnitureSpec> workModels = {
  // 2D: Platte, Monitor an der Oberkante (y < 0), Tastatur in der Mitte.
  // Gesamthöhe 1,15 m: Platte bei 0,75 m, Monitor ragt darüber hinaus.
  'desk': FurnitureSpec(
    height: 1.15,
    build: (b, w, d, h) {
      final top = h * 0.65;
      const t = 0.035;
      final leg = math.min(0.05, math.min(w, d) * 0.1);
      final inset = math.min(0.04, math.min(w, d) * 0.05);
      // Platte.
      b.box(-w / 2, -d / 2, top - t, w / 2, d / 2, top);
      // Vier Beine.
      for (final sx in [-1, 1]) {
        for (final sy in [-1, 1]) {
          b.boxC(
            sx * (w / 2 - inset - leg / 2),
            sy * (d / 2 - inset - leg / 2),
            leg,
            leg,
            0,
            top - t,
          );
        }
      }
      // Monitor: eine dünne, senkrechte Platte auf flachem Fuß.
      final mw = w * 0.4, mh = math.min(h - top - 0.03, 0.32);
      final my = -d / 2 + d * 0.17;
      final mz = top + 0.05;
      b.boxC(0, my, mw * 0.3, d * 0.08, top, mz);
      b.boxC(0, my, mw, 0.025, mz, mz + mh);
      // Bildschirmrand als Linien auf der Vorderseite (+y).
      final fy = my + 0.0125, e = 0.02;
      b.polyline([
        V3(-mw / 2 + e, fy, mz + e),
        V3(mw / 2 - e, fy, mz + e),
        V3(mw / 2 - e, fy, mz + mh - e),
        V3(-mw / 2 + e, fy, mz + mh - e),
      ], closed: true);
      // Tastatur nur als Linien auf der Platte.
      final kw = w * 0.28, kd = d * 0.16, ky = d * 0.06;
      b.rectLines(-kw / 2, ky - kd / 2, kw / 2, ky + kd / 2, top);
    },
  ),
  // 2D: runder Sitz, Fünfstern-Fuß, Lehne an der Oberkante (y < 0).
  'office_chair': FurnitureSpec(
    height: 1.0,
    build: (b, w, d, h) {
      final u = math.min(w, d);
      final seatTop = h * 0.46;
      final seatT = h * 0.06;
      final cy = d * 0.06;
      final r = u * 0.34;
      // Fünfstern-Fuß nur als Linien auf dem Boden.
      final rb = math.min(u * 0.46, math.min(w / 2, d / 2 - cy));
      for (var i = 0; i < 5; i++) {
        final a = i * 2 * math.pi / 5 + math.pi / 2;
        b.line(V3(0, cy, 0), V3(math.cos(a) * rb, cy + math.sin(a) * rb, 0));
      }
      // Eine Säule.
      b.cylinder(0, cy, 0.03, 0, seatTop - seatT, segments: 8);
      // Sitzscheibe.
      b.cylinder(
        0,
        cy,
        r,
        seatTop - seatT,
        seatTop,
        segments: 12,
        mat: Mat.soft,
      );
      // Lehne: eine Platte an der Rückseite (y < 0), kurzer Steg zum Sitz.
      final bw = u * 0.64;
      b.box(-0.02, -d / 2, seatTop - seatT, 0.02, cy - r + 0.02, seatTop);
      b.box(
        -bw / 2,
        -d / 2,
        seatTop + h * 0.1,
        bw / 2,
        -d / 2 + 0.06,
        h,
        mat: Mat.soft,
      );
      b.box(-0.02, -d / 2, seatTop, 0.02, -d / 2 + 0.06, seatTop + h * 0.1);
    },
  ),
};
