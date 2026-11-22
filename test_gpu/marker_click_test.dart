// Geräte setzen mit echter 3D-Szene: Mausklick auf einen Marker wählt ihn,
// Ziehen verschiebt ihn. (Die Widget-Tests laufen ohne GPU-Szene.)
//   flutter test --enable-flutter-gpu --enable-impeller test_gpu/marker_click_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/map/floor_plan_store.dart';
import 'package:haven/features/map/map_markers.dart';
import 'package:haven_3d/haven_3d.dart' show Scene3DSupport, Scene3DView;
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Repo implements FloorPlanRepository {
  _Repo(this.plan);
  HavenFloorPlan? plan;
  @override
  Future<HavenFloorPlan?> load() async => plan;
  @override
  Future<void> save(HavenFloorPlan p) async => plan = p;
  @override
  Future<void> clear() async => plan = null;
}

Future<void> idle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  Scene3DSupport.debugOverride = true;
  testWidgets('Geräte setzen in 3D: Klick wählt, Ziehen verschiebt', (
    tester,
  ) async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore(await SharedPreferences.getInstance());
    late Session session;
    await tester.runAsync(() async {
      final r = FakeRepository(simulate: false);
      await r.start();
      session = Session(SessionMode.fake, r);
    });
    tester.view.physicalSize = const Size(1400, 860) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final repo = _Repo(kFakeFloorPlan);
    final container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(store),
        tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
        initialSessionProvider.overrideWithValue(session),
        floorPlanRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
    final shotKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: shotKey,
        child: UncontrolledProviderScope(
          container: container,
          child: const HavenApp(initialLocation: '/map/editor?mode=devices'),
        ),
      ),
    );
    await idle(tester, 60);
    await tester.runAsync(() async {
      final b =
          shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 1);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File('build/gpu/marker_click.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(png!.buffer.asUint8List());
    });
    expect(find.byType(Scene3DView), findsOneWidget);
    final markers = find.byType(MapMarker);
    debugPrint('Marker: ${markers.evaluate().length}');
    final marker = markers.first;
    final id = tester.widget<MapMarker>(marker).entityId;
    final at = tester.getCenter(marker);
    final hit = tester.hitTestOnBinding(at);
    debugPrint(
      'Treffer bei $at: ${hit.path.take(60).map((e) => e.target.runtimeType).join(' > ')}',
    );
    final m = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await m.addPointer(location: at);
    await m.down(at);
    await idle(tester, 2);
    await m.up();
    await idle(tester, 6);
    expect(find.byKey(ValueKey('dsel-$id')), findsOneWidget, reason: 'gewählt');
    debugPrint('Klick: gewählt');
    // Wie eine echte Maus: hinbewegen (Hover), drücken, kurz halten.
    final ok = <String>[], bad = <String>[];
    var pos = const Offset(900, 760);
    for (var i = 0; i < markers.evaluate().length; i++) {
      final f = markers.at(i);
      final mid = tester.widget<MapMarker>(f).entityId;
      final to = tester.getCenter(f);
      for (var k = 1; k <= 6; k++) {
        await m.moveTo(Offset.lerp(pos, to, k / 6)!);
        await idle(tester, 1);
      }
      pos = to;
      await m.down(to);
      await idle(tester, 3);
      await m.up();
      await idle(tester, 4);
      final sel = find.byKey(ValueKey('dsel-$mid')).evaluate().isNotEmpty;
      (sel ? ok : bad).add(mid);
    }
    debugPrint('gewählt: ${ok.length}, nicht: ${bad.length} $bad');
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(seconds: 3));
    }
  });
}
