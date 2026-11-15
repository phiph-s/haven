import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/models/entity_state.dart';
import 'package:haven/data/models/room.dart';
import 'package:haven/data/models/zigbee.dart';
import 'package:haven/dev/fake_data.dart';
import 'package:haven/features/zigbee/zigbee_model.dart';

List<ZbDevice> _asset() {
  return [
    for (final d in (kFakeZigbee['devices'] as List))
      ZbDevice.fromJson(Map<String, dynamic>.from(d as Map)),
  ];
}

ZbDeviceView _view(
  String name, {
  String type = 'EndDevice',
  String power = 'Battery',
  String? area,
  Map<String, dynamic> state = const {},
  bool withArea = true,
}) => ZbDeviceView.build(
  ZbDevice(
    ieee: '0x$name',
    friendlyName: name,
    type: type,
    powerSource: power,
    deviceType: 'climate_sensor',
    areaId: area,
    hasAreaInfo: withArea,
  ),
  state: state,
  rooms: const [Room(id: 'kochbereich', name: 'Kochbereich', lightIds: [])],
);

void main() {
  group('Parsing', () {
    test('alle Geräte der Beispielwohnung', () {
      final devs = _asset();
      expect(devs, hasLength(20));
      for (final d in devs) {
        expect(d.ieee, startsWith('0x'));
        expect(d.classified.deviceType, isNot(ZbType.unknown));
        expect(d.deviceType, d.classified.deviceType);
      }
    });

    test('Bewegungsmelder: Einstellungen, Gruppen, Enum-Labels', () {
      final d = _asset().firstWhere((d) => d.model == 'ZG-204ZL');
      final c = d.classified;
      expect(d.vendor, 'HOBEIAN');
      expect(d.isBattery, isTrue);
      expect(c.settingGroups, ['Erkennung', 'Messung']);
      expect(c.groupedSettings.map((g) => g.$1), ['Erkennung', 'Messung']);
      final sens = c.settings.firstWhere((f) => f.property == 'sensitivity');
      expect(sens.isEnum, isTrue);
      expect(sens.canWrite, isTrue);
      expect(sens.values.map((v) => v.label), ['Niedrig', 'Mittel', 'Hoch']);
      expect(sens.labelOf('high'), 'Hoch');
      final interval = c.settings.firstWhere(
        (f) => f.property == 'illuminance_interval',
      );
      expect(interval.isNumeric, isTrue);
      expect([interval.min, interval.max, interval.step], [1, 720, 1]);
      expect(c.diagnostic.map((f) => f.property), contains('battery'));
    });

    test('Binär: value_on/value_off, identify getrennt', () {
      final plug = _asset().firstWhere((d) => d.model == 'HT-SP-ZB-01');
      final lock = plug.classified.settings.firstWhere(
        (f) => f.property == 'child_lock',
      );
      expect(lock.isBinary, isTrue);
      expect(lock.isOn('LOCK'), isTrue);
      expect(lock.isOn('UNLOCK'), isFalse);
      expect(lock.binaryValue(true), 'LOCK');
      expect(plug.classified.canIdentify, isTrue);
      expect(
        plug.classified.groupedSettings
            .expand((g) => g.$2)
            .map((f) => f.property),
        isNot(contains('identify')),
      );
    });

    test('Nachsichtig bei fehlenden Feldern', () {
      final d = ZbDevice.fromJson({'ieee': '0x1'});
      expect(d.friendlyName, '0x1');
      expect(d.deviceType, ZbType.unknown);
      expect(d.classified.settings, isEmpty);
      final f = ZbFeature.fromJson({'property': 'x'});
      expect(f.label, 'x');
      expect(f.canWrite, isFalse);
    });

    test('Bridge-Info und Ereignis', () {
      final i = ZbBridgeInfo.fromJson({
        'version': '2.6.1',
        'channel': 25,
        'bridge_state': 'online',
      });
      expect(i.channel, 25);
      expect(i.online, isTrue);
      final e = ZbEvent.fromJson({
        'kind': 'event',
        'event': {
          'type': 'device_joined',
          'data': {'ieee_address': '0xabc'},
        },
      });
      expect(e.bridgeType, 'device_joined');
      expect(e.bridgeData['ieee_address'], '0xabc');
    });
  });

  group('Braucht dich', () {
    test('Regeln und Reihenfolge', () {
      final views = [
        _view('A', state: {'availability': 'offline'}, area: 'kochbereich'),
        _view(
          'B',
          state: {'battery': 18, 'linkquality': 200},
          area: 'kochbereich',
        ),
        _view(
          'C',
          state: {'battery': 30, 'linkquality': 79},
          area: 'kochbereich',
        ),
        _view('D', state: {'battery': 80, 'linkquality': 80}),
        _view(
          'E',
          type: 'Router',
          power: 'Mains (single phase)',
          area: 'kochbereich',
          state: {'battery': 5},
        ),
      ];
      final needs = computeNeeds(views);
      expect(needs.map((n) => (n.kind, n.view.name)).toList(), [
        (ZbNeedKind.offline, 'A'),
        (ZbNeedKind.lowBattery, 'B'),
        (ZbNeedKind.weakSignal, 'C'),
        (ZbNeedKind.noRoom, 'D'),
      ]);
      expect(needs[1].detail, 'Batterie bei 18 %');
    });

    test('Ohne Rauminfo der Integration kein Raum-Hinweis', () {
      final v = [_view('X', withArea: false)];
      expect(computeNeeds(v, roomsKnown: false), isEmpty);
      expect(computeNeeds(v), hasLength(1));
    });

    test('Koordinator und abgeschaltete Geräte zählen nicht', () {
      final c = ZbDeviceView.build(
        const ZbDevice(
          ieee: '0x0',
          friendlyName: 'Coordinator',
          type: 'Coordinator',
        ),
      );
      expect(computeNeeds([c]), isEmpty);
    });

    test('Offline-Gerät meldet nicht zusätzlich Batterie', () {
      final needs = computeNeeds([
        _view(
          'A',
          state: {'availability': 'offline', 'battery': 5, 'linkquality': 3},
          area: 'kochbereich',
        ),
      ]);
      expect(needs.map((n) => n.kind), [ZbNeedKind.offline]);
    });

    test(
      'Raum aus Entities der Integration, nicht erreichbar aus Entities',
      () {
        final dev = const ZbDevice(
          ieee: '0x1',
          friendlyName: 'Sensor Kochbereich',
          areaId: 'kochbereich',
          hasAreaInfo: true,
        );
        final v = ZbDeviceView.build(
          dev,
          allEntities: {
            'sensor.sensor_kochbereich_battery': const EntityState(
              'sensor.sensor_kochbereich_battery',
              'unavailable',
            ),
            'sensor.andere_battery': const EntityState(
              'sensor.andere_battery',
              '5',
            ),
          },
          rooms: const [
            Room(id: 'kochbereich', name: 'Kochbereich', lightIds: []),
          ],
        );
        expect(v.entities, hasLength(1));
        expect(v.available, isFalse);
        expect(v.roomName, 'Kochbereich');
      },
    );
  });

  group('Hilfen', () {
    test('LQI-Stufen', () {
      expect(LqiLevel.of(184), LqiLevel.good);
      expect(LqiLevel.of(120), LqiLevel.medium);
      expect(LqiLevel.of(79), LqiLevel.weak);
    });

    test('haSlug', () {
      expect(
        haSlug('Kochbereich Arbeitslicht 2'),
        'kochbereich_arbeitslicht_2',
      );
      expect(
        haSlug('Drehknopf Ruheraum 2 (Bett)'),
        'drehknopf_ruheraum_2_bett',
      );
    });

    test('Filter', () {
      final dev = _asset();
      int count(ZbFilter f) =>
          dev.where((d) => f.matches(ZbDeviceView(device: d))).length;
      expect(count(ZbFilter.lights), 10);
      expect(count(ZbFilter.plugs), 1);
      expect(count(ZbFilter.battery), greaterThan(6));
    });
  });
}
