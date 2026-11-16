import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/adaptive/desktop_sidebar.dart';
import 'package:haven/core/router/router.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/map/floor_plan_store.dart';
import 'package:haven/features/map/furniture_library.dart';
import 'package:haven/features/map/map_inspector.dart';
import 'package:haven/features/map/map_markers.dart';
import 'package:haven/features/home/widgets/room_tile.dart';
import 'package:haven/features/room/room_screen.dart';
import 'package:haven/features/shell/app_shell.dart';
import 'package:haven/features/zigbee/zigbee_device_screen.dart';
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

Future<ProviderContainer> _pump(
  WidgetTester tester,
  String location, {
  _MemoryRepo? repo,
  Size size = _phone,
  bool settle = true,
}) async {
  SharedPreferences.setMockInitialValues({});
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
      floorPlanRepositoryProvider.overrideWithValue(repo ?? _MemoryRepo()),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: HavenApp(initialLocation: location),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
  return container;
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  testWidgets('Räume zeichnen blendet Geräte aus, Geräte setzen zeigt sie', (
    tester,
  ) async {
    await _pump(tester, '/map/editor', repo: _MemoryRepo(kFakeFloorPlan));
    expect(find.text('Räume zeichnen'), findsOneWidget);
    expect(find.byType(MapMarker), findsNothing);
    await tester.tap(find.text('Geräte setzen'));
    await tester.pumpAndSettle();
    expect(find.byType(MapMarker), findsWidgets);
    await tester.tap(find.text('Einrichten'));
    await tester.pumpAndSettle();
    expect(find.byType(MapMarker), findsNothing);
    expect(find.byType(FurnitureLibrary), findsOneWidget);
  });

  testWidgets('Einrichten: hinzufügen, löschen mit Entf, Strg+Z', (
    tester,
  ) async {
    final repo = _MemoryRepo(kFakeFloorPlan);
    await _pump(tester, '/map/editor?mode=furniture&sel=salon', repo: repo);
    final before = kFakeFloorPlan.furniture.length;
    // Wohnen ist vorgewählt, das Sofa steht vorne.
    final sofa = find.byWidgetPredicate(
      (w) => w is LibraryTile && w.type.id == 'sofa',
    );
    await tester.tap(sofa);
    await tester.pumpAndSettle();
    expect(repo.plan!.furniture.length, before + 1);
    final added = repo.plan!.furniture.last;
    expect(added.kind, 'sofa');
    // In den Salon gesetzt, auf dem Halbraster.
    expect(repo.plan!.locationOfFurniture(added), 'salon');
    final l2 = added.bounds.left * 2;
    expect((l2 - l2.roundToDouble()).abs(), lessThan(1e-6));
    // Auswahl zeigt die Werkzeuge.
    expect(find.text('Sofa'), findsWidgets);
    expect(find.bySemanticsLabel('Duplizieren'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pumpAndSettle();
    expect(repo.plan!.furnitureById(added.id)!.rotation, 90);

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(repo.plan!.furnitureById(added.id), isNull);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(repo.plan!.furnitureById(added.id)!.rotation, 90);
  });

  testWidgets('Desktop: Seitenleiste statt unterer Leiste', (tester) async {
    await _pump(tester, '/home', size: _desk);
    expect(find.byType(DesktopSidebar), findsOneWidget);
    expect(find.byType(HavenNavBar), findsNothing);
    expect(find.text('Widgets'), findsOneWidget);
  });

  testWidgets('Handy: untere Leiste wie bisher', (tester) async {
    await _pump(tester, '/home');
    expect(find.byType(DesktopSidebar), findsNothing);
    expect(find.byType(HavenNavBar), findsOneWidget);
  });

  testWidgets('Desktop: Karte mit Inspektor, Raum wählt aus', (tester) async {
    await _pump(
      tester,
      '/map?inspect=salon',
      repo: _MemoryRepo(kFakeFloorPlan),
      size: _desk,
    );
    expect(find.byType(MapInspector), findsOneWidget);
    expect(find.text('Raum öffnen'), findsOneWidget);
    expect(find.text('Einrichten'), findsOneWidget);
  });

  testWidgets('Desktop: Raum als Seitenpanel, Esc schließt', (tester) async {
    final c = await _pump(tester, '/home', size: _desk);
    unawaited(c.read(routerProvider('/home')).push('/home/room/salon'));
    await tester.pumpAndSettle();
    final room = tester.widget<RoomScreen>(find.byType(RoomScreen));
    expect(room.panel, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(RoomScreen), findsNothing);
  });

  testWidgets('Desktop: Pfeil an der Kachel öffnet den Raum', (tester) async {
    await _pump(tester, '/home', size: _desk);
    await tester.tap(
      find
          .descendant(
            of: find.byType(RoomTile),
            matching: find.byIcon(Icons.chevron_right_rounded),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.byType(RoomScreen), findsOneWidget);
  });

  testWidgets('Desktop: Zigbee als Master-Detail', (tester) async {
    await _pump(
      tester,
      '/zigbee?select=0x00124b0000000009',
      size: _desk,
      settle: false,
    );
    final detail = tester.widget<ZigbeeDeviceScreen>(
      find.byType(ZigbeeDeviceScreen),
    );
    expect(detail.embedded, isTrue);
    expect(detail.ieee, '0x00124b0000000009');
  });

  testWidgets('Desktop: Editor mit Bibliothek als Raster', (tester) async {
    await _pump(
      tester,
      '/map/editor?mode=furniture',
      repo: _MemoryRepo(kFakeFloorPlan),
      size: _desk,
    );
    final lib = tester.widget<FurnitureLibrary>(find.byType(FurnitureLibrary));
    expect(lib.grid, isTrue);
    expect(find.byType(LibraryTile, skipOffstage: false), findsWidgets);
  });
}
