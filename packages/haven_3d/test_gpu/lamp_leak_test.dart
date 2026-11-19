// Lampenlicht darf nicht durch Wände auf Wände und Möbel eines Raums fallen,
// den nur eine Tür verbindet oder der gar nicht angrenzt.
//   flutter test --enable-flutter-gpu --enable-impeller test_gpu/lamp_leak_test.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';

void main() {
  Scene3DSupport.debugOverride = true;
  // Ohne Himmel, schräg: Räume, die nur eine Tür verbindet, bekommen kein
  // Echtzeitlicht der Lampe nebenan auf Wände und Möbel.
  testWidgets('kein Lampenlicht auf Möbeln hinter der Wand', (tester) async {
    addTearDown(tester.view.reset);
    const size = Size(900, 700);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    // Tischlampe im Wohnzimmer dicht an der Wand zum Flur (nur eine Tür
    // verbindet die beiden): ihr Licht strahlt rundum.
    final base = sampleScene();
    final scene = Scene(
      rooms: base.rooms,
      objects: base.objects,
      markers: [
        ...base.markers,
        SceneMarker(
          id: 'lampe_wand',
          at: const Offset(1.2, 4.2),
          kind: MarkerKind.light,
          model: 'table_lamp',
          height: 0.4,
          lamp: LampState.off,
        ),
      ],
    );
    final key = GlobalKey();
    final ctrl = SceneController(const OrbitCamera(yaw: -0.5, pitch: 0.95));
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
            style: SceneStyle.dark(),
          ),
        ),
      ),
    );
    Future<Uint8List> grab(String name) async {
      for (var i = 0; i < 50; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      late Uint8List px;
      await tester.runAsync(() async {
        final b =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final img = await b.toImage();
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('build/gpu/leak_moebel_$name.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(png!.buffer.asUint8List());
        px = (await img.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        ))!.buffer.asUint8List();
      });
      return px;
    }

    // Mittlere Helligkeit um einen Punkt (Welt, halbe Höhe).
    double around(Uint8List px, Offset c, {double z = 0.5, int r = 30}) {
      final p = ctrl.camera.project(V3(c.dx, c.dy, z), size);
      var sum = 0.0, n = 0;
      for (var y = p.y.round() - r; y <= p.y.round() + r; y++) {
        for (var x = p.x.round() - r; x <= p.x.round() + r; x++) {
          final i = (y * size.width.round() + x) * 4;
          sum += px[i] + px[i + 1] + px[i + 2];
          n += 3;
        }
      }
      return sum / n;
    }

    final off = await grab('aus');
    ctrl.setLamp('lampe_wand', const LampState());
    final on = await grab('wohnen');
    // Rückwand des Wohnzimmers; Wand zwischen Schlafen und Arbeiten (über
    // den Flur nur per Tür verbunden).
    const here = Offset(2.5, 0.05), behind = Offset(2.95, 7.5);
    final own =
        around(on, here, z: 1.2, r: 10) - around(off, here, z: 1.2, r: 10);
    final flur =
        around(on, behind, z: 1.2, r: 10) - around(off, behind, z: 1.2, r: 10);
    // ignore: avoid_print
    print('Wohnen +$own, Flur +$flur');
    expect(own, greaterThan(10));
    expect(flur, lessThan(1.5));

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
