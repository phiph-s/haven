// Rendert Karte, Editor und Netzkarte der App mit echter GPU nach
// build/gpu/ (Sichtprüfung).
//   flutter test --enable-flutter-gpu --enable-impeller test_gpu/app_screens_test.dart
import 'dart:io';
import 'dart:ui' as ui;

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
import 'package:haven_3d/haven_3d.dart' show Scene3DSupport;
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

Future<void> shot(
  WidgetTester tester,
  String name,
  String location, {
  Map<String, Object> prefs = const {},
}) async {
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues(prefs);
  final store = SettingsStore(await SharedPreferences.getInstance());
  late Session session;
  await tester.runAsync(() async {
    final r = FakeRepository(simulate: false);
    await r.start();
    session = Session(SessionMode.fake, r);
  });
  tester.view.physicalSize = const Size(412 * 2, 915 * 2);
  tester.view.devicePixelRatio = 2;
  final container = ProviderContainer(
    overrides: [
      settingsStoreProvider.overrideWithValue(store),
      tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
      initialSessionProvider.overrideWithValue(session),
      floorPlanRepositoryProvider.overrideWithValue(_Repo(kFakeFloorPlan)),
    ],
  );
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: UncontrolledProviderScope(
        container: container,
        child: HavenApp(initialLocation: location),
      ),
    ),
  );
  for (var i = 0; i < 60; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.runAsync(() async {
    final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final img = await b.toImage(pixelRatio: 2);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    File('build/gpu/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
  await tester.pumpWidget(const SizedBox());
  container.dispose();
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(seconds: 3));
  }
}

void main() {
  Scene3DSupport.debugOverride = true;
  testWidgets('App-Bildschirme in 3D', (tester) async {
    addTearDown(tester.view.reset);
    await shot(tester, 'screen_map', '/map');
    await shot(tester, 'screen_editor', '/map/editor');
    await shot(
      tester,
      'screen_editor_furniture',
      '/map/editor?mode=furniture&sel=salon',
    );
    await shot(
      tester,
      'screen_network',
      '/map',
      prefs: {'map_layer': 'network'},
    );
  });
}
