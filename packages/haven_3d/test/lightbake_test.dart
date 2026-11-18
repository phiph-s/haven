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
}
