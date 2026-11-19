// GPU-Render des Himmels (Tag, Nacht, Wolken, Lampen) nach build/gpu/sky_*.png.
// Je Fall einzeln aufrufen (der Testlauf zeichnet nur den ersten Fall):
//
//   flutter test --enable-flutter-gpu --enable-impeller \
//     test_gpu/sky_render_test.dart --plain-name nachmittag
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';

void main() {
  Scene3DSupport.debugOverride = true;
  final cases = {
    'nachmittag': (SceneSky.at(dayOfYear: 300, hour: 15.5), false),
    'morgen': (SceneSky.at(dayOfYear: 172, hour: 8), false),
    'vollmond': (SceneSky.at(dayOfYear: 355, hour: 0, moonPhase: 0.5), false),
    'bedeckt': (SceneSky.at(dayOfYear: 300, hour: 13, cloud: 1), false),
    'nacht_lampen': (
      SceneSky.at(dayOfYear: 355, hour: 22, moonPhase: 0.1),
      true,
    ),
  };
  for (final e in cases.entries) {
    testWidgets(e.key, (tester) async {
      addTearDown(tester.view.reset);
      final scene = sampleScene();
      const size = Size(900, 650);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final key = GlobalKey();
      final c = SceneController(const OrbitCamera(yaw: -0.5, pitch: 0.95));
      c.setSky(e.value.$1);
      for (final m in scene.markers) {
        if (m.lamp != null) {
          c.setLamp(
            m.id,
            e.value.$2
                ? const LampState(brightness: 0.8, color: Color(0xFFFFC489))
                : LampState.off,
          );
        }
      }
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: const Color(0xFF6E7F99),
              child: Scene3DView(
                scene: scene,
                controller: c,
                quality: SceneQuality.medium,
                style: SceneStyle.light(),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 60; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.runAsync(() async {
        final b =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final img = await b.toImage(pixelRatio: 1);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('build/gpu/sky_${e.key}.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(png!.buffer.asUint8List());
      });
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(seconds: 3));
      }
    });
  }
}
