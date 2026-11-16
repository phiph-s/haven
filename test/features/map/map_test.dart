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
    // Jede Platzierung hat einen Marker, die Gruppe (zwei Lampen auf einem
    // Feld) zeigt zusätzlich ihr erstes Gerät im Gruppenknoten.
    expect(find.byType(MapMarker), findsNWidgets(plan.placements.length + 1));
    expect(find.byType(FloorGroupBadge), findsOneWidget);
    expect(find.bySemanticsLabel('Kartenart: Licht'), findsOneWidget);

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

  testWidgets('Gruppe fächert auf, dann schaltet die Lampe darin', (
    tester,
  ) async {
    final c = await _pump(tester, '/map', repo: _MemoryRepo());
    const id = 'light.lampe_salon';
    final before = c.read(snapshotProvider).entity(id)!.isOn;
    await tester.tap(find.byType(FloorGroupBadge));
    await tester.pumpAndSettle();
    final marker = find.byWidgetPredicate(
      (w) => w is MapMarker && w.entityId == id,
    );
    // Aufgefächert: die Lampe liegt nicht mehr unter dem Gruppenknoten.
    final g = tester.getCenter(find.byType(FloorGroupBadge));
    final m = tester.getCenter(marker.first);
    expect((g - m).distance, greaterThan(20));
    await tester.tap(marker.first, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.read(snapshotProvider).entity(id)!.isOn, !before);
  });

  testWidgets('Antippen einer Lampe schaltet sie', (tester) async {
    final c = await _pump(tester, '/map', repo: _MemoryRepo());
    const id = 'light.lampe_decke_salon';
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
    expect(r.points, const [
      GridPoint(2, 2),
      GridPoint(9, 2),
      GridPoint(9, 8),
      GridPoint(2, 8),
    ]);
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
    final a = origin + geo.cellToPx(const Offset(16, 27));
    final b = origin + geo.cellToPx(const Offset(21, 22));
    await tester.dragFrom(a, b - a);
    await tester.pumpAndSettle();
    expect(find.text('Raum zuordnen'), findsNothing);
    expect(c.read(floorPlanProvider).value!.rooms.length, 5);
    expect(find.textContaining('Überlappt'), findsOneWidget);
  });

  testWidgets('Editor: Ecke einfügen, entfernen, ziehen und rückgängig', (
    tester,
  ) async {
    final start = HavenFloorPlan(
      rooms: [FloorRoom.rect(id: 'a', name: 'A', x: 2, y: 2, w: 8, h: 6)],
    );
    final repo = _MemoryRepo(start);
    final c = await _pump(tester, '/map/editor?sel=a', repo: repo);
    final view = find.byType(FloorPlanView);
    final origin = tester.getTopLeft(view);
    Offset px(int x, int y) =>
        origin +
        FloorGeometry.compute(
          plan: c.read(floorPlanProvider).value!,
          size: tester.getSize(view),
          fitGrid: true,
          withOutside: true,
        ).cellToPx(Offset(x.toDouble(), y.toDouble()));
    List<GridPoint> pts() => c.read(floorPlanProvider).value!.room('a')!.points;

    // Kantenmitte antippen: neue Ecke auf (6, 2).
    await tester.tapAt(px(6, 2));
    await tester.pumpAndSettle();
    expect(pts(), hasLength(5));
    expect(pts(), contains(const GridPoint(6, 2)));

    // Lange drücken entfernt sie wieder.
    await tester.longPressAt(px(6, 2));
    await tester.pumpAndSettle();
    expect(pts(), start.room('a')!.points);

    // Ecke ziehen: rastet auf dem Rasterpunkt ein, schräge Wand.
    await tester.dragFrom(px(10, 2), px(12, 1) - px(10, 2));
    await tester.pumpAndSettle();
    expect(pts()[1], const GridPoint(12, 1));
    expect(repo.plan!.room('a')!.points[1], const GridPoint(12, 1));

    await tester.tap(find.bySemanticsLabel('Rückgängig'));
    await tester.pumpAndSettle();
    expect(pts(), start.room('a')!.points);
  });

  testWidgets('FloorPlanView: gap 0 zu 2 fährt die Räume weich auseinander', (
    tester,
  ) async {
    final plan = kFakeFloorPlan;
    const node = FloorNode(id: 'k', point: PlanPoint(19.5, 6.5, 'kochbereich'));
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
