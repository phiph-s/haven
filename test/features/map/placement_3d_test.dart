import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/features/map/placement_3d.dart';
import 'package:haven_3d/haven_3d.dart' as h3;

// Ein Raum 10 × 8 Zellen (5 × 4 m) ab (2, 2), Raster 20 × 16.
final _room = FloorRoom.rect(id: 'r', name: 'Raum', x: 2, y: 2, w: 10, h: 8);
final _plan = HavenFloorPlan(
  grid: const FloorGrid(cols: 20, rows: 16),
  rooms: [_room],
);

FloorFurniture _f(
  String kind,
  double x,
  double y, {
  double w = 4,
  double h = 2,
  double rot = 0,
}) =>
    FloorFurniture(id: kind, kind: kind, x: x, y: y, w: w, h: h, rotation: rot);

void _near(Offset a, Offset b, {double eps = 1e-6}) =>
    expect((a - b).distance, lessThan(eps), reason: '$a != $b');

/// Liegen alle Ecken von [f] im Raum (Rand zählt, mit Rundungsspiel)?
bool _inside(FloorFurniture f, FloorRoom r) =>
    f.corners.every((c) => r.contains(c + (f.center - c) * 1e-6));

void main() {
  const size = Size(400, 300);

  group('Bildschirm → Boden', () {
    test('Draufsicht: Bildmitte ist das Ziel, 1 m = scale Pixel', () {
      const cam = h3.OrbitCamera(target: h3.V3(3, 2, 0), scale: 40);
      _near(
        floorCellAt(cam, size, const Offset(200, 150), 0.5)!,
        const Offset(6, 4),
      );
      _near(
        floorCellAt(cam, size, const Offset(240, 170), 0.5)!,
        const Offset(8, 5),
      );
    });

    for (final fov in [0.0, h3.OrbitCamera.perspectiveFov]) {
      test('schräg (fov $fov): Projektion und zurück', () {
        final cam = h3.OrbitCamera(
          target: const h3.V3(3, 2, 0),
          yaw: -0.35,
          pitch: 0.85,
          scale: 50,
          fov: fov,
        );
        for (final p in const [Offset(4, 6), Offset(10, 3)]) {
          for (final z in [0.0, 0.9]) {
            final m = p * 0.5;
            final s = cam.project(h3.V3(m.dx, m.dy, z), size).offset;
            _near(floorCellAt(cam, size, s, 0.5, z: z)!, p, eps: 1e-6);
          }
        }
      });
    }
  });

  group('Einrasten', () {
    test('frei im Raum: Halbraster, Drehung bleibt', () {
      final f = placeFurnitureAt(
        _f('coffee_table', 0, 0, w: 2.4, h: 1.2, rot: 90),
        const Offset(6.93, 6.12),
        _plan,
      );
      expect(f.rotation, 90);
      final b = f.bounds;
      expect((b.left * 2 - (b.left * 2).roundToDouble()).abs(), lessThan(1e-6));
      expect((b.top * 2 - (b.top * 2).roundToDouble()).abs(), lessThan(1e-6));
      // Ohne Einrasten genau unter dem Finger.
      final free = placeFurnitureAt(
        _f('coffee_table', 0, 0, w: 2.4, h: 1.2),
        const Offset(6.93, 6.12),
        _plan,
        snap: false,
      );
      _near(free.center, const Offset(6.93, 6.12));
    });

    test('bleibt im Raster', () {
      final f = placeFurnitureAt(
        _f('plant', 0, 0, w: 1, h: 1),
        const Offset(-5, 40),
        _plan,
      );
      expect(f.center.dx, inInclusiveRange(0, 20));
      expect(f.center.dy, inInclusiveRange(0, 16));
    });

    test('Sofa rückt mit dem Rücken an die nahe Wand oben', () {
      // Rücken 0,6 Zellen vor der Wand y = 2.
      final f = snapBackToWall(_f('sofa', 7.2, 3.6, rot: 30), [_room]);
      expect(f.rotation, 0, reason: 'Rücken (-y) zur Wand');
      _near(f.center, const Offset(7, 3));
      // Rückseite liegt auf der Wand.
      _near(f.toWorld(Offset(0, -f.h / 2)), const Offset(7, 2));
      expect(_inside(f, _room), isTrue);
    });

    test('an der rechten Wand: 90°, Rücken auf x = 12', () {
      final f = snapBackToWall(_f('wardrobe', 10.3, 6.1, h: 1.2), [_room]);
      expect(f.rotation, 90);
      expect(f.toWorld(Offset(0, -f.h / 2)).dx, closeTo(12, 1e-6));
      expect(f.center.dx, closeTo(12 - 0.6, 1e-6));
      // Entlang der Wand auf dem Halbraster.
      final start = f.center.dy - f.w / 2;
      expect((start * 2 - (start * 2).roundToDouble()).abs(), lessThan(1e-6));
      expect(_inside(f, _room), isTrue);
    });

    test('unten (180°) und links (270°)', () {
      expect(
        snapBackToWall(_f('bed_single', 6, 8.6, w: 2, h: 4.2), [
          _room,
        ]).rotation,
        180,
      );
      expect(
        snapBackToWall(_f('desk', 3.4, 6, w: 3, h: 1.4), [_room]).rotation,
        270,
      );
    });

    test('in der Ecke: ganz auf der Wand, nichts ragt hinaus', () {
      final f = snapBackToWall(_f('sofa', 2.6, 2.9), [_room]);
      expect(_inside(f, _room), isTrue, reason: '$f');
      // Stirnseite stößt an die Nachbarwand.
      final b = f.bounds;
      expect(math.min(b.left - 2, b.top - 2), closeTo(0, 1e-6));
    });

    test('weit weg von jeder Wand: unverändert', () {
      final f = _f('sofa', 7, 6, rot: 15);
      expect(snapBackToWall(f, [_room]), f);
      expect(snapToWalls(_f('coffee_table', 7, 2.6), [_room]).rotation, 0);
    });

    test('offene Wand zieht nicht an', () {
      final open = _room.copyWith(open: {0});
      final f = snapBackToWall(_f('sofa', 7.2, 3.6, rot: 30), [open]);
      expect(f.rotation, isNot(0));
    });

    test('schräge Wand: Rücken liegt auf der Wand', () {
      // Dreieck mit Schräge von (0, 8) nach (8, 0).
      const tri = FloorRoom(
        id: 't',
        name: 'T',
        points: [GridPoint(0, 0), GridPoint(8, 0), GridPoint(0, 8)],
      );
      final f = snapBackToWall(_f('shelf', 3.6, 3.6, w: 2, h: 0.8), [tri]);
      final back = f.toWorld(Offset(0, -f.h / 2));
      // Auf der Geraden x + y = 8.
      expect(back.dx + back.dy, closeTo(8, 1e-6));
      expect(f.rotation, closeTo(135, 1e-6));
      expect(_inside(f, tri), isTrue);
    });

    test('Fenster sitzt mittig in der Wand, längs zur Wand', () {
      final f = snapWindowToWall(
        _f('window', 5.2, 2.5, w: 2.4, h: 0.4, rot: 80),
        [_room],
      );
      expect(f.center.dy, closeTo(2, 1e-6));
      expect(f.rotation % 180, closeTo(0, 1e-6));
      final side = snapWindowToWall(_f('window', 11.7, 6, w: 2.4, h: 0.4), [
        _room,
      ]);
      expect(side.center.dx, closeTo(12, 1e-6));
      expect(side.rotation % 180, closeTo(90, 1e-6));
    });

    test('Fenster ziehen in 3D: bleibt an der Wand, auch neben dem Finger', () {
      final win = snapWindowToWall(_f('window', 6, 2, w: 2.4, h: 0.4), [
        _room,
      ]);
      // Finger 2 Zellen nach rechts und knapp 2 Zellen in den Raum (die Wand
      // verdeckt das Fenster, der Punkt liegt neben ihm): Fenster gleitet
      // auf der Wand mit, statt frei im Raum zu stehen.
      final moved = moveFurniture3d(win, const Offset(2, 1.8), _plan);
      expect(moved.center.dy, closeTo(2, 1e-6));
      expect(moved.center.dx, closeTo(8, 0.25)); // Halbraster
      expect(moved.rotation % 180, closeTo(0, 1e-6));
      // Auch über die Außenseite hinaus gezogen (vor dem Raum).
      final outside = moveFurniture3d(win, const Offset(-1, -1.6), _plan);
      expect(outside.center.dy, closeTo(2, 1e-6));
      // Weit weg (Raummitte): frei.
      final far = moveFurniture3d(win, const Offset(0, 4), _plan);
      expect(far.center.dy, greaterThan(4));
      // Greifhöhe: Mitte des Fensters, nicht Oberkante.
      expect(grabHeight(win), lessThan(furnitureTop(win)));
    });

    test('placeFurnitureAt: Schrank an der Wand, Tür in die Wand', () {
      final wardrobe = placeFurnitureAt(
        _f('wardrobe', 0, 0, h: 1.2),
        const Offset(6, 2.9),
        _plan,
      );
      expect(wardrobe.toWorld(Offset(0, -wardrobe.h / 2)).dy, closeTo(2, 1e-6));
      final door = placeFurnitureAt(
        _f('door', 0, 0, w: 1.8, h: 1.8),
        const Offset(6, 2.6),
        _plan,
      );
      // Wandlinie der Tür (lokal y = h/2) auf der Kante y = 2.
      expect(door.toWorld(Offset(0, door.h / 2)).dy, closeTo(2, 1e-6));
    });
  });

  group('Drehen', () {
    test('am Ring: überstrichener Winkel, 15°-Raster', () {
      final base = _f('sofa', 5, 5);
      final f = rotateAround(base, const Offset(6, 5), const Offset(5, 6));
      expect(f.rotation, 90);
      final g = rotateAround(base, const Offset(6, 5), const Offset(6, 5.45));
      expect(g.rotation, 30, reason: '24° rastet auf 30°');
      final free = rotateAround(
        base,
        const Offset(6, 5),
        const Offset(6, 5.45),
        snap: false,
      );
      expect(free.rotation, closeTo(math.atan(0.45) * 180 / math.pi, 1e-4));
    });

    test('Griff liegt vor der Vorderseite, außerhalb des Möbels', () {
      final f = _f('sofa', 5, 5, rot: 90);
      final k = rotationKnob(f, 0.5) / 0.5;
      // Vorderseite (+y lokal) zeigt bei 90° nach -x.
      expect(k.dx, lessThan(f.center.dx - f.h / 2));
      expect(f.contains(k), isFalse);
    });

    test('snapRotation', () {
      expect(snapRotation(97), 90);
      expect(snapRotation(-10), 345);
      expect(snapRotation(97, free: true), 97);
    });
  });

  group('Treffer in 3D', () {
    final sofa = _f('sofa', 6, 5);
    final rug = _f('rug', 6, 5, w: 6, h: 4);
    const cam = h3.OrbitCamera(target: h3.V3(3, 3, 0), pitch: 0.8, scale: 40);
    Offset at(FloorFurniture f, [double z = 0.2]) {
      final c = f.center * 0.5;
      return cam.project(h3.V3(c.dx, c.dy, z), size).offset;
    }

    test('Möbel vor Teppich, Teppich allein, daneben nichts', () {
      expect(furnitureAt3d([rug, sofa], cam, size, at(sofa), 0.5), sofa);
      final edge = rug.toWorld(const Offset(2.7, 1.8)) * 0.5;
      final s = cam.project(h3.V3(edge.dx, edge.dy, 0), size).offset;
      expect(furnitureAt3d([rug, sofa], cam, size, s, 0.5), rug);
      expect(
        furnitureAt3d([rug, sofa], cam, size, const Offset(2, 2), 0.5),
        isNull,
      );
    });

    test('Überdeckung: das vordere gewinnt', () {
      // Der Couchtisch steht weiter unten im Plan, näher an der Kamera,
      // und verdeckt den Fuß des Schranks.
      final tall = _f('wardrobe', 6, 7, h: 1.2);
      final table = _f('coffee_table', 6, 8.4, w: 2.4, h: 1.2);
      final both = [tall, table];
      final low = at(table, 0.42);
      expect(
        h3.pointInPolygon(
          h3.convexHull([
            for (final p in furnitureBox(tall, 0.5))
              cam.project(p, size).offset,
          ]),
          low,
        ),
        isTrue,
        reason: 'beide Hüllen enthalten den Punkt',
      );
      expect(furnitureAt3d(both, cam, size, low, 0.5), table);
      expect(furnitureAt3d(both.reversed, cam, size, low, 0.5), table);
      expect(furnitureAt3d(both, cam, size, at(tall, 1.9), 0.5), tall);
    });
  });

  group('Geräte an der Wand', () {
    test('Zelle direkt vor der Wand im getroffenen Raum', () {
      final hit = h3.WallHit(
        roomId: 'r',
        edge: 0,
        point: const h3.V3(3.3, 1.16, 1.4),
        inward: const Offset(0, 1),
        t: 0,
      );
      expect(cellBeforeWall(hit, _plan), const GridPoint(6, 2));
      final outside = h3.WallHit(
        roomId: 'anders',
        edge: 0,
        point: const h3.V3(3.3, 1.16, 1.4),
        inward: const Offset(0, 1),
        t: 0,
      );
      expect(cellBeforeWall(outside, _plan), isNull);
    });

    test('Wandgeräte erkennen', () {
      expect(wallMountable(h3.deviceSpec('motion')), isTrue);
      expect(wallMountable(h3.deviceSpec('floor_lamp')), isFalse);
    });
  });
}
