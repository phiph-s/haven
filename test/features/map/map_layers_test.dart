import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/data/models/haven_automation.dart';
import 'package:haven/data/models/zigbee.dart';
import 'package:haven/features/map/map_light_controls.dart';
import 'package:haven/features/map/map_markers.dart';
import 'package:haven/data/models/state_history.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/map/floor_plan_store.dart';
import 'package:haven/features/map/heatmap.dart';
import 'package:haven/features/map/map_layer_widgets.dart';
import 'package:haven/features/map/map_layers.dart';
import 'package:haven/features/map/map_readings.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Repo implements FloorPlanRepository {
  _Repo([this.plan]);
  HavenFloorPlan? plan;
  @override
  Future<HavenFloorPlan?> load() async => plan;
  @override
  Future<void> save(HavenFloorPlan p) async => plan = p;
  @override
  Future<void> clear() async => plan = null;
}

Future<(ProviderContainer, SettingsStore)> _pump(
  WidgetTester tester, {
  Map<String, Object> prefs = const {},
  bool settle = true,
  HavenFloorPlan? plan,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final store = SettingsStore(await SharedPreferences.getInstance());
  late Session session;
  await tester.runAsync(() async {
    final r = FakeRepository(simulate: false);
    await r.start();
    session = Session(SessionMode.fake, r);
  });
  tester.view.physicalSize = const Size(412 * 2.625, 915 * 2.625);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  final c = ProviderContainer(
    overrides: [
      settingsStoreProvider.overrideWithValue(store),
      tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
      initialSessionProvider.overrideWithValue(session),
      floorPlanRepositoryProvider.overrideWithValue(_Repo(plan)),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const HavenApp(initialLocation: '/map'),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // Melder pulsieren endlos, solange Bewegung da ist.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
  return (c, store);
}

void main() {
  group('Lichtschalter der Kartenart Licht', () {
    ZbDevice dev(String ieee, String type, List<String> ents) => ZbDevice(
      ieee: ieee,
      friendlyName: 'Gerät $ieee',
      deviceType: type,
      haEntities: ents,
    );
    FloorPlacement at(String id) => FloorPlacement(entityId: id, x: 1, y: 1);
    HavenAutomation auto(String type, List<String> devs, {bool on = true}) =>
        HavenAutomation(
          id: 'a',
          type: type,
          name: 'x',
          enabled: on,
          roomAreaId: 'salon',
          devices: devs,
        );
    final plan = HavenFloorPlan(
      placements: [
        at('light.a'),
        at('sensor.knob_battery'),
        at('sensor.btn_battery'),
        at('sensor.motion_battery'),
        at('sensor.plain_battery'),
      ],
    );
    final devices = [
      dev('k', ZbType.knob, ['sensor.knob_battery']),
      dev('b', ZbType.remote, ['sensor.btn_battery']),
      dev('m', ZbType.motion, ['sensor.motion_battery']),
      dev('p', ZbType.remote, ['sensor.plain_battery']),
    ];
    const rooms = {
      'salon': AutomationRoom(areaId: 'salon', name: 'Salon', group: 'g_salon'),
    };

    test('Knob-Automation oder Raumgruppe, mit Raumhinweis', () {
      final r = lightControlRooms(
        plan: plan,
        devices: devices,
        groups: const [
          ZbGroup(id: 1, friendlyName: 'g_salon', memberIeees: ['b']),
        ],
        automations: HavenAutomations(
          automations: [
            auto('room_knob', ['k']),
          ],
          rooms: rooms,
        ),
      );
      expect(r, {
        'sensor.knob_battery': 'Salon',
        'sensor.btn_battery': 'Salon',
      });
    });

    test(
      'Bewegungslicht-Melder, deaktivierte und fremde Geräte zählen nicht',
      () {
        final r = lightControlRooms(
          plan: plan,
          devices: devices,
          groups: const [],
          automations: HavenAutomations(
            automations: [
              auto('room_motion', ['m']),
              auto('room_knob', ['k'], on: false),
            ],
            rooms: rooms,
          ),
        );
        expect(r, isEmpty);
      },
    );
  });

  group('Heatmap', () {
    test('IDW: ein Sensor gleichmäßig, zwei ergeben einen Verlauf', () {
      const one = [HeatSample(Offset(2, 2), 21)];
      expect(idw(one, const Offset(0, 0)), 21);
      expect(idw(one, const Offset(9, 9)), 21);
      const two = [HeatSample(Offset(1, 1), 20), HeatSample(Offset(9, 1), 24)];
      final a = idw(two, const Offset(1.5, 1));
      final m = idw(two, const Offset(5, 1));
      final b = idw(two, const Offset(8.5, 1));
      expect(a, lessThan(m));
      expect(m, closeTo(22, 1e-9), reason: 'Mitte: gleiche Gewichte');
      expect(b, greaterThan(m));
      expect(a, greaterThanOrEqualTo(20));
      expect(b, lessThanOrEqualTo(24));
    });

    test('Raumgrenze: jeder Raum nur aus seinen eigenen Sensoren', () {
      // Salon hat zwei Sensoren (Verlauf), der Ruheraum einen.
      final readings = MapReadings([
        PlacedReading(
          entityId: 'a',
          cell: const GridPoint(4, 4),
          location: 'salon',
          temp: 20,
        ),
        PlacedReading(
          entityId: 'b',
          cell: const GridPoint(13, 8),
          location: 'salon',
          temp: 23,
        ),
        PlacedReading(
          entityId: 'c',
          cell: const GridPoint(8, 20),
          location: 'ruheraum',
          temp: 18,
        ),
        PlacedReading(
          entityId: 'd',
          cell: const GridPoint(24, 7),
          location: kOutsideId,
          temp: 2,
        ),
      ]);
      final d = readings.heat(HeatKind.temperature);
      expect(d.rooms.keys, {'salon', 'ruheraum'});
      expect(d.rooms['salon'], hasLength(2));
      // Der kalte Ruheraum-Sensor wirkt nicht in den Salon hinein: auch an
      // der gemeinsamen Wand bleibt der Salon zwischen seinen eigenen Werten.
      final salon = kFakeFloorPlan.room('salon')!;
      for (final (p, v) in roomHeatGrid(salon, d.rooms['salon']!)) {
        expect(v, inInclusiveRange(20, 23), reason: '$p');
      }
      final ruhe = kFakeFloorPlan.room('ruheraum')!;
      for (final (_, v) in roomHeatGrid(ruhe, d.rooms['ruheraum']!)) {
        expect(v, 18, reason: 'ein Sensor färbt gleichmäßig');
      }
      // Gemeinsame Skala nur innen: 18 bis 23, draußen (2 °C) zählt nicht.
      expect(d.scale, const HeatScale(18, 23));
      expect(d.outsideValue, 2);
      expect(d.roomRange('salon'), (20.0, 23.0));
      expect(d.roomRange('diele'), isNull);
    });

    test('globale Skala: gerundet, Mindestspanne, Luftfeuchte eigene', () {
      expect(
        HeatScale.fit([21.3, 21.9]),
        const HeatScale(19, 23),
        reason: 'mindestens 4 Grad um die Mitte',
      );
      expect(HeatScale.fit([17.6, 24.2]), const HeatScale(17, 25));
      expect(HeatScale.fit(const []), isNull);
      final h = HeatScale.fit([38, 61], step: 5, minSpan: 20)!;
      expect((h.lo, h.hi), (35.0, 65.0));
      final s = const HeatScale(18, 22);
      expect(s.t(18), 0);
      expect(s.t(22), 1);
      expect(s.t(30), 1);
      expect(s.t(20), 0.5);
      // Rampen: Enden sind die Stützfarben.
      expect(HeatRamp.temperature.at(0), HeatRamp.temperature.colors.first);
      expect(HeatRamp.temperature.at(1), HeatRamp.temperature.colors.last);
    });

    test('Netz der Heatmap: Ecken über dem Raum, Cache rechnet nur neu', () {
      final room = kFakeFloorPlan.room('salon')!;
      const s = [HeatSample(Offset(5, 5), 20), HeatSample(Offset(14, 10), 23)];
      final cache = HeatCache();
      final v1 = cache.get(
        room,
        s,
        const HeatScale(18, 24),
        HeatRamp.temperature,
        0.5,
      );
      final v2 = cache.get(
        room,
        s,
        const HeatScale(18, 24),
        HeatRamp.temperature,
        0.5,
      );
      expect(identical(v1, v2), isTrue);
      final v3 = cache.get(
        room,
        const [HeatSample(Offset(5, 5), 21)],
        const HeatScale(18, 24),
        HeatRamp.temperature,
        0.5,
      );
      expect(identical(v1, v3), isFalse);
      cache.dispose();
    });
  });

  group('Bewegung', () {
    final now = DateTime.utc(2026, 11, 16, 12);

    test('an leuchtet voll, danach klingt es ab, nach 30 min aus', () {
      expect(presenceLevel(on: true, now: now), 1);
      final half = presenceLevel(
        on: false,
        since: now.subtract(kPresenceHalfLife),
        now: now,
      );
      expect(half, closeTo(0.5, 1e-9));
      expect(
        presenceLevel(
          on: false,
          since: now.subtract(const Duration(minutes: 31)),
          now: now,
        ),
        0,
      );
      expect(presenceLevel(on: false, now: now), 0);
      expect(
        agoText(now.subtract(const Duration(minutes: 3)), now),
        'vor 3 min',
      );
      expect(
        agoText(now.subtract(const Duration(seconds: 20)), now),
        'gerade eben',
      );
    });

    test('History: kompakt lesen, Zustand zu einem Zeitpunkt', () {
      double sec(DateTime t) => t.millisecondsSinceEpoch / 1000;
      final h = parseStateHistory({
        'binary_sensor.a': [
          {'s': 'off', 'lu': sec(now.subtract(const Duration(minutes: 50)))},
          {'s': 'on', 'lu': sec(now.subtract(const Duration(minutes: 20)))},
          {'s': 'on', 'lu': sec(now.subtract(const Duration(minutes: 19)))},
          {'s': 'off', 'lu': sec(now.subtract(const Duration(minutes: 10)))},
        ],
        'binary_sensor.b': [
          {
            'state': 'on',
            'last_changed': now
                .subtract(const Duration(minutes: 5))
                .toIso8601String(),
          },
        ],
        'kaputt': 'x',
      });
      expect(
        h['binary_sensor.a'],
        hasLength(3),
        reason: 'on, on fällt zusammen',
      );
      final a = h['binary_sensor.a']!;
      expect(
        stateAt(a, now.subtract(const Duration(minutes: 15)))!.isOn,
        isTrue,
      );
      expect(stateAt(a, now)!.isOn, isFalse);
      expect(stateAt(a, now.subtract(const Duration(hours: 2))), isNull);
      expect(h['binary_sensor.b']!.single.isOn, isTrue);

      // Raumstand vor 15 min aus der History, jetzt aus dem Zustand.
      final motion = [
        PlacedReading(
          entityId: 'x',
          cell: const GridPoint(1, 1),
          location: 'salon',
          motionId: 'binary_sensor.a',
          motion: false,
          motionSince: now.subtract(const Duration(minutes: 10)),
        ),
      ];
      final then = presenceAt(
        motion,
        now.subtract(const Duration(minutes: 15)),
        history: h,
      );
      expect(then['salon']!.active, isTrue);
      final current = presenceAt(motion, now);
      expect(current['salon']!.active, isFalse);
      expect(current['salon']!.level, closeTo(0.0992, 0.001));
    });

    test('Entwicklungsdaten: History passt zum aktuellen Zustand', () async {
      final r = FakeRepository(simulate: false);
      await r.start();
      const id = 'binary_sensor.prasenz_waschraum_presence';
      final start = DateTime.now().subtract(const Duration(minutes: 60));
      final h = await r.stateHistory([id, 'light.lampe_salon'], start);
      expect(h.keys, [id]);
      final list = h[id]!;
      expect(list.first.at.isBefore(start), isTrue);
      expect(list.last.state, r.snapshot.entity(id)!.state);
      expect(list.last.at, r.snapshot.entity(id)!.lastChanged);
      for (var i = 1; i < list.length; i++) {
        expect(list[i].state, isNot(list[i - 1].state));
      }
      await r.dispose();
    });
  });

  group('Kartenart', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    });

    test('Name lesen, unbekannt wird Kombi, altes „light“ wird migriert', () {
      expect(MapLayer.fromName('temperature'), MapLayer.temperature);
      expect(MapLayer.fromName('gibtsnicht'), MapLayer.combo);
      expect(MapLayer.fromName(null), MapLayer.combo);
      expect(MapLayer.fromName('light'), MapLayer.combo);
      expect(MapLayer.fromName('combo'), MapLayer.combo);
      expect(MapLayer.fromName('lamps'), MapLayer.light);
      expect(MapLayer.combo.label, 'Kombi');
      for (final l in MapLayer.values) {
        expect(MapLayer.fromName(l.storeName), l, reason: l.name);
      }
    });

    testWidgets('Auswahl klappt auf, wechselt und merkt sich die Art', (
      tester,
    ) async {
      final (c, store) = await _pump(tester);
      expect(c.read(mapLayerProvider), MapLayer.combo);
      expect(find.text('Temperatur'), findsNothing);
      await tester.tap(find.bySemanticsLabel('Kartenart: Kombi'));
      await tester.pumpAndSettle();
      expect(find.text('Temperatur'), findsOneWidget);
      expect(find.text('Funknetz'), findsOneWidget);
      await tester.tap(find.text('Temperatur'));
      await tester.pumpAndSettle();
      expect(c.read(mapLayerProvider), MapLayer.temperature);
      expect(store.mapLayer, 'temperature');
      // Legende mit Skala und dem Wert draußen.
      expect(find.byType(HeatLegend), findsOneWidget);
      expect(find.text('Temperatur innen'), findsOneWidget);
      expect(find.byType(HeatValueMarker), findsWidgets);
      expect(find.text('Luftfeuchte'), findsNothing, reason: 'zugeklappt');
    });

    testWidgets('gemerkte Art gilt beim Start, Bewegung zeigt die Melder', (
      tester,
    ) async {
      final (c, _) = await _pump(
        tester,
        prefs: {'map_layer': 'presence'},
        settle: false,
      );
      expect(c.read(mapLayerProvider), MapLayer.presence);
      expect(find.byType(PresenceMarker), findsNWidgets(2));
      expect(find.textContaining('Bewegung'), findsWidgets);
    });

    testWidgets('gemerkte alte Art „light“ startet als Kombi', (tester) async {
      final (c, _) = await _pump(tester, prefs: {'map_layer': 'light'});
      expect(c.read(mapLayerProvider), MapLayer.combo);
      expect(find.bySemanticsLabel('Kartenart: Kombi'), findsOneWidget);
    });

    testWidgets('Licht: nur Lampen und Lichtschalter, Rest ausgeblendet', (
      tester,
    ) async {
      final plan = HavenFloorPlan(
        grid: kFakeFloorPlan.grid,
        rooms: kFakeFloorPlan.rooms,
        furniture: kFakeFloorPlan.furniture,
        coordinator: kFakeFloorPlan.coordinator,
        placements: [
          ...kFakeFloorPlan.placements,
          const FloorPlacement(
            entityId: 'sensor.drehknopf_salon_1_battery',
            x: 6,
            y: 9,
          ),
        ],
      );
      final (c, store) = await _pump(
        tester,
        prefs: {'map_layer': 'lamps'},
        plan: plan,
      );
      expect(c.read(mapLayerProvider), MapLayer.light);
      final lamps = kFakeFloorPlan.placements
          .where((p) => p.entityId.startsWith('light.'))
          .length;
      expect(
        find.byType(MapMarker),
        findsNWidgets(lamps + 2),
        reason: 'Lampen, ein Regler, Koordinator',
      );
      expect(find.byType(PresenceMarker), findsNothing);
      expect(find.textContaining('Licht'), findsWidgets);
      await tester.tap(find.bySemanticsLabel('Kartenart: Licht'));
      await tester.pumpAndSettle();
      expect(find.text('Kombi'), findsOneWidget);
      await tester.tap(find.text('Kombi'));
      await tester.pumpAndSettle();
      expect(store.mapLayer, 'combo');
      expect(find.byType(MapMarker), findsNWidgets(plan.placements.length + 1));
    });

    testWidgets('Batterie: schwache hervorgehoben', (tester) async {
      await _pump(tester, prefs: {'map_layer': 'battery'});
      expect(find.byType(BatteryMarker), findsWidgets);
      expect(find.textContaining('Sensor Terrasse 18 %'), findsOneWidget);
    });
  });
}
