import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/data/models/polygon.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/features/map/floor_editor_ops.dart';
import 'package:haven/features/map/floor_geometry.dart';

GridPoint g(int x, int y) => GridPoint(x, y);

HavenFloorPlan _two() => HavenFloorPlan(
  grid: const FloorGrid(cols: 20, rows: 20),
  rooms: [
    FloorRoom.rect(id: 'a', name: 'A', x: 0, y: 0, w: 6, h: 6),
    FloorRoom.rect(id: 'b', name: 'B', x: 6, y: 0, w: 4, h: 6, areaId: 'bad'),
  ],
  placements: const [
    FloorPlacement(entityId: 'light.x', x: 3, y: 1),
    FloorPlacement(entityId: 'sensor.t', x: 7, y: 3),
  ],
);

/// L-Form (6 x 6 ohne die Ecke rechts oben) und das Stück, das hineinpasst.
FloorRoom _l() => FloorRoom(
  id: 'l',
  name: 'L',
  points: [g(0, 0), g(3, 0), g(3, 3), g(6, 3), g(6, 6), g(0, 6)],
);
FloorRoom _notch() =>
    FloorRoom.rect(id: 'n', name: 'N', x: 3, y: 0, w: 3, h: 3);

const _v1 = {
  'version': 1,
  'grid': {'cols': 20, 'rows': 26, 'cellMeters': 0.5},
  'rooms': [
    {
      'id': 'wz',
      'name': 'Wohnen',
      'areaId': 'wohnen',
      'x': 0,
      'y': 0,
      'w': 10,
      'h': 8,
    },
    {
      'id': 'k',
      'name': 'Küche',
      'areaId': null,
      'x': 10,
      'y': 0,
      'w': 6,
      'h': 8,
    },
  ],
  'placements': [
    {
      'entityId': 'light.a',
      'roomId': 'wz',
      'rx': 0.5,
      'ry': 0.25,
      'kind': 'light',
    },
    {
      'entityId': 'sensor.b',
      'roomId': 'k',
      'rx': 1.0,
      'ry': 1.0,
      'deviceId': '0x01',
    },
    {'entityId': 'switch.weg', 'roomId': 'gibtsnicht', 'rx': 0.5, 'ry': 0.5},
  ],
  'coordinator': {'roomId': 'k', 'rx': 0.0, 'ry': 0.5},
  'updatedAt': 1763208000000,
};

