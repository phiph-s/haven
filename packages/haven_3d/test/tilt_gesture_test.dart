import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';

// Zwei Finger senkrecht kippen aus der Draufsicht in die Schrägansicht
// (wie in Karten-Apps); auseinander bleibt Zoomen.
void main() {
  Future<(SceneController, List<double>)> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = SceneController(const OrbitCamera(pitch: 0));
    final tilts = <double>[];
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Scene3DView(
          scene: sampleScene(),
          controller: c,
          style: SceneStyle.light(),
          gestures: SceneGestures.map,
          fitOnStart: false,
          onTiltGesture: tilts.add,
        ),
      ),
    );
    await tester.pump();
    return (c, tilts);
  }

  testWidgets('Zwei Finger nach oben kippen die Kamera', (tester) async {
    final (c, tilts) = await pump(tester);
    final a = await tester.startGesture(const Offset(150, 400), pointer: 1);
    final b = await tester.startGesture(const Offset(250, 400), pointer: 2);
    for (var i = 0; i < 10; i++) {
      await a.moveBy(const Offset(0, -12));
      await b.moveBy(const Offset(0, -12));
      await tester.pump();
    }
    await a.up();
    await b.up();
    expect(c.camera.pitch, greaterThan(0.3));
    expect(tilts, isNotEmpty);
  });

  testWidgets('Zwei Finger auseinander zoomen, ohne zu kippen', (tester) async {
    final (c, tilts) = await pump(tester);
    final scale0 = c.camera.scale;
    final a = await tester.startGesture(const Offset(150, 400), pointer: 1);
    final b = await tester.startGesture(const Offset(250, 400), pointer: 2);
    for (var i = 0; i < 10; i++) {
      await a.moveBy(const Offset(-8, 0));
      await b.moveBy(const Offset(8, 0));
      await tester.pump();
    }
    await a.up();
    await b.up();
    expect(c.camera.pitch, 0);
    expect(c.camera.scale, greaterThan(scale0));
    expect(tilts, isEmpty);
  });
}
