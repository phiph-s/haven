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
  // (Himmel, Lampen an, dunkles Design)
  final cases = {
    'nachmittag': (SceneSky.at(dayOfYear: 300, hour: 15.5), false, false),
    'morgen': (SceneSky.at(dayOfYear: 172, hour: 8), false, false),
    'vollmond': (
      SceneSky.at(dayOfYear: 355, hour: 0, moonPhase: 0.5),
      false,
      false,
    ),
    'bedeckt': (SceneSky.at(dayOfYear: 300, hour: 13, cloud: 1), false, false),
    'nacht_lampen': (
      SceneSky.at(dayOfYear: 355, hour: 22, moonPhase: 0.1),
      true,
      false,
    ),
    'dunkel_abend': (SceneSky.at(dayOfYear: 300, hour: 17), true, true),
    'wolkig': (SceneSky.at(dayOfYear: 172, hour: 10, cloud: 0.5), false, false),
    'regen': (
      SceneSky.at(dayOfYear: 300, hour: 11, cloud: 0.6, rain: 0.8),
      false,
      false,
    ),
    'schnee': (
      SceneSky.at(dayOfYear: 20, hour: 13, cloud: 0.7, snow: 0.7),
      false,
      false,
    ),
    'schneedecke': (SceneSky.at(dayOfYear: 30, hour: 12), false, false),
    'gewitter': (SceneSky.at(dayOfYear: 200, hour: 17, storm: 1), false, true),
    'regen_nacht': (
      SceneSky.at(dayOfYear: 300, hour: 21, rain: 0.6),
      true,
      false,
    ),
    'dunkel_mittag': (SceneSky.at(dayOfYear: 172, hour: 13), false, true),
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
      final dark = e.value.$3;
      final fog = e.value.$1.cover;
      c.setGround(
        SceneGround(
          color: const Color(0x00FFFFFF),
          margin: 6 + 3 * fog,
          fade: 3 + 2.5 * fog,
          snow: const {'schnee': 0.45, 'schneedecke': 1.0}[e.key] ?? 0,
        ),
      );
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
            // Hell und dunkel: nur der Verlauf (unten weiß bzw. schwarz).
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color.lerp(
                      const Color(0xFF0B1020),
                      const Color(0xFF8DB7E8),
                      ((e.value.$1.sunElevation + 8) / 20).clamp(0.0, 1.0),
                    )!,
                    if (dark)
                      const Color(0xFF07080B)
                    else
                      const Color(0xFFF4F3F0),
                  ],
                ),
              ),
              child: SkyLayers(
                sky: e.value.$1,
                controller: c,
                center: const V3(4.25, 5.25, 0),
                extent: const Rect.fromLTWH(0, 0, 8.5, 10.5),
                child: Scene3DView(
                  scene: scene,
                  controller: c,
                  quality: SceneQuality.medium,
                  style: SceneStyle.light(),
                ),
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
