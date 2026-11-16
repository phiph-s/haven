import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/models/zigbee.dart';
import 'package:haven/data/models/zigbee_network.dart';
import 'package:haven/features/zigbee/ghost_rules.dart';
import 'package:haven/features/zigbee/zigbee_model.dart';

final _now = DateTime(2026, 11, 16, 12);

GhostInfo? _eval({bool battery = false, Duration? ago, String? availability}) =>
    evaluateGhost(
      isBattery: battery,
      lastSeen: ago == null ? null : _now.subtract(ago),
      availability: availability,
      now: _now,
    );

ZbDeviceView _view(
  String name, {
  bool battery = false,
  ZbDevice? device,
  Map<String, dynamic> state = const {},
  ZbMeshNode? node,
  DateTime? measured,
}) => ZbDeviceView.build(
  device ??
      ZbDevice(
        ieee: '0x$name',
        friendlyName: name,
        type: battery ? 'EndDevice' : 'Router',
        powerSource: battery ? 'Battery' : 'Mains (single phase)',
        hasAreaInfo: true,
        areaId: 'x',
      ),
  state: state,
  meshNode: node,
  meshMeasuredAt: measured,
);

void main() {
  group('Netzgerät', () {
    test('bis 24 h kein Verdacht, danach „Seit X Tagen“', () {
      expect(_eval(ago: const Duration(hours: 23)), isNull);
      expect(_eval(ago: const Duration(hours: 24)), isNull);
      final g = _eval(ago: const Duration(hours: 25))!;
      expect(g.kind, GhostKind.unreachable);
      expect(g.text, 'Seit 1 Tag nicht erreichbar');
      expect(g.canRemove, isTrue);
      expect(
        _eval(ago: const Duration(days: 180))!.text,
        'Seit 180 Tagen nicht erreichbar',
      );
    });

    test('offline: erst nach über 1 h', () {
      expect(
        _eval(ago: const Duration(minutes: 30), availability: 'offline'),
        isNull,
      );
      final g = _eval(ago: const Duration(hours: 2), availability: 'offline')!;
      expect(g.text, 'Seit 2 Std nicht erreichbar');
      expect(
        _eval(ago: const Duration(hours: 2), availability: 'online'),
        isNull,
      );
    });

    test('offline ohne Zeitstempel zählt, online ohne Zeitstempel nicht', () {
      expect(_eval(availability: 'offline')!.text, 'Nicht erreichbar');
      expect(_eval(availability: 'online'), isNull);
      expect(_eval(), isNull);
    });
  });

  group('Batteriegerät', () {
    test('bis 2 Tage kein Verdacht', () {
      expect(_eval(battery: true, ago: const Duration(days: 2)), isNull);
      expect(_eval(battery: true), isNull);
    });

    test('ab über 2 Tagen: Batterie prüfen, noch ohne Entfernen', () {
      final g = _eval(battery: true, ago: const Duration(days: 5))!;
      expect(g.kind, GhostKind.silent);
      expect(g.text, 'Seit 5 Tagen keine Meldung, Batterie prüfen');
      expect(g.canRemove, isFalse);
    });

    test('ab 21 Tagen zusätzlich Entfernen', () {
      expect(
        _eval(battery: true, ago: const Duration(days: 20))!.canRemove,
        isFalse,
      );
      expect(
        _eval(battery: true, ago: const Duration(days: 21))!.canRemove,
        isTrue,
      );
    });

    test('Verfügbarkeit offline allein macht kein Batterie-Geist', () {
      expect(
        _eval(
          battery: true,
          ago: const Duration(hours: 5),
          availability: 'offline',
        ),
        isNull,
      );
    });
  });

  group('Ignorieren', () {
    final seen = DateTime(2026, 5, 1, 8);

    test('gilt für denselben Stempel, nicht für eine neue Meldung', () {
      final ignored = {'0x1': ghostStamp(seen)};
      expect(isGhostIgnored(ignored, '0x1', seen), isTrue);
      expect(
        isGhostIgnored(ignored, '0x1', seen.add(const Duration(minutes: 3))),
        isFalse,
      );
      expect(isGhostIgnored(ignored, '0x2', seen), isFalse);
      expect(isGhostIgnored({'0x1': ghostStamp(null)}, '0x1', null), isTrue);
    });

    test('computeNeeds blendet ignorierte Geister aus', () {
      final v = _view(
        'Lampe',
        state: {
          'last_seen': _now
              .subtract(const Duration(days: 30))
              .toIso8601String(),
        },
      );
      expect(computeNeeds([v], now: _now).map((n) => n.kind), [
        ZbNeedKind.ghost,
      ]);
      final ignored = {v.ieee: ghostStamp(v.lastSeen)};
      expect(computeNeeds([v], now: _now, ignored: ignored), isEmpty);
    });
  });

  group('Sortierung und Quellen', () {
    test('Geister stehen oben, ohne doppelten Offline-Eintrag', () {
      final old = _now.subtract(const Duration(days: 9)).toIso8601String();
      final ghost = _view(
        'Geist',
        state: {'last_seen': old, 'availability': 'offline'},
      );
      final low = _view('Schwach', battery: true, state: {'battery': 5});
      final needs = computeNeeds([low, ghost], now: _now);
      expect(needs.map((n) => (n.kind, n.view.name)).toList(), [
        (ZbNeedKind.ghost, 'Geist'),
        (ZbNeedKind.lowBattery, 'Schwach'),
      ]);
      expect(needs.first.ghost!.text, 'Seit 9 Tagen nicht erreichbar');
    });

    test('Ohne jede Quelle kein Geist', () {
      expect(
        computeNeeds([_view('A'), _view('B', battery: true)], now: _now),
        isEmpty,
      );
    });

    test('Quelle: Z2M-Zustand vor Integration vor Netzkarte', () {
      final dev = ZbDevice(
        ieee: '0x1',
        friendlyName: 'L',
        lastSeen: DateTime(2026, 4, 1),
        lastSeenSource: 'networkmap',
      );
      final node = ZbMeshNode(
        ieee: '0x1',
        name: 'L',
        lastSeen: DateTime(2026, 3, 1),
      );
      final measured = DateTime(2026, 5, 2);
      final live = _view(
        'L',
        device: dev,
        node: node,
        state: {'last_seen': '2026-06-01T00:00:00Z'},
      );
      expect(live.lastSeenSource, 'z2m');
      expect(live.lastSeen!.toUtc(), DateTime.utc(2026, 6, 1));
      final fromDevice = _view('L', device: dev, node: node);
      expect(fromDevice.lastSeenSource, 'networkmap');
      expect(fromDevice.lastSeen, DateTime(2026, 4, 1));
      final legacy = _view(
        'L',
        device: const ZbDevice(ieee: '0x1', friendlyName: 'L'),
        node: node,
        measured: measured,
      );
      expect(legacy.lastSeenSource, 'networkmap');
      expect(legacy.lastSeen, DateTime(2026, 3, 1));
      expect(legacy.networkMeasuredAt, measured);
    });
  });

  group('Parsing der neuen Felder', () {
    test('Gerät: last_seen, Quelle, Verfügbarkeit', () {
      final d = ZbDevice.fromJson({
        'ieee': '0x1',
        'friendly_name': 'L',
        'last_seen': '2026-04-29T08:15:00+00:00',
        'last_seen_source': 'z2m',
        'availability': 'offline',
      });
      expect(d.lastSeen!.toUtc(), DateTime.utc(2026, 4, 29, 8, 15));
      expect(d.lastSeenSource, 'z2m');
      expect(d.availability, 'offline');
      final none = ZbDevice.fromJson({'ieee': '0x2', 'last_seen': null});
      expect(none.lastSeen, isNull);
      expect(none.availability, isNull);
    });

    test('last_seen als Millisekunden, Sekunden und Text', () {
      final t = DateTime.utc(2026, 4, 29, 8, 15);
      expect(ZbDevice.parseLastSeen(t.millisecondsSinceEpoch)!.toUtc(), t);
      expect(
        ZbDevice.parseLastSeen(t.millisecondsSinceEpoch ~/ 1000)!.toUtc(),
        t,
      );
      expect(ZbDevice.parseLastSeen('${t.millisecondsSinceEpoch}')!.toUtc(), t);
      expect(ZbDevice.parseLastSeen('kaputt'), isNull);
      expect(ZbDevice.parseLastSeen(0), isNull);
    });

    test('Bridge-Info und Netzknoten', () {
      final i = ZbBridgeInfo.fromJson({
        'last_seen_enabled': false,
        'availability_enabled': true,
      });
      expect(i.lastSeenEnabled, isFalse);
      expect(i.availabilityEnabled, isTrue);
      expect(ZbBridgeInfo.fromJson({}).lastSeenEnabled, isNull);
      final n = ZbMeshNode.fromJson({
        'ieeeAddr': '0x1',
        'friendlyName': 'L',
        'type': 'Router',
        'lastSeen': 1777450500000,
      });
      expect(n.lastSeen!.toUtc(), DateTime.utc(2026, 4, 29, 8, 15));
    });
  });
}
