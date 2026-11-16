import 'package:flutter_test/flutter_test.dart';
import 'package:haven/core/light/color_math.dart';
import 'package:haven/data/haven_repository.dart';
import 'package:haven/data/models/snapshot.dart';
import 'package:haven/data/room_view.dart';
import 'package:haven/dev/fake_data.dart';
import 'package:haven/dev/fake_repository.dart';

Future<FakeRepository> _repo() async {
  final r = FakeRepository(simulate: false);
  await r.start();
  return r;
}

RoomView _view(FakeRepository r, String id) =>
    RoomView.from(r.snapshot, r.snapshot.room(id)!);

void main() {
  group('Beispielwohnung', () {
    test('fünf Räume mit den richtigen Lichtern', () async {
      final r = await _repo();
      final rooms = r.snapshot.rooms;
      expect(rooms.map((e) => e.name), [
        'Salon',
        'Ruheraum',
        'Kochbereich',
        'Waschraum',
        'Diele',
      ]);
      expect(r.snapshot.room('salon')!.lightIds, hasLength(3));
      expect(
        r.snapshot.room('ruheraum')!.lightIds,
        containsAll([
          'light.lichtleiste_links',
          'light.lichtleiste_rechts',
          'light.lampe_ruhebett',
        ]),
      );
      expect(r.snapshot.room('kochbereich')!.lightIds, [
        'light.kochbereich_arbeitslicht_1',
        'light.kochbereich_arbeitslicht_2',
      ]);
      expect(r.snapshot.room('waschraum')!.lightIds, ['light.lampe_waschraum']);
      expect(r.snapshot.room('diele')!.lightIds, isEmpty);
    });

    test('Klima, Szenen und Bedienelemente', () async {
      final r = await _repo();
      final salon = r.snapshot.room('salon')!;
      expect(salon.temperatureId, 'sensor.sensor_salon_temperature');
      expect(salon.scenes, hasLength(5));
      expect(salon.scenes.first.entityId, 'scene.zgsalon_0_golden_hour');
      expect(salon.knobs, hasLength(1));
      expect(r.snapshot.room('kochbereich')!.temperatureId, isNull);
      expect(r.snapshot.room('kochbereich')!.scenes, isEmpty);
      final ruhe = r.snapshot.room('ruheraum')!;
      expect(
        ruhe.scenes.firstWhere((s) => s.name == 'Lichtleiste').onlyLightIds,
        ['light.lichtleiste_links', 'light.lichtleiste_rechts'],
      );
    });

    test('Konstanten: zwei Gruppen mit Szenen, erfundene IEEE-Adressen', () {
      expect((kFakeInventory['z2m_groups'] as List), hasLength(2));
      for (final d in kFakeInventory['z2m_devices'] as List) {
        expect(
          (d as Map)['ieee'],
          matches(RegExp(r'^0x00124b00000000[0-9a-f]{2}$')),
        );
      }
    });
  });

  group('Simulation', () {
    test('Startzustand: nur die Tischlampe leuchtet', () async {
      final r = await _repo();
      expect(r.snapshot.status, ConnectionStatus.connected);
      final on = [
        for (final room in r.snapshot.rooms)
          ...r.snapshot.lampsOf(room).where((l) => l.on),
      ];
      expect(on.map((l) => l.entityId), ['light.tischlampe_salon']);
    });

    test(
      'Raum schalten: erst alles an, dann merkt er sich die Lampen',
      () async {
        final r = await _repo();
        await r.toggleRoom('ruheraum');
        expect(_view(r, 'ruheraum').lampsOn, hasLength(4));
        await r.setLights(['light.lampe_ruhebett'], on: false);
        await r.toggleRoom('ruheraum'); // alles aus
        expect(_view(r, 'ruheraum').anyOn, isFalse);
        await r.toggleRoom('ruheraum'); // zuletzt an: ohne Bett
        expect(
          _view(r, 'ruheraum').lampsOn.map((l) => l.entityId),
          isNot(contains('light.lampe_ruhebett')),
        );
        expect(_view(r, 'ruheraum').lampsOn, hasLength(3));
      },
    );

    test(
      'Raumhelligkeit setzt nur eingeschaltete Lampen, 0 schaltet aus',
      () async {
        final r = await _repo();
        await r.setRoomBrightness('salon', 40);
        final v = _view(r, 'salon');
        expect(v.lampsOn, hasLength(1));
        expect(v.brightness, 40);
        await r.setRoomBrightness('salon', 0);
        expect(_view(r, 'salon').anyOn, isFalse);
        await r.setRoomBrightness(
          'salon',
          60,
        ); // zuletzt eingeschaltete Lampe kommt zurück
        expect(_view(r, 'salon').lampsOn.map((l) => l.entityId), [
          'light.tischlampe_salon',
        ]);
      },
    );

    test(
      'Szene ändert die Lampenfarben reihum und setzt die Helligkeit',
      () async {
        final r = await _repo();
        await r.applyScene('salon', 'neon_tokyo');
        final v = _view(r, 'salon');
        expect(v.lampsOn, hasLength(3));
        expect(v.activeSceneId, 'neon_tokyo');
        final colors = r.snapshot
            .room('salon')!
            .scenes
            .firstWhere((s) => s.id == 'neon_tokyo')
            .colors;
        for (var i = 0; i < 3; i++) {
          expect(v.lamps[i].color, colors[i % 3], reason: 'Lampe $i');
          expect(v.lamps[i].brightness, closeTo(90, 1));
        }
        final p = v.palette(dark: true);
        expect(p.isOn, isTrue);
      },
    );

    test('Weißszene setzt Kelvin und die passende Farbe', () async {
      final r = await _repo();
      await r.applyScene('salon', 'fokus');
      final l = _view(r, 'salon').lamps.first;
      expect(l.kelvin, 5600);
      expect(l.color, kelvinToRgb(5600));
      expect(l.brightness, 100);
    });

    test('Szene mit only schaltet die übrigen Lampen aus', () async {
      final r = await _repo();
      await r.setLights([
        'light.lampe_ruhebett',
        'light.lampe_decke_ruheraum',
      ], on: true);
      await r.applyScene('ruheraum', 'lichtleiste');
      expect(_view(r, 'ruheraum').lampsOn.map((l) => l.entityId), [
        'light.lichtleiste_links',
        'light.lichtleiste_rechts',
      ]);
    });

    test('Handarbeit löscht die aktive Szene', () async {
      final r = await _repo();
      await r.applyScene('salon', 'nordlicht');
      expect(_view(r, 'salon').activeSceneId, 'nordlicht');
      await r.setLights(['light.tischlampe_salon'], brightness: 20);
      expect(_view(r, 'salon').activeSceneId, isNull);
    });

    test('Farbe und Kelvin setzen, Dimmer ignorieren Farbe', () async {
      final r = await _repo();
      await r.setLights(
        ['light.lampe_salon', 'light.kochbereich_arbeitslicht_2'],
        rgb: (10, 200, 90),
      );
      final wz = r.snapshot.lamp('light.lampe_salon')!;
      expect(wz.on, isTrue);
      expect(wz.color, (10, 200, 90));
      expect(wz.kelvin, isNull);
      final ku = r.snapshot.lamp('light.kochbereich_arbeitslicht_2')!;
      expect(ku.supportsColor, isFalse);
      await r.setLights(['light.lampe_salon'], kelvin: 3000);
      expect(r.snapshot.lamp('light.lampe_salon')!.kelvin, 3000);
    });

    test('Alles aus', () async {
      final r = await _repo();
      await r.toggleRoom('waschraum');
      await r.allLightsOff();
      for (final room in r.snapshot.rooms) {
        expect(r.snapshot.lampsOf(room).any((l) => l.on), isFalse);
      }
    });

    test('Schalter und Automationen per call_service', () async {
      final r = await _repo();
      expect(r.snapshot.entity('switch.lufter_waschraum')!.isOn, isFalse);
      await r.callService(
        'switch',
        'turn_on',
        entityId: 'switch.lufter_waschraum',
      );
      expect(r.snapshot.entity('switch.lufter_waschraum')!.isOn, isTrue);
      await r.callService(
        'switch',
        'toggle',
        entityId: 'switch.lufter_waschraum',
      );
      expect(r.snapshot.entity('switch.lufter_waschraum')!.isOn, isFalse);
    });

    test('Snapshots werden gemeldet', () async {
      final r = await _repo();
      final events = <HavenSnapshot>[];
      final sub = r.snapshots.listen(events.add);
      await r.toggleRoom('waschraum');
      await Future<void>.delayed(Duration.zero);
      expect(events, isNotEmpty);
      expect(events.last.revision, greaterThan(0));
      await sub.cancel();
    });

    test('Rohbefehle der Integration kommen aus den Konstanten', () async {
      final r = await _repo();
      final devices = await r.command('haven/zigbee/devices') as Map;
      expect((devices['devices'] as List), hasLength(21));
      final groups = await r.command('haven/zigbee/groups') as Map;
      expect((groups['groups'] as List), hasLength(2));
      expect(
        () => r.command('haven/unbekannt'),
        throwsA(isA<HavenException>()),
      );
    });
  });
}
