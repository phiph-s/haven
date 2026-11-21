// Ruhe der 3D-Karte: steht das Bild, rendert die Szene nicht weiter (keine
// Bilder je Sekunde ohne Bewegung); eine Kamerabewegung weckt sie wieder.
//   flutter test --enable-flutter-gpu --enable-impeller test_gpu/idle_render_test.dart
import 'package:flutter/widgets.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_scene/scene.dart' as fs;
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/features/map/map_3d.dart';
import 'package:haven_3d/haven_3d.dart';

void main() {
  Scene3DSupport.debugOverride = true;
  testWidgets('Karte rendert nur bei Bewegung', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(430, 800) * 2;
    tester.view.devicePixelRatio = 2;
    final ctrl = SceneController(const OrbitCamera());
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Scene3DView(
          scene: sceneOfPlan(kFakeFloorPlan),
          controller: ctrl,
          style: SceneStyle.dark(),
        ),
      ),
    );
    // Aufbau, Baking und Einblenden abwarten.
    Future<void> run(int frames) async {
      for (var i = 0; i < frames; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    await run(200);
    int count() => tester
        .widget<fs.SceneView>(find.byType(fs.SceneView))
        .scene!
        .renderStats
        .frameCount;
    expect(count(), greaterThan(0));
    // Zwei Sekunden Ruhe: kein neues Bild.
    await run(60);
    final idle = count();
    await run(125);
    // ignore: avoid_print
    print('IDLE Bilder in 2 s Ruhe: ${count() - idle}');
    expect(count() - idle, lessThanOrEqualTo(1));
    // Bewegung weckt die Ansicht.
    final before = count();
    ctrl.camera = ctrl.camera.copyWith(yaw: 0.3);
    await run(10);
    expect(count(), greaterThan(before));
    // … und danach ist wieder Ruhe.
    await run(120);
    final after = count();
    await run(60);
    expect(count() - after, lessThanOrEqualTo(1));
    await tester.pumpWidget(const SizedBox());
    await run(5);
  });
}
