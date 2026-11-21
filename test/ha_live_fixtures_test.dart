import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/ha/ha_client.dart';
import 'package:haven/data/ha/ha_repository.dart';
import 'package:haven/data/light_targets.dart';
import 'package:haven/data/models/lamp_calibration.dart';
import 'package:haven/data/models/light_groups.dart';
import 'package:haven/data/models/room.dart';
import 'package:haven/data/storage/settings_store.dart';

import 'support/fake_ha.dart';
import 'support/live_fixtures.dart';

/// Tests gegen anonymisierte Antworten einer echten HA-Installation (Integration 0.1.0).
void main() {
  Future<(HaRepository, LiveHa)> start({LiveHa? ha, LocalPrefs? local}) async {
    final live = ha ?? LiveHa();
    final client = HaClient(
      url: 'http://ha.local:8123',
      token: 't',
      pingInterval: const Duration(minutes: 5),
      channelFactory: (_) {
        final c = FakeChannel();
        live.channels.add(c);
        c.server.onMessage = live.respond;
        scheduleMicrotask(c.server.greet);
        return c;
      },
    );
    final repo = HaRepository(
      url: 'x',
      token: 'y',
      client: client,
      localPrefs: local,
      registryDebounce: const Duration(milliseconds: 20),
    );
    await repo.start();
    await until(() => repo.snapshot.rooms.isNotEmpty);
    return (repo, live);
  }

  Room room(HaRepository r, String id) =>
      r.snapshot.rooms.firstWhere((x) => x.id == id);

  group('Live-Fixtures: Räume', () {
    test('Salon hat 6 Lampen, Kochbereich 2, Gruppen zählen nicht', () async {
      final (repo, _) = await start();
      final s = repo.snapshot;
      final wz = room(repo, 'salon');
      expect(wz.lightIds, hasLength(6));
      expect(wz.lightIds, isNot(contains('light.salon')));
      expect(wz.lightGroupIds, ['light.salon']);
      expect(wz.groupEntityId, 'light.zgsalon');
      expect(s.lampsOf(wz).map((l) => l.entityId), wz.lightIds);
      expect(s.lampsOf(room(repo, 'kochbereich')), hasLength(2));
      expect(room(repo, 'kochbereich').groupEntityId, 'light.zgkochbereich');
      expect(s.lampsOf(room(repo, 'ruheraum')), hasLength(4));
      expect(s.lampsOf(room(repo, 'zone')), isEmpty);
      await repo.dispose();
    });

    test('Format 0.2.0: light_groups, group_entity und devices', () {
      final res = liveRooms();
      for (final r in res['rooms'] as List) {
        final room = r as Map;
        if (room['area_id'] != 'salon') continue;
        room['lights'] = [
          for (final l in room['lights'] as List)
            if (l != 'light.salon') l,
        ];
        room['light_groups'] = [
          {
            'entity_id': 'light.salon',
            'type': 'ha_group',
            'name': 'Salon',
            'members': <String>[],
            'z2m_group_id': null,
          },
        ];
        room['group_entity'] = 'light.zgsalon';
        room['devices'] = [
          {
            'device_id': 'd1',
            'name': 'Snapmaker U1',
            'manufacturer': 'Snapmaker',
            'model': 'U1',
            'ieee': null,
            'entities': ['light.zusatzlicht_1'],
          },
        ];
      }
      final rooms = HaRepository.roomsFromHaven(
        res,
        liveGroups(),
        liveEntities(),
      );
      final wz = rooms.firstWhere((r) => r.id == 'salon');
      expect(wz.lightIds, hasLength(6));
      expect(wz.lightGroupIds, ['light.salon']);
      expect(wz.groupEntityId, 'light.zgsalon');
      final devices = HaRepository.devicesFromHaven(res);
      final d = devices.firstWhere((d) => d.id == 'd1');
      expect(d.areaId, 'salon');
      expect(
        devices.where((d) => d.areaId == null),
        isNotEmpty,
        reason: 'unassigned',
      );
    });

    test('Gruppenerkennung an echten Attributen', () {
      final e = liveEntities();
      expect(isLightGroup(e['light.salon']!), isTrue);
      expect(isLightGroup(e['light.zgsalon']!), isTrue);
      expect(isLightGroup(e['light.zgkochbereich']!), isTrue);
      expect(isLightGroup(e['light.lampe_salon']!), isFalse);
      expect(isLightGroup(e['light.zusatzlicht_1']!), isFalse);
      expect(
        lightGroupMembers(e['light.zgkochbereich']),
        unorderedEquals([
          'light.kochbereich_arbeitslicht_2',
          'light.kochbereich_arbeitslicht_1',
        ]),
      );
    });

    test('Raum war leer, nach Raum setzen sofort aktuell (Bug 1)', () async {
      // Stand beim Verbinden: noch kein Gerät in einem Bereich.
      final live = LiveHa();
      var assigned = false;
      live.answers['haven/rooms'] = (_) {
        if (assigned) return liveRooms();
        final r = liveRooms();
        for (final room in r['rooms'] as List) {
          (room as Map)['lights'] = <String>[];
          room['zigbee_lights'] = <String>[];
        }
        return r;
      };
      live.answers['haven/zigbee/set_area'] = (_) {
        assigned = true;
        return {'ok': true};
      };
      final (repo, _) = await start(ha: live);
      expect(repo.snapshot.lampsOf(room(repo, 'salon')), isEmpty);

      await repo.zigbeeSetArea('0x00124b0000000001', 'salon');
      expect(
        repo.snapshot.lampsOf(room(repo, 'salon')),
        hasLength(6),
        reason: 'Räume werden nach dem eigenen Schreibbefehl neu geladen',
      );
      await repo.dispose();
    });

    test('Registry-Ereignisse laden die Räume neu, gebündelt', () async {
      final live = LiveHa();
      var lights = <String>[];
      live.answers['haven/rooms'] = (_) {
        final r = liveRooms();
        for (final room in r['rooms'] as List) {
          if ((room as Map)['area_id'] == 'kochbereich') {
            room['lights'] = lights;
          }
        }
        return r;
      };
      final (repo, _) = await start(ha: live);
      expect(room(repo, 'kochbereich').lightIds, isEmpty);
      for (final t in HaRepository.registryEvents) {
        expect(live.subscriptions, contains(t));
      }
      final before = live.received
          .where((m) => m['type'] == 'haven/rooms')
          .length;

      lights = [
        'light.kochbereich_arbeitslicht_1',
        'light.kochbereich_arbeitslicht_2',
      ];
      live.fire('device_registry_updated', {'action': 'update'});
      live.fire('entity_registry_updated', {'action': 'update'});
      live.fire('area_registry_updated', {'action': 'update'});
      await until(() => room(repo, 'kochbereich').lightIds.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final after = live.received
          .where((m) => m['type'] == 'haven/rooms')
          .length;
      expect(after - before, 1, reason: 'drei Ereignisse, ein Neuladen');
      await repo.dispose();
    });
  });

  group('Live-Fixtures: Raumsteuerung', () {
    test('Kochbereich schaltet über die Z2M-Gruppe', () async {
      final (repo, live) = await start();
      await repo.toggleRoom('kochbereich'); // aus -> an
      await until(() => live.calls().isNotEmpty);
      final call = live.calls().last;
      expect(call['service'], 'turn_on');
      expect(call['target'], {
        'entity_id': ['light.zgkochbereich'],
      });
      expect(
        repo.snapshot.lampsOf(room(repo, 'kochbereich')).every((l) => l.on),
        isTrue,
        reason: 'optimistisch für die einzelnen Lampen',
      );
      await repo.dispose();
    });

    test('Salon: Gruppe mit fremder Lampe wird nicht genommen', () async {
      final (repo, live) = await start();
      final wz = room(repo, 'salon');
      // ZGSalon enthält light.lampe_ruhebett aus dem Ruheraum.
      final targets = lightCallTargets(
        repo.snapshot.controlledLightIds(wz),
        repo.snapshot.rooms,
        repo.snapshot.entities,
      );
      expect(targets, isNot(contains('light.zgsalon')));
      expect(targets, isNot(contains('light.salon')));
      await repo.allLightsOff();
      await until(() => live.calls().isNotEmpty);
      final ids = (live.calls().last['target'] as Map)['entity_id'] as List;
      expect(ids, isNot(contains('light.salon')));
      expect(ids.where((i) => '$i'.startsWith('light.zg')), [
        'light.zgkochbereich',
        'light.zgruheraum',
        'light.zgwaschraum',
      ]);
      await repo.dispose();
    });
  });

  group('Live-Fixtures: Ausnahmen (Prefs)', () {
    test(
      'zentral in HA: gespeichert, nicht gezählt, nicht geschaltet',
      () async {
        final live = LiveHa()
          ..prefs = {
            'excluded_lights': ['light.zusatzlicht_2'],
          };
        final (repo, _) = await start(ha: live);
        expect(repo.prefsShared, isTrue);
        expect(
          repo.snapshot.lampsOf(room(repo, 'gasteraum')).map((l) => l.entityId),
          ['light.lampe_waschraum'],
        );

        await repo.setLightExcluded('light.zusatzlicht_1', true);
        final set = live.received.lastWhere(
          (m) => m['type'] == 'haven/prefs/set',
        );
        expect((set['prefs'] as Map)['excluded_lights'], [
          'light.zusatzlicht_1',
          'light.zusatzlicht_2',
        ]);
        final wz = room(repo, 'salon');
        expect(repo.snapshot.lampsOf(wz), hasLength(5));
        expect(
          repo.snapshot.excludedLampsOf(wz).single.entityId,
          'light.zusatzlicht_1',
        );

        await repo.allLightsOff();
        await until(() => live.calls().isNotEmpty);
        final ids = (live.calls().last['target'] as Map)['entity_id'] as List;
        expect(ids, isNot(contains('light.zusatzlicht_1')));
        expect(ids, isNot(contains('light.zusatzlicht_2')));
        await repo.dispose();
      },
    );

    test('Integration 0.1.0 ohne prefs: lokal gespeichert', () async {
      final local = MemoryPrefs({'light.zusatzlicht_1'});
      final (repo, live) = await start(
        ha: LiveHa(prefsSupported: false),
        local: local,
      );
      expect(repo.prefsShared, isFalse);
      expect(repo.snapshot.lampsOf(room(repo, 'salon')), hasLength(5));
      await repo.setLightExcluded('light.zusatzlicht_1', false);
      expect(local.excludedLights, isEmpty);
      expect(
        live.received.where((m) => m['type'] == 'haven/prefs/set'),
        isEmpty,
      );
      expect(repo.snapshot.lampsOf(room(repo, 'salon')), hasLength(6));
      await repo.dispose();
    });
  });

  group('Live-Fixtures: Lampen kalibrieren', () {
    test(
      'Modelle aus Zigbee2MQTT, Korrektur in prefs, Fremdes bleibt',
      () async {
        final live = LiveHa()
          ..prefs = {
            'excluded_lights': <String>[],
            'zukunft': {'von': 'neuerer App'},
            'lamp_calibration': {
              'Tuya|TS0505B_hs': {
                'white': [
                  [2700, 3600],
                ],
              },
            },
          };
        final (repo, _) = await start(ha: live);
        await until(() => repo.snapshot.lampModels.length >= 10);
        final s = repo.snapshot;
        expect(s.lampModels['light.lampe_decke_salon']!.key, 'Tuya|TS0505B_hs');
        expect(
          s.lampModels['light.kochbereich_arbeitslicht_1']!.model,
          'YSR-MINI-01_dimmer',
        );
        expect(s.calibrationFor('light.lampe_waschraum').mapKelvin(2700), 3600);
        expect(s.calibrationFor('light.tischlampe_salon').isIdentity, isTrue);

        await repo.setLampCalibration(
          s.lampCalibration.withModel(
            'YSRSAI|YSR-MINI-01_dimmer',
            const LampCalibration(gain: 0.7),
          ),
        );
        final set = live.received.lastWhere(
          (m) => m['type'] == 'haven/prefs/set',
        );
        final prefs = set['prefs'] as Map;
        expect(prefs['zukunft'], {'von': 'neuerer App'});
        expect(prefs['lamp_calibration'], {
          'Tuya|TS0505B_hs': {
            'white': [
              [2700, 3600],
            ],
          },
          'YSRSAI|YSR-MINI-01_dimmer': {'gain': 0.7},
        });
        expect(
          repo.snapshot
              .lamp('light.kochbereich_arbeitslicht_2')!
              .calibration
              .gain,
          0.7,
        );
        await repo.dispose();
      },
    );

    test('ohne prefs in HA: lokal gespeichert', () async {
      final local = MemoryPrefs();
      final (repo, live) = await start(
        ha: LiveHa(prefsSupported: false),
        local: local,
      );
      await repo.setLampCalibration(
        const LampCalibrations().withModel(
          'Tuya|TS0505B_hs',
          const LampCalibration(gamma: 1.5),
        ),
      );
      expect(local.lampCalibration, {
        'Tuya|TS0505B_hs': {'gamma': 1.5},
      });
      expect(
        live.received.where((m) => m['type'] == 'haven/prefs/set'),
        isEmpty,
      );
      await repo.dispose();
    });
  });
}

Future<void> until(bool Function() cond) async {
  for (var i = 0; i < 300 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(cond(), isTrue, reason: 'Bedingung nicht erreicht');
}
