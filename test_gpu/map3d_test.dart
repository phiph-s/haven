// Rendert den Beispielgrundriss über den Adapter der App mit flutter_scene
// nach build/gpu/ (Prüfung von Maßstab, Drehung, Möbeln, Licht, Labels).
//   flutter test --enable-flutter-gpu --enable-impeller test_gpu/map3d_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/features/map/map_3d.dart';
import 'package:haven_3d/haven_3d.dart';

Future<void> shot(
  WidgetTester tester,
  String name, {
  required bool dark,
  required OrbitCamera cam,
  Set<String>? raised,
  String? selected,
  SceneHeatmap? heatmap,
  Map<String, LampState> lamps = const {},
}) async {
  const size = Size(430, 800);
  const dpr = 2.0;
  tester.view.physicalSize = size * dpr;
  tester.view.devicePixelRatio = dpr;
  final plan = kFakeFloorPlan;
  final scene = sceneOfPlan(plan);
  final m = plan.grid.cellMeters;
  final key = GlobalKey();
  final ctrl = SceneController(cam);
  for (final e in lamps.entries) {
    ctrl.setLamp(e.key, e.value);
  }
  final ink = dark ? const Color(0xFFE6E8EB) : const Color(0xFF1B1D21);
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: key,
        child: ColoredBox(
          color: dark ? const Color(0xFF111316) : const Color(0xFFF2F1EE),
          child: Scene3DView(
            scene: scene,
            controller: ctrl,
            style: dark ? SceneStyle.dark() : SceneStyle.light(),
            raisedRooms: raised,
            selectedRoomId: selected,
            heatmap: heatmap,
            insets: const EdgeInsets.fromLTRB(8, 110, 8, 200),
            markers: [
              for (final p in plan.placements)
                SceneMarker(
                  id: p.entityId,
                  at: p.center * m,
                  kind: markerKindOf(p.resolvedKind),
                ),
            ],
            roomLabelBuilder: (context, room, cam) => Text(
              plan.room(room.id)?.name ?? room.id,
              style: TextStyle(
                color: ink,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.runAsync(() async {
    final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final img = await b.toImage(pixelRatio: dpr);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    File('build/gpu/$name.png')
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
}

void main() {
  // Echte GPU (flutter test --enable-flutter-gpu), nicht ohne Bild.
  Scene3DSupport.debugOverride = true;
  testWidgets('3D-Karte der App', (tester) async {
    addTearDown(tester.view.reset);
    final lamps = {
      for (final p in kFakeFloorPlan.placements)
        if (p.resolvedKind == FloorKind.light)
          p.entityId: p.entityId.hashCode.isEven
              ? const LampState(color: Color(0xFFFFC98A))
              : LampState.off,
    };
    await shot(
      tester,
      'app_top_dark',
      dark: true,
      cam: const OrbitCamera(),
      raised: const {},
      lamps: lamps,
    );
    await shot(
      tester,
      'app_top_light',
      dark: false,
      cam: const OrbitCamera(),
      raised: const {},
      lamps: lamps,
    );
    await shot(
      tester,
      'app_tilt_dark',
      dark: true,
      cam: const OrbitCamera(yaw: kMapTiltYaw, pitch: kMapTiltPitch),
      lamps: lamps,
    );
    await shot(
      tester,
      'app_focus_salon',
      dark: true,
      cam: const OrbitCamera(yaw: kMapFocusYaw, pitch: kMapFocusPitch),
      raised: const {'salon'},
      selected: 'salon',
      lamps: lamps,
    );
  });
}
