import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/core/widgets/sparkline.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/map/floor_plan_store.dart';
import 'package:haven/features/map/map_layer_widgets.dart';
import 'package:haven/features/map/map_markers.dart';
import 'package:haven/features/map/map_panels.dart';
import 'package:haven/features/zigbee/zigbee_device_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Repo implements FloorPlanRepository {
  _Repo(this.plan);
  final HavenFloorPlan? plan;
  @override
  Future<HavenFloorPlan?> load() async => plan;
  @override
  Future<void> save(HavenFloorPlan p) async {}
  @override
  Future<void> clear() async {}
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  String layer, {
  bool desktop = false,
}) async {
  SharedPreferences.setMockInitialValues({'map_layer': layer});
  final store = SettingsStore(await SharedPreferences.getInstance());
  late Session session;
  await tester.runAsync(() async {
    final r = FakeRepository(simulate: false);
    await r.start();
    session = Session(SessionMode.fake, r);
  });
  tester.view.physicalSize = desktop
      ? const Size(1440 * 2, 900 * 2)
      : const Size(412 * 2.625, 915 * 2.625);
  tester.view.devicePixelRatio = desktop ? 2 : 2.625;
  addTearDown(tester.view.reset);
  final c = ProviderContainer(
    overrides: [
      settingsStoreProvider.overrideWithValue(store),
      tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
      initialSessionProvider.overrideWithValue(session),
      floorPlanRepositoryProvider.overrideWithValue(
        _Repo(desktop ? kFakeFloorPlan : null),
      ),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const HavenApp(initialLocation: '/map'),
    ),
  );
  // Melder pulsieren endlos, deshalb kein pumpAndSettle.
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return c;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  testWidgets('Temperatur: Antippen eines Sensors öffnet das Sensor-Sheet', (
    tester,
  ) async {
    await _pump(tester, 'temperature');
    final marker = find.byWidgetPredicate(
      (w) => w is HeatValueMarker && w.label.contains('Sensor Salon'),
    );
    await tester.tap(marker.first);
    await _settle(tester);
    expect(find.byType(SensorPanel), findsOneWidget);
    expect(find.text('Niedrigster Wert'), findsOneWidget);
    expect(find.text('Höchster Wert'), findsOneWidget);
    expect(find.byType(Sparkline), findsOneWidget, reason: 'Verlauf 24 h');
    expect(find.text('Zuletzt gemeldet'), findsOneWidget);
    expect(find.text('Batterie'), findsOneWidget);
  });

  testWidgets('Licht: Antippen einer Lampe schaltet sie', (tester) async {
    final c = await _pump(tester, 'lamps');
    const id = 'light.lampe_waschraum';
    final before = c.read(entityProvider(id))!.isOn;
    await tester.tap(
      find.byWidgetPredicate((w) => w is MapMarker && w.entityId == id),
    );
    await _settle(tester);
    expect(c.read(entityProvider(id))!.isOn, !before);
    expect(find.byType(SensorPanel), findsNothing);
  });

  testWidgets('Bewegung: Raum mit Automation zeigt ihren Zustand', (
    tester,
  ) async {
    await _pump(tester, 'presence');
    final m = find.byWidgetPredicate(
      (w) =>
          w is PresenceMarker &&
          w.entityId == 'binary_sensor.prasenz_waschraum_presence',
    );
    await tester.tapAt(tester.getCenter(m) + const Offset(-60, 30));
    await _settle(tester);
    expect(find.byType(RoomMotionPanel), findsOneWidget);
    expect(find.textContaining('Licht vom Melder'), findsOneWidget);
    expect(find.text('Bewegungslicht bearbeiten'), findsOneWidget);
    expect(find.text('Bewegungslicht einrichten'), findsNothing);
  });

  testWidgets('Bewegung: Raum ohne Automation bietet „einrichten“', (
    tester,
  ) async {
    await _pump(tester, 'presence');
    final m = find.byWidgetPredicate(
      (w) =>
          w is PresenceMarker &&
          w.entityId == 'binary_sensor.bewegungsmelder_salon_occupancy',
    );
    await tester.tapAt(tester.getCenter(m) + const Offset(-40, -30));
    await _settle(tester);
    expect(find.byType(RoomMotionPanel), findsOneWidget);
    expect(find.text('Bewegungslicht einrichten'), findsOneWidget);
    expect(find.textContaining('Licht vom Melder'), findsNothing);
  });

  testWidgets('Bewegung: Melder zeigt Zustand und die letzte Stunde', (
    tester,
  ) async {
    await _pump(tester, 'presence');
    final m = find.byWidgetPredicate(
      (w) =>
          w is PresenceMarker &&
          w.entityId == 'binary_sensor.prasenz_waschraum_presence',
    );
    await tester.tap(m);
    await _settle(tester);
    expect(find.byType(MotionPanel), findsOneWidget);
    expect(find.text('Letzte 60 Minuten'), findsOneWidget);
    expect(find.byType(MotionStrip), findsOneWidget);
  });

  testWidgets('Batterie: schwacher Sensor bekommt den Hinweis', (tester) async {
    await _pump(tester, 'battery');
    final m = find.byWidgetPredicate(
      (w) => w is BatteryMarker && w.label.contains('Sensor Terrasse'),
    );
    await tester.tap(m.first);
    await _settle(tester);
    expect(find.byType(BatteryPanel), findsOneWidget);
    expect(find.text('18 %'), findsOneWidget);
    expect(find.textContaining('Batterie prüfen'), findsOneWidget);
    expect(find.text('Spannung'), findsOneWidget);
  });

  testWidgets('Desktop: das Sensor-Panel erscheint im Inspektor', (
    tester,
  ) async {
    await _pump(tester, 'temperature', desktop: true);
    final marker = find.byWidgetPredicate(
      (w) => w is HeatValueMarker && w.label.contains('Sensor Salon'),
    );
    await tester.tap(marker.first);
    await _settle(tester);
    expect(find.byType(SensorPanel), findsOneWidget);
    expect(find.bySemanticsLabel('Schließen'), findsWidgets);
    await tester.tap(find.bySemanticsLabel('Schließen').first);
    await _settle(tester);
    expect(find.byType(SensorPanel), findsNothing);
  });

  testWidgets('Licht: langes Drücken öffnet das Licht-Sheet', (tester) async {
    await _pump(tester, 'lamps');
    await tester.longPress(
      find.byWidgetPredicate(
        (w) => w is MapMarker && w.entityId == 'light.lampe_waschraum',
      ),
    );
    await _settle(tester);
    expect(find.textContaining('Nicht in der Lichtsteuerung'), findsOneWidget);
  });

  testWidgets('Temperatur: langes Drücken öffnet das Gerät-Detail', (
    tester,
  ) async {
    await _pump(tester, 'temperature');
    await tester.longPress(
      find
          .byWidgetPredicate(
            (w) => w is HeatValueMarker && w.label.contains('Sensor Salon'),
          )
          .first,
    );
    await _settle(tester);
    expect(find.byType(ZigbeeDeviceScreen), findsOneWidget);
  });
}