void main() {
  group('JSON und Migration', () {
    test('Version 2 hin und zurück', () {
      final p = kFakeFloorPlan.withPlacement(
        const FloorPlacement(
          entityId: 'switch.x',
          x: 1,
          y: 2,
          kind: FloorKind.switchKind,
        ),
      );
      final json = p.toJson();
      expect(json['version'], 2);
      expect((json['rooms'] as List).first['points'], isA<List>());
      final back = HavenFloorPlan.decode(jsonEncode(json));
      expect(back, p);
      expect(back.coordinator, p.coordinator);
      expect(back.placementOf('switch.x')!.kind, FloorKind.switchKind);
      expect(back.migratedFrom, isNull);
    });

    test('Version 1: Rechtecke werden Polygone, rx/ry absolute Zellen', () {
      final p = HavenFloorPlan.fromJson(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(_v1)) as Map),
      );
      expect(p.migratedFrom, 1);
      expect(p.version, 2);
      // Raster wächst um den Rand für Draußen.
      expect((p.grid.cols, p.grid.rows), (26, 32));
      final wz = p.room('wz')!;
      expect(wz.points, [g(3, 3), g(13, 3), g(13, 11), g(3, 11)]);
      expect(wz.areaId, 'wohnen');
      // 0,5 x 10 = Zelle 5, 0,25 x 8 = Zelle 2, plus Rand 3.
      expect(p.placementOf('light.a')!.cell, g(8, 5));
      expect(p.placementOf('light.a')!.kind, FloorKind.light);
      // rx = 1 bleibt in der letzten Zelle des Raums.
      expect(p.placementOf('sensor.b')!.cell, g(18, 10));
      expect(p.placementOf('sensor.b')!.deviceId, '0x01');
      expect(p.locationOf(p.placementOf('sensor.b')!), 'k');
      expect(p.placementOf('switch.weg'), isNull, reason: 'Raum fehlt');
      expect(p.coordinator, g(13, 7));
      expect(p.locationOfCell(13, 7), 'k');
      expect(p.updatedAt, 1763208000000);
      expect(p.isValid, isTrue);
      // Beim Speichern steht Version 2 im Dokument.
      final saved = p.toJson();
      expect(saved['version'], 2);
      expect(HavenFloorPlan.fromJson(saved), p);
    });

    test('unbekannte Version', () {
      expect(
        () => HavenFloorPlan.fromJson({
          'version': 3,
          'grid': {'cols': 10, 'rows': 10},
          'rooms': [],
          'placements': [],
        }),
        throwsFormatException,
      );
    });

    test('Beispielgrundriss: gültig, L-Formen, schräge Wand, Draußen', () {
      final d = kFakeFloorPlan;
      expect(d.validate(), isEmpty);
      expect(d.rooms.map((r) => r.name), [
        'Salon',
        'Kochbereich',
        'Diele',
        'Ruheraum',
        'Waschraum',
      ]);
      expect(d.room('salon')!.points, hasLength(6), reason: 'L-Form');
      final slanted = d.room('ruheraum')!.points;
      var diagonal = false;
      for (var i = 0; i < slanted.length; i++) {
        final a = slanted[i];
        final b = slanted[(i + 1) % slanted.length];
        if (a.x != b.x && a.y != b.y) diagonal = true;
      }
      expect(diagonal, isTrue);
      expect(
        d.locationOf(d.placementOf('sensor.sensor_terrasse_temperature')!),
        kOutsideId,
      );
      expect(
        d
            .placementsAt('salon')
            .where((p) => p.entityId.contains('temperature')),
        hasLength(2),
      );
    });
  });

  group('Punkt im Polygon', () {
    test('innen, Rand, außen, Nische der L-Form', () {
      final l = _l();
      expect(l.locate(const Offset(1, 1)), PointLocation.inside);
      expect(l.locate(const Offset(4.5, 1)), PointLocation.outside);
      expect(l.locate(const Offset(3, 1)), PointLocation.boundary);
      expect(l.locate(const Offset(5, 3)), PointLocation.boundary);
      expect(l.locate(const Offset(5, 4)), PointLocation.inside);
      expect(l.locate(const Offset(-0.1, 2)), PointLocation.outside);
    });

    test('schräge Wand: Zellmitte auf der Kante gehört dem ersten Raum', () {
      final a = FloorRoom(
        id: 'a',
        name: 'A',
        points: [g(0, 0), g(4, 0), g(0, 4)],
      );
      final b = FloorRoom(
        id: 'b',
        name: 'B',
        points: [g(4, 0), g(4, 4), g(0, 4)],
      );
      final p = HavenFloorPlan(rooms: [a, b]);
      expect(p.isValid, isTrue, reason: 'gemeinsame schräge Kante');
      expect(p.locationOfCell(0, 0), 'a');
      expect(p.locationOfCell(3, 3), 'b');
      // (1,5; 2,5) liegt genau auf der Diagonalen.
      expect(p.locationOfCell(1, 2), isIn(['a', 'b']));
      expect(p.locationOfCell(9, 9), kOutsideId);
    });

    test('größtes inneres Rechteck liegt im Raum', () {
      final r = _l().innerRect;
      expect(r.width * r.height, greaterThanOrEqualTo(18));
      expect(_l().contains(r.center), isTrue);
      expect(_l().contains(_l().anchor), isTrue);
    });
  });

  group('Validierung', () {
    test('Überlappung', () {
      final p = _two().withRoom(
        FloorRoom.rect(id: 'c', name: 'C', x: 4, y: 2, w: 4, h: 4),
      );
      expect(p.validate().any((e) => e.contains('überlappt')), isTrue);
    });

    test('gemeinsame Kante und gemeinsame Ecke sind erlaubt', () {
      expect(_two().isValid, isTrue);
      final corner = _two().withRoom(
        FloorRoom.rect(id: 'c', name: 'C', x: 10, y: 6, w: 3, h: 3),
      );
      expect(corner.isValid, isTrue);
    });

    test('ineinandergreifend: L-Form und Nische', () {
      final p = HavenFloorPlan(rooms: [_l(), _notch()]);
      expect(p.isValid, isTrue);
      // Eine Zelle zu weit in die L-Form: überlappt.
      final over = FloorRoom.rect(id: 'n', name: 'N', x: 3, y: 0, w: 3, h: 4);
      expect(p.roomProblem(over), 'Überlappt L');
    });

    test('deckungsgleich, enthalten, Ränder auf Ecken', () {
      final a = FloorRoom.rect(id: 'a', name: 'A', x: 0, y: 0, w: 4, h: 4);
      final same = FloorRoom.rect(id: 'b', name: 'B', x: 0, y: 0, w: 4, h: 4);
      final inner = FloorRoom.rect(id: 'c', name: 'C', x: 1, y: 1, w: 2, h: 2);
      final tri = FloorRoom(
        id: 'd',
        name: 'D',
        points: [g(0, 0), g(4, 0), g(0, 4)],
      );
      // Raute, deren Spitzen auf der Kante von a liegen.
      final diamond = FloorRoom(
        id: 'e',
        name: 'E',
        points: [g(1, 0), g(2, -1), g(3, 0), g(2, 1)],
      );
      expect(a.overlaps(same), isTrue);
      expect(a.overlaps(inner), isTrue);
      expect(inner.overlaps(a), isTrue);
      expect(a.overlaps(tri), isTrue);
      expect(a.overlaps(diamond), isTrue);
      final outsideDiamond = FloorRoom(
        id: 'f',
        name: 'F',
        points: [g(1, 0), g(2, -2), g(3, 0)],
      );
      expect(a.overlaps(outsideDiamond), isFalse, reason: 'nur Kante');
    });

    test('Form: kreuzende Wände, zu klein, zu wenig Ecken, Raster', () {
      final bow = FloorRoom(
        id: 'x',
        name: 'X',
        points: [g(0, 0), g(4, 4), g(4, 0), g(0, 4)],
      );
      expect(_two().roomProblem(bow), 'Die Wände kreuzen sich');
      final tiny = FloorRoom.rect(id: 't', name: 'T', x: 12, y: 12, w: 1, h: 2);
      expect(_two().roomProblem(tiny), 'Der Raum ist zu klein');
      final two = FloorRoom(id: 'z', name: 'Z', points: [g(0, 0), g(4, 0)]);
      expect(_two().roomProblem(two), isNotNull);
      final out = FloorRoom.rect(id: 'o', name: 'O', x: 18, y: 0, w: 4, h: 4);
      expect(_two().roomProblem(out), 'Außerhalb des Rasters');
      final spike = FloorRoom(
        id: 's',
        name: 'S',
        points: [g(12, 12), g(16, 12), g(14, 12), g(14, 16)],
      );
      expect(_two().roomProblem(spike), 'Die Wände kreuzen sich');
    });

    test('Raum-ID outside ist vergeben', () {
      final p = HavenFloorPlan(
        rooms: [
          FloorRoom.rect(id: kOutsideId, name: 'X', x: 0, y: 0, w: 4, h: 4),
        ],
      );
      expect(p.isValid, isFalse);
    });
  });

  group('Editor-Operationen', () {
    test('Ecke ziehen, einfügen, entfernen', () {
      const grid = FloorGrid(cols: 20, rows: 20);
      final r = FloorRoom.rect(id: 'a', name: 'A', x: 2, y: 2, w: 6, h: 4);
      final moved = moveVertex(r, 1, g(10, 1), grid);
      expect(moved.points[1], g(10, 1));
      expect(moveVertex(r, 1, g(99, -5), grid).points[1], g(20, 0));

      final ins = insertVertex(r, 0)!;
      expect(ins.points, hasLength(5));
      expect(ins.points[1], g(5, 2), reason: 'Mitte der oberen Kante');
      final short = FloorRoom.rect(id: 's', name: 'S', x: 0, y: 0, w: 1, h: 4);
      expect(insertVertex(short, 0), isNull);

      final removed = removeVertex(ins, 1)!;
      expect(removed.points, r.points);
      final tri = removeVertex(r, 0)!;
      expect(tri.points, hasLength(3));
      expect(removeVertex(tri, 0), isNull, reason: 'mindestens drei Ecken');
      expect(simplifyRoom(ins).points, r.points);
    });

    test('Raum verschieben nimmt Geräte und Koordinator mit', () {
      final p = _two().withCoordinator(g(1, 1));
      final m = moveRoom(p.room('a')!, -5, 3, p.grid);
      expect((m.dx, m.dy), (0, 3), reason: 'im Raster gehalten');
      final q = p.withoutRoom('b').withRoomMoved('a', m.dx, m.dy);
      expect(q.placementOf('light.x')!.cell, g(3, 4));
      expect(q.coordinator, g(1, 4));
      expect(q.isValid, isTrue);
    });

    test('Raum löschen nimmt Geräte und Koordinator mit', () {
      final p = _two().withCoordinator(g(1, 1));
      final q = p.withoutRoom('a');
      expect(q.rooms.map((r) => r.id), ['b']);
      expect(q.placementOf('light.x'), isNull);
      expect(q.coordinator, isNull);
      expect(q.placementOf('sensor.t'), isNotNull);
    });

    test('Griffe: Ecke vor Kantenmitte, sonst nichts', () {
      const px = [
        Offset(0, 0),
        Offset(100, 0),
        Offset(100, 100),
        Offset(0, 100),
      ];
      expect(handleAt(px, const Offset(5, 4)), isA<VertexHandle>());
      final e = handleAt(px, const Offset(52, 3));
      expect(e, isA<EdgeHandle>());
      expect((e! as EdgeHandle).index, 0);
      expect(handleAt(px, const Offset(50, 50)), isNull);
    });
  });

  group('Positionen', () {
    test('Entity und Koordinator (Zellmitte)', () {
      final p = _two().withCoordinator(g(8, 5));
      expect(p.entityPosition('light.x'), const Offset(3.5, 1.5));
      expect(p.entityPosition('nix'), isNull);
      expect(p.coordinatorPosition(), const Offset(8.5, 5.5));
      expect(p.coordinatorPoint!.roomId, 'b');
    });

    test('Gerät über eine seiner Entities', () {
      final pts = _two().devicePoints([
        const FloorDevice('d1', ['sensor.battery', 'light.x'], roomId: 'b'),
      ]);
      expect(pts['d1'], const PlanPoint(3.5, 1.5, 'a'));
    });

    test('unplatzierte Geräte: eigene freie Zellen nahe der Mitte', () {
      final p = _two();
      final pts = p.devicePoints([
        for (var i = 0; i < 4; i++) FloorDevice('d$i', ['x$i'], roomId: 'a'),
        const FloorDevice('e', ['y'], roomId: 'bad'),
      ]);
      expect(pts.length, 5);
      final cells = [for (var i = 0; i < 4; i++) pts['d$i']!.cell];
      expect(cells.toSet(), hasLength(4));
      for (final c in cells) {
        expect(p.locationOfCell(c.x, c.y), 'a');
        expect(c, isNot(p.placementOf('light.x')!.cell));
      }
      expect(pts['e']!.roomId, 'b', reason: 'über die Bereichs-ID');
    });

    test('Gerät ohne Platzierung und ohne Raum fehlt', () {
      final pts = _two().devicePoints([
        const FloorDevice('d1', ['x']),
        const FloorDevice('d2', ['y'], roomId: 'unbekannt'),
      ]);
      expect(pts, isEmpty);
    });

    test('Schnell platzieren: freie, getrennte Zellen im Raum', () {
      final room = _l();
      for (final n in [1, 3, 6, 20]) {
        final cells = HavenFloorPlan.quickCells(room, n);
        expect(cells, hasLength(n));
        for (final c in cells) {
          expect(room.containsCell(c.x, c.y), isTrue);
        }
        if (n <= 6) expect(cells.toSet(), hasLength(n));
      }
      final busy = HavenFloorPlan.quickCells(
        room,
        1,
        occupied: {HavenFloorPlan.quickCells(room, 1).first},
      );
      expect(busy.first, isNot(HavenFloorPlan.quickCells(room, 1).first));
    });

    test('Draußen wie einen Raum wählen: freie Zellen rund ums Haus', () {
      final p = kFakeFloorPlan;
      final cells = p.outsideCells(4);
      expect(cells, hasLength(4));
      expect(cells.toSet(), hasLength(4));
      for (final c in cells) {
        expect(p.locationOfCell(c.x, c.y), kOutsideId);
        expect(p.outsideRect.contains(c.center), isTrue);
        expect(p.placements.any((x) => x.cell == c), isFalse);
      }
    });

    test('Draußen: Rand um die Wohnung im Raster', () {
      final p = kFakeFloorPlan;
      final o = p.outsideRect;
      expect(o.contains(p.houseBounds.topLeft), isTrue);
      expect(o.left, lessThan(p.houseBounds.left));
      final t = p.placementOf('sensor.sensor_terrasse_temperature')!;
      expect(o.contains(t.center), isTrue);
    });
  });

  group('Abstand (gap)', () {
    test('gap 0 lässt alles, wie es ist', () {
      final p = kFakeFloorPlan;
      for (final o in p.roomOffsets().values) {
        expect(o, Offset.zero);
      }
      expect(p.layoutBounds(), p.houseBounds);
    });

    test('Formen bleiben, Nachbarn rücken auseinander, stetig', () {
      final p = kFakeFloorPlan;
      final o2 = p.roomOffsets(gap: 2);
      final o1 = p.roomOffsets(gap: 1);
      for (final r in p.rooms) {
        // Halber Abstand, halbe Verschiebung (linear, also stetig).
        expect((o1[r.id]! * 2 - o2[r.id]!).distance, lessThan(1e-9));
      }
      List<Offset> moved(FloorRoom r) => [
        for (final q in r.offsets) q + o2[r.id]!,
      ];
      for (var i = 0; i < p.rooms.length; i++) {
        for (var j = i + 1; j < p.rooms.length; j++) {
          final a = moved(p.rooms[i]);
          final b = moved(p.rooms[j]);
          expect(polygonsOverlap(a, b), isFalse);
          // Jede Ecke von a hat Abstand zu b (keine gemeinsame Kante mehr).
          for (final q in a) {
            expect(locatePoint(b, q, tolerance: 0.3), PointLocation.outside);
          }
        }
      }
      // Punkte im Raum wandern mit dem Raum.
      final e = p.entityPosition('light.lampe_decke_salon')!;
      expect(
        p.entityPosition('light.lampe_decke_salon', gap: 2),
        e + o2['salon']!,
      );
      // Draußen rückt mit nach außen.
      final t = p.entityPosition('sensor.sensor_terrasse_temperature')!;
      final t2 = p.entityPosition(
        'sensor.sensor_terrasse_temperature',
        gap: 2,
      )!;
      expect(
        (t2 - p.explodeCenter).distance,
        greaterThan((t - p.explodeCenter).distance),
      );
    });
  });

  group('Gruppen', () {
    test('gleiche Zelle wird eine Gruppe, sonst einzeln', () {
      FloorNode n(String id, double x, double y) =>
          FloorNode(id: id, point: PlanPoint(x, y, 'a'));
      final r = groupFloorNodes([
        n('a', 1.5, 1.5),
        n('b', 1.2, 1.9),
        n('c', 2.5, 1.5),
        const FloorNode(
          id: 'd',
          point: PlanPoint(1.5, 1.5, 'a'),
          groupable: false,
        ),
      ]);
      expect(r.groups, hasLength(1));
      expect(r.groups.single.members.map((m) => m.id), ['a', 'b']);
      expect(r.groups.single.cell, g(1, 1));
      expect(r.single.map((m) => m.id), containsAll(['c', 'd']));
    });

    test('Beispiel: Tischlampe und Stehlampe teilen sich ein Feld', () {
      final p = kFakeFloorPlan;
      final nodes = [
        for (final x in p.placements)
          FloorNode(id: x.entityId, point: p.pointOfCell(x.cell)),
      ];
      final grp = groupFloorNodes(nodes).groups;
      expect(grp, hasLength(1));
      expect(grp.single.members.map((m) => m.id), {
        'light.tischlampe_salon',
        'light.lampe_salon',
      });
    });

    test('Auffächern verteilt im Kreis', () {
      final a = fanOffset(0, 3);
      final b = fanOffset(1, 3);
      expect(a.distance, closeTo(b.distance, 1e-9));
      expect((a - b).distance, greaterThan(40));
    });
  });
}
