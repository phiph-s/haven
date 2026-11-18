import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';

void main() {
  const size = Size(800, 600);

  test('Stück des abgerundeten Umrisses findet seine Kante', () {
    final r = SceneRoom(
      id: 'r',
      outline: const [Offset(0, 0), Offset(4, 0), Offset(4, 3), Offset(0, 3)],
      openEdges: const {1},
    );
    // Eingerückt (0,08 m) an der rechten Wand.
    expect(r.edgeNear(const Offset(3.92, 0.5), const Offset(3.92, 2.5)), 1);
    expect(
      r.isOpenAt(const Offset(3.92, 0.5), const Offset(3.92, 2.5)),
      isTrue,
    );
    expect(
      r.isOpenAt(const Offset(0.5, 0.08), const Offset(3.5, 0.08)),
      isFalse,
    );
  });

  test('Verdecken: nur der Raum davor liegt flach, Draufsicht nichts', () {
    // Drei Räume nebeneinander von Norden (y klein) nach Süden.
    SceneRoom room(String id, double y0) => SceneRoom(
      id: id,
      outline: [
        Offset(0, y0),
        Offset(4, y0),
        Offset(4, y0 + 3),
        Offset(0, y0 + 3),
      ],
    );
    final scene = Scene(
      rooms: [room('nord', 0), room('mitte', 3), room('sued', 6)],
    );
    // Blick schräg von Süden: der südliche Raum steht vor der Mitte.
    final cam = const OrbitCamera(target: V3(2, 4.5, 0), pitch: 0.9, scale: 50);
    expect(occludersOf(scene, 'mitte', cam, size), {'sued'});
    expect(occludersOf(scene, 'sued', cam, size), isEmpty);
    expect(
      occludersOf(scene, 'mitte', const OrbitCamera(scale: 50), size),
      isEmpty,
    );
  });
}
