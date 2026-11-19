import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/data/models/room_heating.dart';
import 'package:haven/data/models/snapshot.dart';
import 'package:haven/data/models/zigbee.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/map/climate_links.dart';

/// Ein Raum 12 × 8 Zellen, ein Tisch in der Mitte.
HavenFloorPlan _plan({List<FloorFurniture> furniture = const []}) =>
    HavenFloorPlan(
      rooms: [FloorRoom.rect(id: 'r', name: 'R', x: 0, y: 0, w: 12, h: 8)],
      furniture: furniture,
    );

bool _passesUnder(List<Offset> corners, FloorFurniture f) {
  for (var i = 0; i < corners.length - 1; i++) {
    final a = corners[i], b = corners[i + 1];
    final steps = (b - a).distance.round();
    for (var s = 0; s <= steps; s++) {
      final p = Offset.lerp(a, b, steps == 0 ? 0 : s / steps)!;
      if (f.contains(p)) return true;
    }
  }
  return false;
}

void main() {
  test('Leitung rechtwinklig, mit wenig Knicken', () {
    final path = routeOnFloor(
      _plan(),
      const GridPoint(1, 1),
      const GridPoint(9, 6),
    );
    expect(path.first, const Offset(1.5, 1.5));
    expect(path.last, const Offset(9.5, 6.5));
    for (var i = 0; i < path.length - 1; i++) {
      final d = path[i + 1] - path[i];
      expect(d.dx == 0 || d.dy == 0, isTrue, reason: 'rechtwinklig');
    }
    expect(path.length, 3, reason: 'ein Knick genügt');
  });

  test('Leitung läuft um Möbel herum', () {
    const table = FloorFurniture(
      id: 't',
      kind: 'dining_table',
      x: 6,
      y: 4,
      w: 4,
      h: 4,
    );
    final plan = _plan(furniture: [table]);
    final path = routeOnFloor(
      plan,
      const GridPoint(1, 4),
      const GridPoint(10, 4),
    );
    expect(_passesUnder(path, table), isFalse);
    // Ein Teppich hält nicht auf.
    const rug = FloorFurniture(id: 'u', kind: 'rug', x: 6, y: 4, w: 4, h: 4);
    final under = routeOnFloor(
      _plan(furniture: [rug]),
      const GridPoint(1, 4),
      const GridPoint(10, 4),
    );
    expect(under, [const Offset(1.5, 4.5), const Offset(10.5, 4.5)]);
  });

  test('Ganz zugestellt: notfalls unter dem Möbel durch', () {
    const wall = FloorFurniture(
      id: 'w',
      kind: 'wardrobe',
      x: 6,
      y: 4,
      w: 2,
      h: 8,
    );
    final path = routeOnFloor(
      _plan(furniture: [wall]),
      const GridPoint(1, 4),
      const GridPoint(10, 4),
    );
    expect(path.first, const Offset(1.5, 4.5));
    expect(path.last, const Offset(10.5, 4.5));
  });

  test(
    'Entwicklungsdaten: Thermometer des Salons führen zum Thermostat',
    () async {
      final repo = FakeRepository(simulate: false);
      await repo.start();
      addTearDown(repo.dispose);
      final rooms = (await repo.heatingRooms()).rooms;
      final links = climateLinks(
        plan: kFakeFloorPlan,
        heating: rooms,
        snapshot: repo.snapshot,
        zigbee: await repo.zigbeeDevices(),
      );
      final sensors = links.where((l) => l.kind == ClimateLinkKind.sensor);
      expect(sensors, isNotEmpty);
      // Salon heizt in den Entwicklungsdaten: die Leitungen wirken.
      expect(sensors.every((l) => l.state == ClimateLinkState.active), isTrue);
      expect(sensors.map((l) => l.to).toSet(), hasLength(1));
    },
  );

  test('Freigegebenes Thermostat: Leitung ruht gestrichelt', () {
    final plan = HavenFloorPlan(
      rooms: [FloorRoom.rect(id: 'r', name: 'R', x: 0, y: 0, w: 10, h: 6)],
      placements: const [
        FloorPlacement(entityId: 'sensor.t', x: 1, y: 1),
        FloorPlacement(entityId: 'climate.trv', x: 8, y: 4),
      ],
    );
    final room = RoomHeating(
      const HeatingConfig(areaId: 'r', trvs: ['0x1'], sensors: ['sensor.t']),
      const HeatingStatus(
        heating: true,
        trvs: [HeatingTrvStatus(ieee: '0x1', heating: true, released: true)],
      ),
    );
    final links = climateLinks(
      plan: plan,
      heating: [room],
      snapshot: const HavenSnapshot(),
      zigbee: const [
        ZbDevice(ieee: '0x1', friendlyName: 'TRV', haEntities: ['climate.trv']),
      ],
    );
    expect(links.single.state, ClimateLinkState.released);
  });
}
