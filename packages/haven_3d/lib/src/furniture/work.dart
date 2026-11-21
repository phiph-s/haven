import 'dart:math' as math;

import '../model.dart';
import 'catalog.dart';

const _frame = ColorZone('frame', 'Gestell', Mat.dark);

/// 3D-Modelle der Kategorie „work“.
final Map<String, FurnitureSpec> workModels = {
  // 2D: Platte, Monitor an der Oberkante (y < 0), Tastatur in der Mitte.
  // Gesamthöhe 1,15 m: Platte bei 0,75 m, Monitor ragt darüber hinaus.
  'desk': FurnitureSpec(
    height: 1.15,
    againstWall: true,
    zones: const [
      ColorZone('top', 'Platte'),
      ColorZone('legs', 'Gestell', Mat.dark),
      ColorZone('monitor', 'Monitor', Mat.dark),
    ],
    build: (b, w, d, h) {
      final top = h * 0.65;
      const t = 0.03;
      b.roundBox(
        -w / 2,
        -d / 2,
        top - t,
        w / 2,
        d / 2,
        top,
        0.015,
        segments: 2,
      );
      // Kufengestell: je Seite zwei Pfosten, Fuß- und Querholm; hinten
      // eine Traverse.
      b.zone = 'legs';
      const p = 0.04;
      final ix = w / 2 - 0.05 - p / 2;
      final iy = d / 2 - 0.06 - p / 2;
      for (final sx in [-1.0, 1.0]) {
        final x = sx * ix;
        for (final sy in [-1.0, 1.0]) {
          b.boxC(x, sy * iy, p, p, 0.02, top - t - 0.02, mat: Mat.dark);
        }
        b.boxC(x, 0, p, 2 * iy + p, 0, 0.02, mat: Mat.dark);
        b.boxC(x, 0, p, 2 * iy + p, top - t - 0.02, top - t, mat: Mat.dark);
      }
      b.box(
        -ix,
        -iy - p / 2,
        top - t - 0.12,
        ix,
        -iy + p / 2,
        top - t - 0.08,
        mat: Mat.dark,
      );
      // Monitor: Fuß, Hals, Gehäuse, Bild nach vorn (+y).
      b.zone = 'monitor';
      final mw = math.min(w * 0.42, 0.62);
      final mh = math.min(h - top - 0.06, mw * 0.58);
      final my = -d / 2 + d * 0.17;
      final mz = top + 0.06;
      b.roundBox(
        -0.11,
        my - 0.08,
        top,
        0.11,
        my + 0.06,
        top + 0.01,
        0.03,
        mat: Mat.dark,
        segments: 2,
      );
      b.boxC(
        0,
        my - 0.02,
        0.04,
        0.02,
        top + 0.01,
        mz + mh * 0.5,
        mat: Mat.dark,
      );
      b.roundBox(
        -mw / 2,
        my - 0.01,
        mz,
        mw / 2,
        my + 0.012,
        mz + mh,
        0.008,
        mat: Mat.dark,
        segments: 2,
      );
      b.zone = null;
      b.box(
        -mw / 2 + 0.01,
        my + 0.012,
        mz + 0.012,
        mw / 2 - 0.01,
        my + 0.014,
        mz + mh - 0.01,
        mat: Mat.screen,
      );
      // Tastatur und Maus flach auf der Platte.
      final kw = math.min(w * 0.3, 0.44), kd = math.min(d * 0.2, 0.15);
      final ky = d * 0.06;
      b.roundBox(
        -kw / 2,
        ky - kd / 2,
        top,
        kw / 2,
        ky + kd / 2,
        top + 0.012,
        0.01,
        mat: Mat.metal,
        segments: 1,
      );
      b.roundBox(
        kw / 2 + 0.06,
        ky - 0.05,
        top,
        kw / 2 + 0.12,
        ky + 0.05,
        top + 0.02,
        0.025,
        mat: Mat.metal,
        segments: 2,
      );
    },
  ),
  // 2D: runder Sitz, Fünfstern-Fuß, Lehne an der Oberkante (y < 0).
  'office_chair': FurnitureSpec(
    height: 1.0,
    zones: const [ColorZone('cushions', 'Polster', Mat.soft), _frame],
    build: (b, w, d, h) {
      final u = math.min(w, d);
      final seatTop = h * 0.48;
      final cy = d * 0.06;
      // Fünfstern-Fuß mit Rollen.
      b.zone = _frame.id;
      final rb = math.min(u * 0.46, math.min(w / 2, d / 2 - cy)) - 0.02;
      for (var i = 0; i < 5; i++) {
        final a = i * 2 * math.pi / 5 + math.pi / 2;
        b.placed(V3(0, cy, 0), a, () {
          b.box(0, -0.014, 0.05, rb, 0.014, 0.08, mat: Mat.dark);
          b.cylinder(rb - 0.01, 0, 0.022, 0, 0.05, segments: 6, mat: Mat.dark);
        });
      }
      b.cylinder(0, cy, 0.035, 0.05, 0.1, segments: 10, mat: Mat.dark);
      b.cylinder(
        0,
        cy,
        0.022,
        0.1,
        seatTop - 0.08,
        segments: 8,
        mat: Mat.metal,
      );
      // Sitzträger, Lehnenbügel, Armlehnen.
      final sw = u * 0.78, sd = u * 0.72;
      b.box(
        -0.08,
        cy - 0.08,
        seatTop - 0.1,
        0.08,
        cy + 0.08,
        seatTop - 0.07,
        mat: Mat.dark,
      );
      final by = -d / 2 + 0.03;
      b.box(
        -0.025,
        by,
        seatTop - 0.1,
        0.025,
        cy - 0.06,
        seatTop - 0.075,
        mat: Mat.dark,
      );
      b.box(
        -0.025,
        by,
        seatTop - 0.1,
        0.025,
        by + 0.025,
        seatTop + 0.16,
        mat: Mat.dark,
      );
      for (final sx in [-1.0, 1.0]) {
        final x = sx * (sw / 2 + 0.025);
        b.box(
          x - 0.012,
          cy - 0.02,
          seatTop - 0.08,
          x + 0.012,
          cy + 0.02,
          seatTop + 0.19,
          mat: Mat.dark,
        );
        b.box(
          x - 0.028,
          cy - 0.13,
          seatTop + 0.19,
          x + 0.028,
          cy + 0.1,
          seatTop + 0.215,
          mat: Mat.dark,
        );
      }
      // Sitz und Lehne gepolstert.
      b.zone = 'cushions';
      b.roundBox(
        -sw / 2,
        cy - sd / 2,
        seatTop - 0.075,
        sw / 2,
        cy + sd / 2,
        seatTop,
        0.06,
        mat: Mat.soft,
        segments: 3,
      );
      final bw = u * 0.68;
      b.loft(
        ModelBuilder.roundedRect(
          -bw / 2,
          -d / 2,
          bw / 2,
          -d / 2 + 0.06,
          0.03,
          segments: 2,
        ),
        seatTop + 0.12,
        ModelBuilder.roundedRect(
          -bw / 2 * 0.92,
          -d / 2,
          bw / 2 * 0.92,
          -d / 2 + 0.05,
          0.025,
          segments: 2,
        ),
        h,
        mat: Mat.soft,
      );
    },
  ),
};
