import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/map/floor_plan_store.dart';
import 'package:haven/features/map/furniture_library.dart';
import 'package:haven/features/map/map_markers.dart';
import 'package:haven/features/map/placement_3d.dart';
import 'package:haven_3d/haven_3d.dart' as h3;
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

const _phone = Size(412, 915);
const _desk = Size(1440, 900);

Future<void> _pump(
  WidgetTester tester,
  String location, {
  required _MemoryRepo repo,
  Size size = _phone,
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
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
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
}

/// Bildschirmpunkt (global) eines Weltpunkts in der 3D-Ansicht des Editors.
Offset _screen(WidgetTester tester, Offset cells, {double z = 0}) {
  final view = find.byType(h3.Scene3DView);
  final cam = tester.widget<h3.Scene3DView>(view).controller.camera;
  final m = kFakeFloorPlan.grid.cellMeters;
  final p = cam.project(
    h3.V3(cells.dx * m, cells.dy * m, z),
    tester.getSize(view),
  );
  return tester.getTopLeft(view) + p.offset;
}

Future<void> _drag(WidgetTester tester, List<Offset> path) async {
  final g = await tester.startGesture(path.first);
  for (final p in path.skip(1)) {
    await g.moveTo(p);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await tester.pumpAndSettle();
}

List<Offset> _line(Offset a, Offset b, [int steps = 12]) => [
  for (var i = 0; i <= steps; i++) Offset.lerp(a, b, i / steps)!,
];

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  for (final size in [_phone, _desk]) {
    testWidgets('Einrichten in 3D: platzieren, verschieben, drehen, löschen '
        '(${size.width})', (tester) async {
      final repo = _MemoryRepo(kFakeFloorPlan);
      await _pump(
        tester,
        '/map/editor?mode=furniture&view=3d&sel=salon',
        repo: repo,
        size: size,
      );
      final before = kFakeFloorPlan.furniture.length;
      expect(find.byType(h3.Scene3DView), findsOneWidget);

      // Sofa aus der Bibliothek: folgt erst dem Finger, nichts gespeichert.
      await tester.tap(
        find.byWidgetPredicate((w) => w is LibraryTile && w.type.id == 'sofa'),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('placing-bar')), findsOneWidget);
      expect(repo.plan!.furniture.length, before);

      // Tippen in den Salon stellt es dort ab (eingerastet).
      const target = Offset(11, 6);
      await tester.tapAt(_screen(tester, target));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('placing-bar')), findsNothing);
      expect(repo.plan!.furniture.length, before + 1);
      var sofa = repo.plan!.furniture.last;
      expect(sofa.kind, 'sofa');
      expect((sofa.center - target).distance, lessThan(0.6));
      expect(repo.plan!.locationOfFurniture(sofa), 'salon');
      // Gewählt: Werkzeuge über dem Sofa.
      expect(
        find.byKey(const ValueKey('furniture-toolbar-3d')),
        findsOneWidget,
      );

      // Ziehen verschiebt auf dem Boden (Halbraster), ein Schritt zurück.
      final top = furnitureTop(sofa);
      final from = sofa.center;
      await _drag(
        tester,
        _line(
          _screen(tester, from, z: top),
          _screen(tester, from + const Offset(0, 2.5), z: top),
        ),
      );
      sofa = repo.plan!.furnitureById(sofa.id)!;
      expect(sofa.center.dy - from.dy, closeTo(2.5, 0.51));
      expect(sofa.center.dx, closeTo(from.dx, 0.51));
      final moved = sofa;

      // Am Ring drehen: Griff vor der Vorderseite eine Vierteldrehung weiter.
      final m = kFakeFloorPlan.grid.cellMeters;
      final r = rotationRingRadius(sofa, m) / m;
      await _drag(tester, [
        for (var i = 0; i <= 12; i++)
          _screen(
            tester,
            sofa.center +
                Offset.fromDirection(math.pi / 2 + i / 12 * math.pi / 2, r),
            z: 0.02,
          ),
      ]);
      sofa = repo.plan!.furnitureById(sofa.id)!;
      expect(sofa.rotation, 90);
      expect(sofa.center, moved.center);

      // 90°-Knopf in der Leiste.
      await tester.tap(find.bySemanticsLabel('Um 90° nach rechts drehen'));
      await tester.pumpAndSettle();
      expect(repo.plan!.furnitureById(sofa.id)!.rotation, 180);

      // Farben: Knopf in der Leiste öffnet die Farbwahl, eine Palettenfarbe
      // färbt das erste Teil; rückgängig nimmt sie wieder weg.
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('furniture-toolbar-3d')),
          matching: find.bySemanticsLabel('Farben'),
        ),
      );
      await tester.pumpAndSettle();
      final sheet = find.byKey(ValueKey('fcolors-sheet${sofa.id}'));
      expect(sheet, findsOneWidget);
      await tester.tap(
        find.descendant(of: sheet, matching: find.byTooltip('Salbei')),
      );
      await tester.pumpAndSettle();
      final zone = h3.furnitureSpec('sofa').zones.first.id;
      expect(
        repo.plan!.furnitureById(sofa.id)!.colors[zone]?.toARGB32(),
        0xFF93A68A,
      );
      Navigator.of(tester.element(sheet)).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Rückgängig').first);
      await tester.pumpAndSettle();
      expect(repo.plan!.furnitureById(sofa.id)!.colors, isEmpty);
      expect(repo.plan!.furnitureById(sofa.id)!.rotation, 180);

      // Löschen, dann zweimal rückgängig: wieder da, wie vor dem Knopf.
      await tester.tap(find.bySemanticsLabel('Löschen').last);
      await tester.pumpAndSettle();
      expect(repo.plan!.furnitureById(sofa.id), isNull);
      await tester.tap(find.bySemanticsLabel('Rückgängig').first);
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Rückgängig').first);
      await tester.pumpAndSettle();
      expect(repo.plan!.furnitureById(sofa.id), sofa);

      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Einrichten in 3D: Esc bricht ab, Enter stellt ab, Umschalt + '
      'Mausrad dreht', (tester) async {
    final repo = _MemoryRepo(kFakeFloorPlan);
    await _pump(
      tester,
      '/map/editor?mode=furniture&view=3d',
      repo: repo,
      size: _desk,
    );
    final before = kFakeFloorPlan.furniture.length;
    final tile = find.byWidgetPredicate(
      (w) => w is LibraryTile && w.type.id == 'coffee_table',
    );
    await tester.tap(tile);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('placing-bar')), findsNothing);
    expect(repo.plan!.furniture.length, before);

    // Maus über dem Salon: die Vorschau folgt, Enter stellt sie dort ab.
    await tester.tap(tile);
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: _screen(tester, const Offset(10, 5)));
    await mouse.moveTo(_screen(tester, const Offset(11, 6)));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(repo.plan!.furniture.length, before + 1);
    final table = repo.plan!.furniture.last;
    expect((table.center - const Offset(11, 6)).distance, lessThan(0.6));

    // Umschalt + Mausrad: 15° je Raste, ein Schritt zum Rückgängigmachen.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final at = _screen(tester, table.center, z: furnitureTop(table));
    for (var i = 0; i < 3; i++) {
      await tester.sendEventToBinding(
        PointerScrollEvent(position: at, scrollDelta: const Offset(0, 40)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(repo.plan!.furnitureById(table.id)!.rotation, 45);
    await tester.tap(find.bySemanticsLabel('Rückgängig').first);
    await tester.pumpAndSettle();
    expect(repo.plan!.furnitureById(table.id)!.rotation, 0);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('2D/3D-Schalter beim Einrichten bleibt gemerkt', (tester) async {
    final repo = _MemoryRepo(kFakeFloorPlan);
    await _pump(tester, '/map/editor?mode=furniture', repo: repo);
    final store = SettingsStore(await SharedPreferences.getInstance());
    expect(store.editorFurniture3d, isTrue, reason: 'Standard ist 3D');
    await tester.tap(find.text('2D'));
    await tester.pumpAndSettle();
    expect(store.editorFurniture3d, isFalse);
    // In 2D setzt Antippen wie bisher sofort in die Mitte.
    await tester.tap(
      find.byWidgetPredicate((w) => w is LibraryTile && w.type.id == 'sofa'),
    );
    await tester.pumpAndSettle();
    expect(repo.plan!.furniture.length, kFakeFloorPlan.furniture.length + 1);
  });

  testWidgets('Geräte setzen: auf die Wand gezeigt hängt der Melder dort', (
    tester,
  ) async {
    final repo = _MemoryRepo(kFakeFloorPlan);
    await _pump(tester, '/map/editor?mode=devices', repo: repo, size: _desk);
    const id = 'binary_sensor.bewegungsmelder_salon_occupancy';
    expect(repo.plan!.placementOf(id)!.mount, isNull, reason: 'an der Decke');
    final marker = find.byWidgetPredicate(
      (w) => w is MapMarker && w.entityId == id,
    );
    // Nordwand des Salons (y = 3 Zellen), Innenseite, auf 1,5 m Höhe.
    final m = kFakeFloorPlan.grid.cellMeters;
    final inset = h3.wallInset(h3.SceneStyle.light().roomGap) / m;
    final onWall = _screen(tester, Offset(8.2, 3 + inset), z: 1.5);
    await _drag(tester, _line(tester.getCenter(marker), onWall, 16));
    final p = repo.plan!.placementOf(id)!;
    expect(p.mount, 'wall');
    expect(p.cell, const GridPoint(8, 3));
    expect(repo.plan!.locationOf(p), 'salon');
  });
}
