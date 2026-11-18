import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/data/models/haven_automation.dart';
import 'package:haven/data/models/state_history.dart';
import 'package:haven/data/models/zigbee.dart';
import 'package:haven/features/map/map_actions.dart';
import 'package:haven/features/map/map_info.dart';
import 'package:haven/features/map/map_layers.dart';

void main() {
  group('Kartenart und Zieltyp ergeben die Aktion', () {
    // Erwartung je Kartenart in der Reihenfolge von MapTarget.values:
    // Lampe, Steckdose, Klima, Thermostat, Melder, Kontakt, Regler, Rest, Raum.
    const expected = <MapLayer, List<MapTapAction>>{
      MapLayer.combo: [
        MapTapAction.toggleLamp,
        MapTapAction.togglePlug,
        MapTapAction.openClimateSheet,
        MapTapAction.openThermostat,
        MapTapAction.openMotionSheet,
        MapTapAction.showStatus,
        MapTapAction.showStatus,
        MapTapAction.showStatus,
        MapTapAction.openRoomSheet,
      ],
      MapLayer.light: [
        MapTapAction.toggleLamp,
        MapTapAction.showStatus,
        MapTapAction.showStatus,
        MapTapAction.showStatus,
        MapTapAction.showStatus,
        MapTapAction.showStatus,
        MapTapAction.showControlInfo,
        MapTapAction.showStatus,
        MapTapAction.openRoomSheet,
      ],
      MapLayer.temperature: [
        MapTapAction.openClimateSheet,
        MapTapAction.openClimateSheet,
        MapTapAction.openClimateSheet,
        MapTapAction.openThermostat,
        MapTapAction.openClimateSheet,
        MapTapAction.openClimateSheet,
        MapTapAction.openClimateSheet,
        MapTapAction.openClimateSheet,
        MapTapAction.openRoomClimate,
      ],
      MapLayer.humidity: [
        MapTapAction.openClimateSheet,
        MapTapAction.openClimateSheet,
        MapTapAction.openClimateSheet,
        MapTapAction.openThermostat,
        MapTapAction.openClimateSheet,
        MapTapAction.openClimateSheet,
        MapTapAction.openClimateSheet,
        MapTapAction.openClimateSheet,
        MapTapAction.openRoomClimate,
      ],
      MapLayer.presence: [
        MapTapAction.openMotionSheet,
        MapTapAction.openMotionSheet,
        MapTapAction.openMotionSheet,
        MapTapAction.openMotionSheet,
        MapTapAction.openMotionSheet,
        MapTapAction.openMotionSheet,
        MapTapAction.openMotionSheet,
        MapTapAction.openMotionSheet,
        MapTapAction.openRoomMotion,
      ],
      MapLayer.network: [
        MapTapAction.selectNetworkNode,
        MapTapAction.selectNetworkNode,
        MapTapAction.selectNetworkNode,
        MapTapAction.selectNetworkNode,
        MapTapAction.selectNetworkNode,
        MapTapAction.selectNetworkNode,
        MapTapAction.selectNetworkNode,
        MapTapAction.selectNetworkNode,
        MapTapAction.none,
      ],
      MapLayer.battery: [
        MapTapAction.openBatterySheet,
        MapTapAction.openBatterySheet,
        MapTapAction.openBatterySheet,
        MapTapAction.openBatterySheet,
        MapTapAction.openBatterySheet,
        MapTapAction.openBatterySheet,
        MapTapAction.openBatterySheet,
        MapTapAction.openBatterySheet,
        MapTapAction.openRoomBatteries,
      ],
    };

    test('alle Kartenarten mal alle Zieltypen', () {
      expect(expected.keys.toSet(), MapLayer.values.toSet());
      for (final layer in MapLayer.values) {
        expect(
          [for (final t in MapTarget.values) mapTapAction(layer, t)],
          expected[layer],
          reason: layer.name,
        );
      }
    });

    test('Lange drücken: Licht-Sheet nur bei Lampen im Licht, sonst Gerät', () {
      for (final layer in MapLayer.values) {
        for (final t in MapTarget.values) {
          final want = t == MapTarget.room
              ? MapHoldAction.none
              : (layer == MapLayer.light && t == MapTarget.lamp)
              ? MapHoldAction.openLampSheet
              : MapHoldAction.openDevice;
          expect(mapHoldAction(layer, t), want, reason: '${layer.name} $t');
        }
      }
    });

    test('Rechtsklick öffnet überall das Gerät, Räume nichts', () {
      for (final layer in MapLayer.values) {
        expect(
          mapSecondaryAction(layer, MapTarget.lamp),
          MapHoldAction.openDevice,
        );
        expect(mapSecondaryAction(layer, MapTarget.room), MapHoldAction.none);
      }
    });

    test('Zieltyp: Zigbee-Typ vor Platzierungsart', () {
      expect(
        mapTargetOf(FloorKind.device, zbType: ZbType.light),
        MapTarget.lamp,
      );
      expect(
        mapTargetOf(FloorKind.device, zbType: ZbType.relay),
        MapTarget.plug,
      );
      expect(
        mapTargetOf(FloorKind.device, zbType: ZbType.plug),
        MapTarget.plug,
      );
      expect(
        mapTargetOf(FloorKind.device, zbType: ZbType.climate),
        MapTarget.climateSensor,
      );
      expect(
        mapTargetOf(FloorKind.temperature, zbType: ZbType.presence),
        MapTarget.motionSensor,
      );
      expect(
        mapTargetOf(FloorKind.device, zbType: ZbType.knob),
        MapTarget.control,
      );
      expect(
        mapTargetOf(FloorKind.device, zbType: ZbType.contact),
        MapTarget.contactSensor,
      );
      expect(mapTargetOf(FloorKind.light), MapTarget.lamp);
      expect(mapTargetOf(FloorKind.switchKind), MapTarget.plug);
      expect(mapTargetOf(FloorKind.temperature), MapTarget.climateSensor);
      // Thermostate: Zigbee-Typ oder Climate-Entity.
      expect(
        mapTargetOf(FloorKind.temperature, zbType: ZbType.thermostat),
        MapTarget.thermostat,
      );
      expect(
        mapTargetOf(FloorKind.temperature, entityId: 'climate.heizung'),
        MapTarget.thermostat,
      );
      expect(
        mapTargetOf(FloorKind.temperature, entityId: 'sensor.temp'),
        MapTarget.climateSensor,
      );
      expect(mapTargetOf(FloorKind.presence), MapTarget.motionSensor);
      expect(mapTargetOf(FloorKind.remote), MapTarget.control);
      expect(mapTargetOf(FloorKind.media), MapTarget.otherDevice);
    });

    test('Zigbee-Gerät zur Entity', () {
      const d = ZbDevice(
        ieee: 'a',
        friendlyName: 'A',
        haEntities: ['sensor.a_battery'],
      );
      expect(zbDeviceForEntity(const [d], 'sensor.a_battery'), d);
      expect(zbDeviceForEntity(const [d], 'sensor.b'), isNull);
    });
  });

  group('Verlauf und Hinweise', () {
    final now = DateTime.utc(2026, 11, 16, 12);
    StateChange at(String s, int minAgo) =>
        StateChange(s, now.subtract(Duration(minutes: minAgo)));

    test('Messreihe: Unlesbares fällt weg, Kennzahlen', () {
      final s = numericSeries([
        at('20.5', 300),
        at('unavailable', 200),
        at('23', 100),
        at('21.5', 10),
      ]);
      expect(s, hasLength(3));
      final st = seriesStats(s)!;
      expect((st.min, st.max, st.last), (20.5, 23.0, 21.5));
      expect(seriesStats(const []), isNull);
    });

    test('Resampling: Treppe, vor dem ersten Wert null, Mittel mehrerer', () {
      final s = numericSeries([at('10', 90), at('20', 30)]);
      final r = resampleSeries(
        s,
        now.subtract(const Duration(minutes: 120)),
        now,
        5,
      );
      // Stützstellen bei -120, -90, -60, -30, 0 Minuten.
      expect(r, [null, 10, 10, 20, 20]);
      expect(
        meanSeries([
          [1, 3, null],
          [3, null, null],
        ]),
        [2, 3, null],
      );
      expect(meanSeries(const []), isEmpty);
      final sp = spreadOf([20, 22, 24])!;
      expect((sp.mean, sp.min, sp.max), (22.0, 20.0, 24.0));
      expect(spreadOf(const []), isNull);
    });

    test(
      'Lüften ab über 60 %, Batterie prüfen unter 20 % oder nach 2 Tagen',
      () {
        expect(needsVenting(60), isFalse);
        expect(needsVenting(61), isTrue);
        expect(needsVenting(null), isFalse);
        expect(batteryNeedsCheck(19, now, now), isTrue);
        expect(batteryNeedsCheck(20, now, now), isFalse);
        expect(
          batteryNeedsCheck(80, now.subtract(const Duration(days: 3)), now),
          isTrue,
        );
        expect(
          batteryNeedsCheck(80, now.subtract(const Duration(hours: 47)), now),
          isFalse,
        );
        expect(batteryNeedsCheck(null, null, now), isFalse);
      },
    );

    test('Bewegungsphasen der letzten 60 min, neueste zuerst', () {
      final h = [
        at('on', 80), // läuft ins Fenster hinein
        at('off', 55),
        at('on', 30),
        at('off', 25),
        at('on', 2),
      ];
      final spans = motionSpans(h, now);
      expect(spans, hasLength(3));
      expect(spans[0].running, isTrue);
      expect(spans[0].from, now.subtract(const Duration(minutes: 2)));
      expect(spans[1].to, now.subtract(const Duration(minutes: 25)));
      expect(
        spans[2].from,
        now.subtract(const Duration(minutes: 60)),
        reason: 'am Fensteranfang abgeschnitten',
      );
      expect(motionSpanText(spans[0], now), 'seit 2 min');
      expect(motionSpanText(spans[1], now), 'vor 30 min, 5 min lang');
      expect(motionSpans([at('off', 90)], now), isEmpty);
      expect(motionSpans(const [], now), isEmpty);
    });

    test('Bewegungslicht des Raums über die Bereichs-ID', () {
      const motion = HavenAutomation(
        id: 'm1',
        type: 'room_motion',
        name: 'Bewegungslicht Waschraum',
        roomAreaId: 'waschraum',
      );
      const knob = HavenAutomation(
        id: 'k1',
        name: 'Regler',
        roomAreaId: 'salon',
        devices: ['k'],
      );
      const all = HavenAutomations(automations: [motion, knob]);
      expect(motionAutomationFor(all, [null, 'waschraum']), motion);
      expect(motionAutomationFor(all, ['salon']), isNull);
      expect(motionAutomationFor(all, const []), isNull);
      expect(motionAutomationFor(null, ['waschraum']), isNull);
      expect(knobAutomationFor(all, 'k'), knob);
      expect(knobAutomationFor(all, 'x'), isNull);
    });

    test('zuletzt gemeldet und Gerätename', () {
      expect(lastSeenText(null, now), 'unbekannt');
      expect(lastSeenText(now, now), 'gerade eben');
      expect(
        lastSeenText(now.subtract(const Duration(hours: 5)), now),
        'vor 5 h',
      );
      expect(
        lastSeenText(now.subtract(const Duration(days: 3)), now),
        'vor 3 d',
      );
      expect(shortDeviceName('Sensor Salon Temperatur'), 'Sensor Salon');
      expect(shortDeviceName('Lampe'), 'Lampe');
    });
  });
}
