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

  test('Fenster über eine Raumgrenze gehört zu beiden Räumen', () {
    SceneRoom room(String id, double x0) => SceneRoom(
      id: id,
      outline: [
        Offset(x0, 0),
        Offset(x0 + 3, 0),
        Offset(x0 + 3, 3),
        Offset(x0, 3),
      ],
    );
    final scene = Scene(
      rooms: [room('west', 0), room('ost', 3)],
      objects: [
        // Außenwand oben (y = 0), mittig über der Grenze bei x = 3.
        SceneObject.furniture(
          id: 'fenster',
          kind: 'window',
          center: const Offset(3, 0),
          w: 2,
          d: 0.2,
        ),
        // Tür in der Wand zwischen beiden Räumen.
        SceneObject.furniture(
          id: 'tuer',
          kind: 'door',
          center: const Offset(3.45, 1.55),
          w: 0.9,
          d: 0.9,
          rotation: 90,
        ),
        SceneObject.furniture(
          id: 'sofa',
          kind: 'sofa',
          center: const Offset(1.5, 1.5),
          w: 2,
          d: 0.9,
        ),
      ],
    );
    final w = scene.objects.first.wallOpening!;
    expect(w.z0, closeTo(0.9, 1e-9));
    expect(w.z1, closeTo(2.1, 1e-9));
    expect((w.b - w.a).distance, closeTo(2, 1e-9));
    expect(scene.objectRooms['fenster'], {'west', 'ost'});
    expect(scene.objectRooms['tuer'], {'west', 'ost'});
    expect(scene.objectRooms['sofa'], {'west'});
  });
}
