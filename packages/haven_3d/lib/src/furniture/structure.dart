import 'dart:math' as math;

import '../model.dart';
import 'catalog.dart';

/// 3D-Modelle der Kategorie „Bau“ (Tür, Fenster). Dient auch als Vorlage
/// für die übrigen Kategorien.
final Map<String, FurnitureSpec> structureModels = {
  // 2D: Angel unten links, Wand an der Unterkante (y = +d/2), Blatt 90° offen
  // nach oben (Richtung -y). Breite der Öffnung = min(w, d).
  'door': FurnitureSpec(
    height: 2.0,
    wallMounted: true,
    build: (b, w, d, h) {
      final r = math.min(w, d);
      final x0 = -w / 2, wall = d / 2;
      const post = 0.04;
      // Zarge: zwei Pfosten und Sturz in der Wandebene, bündig gestoßen
      // (nicht überlappend), damit nur echte Kanten entstehen.
      b.box(x0, wall - post, 0, x0 + post, wall, h - post);
      b.box(x0 + r - post, wall - post, 0, x0 + r, wall, h - post);
      b.box(x0, wall - post, h - post, x0 + r, wall, h);
      if (b.open == false) {
        // Zu (Sensor): Blatt in der Zarge, kein Aufschlag.
        b.box(
          x0 + post,
          wall - post,
          0.01,
          x0 + r - post,
          wall - 0.005,
          h - post,
        );
        return;
      }
      // Türblatt, offen: dünne Platte entlang der Angelseite.
      b.box(x0, wall - r, 0.01, x0 + 0.035, wall - post, h - post);
      // Aufschlag als Bogen auf dem Boden.
      const n = 10;
      b.polyline([
        for (var i = 0; i <= n; i++)
          V3(
            x0 + r * math.sin(math.pi / 2 * i / n),
            wall - r * math.cos(math.pi / 2 * i / n),
            0.005,
          ),
      ]);
    },
  ),
  // 2D: Rahmen über die ganze Fläche, Mittellinie in Längsrichtung (Glas),
  // Sprossen quer. Unterkante (Brüstung) 0,9 m, Höhe 1,2 m.
  'window': FurnitureSpec(
    height: 1.2,
    elevation: 0.9,
    wallMounted: true,
    facesRoom: true,
    build: (b, w, d, h) {
      const f = 0.05;
      // Rahmen als vier Leisten in voller Tiefe.
      b.box(-w / 2, -d / 2, 0, w / 2, d / 2, f);
      b.box(-w / 2, -d / 2, h - f, w / 2, d / 2, h);
      b.box(-w / 2, -d / 2, f, -w / 2 + f, d / 2, h - f);
      b.box(w / 2 - f, -d / 2, f, w / 2, d / 2, h - f);
      // Glas in der Mitte der Wand.
      b.panel([
        V3(-w / 2 + f, 0, f),
        V3(w / 2 - f, 0, f),
        V3(w / 2 - f, 0, h - f),
        V3(-w / 2 + f, 0, h - f),
      ], mat: Mat.glass);
      // Sprossen wie in 2D (etwa alle 4 Tiefen).
      final n = math.max(1, (w / math.max(d * 4, 0.01)).round());
      for (var i = 1; i <= n; i++) {
        final x = -w / 2 + w * i / (n + 1);
        b.line(V3(x, 0, f), V3(x, 0, h - f));
        b.line(V3(x, -d / 2, h), V3(x, d / 2, h));
      }
      // Glas als Mittellinie in der Draufsicht (wie in 2D).
      b.line(V3(-w / 2, 0, h), V3(w / 2, 0, h));
      // Zu (Sensor): kein Aufgehwinkel.
      if (b.open == false) return;
      // Aufgehwinkel wie bei der Tür, auf Brüstungshöhe zur Raumseite (-y):
      // breite Fenster zwei Flügel (Angeln außen), schmale einer.
      final two = w >= 0.8;
      final sash = two ? w / 2 : w;
      const steps = 8;
      for (final (hx, dir)
          in two ? [(-w / 2, 1.0), (w / 2, -1.0)] : [(-w / 2, 1.0)]) {
        b.polyline([
          for (var i = 0; i <= steps; i++)
            V3(
              hx + dir * sash * math.cos(math.pi / 2 * i / steps),
              -d / 2 - sash * math.sin(math.pi / 2 * i / steps),
              0,
            ),
        ]);
        // Offener Flügel als Linie von der Angel in den Raum.
        b.line(V3(hx, -d / 2, 0), V3(hx, -d / 2 - sash, 0));
      }
    },
  ),
};
