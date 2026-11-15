import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/features/map/device_pool.dart';
import 'package:haven/features/map/floor_plan_store.dart';
import 'package:haven/features/map/floor_plan_view.dart';
import 'package:haven/core/theme/theme.dart';
import 'package:haven/features/map/map_markers.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryRepo implements FloorPlanRepository {
  _MemoryRepo([this.plan]);
  HavenFloorPlan? plan;
  @override
  Future<HavenFloorPlan?> load() async => plan;
  @override
  Future<void> save(HavenFloorPlan p) async => plan = p;
  @override
  Future<void> clear() async => plan = null;
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  String location, {
  required _MemoryRepo repo,
}) async {
  SharedPreferences.setMockInitialValues({});
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
  final container = ProviderContainer(
    overrides: [
      settingsStoreProvider.overrideWithValue(store),
      tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
      initialSessionProvider.overrideWithValue(session),
      floorPlanRepositoryProvider.overrideWithValue(repo),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: HavenApp(initialLocation: location),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  testWidgets('Karte rendert mit dem Beispielgrundriss', (tester) async {
    final c = await _pump(tester, '/map', repo: _MemoryRepo());
    expect(find.text('Karte'), findsWidgets);
    expect(find.byType(FloorPlanView), findsOneWidget);
    final plan = kFakeFloorPlan;
    expect(find.byType(MapMarker), findsNWidgets(plan.placements.length));
    expect(find.text('Lichter'), findsOneWidget);
    expect(find.text('Werte'), findsOneWidget);

    // Alle platzierten Entities gibt es in den Beispieldaten.
    final snap = c.read(snapshotProvider);
    for (final p in plan.placements) {
      expect(snap.entity(p.entityId), isNotNull, reason: p.entityId);
    }
    // Der Grundriss ist stimmig (Pool im Editor: Rest bleibt unplatziert).
    final zb = await tester.runAsync(
      () => c.read(repositoryProvider).zigbeeDevices(),
    );
    final pool = buildDevicePool(snap, zb!, plan);
    expect(pool.zigbee.placed, greaterThan(0));
    expect(pool.zigbee.open, greaterThan(0));
  });

  testWidgets('Antippen einer Lampe schaltet sie', (tester) async {
    final c = await _pump(tester, '/map', repo: _MemoryRepo());
    const id = 'light.tischlampe_salon';
    final before = c.read(snapshotProvider).entity(id)!.isOn;
    final marker = find.byWidgetPredicate(
      (w) => w is MapMarker && w.entityId == id,
    );
    await tester.tap(marker);
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.read(snapshotProvider).entity(id)!.isOn, !before);
  });

  testWidgets('Leerzustand ohne Grundriss', (tester) async {
    await _pump(tester, '/map', repo: _MemoryRepo(const HavenFloorPlan()));
    expect(find.text('Noch kein Grundriss'), findsOneWidget);
    await tester.tap(find.text('Grundriss zeichnen'));
    await tester.pumpAndSettle();
    expect(find.text('Räume zeichnen'), findsOneWidget);
    expect(find.text('Geräte setzen'), findsOneWidget);
  });

  testWidgets('Editor legt einen Raum an', (tester) async {
    final repo = _MemoryRepo(const HavenFloorPlan());
    final c = await _pump(tester, '/map/editor', repo: repo);
    expect(find.text('Grundriss'), findsOneWidget);

    final view = find.byType(FloorPlanView);
    final size = tester.getSize(view);
    final origin = tester.getTopLeft(view);
    final geo = FloorGeometry.compute(
      plan: const HavenFloorPlan(),
      size: size,
      fitGrid: true,
    );
    final a = origin + geo.cellToPx(const Offset(2, 2));
    final b = origin + geo.cellToPx(const Offset(9, 8));
    await tester.dragFrom(a, b - a);
    await tester.pumpAndSettle();

    // Bottom Sheet mit der Zuordnung.
    expect(find.text('Raum zuordnen'), findsOneWidget);
    await tester.tap(find.text('Salon'));
    await tester.pumpAndSettle();

    final plan = c.read(floorPlanProvider).value!;
    expect(plan.rooms.length, 1);
    final r = plan.rooms.single;
    expect((r.x, r.y, r.w, r.h), (2, 2, 7, 6));
    expect(r.name, 'Salon');
    expect(r.areaId, 'salon');
    expect(plan.isValid, isTrue);
    expect(repo.plan, plan, reason: 'wurde gespeichert');

    // Rückgängig nimmt den Raum wieder weg (erst Zuordnung, dann Anlegen).
    await tester.tap(find.bySemanticsLabel('Rückgängig'));
    await tester.pumpAndSettle();
    expect(c.read(floorPlanProvider).value!.rooms.single.name, 'Neuer Raum');
    await tester.tap(find.bySemanticsLabel('Rückgängig'));
    await tester.pumpAndSettle();
    expect(c.read(floorPlanProvider).value!.rooms, isEmpty);
  });

  testWidgets('Editor: überlappende Räume werden verworfen', (tester) async {
    final repo = _MemoryRepo(kFakeFloorPlan);
    final c = await _pump(tester, '/map/editor', repo: repo);
    final view = find.byType(FloorPlanView);
    final geo = FloorGeometry.compute(
      plan: kFakeFloorPlan,
      size: tester.getSize(view),
      fitGrid: true,
    );
    // Von freier Fläche unter dem Bad in das Bad ziehen: überlappt.
    final origin = tester.getTopLeft(view);
    final a = origin + geo.cellToPx(const Offset(13, 25));
    final b = origin + geo.cellToPx(const Offset(19, 20));
    await tester.dragFrom(a, b - a);
    await tester.pumpAndSettle();
    expect(find.text('Raum zuordnen'), findsNothing);
    expect(c.read(floorPlanProvider).value!.rooms.length, 5);
    expect(find.textContaining('Überlappt'), findsOneWidget);
  });

  testWidgets('FloorPlanView: gap 0 zu 2 fährt die Räume weich auseinander', (
    tester,
  ) async {
    final plan = kFakeFloorPlan;
    const node = FloorNode(id: 'k', point: PlanPoint('kochbereich', 0.5, 0.5));
    Widget app(double gap) => MaterialApp(
      theme: havenLightTheme,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            height: 600,
            child: FloorPlanView(
              plan: plan,
              gap: gap,
              reserveGap: 2,
              fill: true,
              nodes: const [node],
              nodeBuilder: (c, n) =>
                  const SizedBox(key: Key('probe'), width: 8, height: 8),
            ),
          ),
        ),
      ),
    );
    Offset k() => tester.getCenter(find.byKey(const Key('probe')));
    await tester.pumpWidget(app(0));
    final a = k();
    await tester.pumpWidget(app(2));
    await tester.pump(const Duration(milliseconds: 200));
    final mid = k();
    await tester.pumpAndSettle();
    final b = k();
    expect(mid, isNot(a));
    expect(mid, isNot(b));
    // Die Kochbereich liegt rechts vom Salon: sie rückt nach rechts, bleibt
    // aber wegen der Anpassung an die Fläche im Bild.
    expect((b - a).distance, greaterThan(1));
    await tester.pumpWidget(app(0));
    await tester.pumpAndSettle();
    expect((k() - a).distance, lessThan(0.01));
  });
}
