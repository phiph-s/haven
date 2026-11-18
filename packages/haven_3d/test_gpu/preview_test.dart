// GPU-Vorschau je Möbelstück: Draufsicht, schräg von vorn links, schräg von
// hinten rechts, Seitenansicht nebeneinander in build/preview/<kind>.png.
//
//   flutter test --enable-flutter-gpu --enable-impeller \
//     test_gpu/preview_test.dart --plain-name sofa
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';

/// Standardmaße in Metern wie im App-Katalog (Zellen × 0,5 m).
const Map<String, (double, double)> kPreviewSizes = {
  'bed_double': (1.8, 2.1),
  'bed_single': (1.0, 2.1),
  'nightstand': (0.5, 0.45),
  'wardrobe': (2.0, 0.6),
  'sofa': (2.2, 0.9),
  'sofa_corner': (2.5, 2.0),
  'armchair': (0.9, 0.9),
  'coffee_table': (1.2, 0.6),
  'tv_board': (1.8, 0.45),
  'rug': (2.0, 1.5),
  'plant': (0.5, 0.5),
  'shelf': (1.0, 0.4),
  'dining_table': (1.8, 1.5),
  'kitchen_counter': (3.0, 0.6),
  'stove': (0.6, 0.6),
  'sink': (0.8, 0.6),
  'fridge': (0.6, 0.65),
  'bathtub': (1.7, 0.8),
  'shower': (0.9, 0.9),
  'toilet': (0.4, 0.7),
  'washbasin': (0.6, 0.5),
  'desk': (1.5, 0.7),
  'office_chair': (0.6, 0.6),
  'door': (0.9, 0.9),
  'window': (1.2, 0.2),
};

Future<void> preview(WidgetTester tester, String kind) async {
  final (w, d) = kPreviewSizes[kind]!;
  const cell = Size(340, 300);
  final views = [
    (yaw: 0.0, pitch: 0.0),
    (yaw: -math.pi / 6, pitch: 1.0),
    (yaw: math.pi * 5 / 6, pitch: 1.0),
    (yaw: 0.0, pitch: math.pi / 2),
  ];
  // Ein kleiner Raum als Boden, damit Licht und Schatten etwas zeigen.
  final m = math.max(w, d) / 2 + 0.6;
  final scene = Scene(
    rooms: [
      SceneRoom(
        id: 'r',
        outline: [Offset(-m, -m), Offset(m, -m), Offset(m, m), Offset(-m, m)],
        wallHeight: 0.01,
      ),
    ],
    objects: [
      SceneObject.furniture(
        id: kind,
        kind: kind,
        center: Offset.zero,
        w: w,
        d: d,
      ),
    ],
  );
  final spec = furnitureSpec(kind);
  final box = [
    for (final x in [-w / 2, w / 2])
      for (final y in [-d / 2, d / 2])
        for (final z in [spec.elevation, spec.elevation + spec.height])
          V3(x, y, z),
  ];
  tester.view.physicalSize = Size(cell.width * views.length, cell.height) * 2;
  tester.view.devicePixelRatio = 2;
  final key = GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: key,
        child: ColoredBox(
          color: const Color(0xFFF1EFEB),
          child: Row(
            children: [
              for (final v in views)
                SizedBox.fromSize(
                  size: cell,
                  child: Scene3DView(
                    scene: scene,
                    controller: SceneController(
                      OrbitCamera(
                        yaw: v.yaw,
                        pitch: v.pitch,
                      ).fit(box, cell, padding: 30),
                    ),
                    style: SceneStyle.light().copyWith(cutaway: false),
                    fitOnStart: false,
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.runAsync(() async {
    final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final img = await b.toImage(pixelRatio: 2);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    File('build/preview/$kind.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
  await tester.pumpWidget(const SizedBox());
  // flutter_scene startet im Hintergrund noch Timer (Umgebungslicht).
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(seconds: 3));
  }
}

void main() {
  // Echte GPU (flutter test --enable-flutter-gpu), nicht ohne Bild.
  Scene3DSupport.debugOverride = true;
  for (final kind in kPreviewSizes.keys) {
    testWidgets(kind, (tester) async {
      addTearDown(tester.view.reset);
      await preview(tester, kind);
    });
  }
}
