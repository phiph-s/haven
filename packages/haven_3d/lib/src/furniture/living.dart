import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../model.dart';
import 'catalog.dart';

/// 3D-Modelle der Kategorie „living“.
///
/// Möbel werden nur angedeutet: ein Hauptkörper plus wenige Solids, alles
/// Weitere (Kissenfugen, Fachlinien, Teppichrand) sind Detaillinien auf der
/// Fläche. Rückenlehnen liegen wie in 2D an der Oberkante (y = -d/2), bei der
/// Ecksofa-L zusätzlich an der linken Kante (x = -w/2).
final Map<String, FurnitureSpec> livingModels = {
  // 2D: Rückenlehne oben, Armlehnen links und rechts, Sitzkissen dazwischen.
  'sofa': FurnitureSpec(
    height: 0.85,
    build: (b, w, d, h) {
      final arm = math.min(0.12 * w, 0.4 * d);
      final back = 0.28 * d;
      final seatTop = 0.5 * h;
      final armTop = 0.72 * h;
      // Sitzblock, Lehne und zwei Armlehnen.
      b.box(-w / 2, -d / 2, 0, w / 2, d / 2, seatTop, mat: Mat.soft);
      b.box(-w / 2, -d / 2, seatTop, w / 2, -d / 2 + back, h, mat: Mat.soft);
      b.box(
        -w / 2,
        -d / 2 + back,
        seatTop,
        -w / 2 + arm,
        d / 2,
        armTop,
        mat: Mat.soft,
      );
      b.box(
        w / 2 - arm,
        -d / 2 + back,
        seatTop,
        w / 2,
        d / 2,
        armTop,
        mat: Mat.soft,
      );
      // Kissenfugen auf der Sitzfläche.
      final n = math.max(2, ((w - 2 * arm) / (0.9 * d)).round());
      for (var i = 1; i < n; i++) {
        final x = -w / 2 + arm + (w - 2 * arm) * i / n;
        b.line(V3(x, -d / 2 + back, seatTop), V3(x, d / 2, seatTop));
      }
    },
  ),
  // 2D: L-Form, Schenkel oben (volle Breite) und links (volle Tiefe).
  'sofa_corner': FurnitureSpec(
    height: 0.85,
    build: (b, w, d, h) {
      final t = math.min(0.42 * math.max(w, d), 0.5 * math.min(w, d));
      final back = 0.32 * t;
      final seatTop = 0.5 * h;
      final armTop = 0.72 * h;
      final x0 = -w / 2, y0 = -d / 2;
      // Sitzblock als L.
      b.prism(
        [
          Offset(x0, y0),
          Offset(w / 2, y0),
          Offset(w / 2, y0 + t),
          Offset(x0 + t, y0 + t),
          Offset(x0 + t, d / 2),
          Offset(x0, d / 2),
        ],
        0,
        seatTop,
        mat: Mat.soft,
      );
      // Lehnen oben und links.
      b.box(x0, y0, seatTop, w / 2, y0 + back, h, mat: Mat.soft);
      b.box(x0, y0 + back, seatTop, x0 + back, d / 2, h, mat: Mat.soft);
      // Armlehnen an den Schenkelenden.
      b.box(
        w / 2 - back,
        y0 + back,
        seatTop,
        w / 2,
        y0 + t,
        armTop,
        mat: Mat.soft,
      );
      b.box(
        x0 + back,
        d / 2 - back,
        seatTop,
        x0 + t,
        d / 2,
        armTop,
        mat: Mat.soft,
      );
      // Kissenfugen: Eckkissen abgrenzen, Schenkel unterteilen.
      b.line(V3(x0 + t, y0 + back, seatTop), V3(x0 + t, y0 + t, seatTop));
      b.line(V3(x0 + back, y0 + t, seatTop), V3(x0 + t, y0 + t, seatTop));
      final nx = math.max(1, ((w - t) / (1.1 * t)).round());
      for (var i = 1; i < nx; i++) {
        final x = x0 + t + (w - t - back) * i / nx;
        b.line(V3(x, y0 + back, seatTop), V3(x, y0 + t, seatTop));
      }
      final ny = math.max(1, ((d - t) / (1.1 * t)).round());
      for (var i = 1; i < ny; i++) {
        final y = y0 + t + (d - t - back) * i / ny;
        b.line(V3(x0 + back, y, seatTop), V3(x0 + t, y, seatTop));
      }
    },
  ),
  // 2D: Quadrat mit Lehne oben und zwei Armlehnen.
  'armchair': FurnitureSpec(
    height: 0.85,
    build: (b, w, d, h) {
      final arm = 0.16 * w;
      final back = 0.26 * d;
      final seatTop = 0.5 * h;
      final armTop = 0.72 * h;
      b.box(-w / 2, -d / 2, 0, w / 2, d / 2, seatTop, mat: Mat.soft);
      b.box(-w / 2, -d / 2, seatTop, w / 2, -d / 2 + back, h, mat: Mat.soft);
      b.box(
        -w / 2,
        -d / 2 + back,
        seatTop,
        -w / 2 + arm,
        d / 2,
        armTop,
        mat: Mat.soft,
      );
      b.box(
        w / 2 - arm,
        -d / 2 + back,
        seatTop,
        w / 2,
        d / 2,
        armTop,
        mat: Mat.soft,
      );
      // Sitzkissen als Linie auf der Sitzfläche.
      b.polyline([
        V3(-w / 2 + arm, d / 2 - 0.03, seatTop),
        V3(w / 2 - arm, d / 2 - 0.03, seatTop),
      ]);
    },
  ),
  // 2D: Platte mit abgesetztem Innenrahmen (Ablage).
  'coffee_table': FurnitureSpec(
    height: 0.42,
    build: (b, w, d, h) {
      const top = 0.04;
      final leg = math.min(0.05, 0.1 * math.min(w, d));
      b.box(-w / 2, -d / 2, h - top, w / 2, d / 2, h);
      // Beine.
      for (final sx in [-1, 1]) {
        for (final sy in [-1, 1]) {
          b.boxC(sx * (w / 2 - leg), sy * (d / 2 - leg), leg, leg, 0, h - top);
        }
      }
      // Innenrahmen als Linie auf der Platte.
      final m = 0.14 * math.min(w, d);
      b.rectLines(-w / 2 + m, -d / 2 + m, w / 2 - m, d / 2 - m, h);
    },
  ),
  // 2D: niedriges Board, Fernseher oben. Die Höhe schließt den Fernseher ein.
  'tv_board': FurnitureSpec(
    height: 1.0,
    build: (b, w, d, h) {
      final bh = math.min(0.45, 0.8 * h); // Höhe des Boards
      b.box(-w / 2, -d / 2, 0, w / 2, d / 2, bh);
      // Türfugen auf der Vorderseite (y = +d/2).
      final n = math.max(2, (w / 0.6).round());
      for (var i = 1; i < n; i++) {
        final x = -w / 2 + w * i / n;
        b.line(V3(x, d / 2, 0), V3(x, d / 2, bh));
      }
      // Flachbildschirm als dünne Platte an der Rückseite.
      if (h - bh > 0.1) {
        final sw = 0.7 * w;
        b.box(
          -sw / 2,
          -d / 2 + 0.06,
          bh,
          sw / 2,
          -d / 2 + 0.09,
          h,
          mat: Mat.dark,
        );
      }
    },
  ),
  // Dünne Platte am Boden mit Randlinie.
  'rug': FurnitureSpec(
    height: 0.02,
    build: (b, w, d, h) {
      b.box(-w / 2, -d / 2, 0, w / 2, d / 2, h, mat: Mat.rug);
      final m = 0.1 * math.min(w, d);
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
  // Topf mit einem ruhigen Laubkegel darüber.
  'plant': FurnitureSpec(
    height: 1.2,
    build: (b, w, d, h) {
      final r = 0.5 * math.min(w, d);
      final potH = 0.28 * h;
      b.cone(0, 0, 0.6 * r, 0.8 * r, 0, potH, segments: 10);
      // Laub: unten breiter Kegelstumpf, darüber eine Spitze.
      b.cone(
        0,
        0,
        0.95 * r,
        0.7 * r,
        potH,
        0.7 * h,
        segments: 10,
        mat: Mat.green,
      );
      b.cone(0, 0, 0.7 * r, 0.05 * r, 0.7 * h, h, segments: 10, mat: Mat.green);
    },
  ),
  // Hohes Regal: ein Korpus, Fachlinien auf der Vorderseite.
  'shelf': FurnitureSpec(
    height: 1.8,
    build: (b, w, d, h) {
      b.box(-w / 2, -d / 2, 0, w / 2, d / 2, h);
      // Fachböden als Linien auf der Front (y = +d/2).
      final rows = math.max(3, (h / 0.38).round());
      for (var i = 1; i < rows; i++) {
        final z = h * i / rows;
        b.line(V3(-w / 2, d / 2, z), V3(w / 2, d / 2, z));
      }
      // Senkrechte Teiler wie in 2D.
      final n = math.max(1, (w / math.max(d * 2.5, 0.01)).round());
      for (var i = 1; i < n; i++) {
        final x = -w / 2 + w * i / n;
        b.line(V3(x, d / 2, 0), V3(x, d / 2, h));
      }
    },
  ),
};
