import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';

void main() {
  // Ein Raum 4 × 3 m, Wände 2,5 m hoch.
  final scene = Scene(
    rooms: [
      SceneRoom(
        id: 'a',
        outline: const [Offset(0, 0), Offset(4, 0), Offset(4, 3), Offset(0, 3)],
      ),
    ],
  );
  const size = Size(400, 300);
  // Schräg von Süden (unten im Plan): die Nordwand (y = 0) zeigt ihre
  // Innenseite zur Kamera, die Südwand ihre Außenseite.
  const tilted = OrbitCamera(target: V3(2, 1.5, 1), pitch: 0.9, scale: 60);

  group('Sehstrahl', () {
    for (final cam in [
      tilted,
      tilted.copyWith(fov: OrbitCamera.perspectiveFov),
      tilted.copyWith(yaw: 0.7, pan: const Offset(20, -10)),
    ]) {
      test(
        'trifft dieselben Punkte wie unprojectOnPlane (${cam.fov}, ${cam.yaw})',
        () {
          for (final s in const [Offset(200, 150), Offset(40, 260)]) {
            for (final z in [0.0, 1.2]) {
              final ray = rayAt(cam, s, size);
              final t = ray.tOnPlane(z)!;
              final p = ray.at(t);
              final q = cam.unprojectOnPlane(s, size, z: z)!;
              expect((p - q).length, lessThan(1e-9));
              // Und zurück auf denselben Bildpunkt.
              expect(
                (cam.project(p, size).offset - s).distance,
                lessThan(1e-6),
              );
            }
          }
        },
      );
    }
  });

  group('Wand unter dem Zeiger', () {
    test('Innenseite der hinteren Wand, Normale in den Raum', () {
      final inset = wallInset(0.16);
      final onWall = V3(1.5, inset, 1.2);
      final s = tilted.project(onWall, size).offset;
      final hit = wallAt(scene, tilted, size, s, inset: inset)!;
      expect(hit.roomId, 'a');
      expect(hit.edge, 0);
      expect((hit.point - onWall).length, lessThan(1e-6));
      expect((hit.inward - const Offset(0, 1)).distance, lessThan(1e-9));
      expect(hit.inFront(0.5).dy, closeTo(inset + 0.5, 1e-9));
    });

    test('Boden davor und Außenseite der vorderen Wand treffen nichts', () {
      final floor = tilted.project(const V3(2, 1.5, 0), size).offset;
      expect(wallAt(scene, tilted, size, floor), isNull);
      // Südwand von außen (Kamera steht südlich): keine Innenseite sichtbar.
      final south = tilted.project(const V3(2, 3, 2), size).offset;
      final hit = wallAt(scene, tilted, size, south);
      expect(hit?.edge, isNot(2));
    });

    test('Über der Wandoberkante und neben der Wand: kein Treffer', () {
      final above = tilted.project(const V3(2, 0, 2.9), size).offset;
      expect(wallAt(scene, tilted, size, above), isNull);
    });

    test('offene Kanten haben keine Wand, flache Räume zählen nicht', () {
      final open = Scene(
        rooms: [
          SceneRoom(
            id: 'a',
            outline: scene.rooms.first.outline,
            openEdges: const {0},
          ),
        ],
      );
      final s = tilted.project(const V3(2, 0, 1), size).offset;
      expect(wallAt(open, tilted, size, s), isNull);
      expect(wallAt(scene, tilted, size, s), isNotNull);
      expect(wallAt(scene, tilted, size, s, flat: {'a'}), isNull);
    });

    test('Umlaufsinn egal: Normale zeigt immer in den Raum', () {
      final cw = Scene(
        rooms: [
          SceneRoom(
            id: 'a',
            outline: scene.rooms.first.outline.reversed.toList(),
          ),
        ],
      );
      final cam = tilted.copyWith(yaw: math.pi / 2);
      // Von Osten gesehen: die Westwand (x = 0) zeigt ihre Innenseite.
      final s = cam.project(const V3(0, 1.5, 1), size).offset;
      final hit = wallAt(cw, cam, size, s)!;
      expect((hit.inward - const Offset(1, 0)).distance, lessThan(1e-9));
    });
  });
}
