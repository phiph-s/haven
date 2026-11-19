// Startseite mit Raumbildern: rendert die Lichtebenen des Beispiel-
// Grundrisses in die Entwicklungsdaten (wie nach einer Kartenänderung) und
// zeigt Zuhause hell und dunkel nach build/gpu/home_render_*.png.
//   flutter test --enable-flutter-gpu --enable-impeller test_gpu/home_render_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/map/map_render.dart';
import 'package:haven_3d/haven_3d.dart' show Scene3DSupport;
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Scene3DSupport.debugOverride = true;
  testWidgets('Zuhause mit Raumbildern', (tester) async {
    addTearDown(tester.view.reset);
    late FakeRepository repo;
    await tester.runAsync(() async {
      repo = FakeRepository(simulate: false);
      await repo.start();
      await MapRenderJob(repo, kFakeFloorPlan).run((_) {});
    });
    for (final mode in ['dark', 'light']) {
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({'theme_mode': mode});
      final store = SettingsStore(await SharedPreferences.getInstance());
      tester.view.physicalSize = const Size(412, 915) * 2;
      tester.view.devicePixelRatio = 2;
      final container = ProviderContainer(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
          initialSessionProvider.overrideWithValue(
            Session(SessionMode.fake, repo),
          ),
        ],
      );
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: UncontrolledProviderScope(
            container: container,
            child: const HavenApp(initialLocation: '/home'),
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
        final b =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final img = await b.toImage(pixelRatio: 2);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('build/gpu/home_render_$mode.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(png!.buffer.asUint8List());
      });
      if (mode == 'dark') {
        // Übergang in die Raumseite: Bildfolge über die Dauer des Flugs.
        final ctx = key.currentContext!;
        await tester.tap(find.bySemanticsLabel('Salon öffnen').first);
        for (final ms in [0, 120, 240, 420]) {
          await tester.pump(Duration(milliseconds: ms == 0 ? 16 : 120));
          await tester.runAsync(() async {
            final b = ctx.findRenderObject() as RenderRepaintBoundary;
            final img = await b.toImage(pixelRatio: 1);
            final png = await img.toByteData(format: ui.ImageByteFormat.png);
            File(
              'build/gpu/home_flight_$ms.png',
            ).writeAsBytesSync(png!.buffer.asUint8List());
          });
        }
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
        await tester.runAsync(() async {
          final b = ctx.findRenderObject() as RenderRepaintBoundary;
          final img = await b.toImage(pixelRatio: 1);
          final png = await img.toByteData(format: ui.ImageByteFormat.png);
          File(
            'build/gpu/home_flight_end.png',
          ).writeAsBytesSync(png!.buffer.asUint8List());
        });
      }
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(seconds: 3));
      }
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
