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
import 'package:haven/features/map/floor_geometry.dart';
import 'package:haven/features/map/map_3d.dart';
import 'package:haven_3d/haven_3d.dart' show Scene3DView;
import 'package:haven/features/map/map_markers.dart';
import 'package:haven/features/map/map_sky.dart';
import 'package:flutter/widgets.dart' show ValueKey;
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
  Map<String, Object> prefs = const {},
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
    expect(find.byType(Map3DView), findsOneWidget);
    final plan = kFakeFloorPlan;
    // Kombi: nur Geräte, bei denen gerade etwas los ist (z. B. Licht an),
    // höchstens einer je Platzierung.
    final markers = tester.widgetList<MapMarker>(find.byType(MapMarker));
    expect(markers.length, lessThan(plan.placements.length));
    final snap0 = c.read(snapshotProvider);
    for (final m in markers) {
      final e = snap0.entity(m.entityId);
      if (e != null && e.domain == 'light') expect(e.isOn, isTrue);
    }
    expect(find.bySemanticsLabel('Kartenart Kombi'), findsOneWidget);

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

  testWidgets('Zwei Lampen auf einem Feld rücken auseinander und schalten', (
    tester,
  ) async {
    final c = await _pump(
      tester,
      '/map',
      repo: _MemoryRepo(),
      prefs: {'map_layer': 'lamps'},
    );
    const id = 'light.lampe_salon';
    final plan = kFakeFloorPlan;
    final cell = plan.placementOf(id)!.cell;
    final same = [
      for (final p in plan.placements)
        if (p.cell == cell) p.entityId,
    ];
    expect(same.length, 2, reason: 'Beispiel: zwei Lampen auf einem Feld');
    Offset at(String e) => tester.getCenter(
      find.byWidgetPredicate((w) => w is MapMarker && w.entityId == e),
    );
    expect((at(same[0]) - at(same[1])).distance, greaterThan(20));
    final before = c.read(snapshotProvider).entity(id)!.isOn;
    await tester.tapAt(at(id));
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.read(snapshotProvider).entity(id)!.isOn, !before);
  });

  testWidgets('Antippen einer Lampe schaltet sie', (tester) async {
    final c = await _pump(
      tester,
      '/map',
      repo: _MemoryRepo(),
      prefs: {'map_layer': 'lamps'},
    );
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

    final view = find.byType(Scene3DView);
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
    final view = find.byType(Scene3DView);
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
    final view = find.byType(Scene3DView);
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

  testWidgets('Wetterknopf: Live oder eigene Werte, bleibt gespeichert', (
    tester,
  ) async {
    final c = await _pump(tester, '/map', repo: _MemoryRepo());
    final button = find.byKey(const ValueKey('map-weather'));
    expect(button, findsOneWidget);
    expect(c.read(mapSkySettingsProvider).mode, MapSkyMode.live);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('Himmel der Karte'), findsOneWidget);
    expect(find.text('Wetterquellen einstellen'), findsOneWidget);
    await tester.tap(find.text('Eigenes'));
    await tester.pumpAndSettle();
    expect(c.read(mapSkySettingsProvider).mode, MapSkyMode.manual);
    expect(find.text('Schneehöhe'), findsOneWidget);
    expect(find.text('Gewitter'), findsOneWidget);
    // Eigene Werte landen im Gerät und wirken auf die Karte.
    expect(c.read(settingsStoreProvider).mapSky['mode'], 'manual');
    expect(c.read(mapWeatherProvider(0)).live, isFalse);
  });

  testWidgets('Ohne Umgebung kein Wetterknopf', (tester) async {
    final c = await _pump(
      tester,
      '/map',
      repo: _MemoryRepo(),
      prefs: const {'map_3d_environment': false},
    );
    expect(c.read(map3dSettingsProvider).environment, isFalse);
    expect(find.byKey(const ValueKey('map-weather')), findsNothing);
  });
}
