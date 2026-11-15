import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/features/map/floor_editor_ops.dart';

HavenFloorPlan _two() => const HavenFloorPlan(
  rooms: [
    FloorRoom(id: 'a', name: 'A', x: 0, y: 0, w: 6, h: 6),
    FloorRoom(id: 'b', name: 'B', x: 6, y: 0, w: 4, h: 6, areaId: 'bad'),
  ],
  placements: [
    FloorPlacement(entityId: 'light.x', roomId: 'a', rx: 0.5, ry: 0.25),
    FloorPlacement(entityId: 'sensor.t', roomId: 'b', rx: 0.25, ry: 0.5),
  ],
);

void main() {
  group('JSON', () {
    test('hin und zurück', () {
      final p = kFakeFloorPlan.copyWith(
        placements: [
          ...kFakeFloorPlan.placements,
          const FloorPlacement(
            entityId: 'switch.x',
            roomId: 'bad',
            rx: 0.1,
            ry: 0.2,
            kind: FloorKind.switchKind,
          ),
        ],
      );
      final back = HavenFloorPlan.decode(jsonEncode(p.toJson()));
      expect(back, p);
      expect(back.coordinator, p.coordinator);
      expect(back.placementOf('switch.x')!.kind, FloorKind.switchKind);
    });

    test('Version muss 1 sein', () {
      expect(
        () => HavenFloorPlan.fromJson({
          'version': 2,
          'grid': {'cols': 10, 'rows': 10},
          'rooms': [],
          'placements': [],
        }),
        throwsFormatException,
      );
    });

    test('Beispielgrundriss ist gültig und hat die fünf Räume', () {
      final d = kFakeFloorPlan;
      expect(d.validate(), isEmpty);
      expect(d.rooms.map((r) => r.name), [
        'Salon',
        'Kochbereich',
        'Diele',
        'Ruheraum',
        'Waschraum',
      ]);
    });
  });

  group('Validierung', () {
    test('Überlappung', () {
      final p = _two().withRoom(
        const FloorRoom(id: 'c', name: 'C', x: 4, y: 2, w: 4, h: 4),
      );
      expect(p.validate().any((e) => e.contains('überlappt')), isTrue);
    });

    test('gemeinsame Kante ist erlaubt', () {
      expect(_two().isValid, isTrue);
    });

    test('Mindestgröße und Raster', () {
      const small = FloorRoom(id: 's', name: 'S', x: 0, y: 8, w: 2, h: 5);
      expect(_two().withRoom(small).isValid, isFalse);
      const out = FloorRoom(id: 'o', name: 'O', x: 18, y: 0, w: 4, h: 4);
      expect(_two().roomProblem(out), isNotNull);
      expect(
        _two().roomProblem(
          const FloorRoom(id: 'n', name: 'N', x: 0, y: 6, w: 3, h: 3),
        ),
        isNull,
      );
    });

    test('Platzierung mit unbekanntem Raum', () {
      final p = _two().withPlacement(
        const FloorPlacement(
          entityId: 'light.y',
          roomId: 'zzz',
          rx: 0.5,
          ry: 0.5,
        ),
      );
      expect(p.isValid, isFalse);
    });
  });

  group('Änderungen', () {
    test('Raum löschen nimmt Platzierungen und Koordinator mit', () {
      final p = _two().withCoordinator(const PlanPoint('a', 0.5, 0.5));
      final q = p.withoutRoom('a');
      expect(q.rooms.map((r) => r.id), ['b']);
      expect(q.placementOf('light.x'), isNull);
      expect(q.coordinator, isNull);
      expect(q.placementOf('sensor.t'), isNotNull);
    });

    test('Platzierungen wandern relativ mit dem Raum', () {
      final p = _two();
      final moved = p.withRoom(p.room('a')!.copyWith(x: 2, y: 3));
      expect(p.entityPosition('light.x'), const Offset(3, 1.5));
      expect(moved.entityPosition('light.x'), const Offset(5, 4.5));
    });

    test('Ziehen: Größe und Verschieben rasten ein', () {
      final grid = const FloorGrid();
      const r = FloorRoom(id: 'a', name: 'A', x: 2, y: 2, w: 6, h: 6);
      final big = resizeRoom(
        r,
        FloorSide.right | FloorSide.bottom,
        12,
        11,
        grid,
      );
      expect((big.x, big.y, big.w, big.h), (2, 2, 10, 9));
      final tiny = resizeRoom(r, FloorSide.left, 99, 0, grid);
      expect(tiny.w, kMinRoomCells);
      expect(tiny.x + tiny.w, 8);
      final outside = resizeRoom(r, FloorSide.right, 50, 0, grid);
      expect(outside.x + outside.w, grid.cols);
      final m = moveRoom(r, -9, 40, grid);
      expect((m.x, m.y), (0, grid.rows - 6));
    });
  });

  group('Positionen', () {
    test('Entity und Koordinator', () {
      final p = _two().withCoordinator(const PlanPoint('b', 0.5, 1));
      expect(p.entityPosition('light.x'), const Offset(3, 1.5));
      expect(p.entityPosition('sensor.t'), const Offset(7, 3));
      expect(p.entityPosition('nix'), isNull);
      expect(p.coordinatorPosition(), const Offset(8, 6));
      expect(p.coordinatorPosition(gap: 2), const Offset(10, 6));
    });

    test('Gerät: über eine seiner Entities', () {
      final p = _two();
      final pts = p.devicePoints([
        const FloorDevice('d1', ['sensor.battery', 'light.x'], roomId: 'b'),
      ]);
      expect(pts['d1'], const PlanPoint('a', 0.5, 0.25));
    });

    test('Gerät ohne Platzierung: Raummitte, über Bereichs-ID', () {
      final pts = _two().devicePoints([
        const FloorDevice('d1', ['sensor.nix'], roomId: 'bad'),
      ]);
      expect(pts['d1'], const PlanPoint('b', 0.5, 0.5));
    });

    test('mehrere unplatzierte Geräte liegen im Kreis um die Mitte', () {
      final p = _two();
      final pts = p.devicePoints([
        for (var i = 0; i < 4; i++) FloorDevice('d$i', ['x$i'], roomId: 'a'),
      ]);
      expect(pts.length, 4);
      final cells = {for (final e in pts.entries) e.key: p.cellOf(e.value)};
      const mid = Offset(3, 3);
      for (final c in cells.values) {
        expect((c - mid).distance, closeTo(1.0, 0.001));
        expect(p.room('a')!.rect.contains(c), isTrue);
      }
      final list = cells.values.toList();
      for (var i = 0; i < list.length; i++) {
        for (var j = i + 1; j < list.length; j++) {
          expect((list[i] - list[j]).distance, greaterThan(1.0));
        }
      }
    });

    test('Gerät ohne Platzierung und ohne Raum fehlt', () {
      final pts = _two().devicePoints([
        const FloorDevice('d1', ['x']),
        const FloorDevice('d2', ['y'], roomId: 'unbekannt'),
      ]);
      expect(pts, isEmpty);
    });
  });

  group('layout(gap)', () {
    test('gap 0 entspricht den Räumen', () {
      final p = kFakeFloorPlan;
      final l = p.layout();
      for (final r in p.rooms) {
        expect(l[r.id], r.rect);
      }
    });

    test('Räume behalten ihre Größe und haben mindestens gap Abstand', () {
      final p = kFakeFloorPlan;
      for (final gap in [0.5, 1.0, 2.0]) {
        final l = p.layout(gap: gap);
        for (final r in p.rooms) {
          expect(l[r.id]!.size, r.rect.size);
        }
        for (var i = 0; i < p.rooms.length; i++) {
          for (var j = i + 1; j < p.rooms.length; j++) {
            final a = l[p.rooms[i].id]!;
            final b = l[p.rooms[j].id]!;
            // Der Abstand der Rechtecke (0 bei Überschneidung der Spannen).
            final dx = a.left >= b.right
                ? a.left - b.right
                : (b.left >= a.right ? b.left - a.right : 0.0);
            final dy = a.top >= b.bottom
                ? a.top - b.bottom
                : (b.top >= a.bottom ? b.top - a.bottom : 0.0);
            expect(a.overlaps(b), isFalse);
            // Waren sie Nachbarn (Kante an Kante), gilt jetzt gap.
            final o = p.rooms[i].rect;
            final q = p.rooms[j].rect;
            final touchX = o.right == q.left || q.right == o.left;
            final touchY = o.bottom == q.top || q.bottom == o.top;
            if (touchX && o.top < q.bottom && q.top < o.bottom) {
              expect(dx, greaterThanOrEqualTo(gap - 1e-9));
            }
            if (touchY && o.left < q.right && q.left < o.right) {
              expect(dy, greaterThanOrEqualTo(gap - 1e-9));
            }
          }
        }
      }
    });

    test('stetig und Positionen wandern mit', () {
      final p = kFakeFloorPlan;
      final b0 = p.layoutBounds();
      final b2 = p.layoutBounds(gap: 2);
      expect(b2.width, greaterThan(b0.width));
      expect(b2.height, greaterThan(b0.height));
      // Kochbereich ist die zweite linke Kante in x und die erste in y.
      final k0 = p.entityPosition('light.kochbereich_arbeitslicht_2')!;
      final k2 = p.entityPosition('light.kochbereich_arbeitslicht_2', gap: 2)!;
      expect(k2.dx - k0.dx, 2);
      expect(k2.dy - k0.dy, 0);
      final k1 = p.entityPosition('light.kochbereich_arbeitslicht_2', gap: 1)!;
      expect(k1.dx - k0.dx, 1);
    });
  });
}
