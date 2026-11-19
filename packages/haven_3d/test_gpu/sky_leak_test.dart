// Mit Himmel (Live-Wetter) darf Lampenlicht nicht durch Wände auf die Böden
// der Nachbarräume fallen.
//   flutter test --enable-flutter-gpu --enable-impeller test_gpu/sky_leak_test.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';

void main() {
  Scene3DSupport.debugOverride = true;
  testWidgets('kein Lampenlicht im Nachbarraum', (tester) async {
    addTearDown(tester.view.reset);
    const size = Size(900, 700);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    final scene = sampleScene();
    final key = GlobalKey();
    final ctrl = SceneController(const OrbitCamera())
      // Nacht, kein Mond: nur die Lampen leuchten.
      ..setSky(const SceneSky(sunAzimuth: 0, sunElevation: -30));
    for (final m in scene.markers) {
      if (m.lamp != null) ctrl.setLamp(m.id, LampState.off);
    }
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: key,
          child: Scene3DView(
            scene: scene,
            controller: ctrl,
            style: SceneStyle.light(),
            raisedRooms: const {},
          ),
        ),
      ),
    );
    Future<(Uint8List, int)> grab(String name) async {
      for (var i = 0; i < 50; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      late Uint8List px;
      late int w;
      await tester.runAsync(() async {
        final b =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final img = await b.toImage();
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('build/gpu/leak_$name.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(png!.buffer.asUint8List());
        px = (await img.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        ))!.buffer.asUint8List();
        w = img.width;
      });
      return (px, w);
    }

    // Mittlere Helligkeit um die Mitte eines Raums.
    double around(Uint8List px, int w, String room) {
      final c = scene.room(room)!.centroid;
      final p = ctrl.camera.project(V3(c.dx, c.dy, 0), size);
      var sum = 0.0, n = 0;
      for (var y = p.y.round() - 12; y <= p.y.round() + 12; y++) {
        for (var x = p.x.round() - 12; x <= p.x.round() + 12; x++) {
          final i = (y * w + x) * 4;
          sum += px[i] + px[i + 1] + px[i + 2];
          n += 3;
        }
      }
      return sum / n;
    }

    final (off, w) = await grab('aus');
    ctrl.setLamp('licht_kueche', const LampState());
    final (on, _) = await grab('kueche');
    final own = around(on, w, 'kueche') - around(off, w, 'kueche');
    final bad = around(on, w, 'bad') - around(off, w, 'bad');
    final wohnen = around(on, w, 'wohnen') - around(off, w, 'wohnen');
    // ignore: avoid_print
    print('Küche +$own, Bad +$bad, Wohnen +$wohnen');
    expect(own, greaterThan(10));
    expect(bad, lessThan(1.5));
    expect(wohnen, lessThan(1.5));

    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(seconds: 3));
    }
  });
}
