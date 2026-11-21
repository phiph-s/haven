import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';
import 'package:haven_3d/src/lightbake.dart';

void main() {
  const floor = [V3(0, 0, 0), V3(4, 0, 0), V3(4, 4, 0), V3(0, 4, 0)];

  test('Ohne Hindernis: hell unter der Lampe, dunkler am Rand', () {
    final r = LightReceiver(floor, texel: 0.1);
    final e = bakeLamp(r, const V3(2, 2, 2.4), LightOccluders(const []));
    double at(double x, double y) =>
        e[((y / 4) * r.height).floor() * r.width + ((x / 4) * r.width).floor()];
    expect(at(2, 2), greaterThan(at(0.2, 0.2) * 2));
    expect(at(2, 2), closeTo(1 / (2.4 * 2.4), 0.03));
  });

  test('Ein Quader wirft einen Schatten vom Licht weg', () {
    final box = (ModelBuilder()..box(2.6, 1.6, 0, 3.0, 2.4, 0.8)).build();
    final r = LightReceiver(floor, texel: 0.05);
    final e = bakeLamp(r, const V3(2, 2, 2.4), LightOccluders([box]));
    double at(double x, double y) =>
        e[((y / 4) * r.height).floor() * r.width + ((x / 4) * r.width).floor()];
    // Hinter dem Quader (vom Licht aus) dunkel, davor hell.
    expect(at(3.4, 2.0), lessThan(at(1.0, 2.0) * 0.3));
  });

  test('Bake einer Wohnung bleibt schnell genug', () {
    final s = sampleScene();
    final room = s.room('wohnen')!;
    final objs = [
      for (final o in s.objects)
        if (s.objectRoom[o.id] == 'wohnen') o.world,
    ];
    final r = LightReceiver([for (final p in room.outline) V3(p.dx, p.dy, 0)]);
    final sw = Stopwatch()..start();
    bakeLamp(r, const V3(2.5, 2.2, 2.35), LightOccluders(objs));
    // ignore: avoid_print
    print(
      'Boden Wohnen: ${r.width}×${r.height} in ${sw.elapsedMilliseconds} ms',
    );
    expect(sw.elapsedMilliseconds, lessThan(3000));
  });

  test('sRGB-Stufen aus der Tabelle gleichen der Formel', () {
    int formula(double lin, double max) {
      final v = (lin / max).clamp(0.0, 1.0);
      final s = v <= 0.0031308
          ? v * 12.92
          : 1.055 * math.pow(v, 1 / 2.4) - 0.055;
      return (s * 255).round().clamp(0, 255);
    }

    final rnd = math.Random(7);
    const n = 200000;
    final e = Float32List(n);
    for (var i = 0; i < n; i++) {
      // Viele dunkle Werte (dort liegen die Stufen dicht), dazu Ränder.
      e[i] = switch (i % 4) {
        0 => rnd.nextDouble(),
        1 => math.pow(rnd.nextDouble(), 6).toDouble(),
        2 => rnd.nextDouble() * 0.004,
        _ => i % 8 == 3 ? 0.0 : 1.0,
      };
    }
    final (px, max) = combineLamps(n, [(e, 0.9, 0.31, 1.7)]);
    expect(max, closeTo(1.7, 1e-6));
    final rgb = sumLamps(n, [(e, 0.9, 0.31, 1.7)]);
    for (var i = 0; i < n; i++) {
      for (var c = 0; c < 3; c++) {
        if (px[i * 4 + c] != formula(rgb[i * 3 + c], max)) {
          fail('Texel $i Kanal $c: ${px[i * 4 + c]}');
        }
      }
      if (px[i * 4 + 3] != 255) fail('Alpha $i');
    }
  });

  test('Rand einer Fläche im Atlas wiederholt die Gegenkante', () {
    const w = 3, h = 2, stride = 8;
    final rgb = Float32List(w * h * 3);
    for (var i = 0; i < w * h; i++) {
      rgb[i * 3] = (i + 1) / (w * h);
    }
    final out = Uint8List(stride * 6 * 4);
    encodeLight(rgb, 1, out, w, h, stride: stride, x: 2, y: 2, gutter: 2);
    int red(int x, int y) => out[(y * stride + x) * 4];
    // Innen (ab 2, 2): Zeile 0 = Texel 1 … 3, Zeile 1 = Texel 4 … 6.
    expect(red(2, 2), lessThan(red(4, 2)));
    expect(red(4, 2), lessThan(red(2, 3)));
    // Der Rand wiederholt die Fläche in jede Richtung, auch über Eck.
    for (var y = 0; y < 6; y++) {
      for (var x = 0; x < 7; x++) {
        expect(
          red(x, y),
          red(2 + (x - 2) % w, 2 + (y - 2) % h),
          reason: 'Texel $x, $y',
        );
      }
    }
    // Außerhalb bleibt alles leer.
    expect(red(7, 0), 0);
    expect(red(7, 5), 0);
  });
}
