import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/ha/ha_repository.dart';
import 'package:haven/data/models/entity_state.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/data/models/snapshot.dart';
import 'package:haven/data/models/zigbee.dart';
import 'package:haven/features/map/device_pool.dart';

import '../../support/live_fixtures.dart';

/// Pool des Grundriss-Editors gegen die anonymisierten Live-Geräte: 42 Zigbee-Geräte
/// statt 92 Entities.
void main() {
  final entities = liveEntities();
  final rooms = HaRepository.roomsFromHaven(
    liveRooms(),
    liveGroups(),
    entities,
  );
  final zigbee = [
    for (final d in liveDevices()['devices'] as List)
      ZbDevice.fromJson(Map<String, dynamic>.from(d as Map)),
  ];
  final snap = HavenSnapshot(entities: entities, rooms: rooms);
  final plan = HavenFloorPlan(
    rooms: [
      FloorRoom.rect(
        id: 'wz',
        name: 'Salon',
        areaId: 'salon',
        x: 0,
        y: 0,
        w: 10,
        h: 8,
      ),
      FloorRoom.rect(
        id: 'k',
        name: 'Kochbereich',
        areaId: 'kochbereich',
        x: 10,
        y: 0,
        w: 6,
        h: 6,
      ),
    ],
  );

  test('ein Eintrag je Zigbee-Gerät, nach Raum, mit Hauptentity', () {
    final pool = buildDevicePool(snap, zigbee, plan);
    expect(pool.zigbee.total, 42);
    expect(pool.zigbee.placed, 0);
    final all = pool.zigbee.groups.expand((g) => g.devices).toList();
    expect(all, hasLength(42));
    for (final d in all) {
      final domain = d.mainEntityId.split('.').first;
      expect(
        const {'update', 'button', 'number', 'select'}.contains(domain),
        isFalse,
        reason: '${d.name}: ${d.mainEntityId}',
      );
    }
    PoolDevice byName(String n) => all.firstWhere((d) => d.name == n);
    expect(
      byName('Steckdose Messung 1').mainEntityId,
      'switch.steckdose_messung_1',
    );
    expect(byName('Lüfter Waschraum').mainEntityId, 'switch.lufter_waschraum');
    expect(
      byName('Präsenz Waschraum').mainEntityId,
      'binary_sensor.prasenz_waschraum_presence',
    );
    expect(byName('Präsenz Waschraum').kind, FloorKind.presence);
    expect(
      byName('Sensor Salon').mainEntityId,
      'sensor.sensor_salon_temperature',
    );
    expect(
      byName('Kontaktsensor Schrank').mainEntityId,
      'binary_sensor.kontaktsensor_schrank_contact',
    );
    expect(byName('Kontaktsensor Schrank').kind, FloorKind.contact);
    expect(byName('Drehknopf Kochbereich').kind, FloorKind.remote);
    expect(
      byName('Drehknopf Kochbereich').mainEntityId,
      'sensor.drehknopf_kochbereich_battery',
    );

    // Raumreihenfolge wie in den Räumen, „Ohne Raum“ zuletzt.
    final titles = pool.zigbee.groups.map((g) => g.title).toList();
    expect(titles.first, 'Kochbereich');
    expect(titles.last, kNoRoom);
    expect(
      pool.zigbee.groups.firstWhere((g) => g.title == 'Salon').devices,
      hasLength(16),
    );
  });

  test('Weitere Geräte: nur sinnvolle Arten, nie update, button, Gruppen', () {
    // Integration 0.1.0: keine Geräteliste, Lampen und Klima der Räume.
    final pool = buildDevicePool(snap, zigbee, plan);
    final other = pool.other.groups
        .expand((g) => g.devices)
        .map((d) => d.mainEntityId);
    expect(other, contains('light.zusatzlicht_1'));
    expect(other, isNot(contains('light.salon')), reason: 'Lichtgruppe');
    expect(other.where((id) => id.startsWith('light.zg')), isEmpty);

    // Integration 0.2.0: Geräte mit ihren Haupt-Entities.
    final esp = {
      ...entities,
      'update.kamera_firmware': const EntityState(
        'update.kamera_firmware',
        'off',
      ),
      'button.kamera_restart': const EntityState(
        'button.kamera_restart',
        'unknown',
      ),
      'sensor.kamera_wifi': const EntityState('sensor.kamera_wifi', '-60', {
        'device_class': 'signal_strength',
      }),
      'media_player.salon_tv': const EntityState(
        'media_player.salon_tv',
        'off',
      ),
    };
    final rooms2 = liveRooms();
    final wz =
        (rooms2['rooms'] as List).firstWhere(
              (r) => (r as Map)['area_id'] == 'salon',
            )
            as Map;
    wz['devices'] = [
      {
        'device_id': 'cam',
        'name': 'Testkamera',
        'entities': [
          'update.kamera_firmware',
          'button.kamera_restart',
          'sensor.kamera_wifi',
        ],
      },
      {
        'device_id': 'tv',
        'name': 'Fernseher',
        'entities': ['media_player.salon_tv', 'button.kamera_restart'],
      },
      {
        'device_id': 'drucker',
        'name': 'Snapmaker U1',
        'entities': ['light.zusatzlicht_1', 'update.kamera_firmware'],
      },
    ];
    final snap2 = HavenSnapshot(
      entities: esp,
      rooms: rooms,
      devices: HaRepository.devicesFromHaven(rooms2),
    );
    final pool2 = buildDevicePool(snap2, zigbee, plan);
    final names = pool2.other.groups
        .expand((g) => g.devices)
        .map((d) => d.name)
        .toList();
    expect(names, containsAll(['Fernseher', 'Snapmaker U1']));
    expect(
      names,
      isNot(contains('Testkamera')),
      reason: 'nur Diagnose und Knöpfe',
    );
    final tv = pool2.all.firstWhere((d) => d.id == 'tv');
    expect(tv.mainEntityId, 'media_player.salon_tv');
    expect(tv.kind, FloorKind.media);
  });

  test('platziert ist das Gerät: Hauptentity, die anderen erben', () {
    final pool = buildDevicePool(snap, zigbee, plan);
    final bad = pool.all.firstWhere((d) => d.name == 'Präsenz Salon');
    final placed = plan.withPlacement(
      FloorPlacement(
        entityId: bad.mainEntityId,
        x: 3,
        y: 3,
        kind: bad.kind,
        deviceId: bad.id,
      ),
    );
    final after = buildDevicePool(snap, zigbee, placed);
    expect(after.zigbee.placed, 1);
    expect(
      after.all.where((d) => !isPlaced(d, placed)),
      hasLength(after.all.length - 1),
    );
    // Jede Entity des Geräts liegt an derselben Stelle (Netzgraph, Karte).
    final pts = placed.devicePoints([bad.floorDevice]);
    expect(pts[bad.id], const PlanPoint(3.5, 3.5, 'wz'));
    final json = HavenFloorPlan.decode(placed.encode());
    expect(json.placements.single.deviceId, bad.id);
    expect(json.placements.single.kind, FloorKind.presence);
  });

  test('alte Pläne: Platzierungen je Entity werden zu einer je Gerät', () {
    final pool = buildDevicePool(snap, zigbee, plan);
    final dev = pool.all.firstWhere((d) => d.name == 'Präsenz Salon');
    final old = plan.withPlacements(const [
      FloorPlacement(entityId: 'sensor.prasenz_salon_temperature', x: 2, y: 2),
      FloorPlacement(
        entityId: 'binary_sensor.prasenz_salon_presence',
        x: 7,
        y: 5,
      ),
      FloorPlacement(entityId: 'light.tischlampe_salon', x: 5, y: 4),
    ]);
    final m = old.migrateDevices(
      [for (final d in pool.all) d.floorDevice],
      kinds: {for (final d in pool.all) d.id: d.kind},
    );
    expect(m.placements, hasLength(2));
    final p = m.placements.firstWhere((p) => p.deviceId == dev.id);
    expect(p.entityId, dev.mainEntityId);
    expect((p.x, p.y), (7, 5), reason: 'Platzierung der Hauptentity bleibt');
    expect(m.isValid, isTrue);
    expect(
      identical(m.migrateDevices([for (final d in pool.all) d.floorDevice]), m),
      isTrue,
    );
  });

  test('Schnell platzieren: freie Zellen um die Raummitte', () {
    final room = FloorRoom.rect(
      id: 'wz',
      name: 'Salon',
      x: 0,
      y: 0,
      w: 10,
      h: 8,
    );
    for (final n in [1, 2, 5, 16]) {
      final cells = HavenFloorPlan.quickCells(room, n);
      expect(cells, hasLength(n));
      expect(cells.toSet(), hasLength(n), reason: 'n=$n');
      for (final c in cells) {
        expect(room.containsCell(c.x, c.y), isTrue);
      }
      final cx = cells.map((c) => c.x + 0.5).reduce((a, b) => a + b) / n;
      expect(cx, closeTo(5, 2.5));
    }
  });

  test(
    'Thermostat-Displays stehen an der Wand, Heizkörperthermostate nicht',
    () {
      ZbDevice d(String ieee, String description, {String? model}) =>
          ZbDevice.fromJson({
            'ieee': ieee,
            'friendly_name': ieee,
            'type': 'EndDevice',
            'device_type': 'thermostat',
            'description': description,
            'model': ?model,
          });
      expect(isWallThermostat(d('a', 'Wall thermostat with display.')), isTrue);
      expect(isWallThermostat(d('b', 'Thermostatic radiator valve')), isFalse);
      expect(
        isWallThermostat(d('c', 'Smart thermostat', model: 'TRV06')),
        isFalse,
      );
      // In der Heizungsregelung als Display eingetragen.
      expect(
        isWallThermostat(d('c', 'Smart thermostat'), displays: {'c'}),
        isTrue,
      );
      final pool = buildDevicePool(snap, zigbee, plan);
      for (final p in pool.all.where((p) => p.zigbee)) {
        final z = zigbee.firstWhere((z) => z.ieee == p.id);
        expect(p.model, isWallThermostat(z) ? kWallThermostatModel : isNull);
      }
    },
  );
}
