import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/adaptive/desktop_sidebar.dart';
import 'package:haven/core/router/router.dart';
import 'package:haven_3d/haven_3d.dart' as h3;
import 'package:haven/core/state/providers.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/map/floor_plan_store.dart';
import 'package:haven/features/map/furniture_library.dart';
import 'package:haven/features/map/map_inspector.dart';
import 'package:haven/features/map/map_markers.dart';
import 'package:haven/features/home/widgets/room_row.dart';
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

/// Marker [id] auf der Karte (nicht der im Panel).
Finder _markerOf(String id) =>
    find.byWidgetPredicate((w) => w is MapMarker && w.entityId == id).first;

/// Ein Marker, der frei liegt: Ein Klick auf seine Mitte trifft ihn und
/// keinen anderen, der darüber liegt.
String _freeMarkerId(WidgetTester tester) {
  final e = find.byType(MapMarker).evaluate().firstWhere((e) {
    final at = tester.getCenter(find.byWidget(e.widget));
    return tester
        .hitTestOnBinding(at)
        .path
        .any((h) => h.target == e.renderObject);
  });
  return (e.widget as MapMarker).entityId;
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
    await _pump(
      tester,
      '/map/editor?mode=furniture&view=2d&sel=salon',
      repo: repo,
    );
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
    // Rechts die kleinen Widgets, ohne Überschrift.
    expect(find.text('Strom jetzt'), findsOneWidget);
    expect(find.text('Widgets'), findsNothing);
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
            of: find.byType(RoomRow),
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

  testWidgets('Geräte setzen: Gerät wählen und von der Karte nehmen', (
    tester,
  ) async {
    final repo = _MemoryRepo(kFakeFloorPlan);
    await _pump(tester, '/map/editor?mode=devices', repo: repo, size: _desk);
    final before = kFakeFloorPlan.placements.length;
    final id = _freeMarkerId(tester);
    final marker = _markerOf(id);
    await tester.tap(marker);
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('dsel-$id')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('device-remove')));
    await tester.pumpAndSettle();
    expect(repo.plan!.placements.length, before - 1);
    expect(repo.plan!.placementOf(id), isNull);
    expect(find.byKey(ValueKey('dsel-$id')), findsNothing);
  });

  testWidgets('Geräte setzen: Lichtkegel, Streuung und Drehung', (
    tester,
  ) async {
    final repo = _MemoryRepo(kFakeFloorPlan);
    await _pump(tester, '/map/editor?mode=devices', repo: repo, size: _desk);
    const id = 'light.lampe_decke_salon';
    final marker = find.byWidgetPredicate(
      (w) => w is MapMarker && w.entityId == id,
    );
    await tester.tap(marker.first);
    await tester.pumpAndSettle();
    // Deckenleuchte: Kegel und Streuung, rund (keine Drehung).
    expect(find.byKey(const ValueKey('device-cone')), findsOneWidget);
    expect(find.byKey(const ValueKey('device-spread')), findsOneWidget);
    expect(find.byKey(const ValueKey('device-rotation')), findsNothing);
    await tester.drag(
      find.byKey(const ValueKey('device-cone')),
      const Offset(-60, 0),
    );
    await tester.pumpAndSettle();
    expect(repo.plan!.placementOf(id)!.cone, isNotNull);
    // Lightbar (Standard: nach oben): drehbar, ohne Kegel.
    await tester.tap(find.text('Lightbar'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('device-rotation')), findsOneWidget);
    expect(find.byKey(const ValueKey('device-cone')), findsNothing);
    await tester.drag(
      find.byKey(const ValueKey('device-rotation')),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();
    expect(repo.plan!.placementOf(id)!.rotation, greaterThan(0));
  });

  testWidgets('Geräte setzen: Entf nimmt das gewählte Gerät von der Karte', (
    tester,
  ) async {
    final repo = _MemoryRepo(kFakeFloorPlan);
    await _pump(tester, '/map/editor?mode=devices', repo: repo, size: _desk);
    final id = _freeMarkerId(tester);
    final marker = _markerOf(id);
    await tester.tap(marker);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(repo.plan!.placementOf(id), isNull);
  });

  testWidgets('Geräte setzen: Licht aus, live, alle an', (tester) async {
    await _pump(tester, '/map/editor?mode=devices', size: _desk);
    expect(find.byKey(const ValueKey('editor-light')), findsOneWidget);
    for (final t in ['An', 'Live', 'Aus']) {
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('editor-light')),
          matching: find.text(t),
        ),
      );
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Geräte setzen: Thermostat-Display an die Wand, Details ohne Fehler',
    (tester) async {
      final repo = _MemoryRepo(kFakeFloorPlan);
      await _pump(tester, '/map/editor?mode=devices', repo: repo, size: _desk);
      await tester.tap(find.text('Schnell platzieren').first);
      await tester.pumpAndSettle();
      final p = repo.plan!.placementOf('climate.display_ruheraum');
      expect(p, isNotNull);
      expect(p!.model, 'wall_thermostat');
      // Ein Thermostat wählen: die Pille mit Werten im Panel bricht das
      // Layout nicht.
      final marker = find.byWidgetPredicate(
        (w) => w is MapMarker && w.entityId == 'climate.display_ruheraum',
      );
      await tester.tap(marker.first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('dsel-climate.display_ruheraum')),
        findsOneWidget,
      );
      expect(find.text('Thermostat-Display'), findsOneWidget);
    },
  );

  testWidgets('Geräte setzen: Mausklick mit Zittern wählt, Ziehen verschiebt', (
    tester,
  ) async {
    final repo = _MemoryRepo(kFakeFloorPlan);
    await _pump(tester, '/map/editor?mode=devices', repo: repo, size: _desk);
    final id = _freeMarkerId(tester);
    final marker = _markerOf(id);
    // Links oben im Marker (früher war nur das rechte untere Viertel
    // klickbar).
    final at = tester.getCenter(marker) - const Offset(6, 6);
    // Ein echter Klick: drücken, ein paar Bilder, 2 px gewackelt, loslassen.
    final m = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await m.addPointer(location: at);
    await m.down(at);
    await tester.pump(const Duration(milliseconds: 40));
    await m.moveTo(at + const Offset(2, 1));
    await tester.pump(const Duration(milliseconds: 40));
    await m.up();
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('dsel-$id')), findsOneWidget, reason: 'gewählt');
    // Danach direkt ziehen (gewählt, ein Versuch).
    final before = repo.plan!.placementOf(id)!;
    final start = tester.getCenter(marker);
    final mid = tester.getCenter(find.byType(h3.Scene3DView));
    final step = (mid - start) / 24;
    await m.down(start);
    await tester.pump(const Duration(milliseconds: 30));
    for (var i = 1; i <= 12; i++) {
      await m.moveTo(start + step * i.toDouble());
      await tester.pump(const Duration(milliseconds: 16));
    }
    await m.up();
    await tester.pumpAndSettle();
    expect(repo.plan!.placementOf(id)!.cell, isNot(before.cell));
  });

  for (final size in [_desk, _phone]) {
    testWidgets('Geräte setzen: Gerät ziehen verschiebt es (${size.width})', (
      tester,
    ) async {
      final repo = _MemoryRepo(kFakeFloorPlan);
      await _pump(tester, '/map/editor?mode=devices', repo: repo, size: size);
      final id = _freeMarkerId(tester);
      final marker = _markerOf(id);
      final before = repo.plan!.placementOf(id)!;
      final start = tester.getCenter(marker);
      // Langsam zur Mitte der Fläche ziehen wie mit Maus bzw. Finger.
      final mid = tester.getCenter(find.byType(h3.Scene3DView));
      final step = (mid - start) / 24;
      final g = await tester.startGesture(start);
      for (var i = 1; i <= 12; i++) {
        await g.moveTo(start + step * i.toDouble());
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pumpAndSettle();
      final after = repo.plan!.placementOf(id);
      expect(after, isNotNull, reason: 'nicht von der Karte gefallen');
      expect(after!.cell, isNot(before.cell), reason: 'verschoben');
    });

    testWidgets(
      'Geräte setzen: Antippen wählt, noch mal abwählt (${size.width})',
      (tester) async {
        await _pump(
          tester,
          '/map/editor?mode=devices',
          repo: _MemoryRepo(kFakeFloorPlan),
          size: size,
        );
        final id = _freeMarkerId(tester);
        final marker = _markerOf(id);
        for (var i = 0; i < 3; i++) {
          await tester.tap(marker);
          await tester.pumpAndSettle();
          expect(
            find.byKey(ValueKey('dsel-$id')),
            findsOneWidget,
            reason: 'Runde $i',
          );
          await tester.tap(marker);
          await tester.pumpAndSettle();
          expect(
            find.byKey(ValueKey('dsel-$id')),
            findsNothing,
            reason: 'Runde $i',
          );
        }
      },
    );
  }

  testWidgets(
    'Geräte setzen: neben dem Raster bleibt es, auf der Liste geht es',
    (tester) async {
      final repo = _MemoryRepo(kFakeFloorPlan);
      await _pump(tester, '/map/editor?mode=devices', repo: repo, size: _phone);
      final id = _freeMarkerId(tester);
      final before = repo.plan!.placementOf(id)!;
      Future<void> dragTo(Offset to) async {
        final start = tester.getCenter(_markerOf(id));
        final g = await tester.startGesture(start);
        for (var i = 1; i <= 10; i++) {
          await g.moveTo(Offset.lerp(start, to, i / 10)!);
          await tester.pump(const Duration(milliseconds: 16));
        }
        await g.up();
        await tester.pumpAndSettle();
      }

      // Ganz oben links aus dem Bild: bleibt, wo es war.
      await dragTo(const Offset(2, 2));
      expect(repo.plan!.placementOf(id), before);
      // Auf die Geräteliste: von der Karte genommen.
      await dragTo(tester.getCenter(find.text('Geräte platzieren')));
      expect(repo.plan!.placementOf(id), isNull);
    },
  );
}
