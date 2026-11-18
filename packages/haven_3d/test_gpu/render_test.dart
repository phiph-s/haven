// Rendert die Beispielwohnung mit flutter_scene ohne Fenster nach build/gpu/.
//   flutter test --enable-flutter-gpu --enable-impeller test_gpu/render_test.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';

Future<void> shot(
  WidgetTester tester,
  String name,
  OrbitCamera cam, {
  bool dark = false,
  String? room,
  Size size = const Size(900, 700),
  double dpr = 2,
  bool fit = true,
  Set<String>? raised,
  Scene? scene,
  SceneQuality quality = SceneQuality.high,
  SceneHeatmap? heatmap,
  String? selectedRoom,
  Future<void> Function(SceneController c, Size size)? then,
}) async {
  tester.view.physicalSize = size * dpr;
  tester.view.devicePixelRatio = dpr;
  final key = GlobalKey();
  final style = dark ? SceneStyle.dark() : SceneStyle.light();
  final bg = dark
      ? const [Color(0xFF2A2117), Color(0xFF15171B), Color(0xFF101114)]
      : const [Color(0xFFF3EEE6), Color(0xFFF1F1EF), Color(0xFFE4E7EA)];
  final ctrl = SceneController(cam);
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: key,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: bg,
            ),
          ),
          child: Scene3DView(
            key: ValueKey(name),
            scene: scene ?? sampleScene(),
            controller: ctrl,
            fitOnStart: fit,
            raisedRooms: raised,
            quality: quality,
            heatmap: heatmap,
            selectedRoomId: selectedRoom,
            style: style,
            focusRoomId: room,
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
  if (then != null) {
    unawaited(then(ctrl, size));
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
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
  testWidgets('gpu render', (tester) async {
    addTearDown(tester.view.reset);
    final views = {
      'iso': const OrbitCamera(yaw: -0.5, pitch: 0.95),
      'top': const OrbitCamera(),
    };
    // Herausgezoomt und verschoben: Marker müssen auf der Szene bleiben.
    await shot(
      tester,
      'zoom_pan',
      const OrbitCamera(
        target: V3(4.25, 5.25, 1.25),
        yaw: 0.6,
        pitch: 0.9,
        scale: 18,
        pan: Offset(230, -120),
      ),
      fit: false,
      dpr: 1,
    );
    for (final e in views.entries) {
      await shot(tester, e.key, e.value);
    }
    await shot(
      tester,
      'iso_dark',
      const OrbitCamera(yaw: -0.5, pitch: 0.95),
      dark: true,
    );
    await shot(
      tester,
      'wohnen',
      const OrbitCamera(yaw: 0.35, pitch: 1.2),
      room: 'wohnen',
    );
    await shot(
      tester,
      'bad_dark',
      const OrbitCamera(yaw: -2.4, pitch: 0.9),
      room: 'bad',
      dark: true,
    );
    await shot(
      tester,
      'schlafen',
      const OrbitCamera(yaw: 2.6, pitch: 1.0),
      room: 'schlafen',
    );
    await shot(
      tester,
      'raised_wohnen',
      const OrbitCamera(yaw: -0.5, pitch: 0.95),
      raised: {'wohnen'},
    );
    await shot(
      tester,
      'raised_arbeiten_dark',
      const OrbitCamera(yaw: -0.5, pitch: 0.95),
      raised: {'arbeiten'},
      dark: true,
    );
    await shot(tester, 'flat_top', const OrbitCamera(), raised: {});
    final s0 = sampleScene();
    Map<String, List<HeatPoint>> heat(Map<String, List<double>> v) => {
      for (final e in v.entries)
        e.key: [
          for (var i = 0; i < e.value.length; i++)
            HeatPoint(
              s0.room(e.key)!.centroid +
                  Offset(i == 0 ? -0.9 : 0.9, i == 0 ? -0.6 : 0.6) *
                      (e.value.length == 1 ? 0 : 1),
              e.value[i],
            ),
        ],
    };
    final temps = SceneHeatmap.fitted(
      heat(const {
        'wohnen': [21.6, 20.9],
        'kueche': [22.8, 21.1],
        'bad': [23.4],
        'flur': [19.6],
        'schlafen': [18.4, 18.9],
        'arbeiten': [21.0, 20.1],
      }),
      ramp: HeatRamps.temperature,
    );
    await shot(
      tester,
      'heat_top_dark',
      const OrbitCamera(),
      raised: {},
      dark: true,
      heatmap: temps,
      selectedRoom: 'kueche',
    );
    await shot(
      tester,
      'heat_iso_dark',
      const OrbitCamera(yaw: -0.5, pitch: 0.95),
      dark: true,
      heatmap: temps,
    );
    await shot(
      tester,
      'focus_device',
      const OrbitCamera(),
      raised: {'kueche'},
      dark: true,
      selectedRoom: 'kueche',
      then: (c, size) => c.focus(
        markerId: 'licht_kueche',
        pitch: 0.9,
        insets: EdgeInsets.only(bottom: size.height * 2 / 3),
        duration: const Duration(milliseconds: 200),
      ),
    );
    await shot(
      tester,
      'flat_top_dark',
      const OrbitCamera(),
      raised: {},
      dark: true,
    );
    // Flur nah (Schattenartefakte auf dem Boden prüfen).
    await shot(
      tester,
      'flur_close',
      const OrbitCamera(
        target: V3(2.5, 5.5, 0),
        yaw: -0.3,
        pitch: 0.8,
        scale: 160,
        fov: OrbitCamera.perspectiveFov,
      ),
      fit: false,
    );
    await shot(
      tester,
      'flur_door_closed',
      const OrbitCamera(
        target: V3(2.5, 5.5, 0),
        yaw: -0.3,
        pitch: 0.8,
        scale: 160,
        fov: OrbitCamera.perspectiveFov,
      ),
      fit: false,
      then: (c, size) async {
        c.setObjectOpen('door_8', false);
        c.setObjectOpen('door_20', false);
      },
    );
    await shot(
      tester,
      'perspective',
      const OrbitCamera(
        yaw: -0.5,
        pitch: 0.95,
        fov: OrbitCamera.perspectiveFov,
      ),
      raised: {'wohnen', 'arbeiten'},
      dark: true,
    );
    await shot(
      tester,
      'quality_low',
      const OrbitCamera(yaw: -0.5, pitch: 0.95),
      raised: {'arbeiten'},
      dark: true,
      quality: SceneQuality.low,
    );
    // Lampe im Wohnzimmer an/aus: Schatten vergleichen.
    final base = sampleScene();
    final off = Scene(
      rooms: base.rooms,
      objects: base.objects,
      markers: [
        for (final m in base.markers)
          m.id == 'licht_wohnen'
              ? SceneMarker(
                  id: m.id,
                  at: m.position.xy,
                  kind: m.kind,
                  height: m.position.z,
                  lamp: LampState.off,
                )
              : m,
      ],
    );
    for (final (name, sc) in [('five_on', base), ('wohnen_off', off)]) {
      await shot(
        tester,
        name,
        const OrbitCamera(yaw: -0.5, pitch: 0.95),
        raised: {'arbeiten'},
        dark: true,
        scene: sc,
      );
    }
    for (final (name, sc) in [('lamp_on', base), ('lamp_off', off)]) {
      await shot(
        tester,
        name,
        const OrbitCamera(yaw: 0.35, pitch: 1.0),
        room: 'wohnen',
        scene: sc,
      );
    }
    for (final dark in [true, false]) {
      await shot(
        tester,
        dark ? 'arbeiten_dark' : 'arbeiten',
        const OrbitCamera(yaw: -0.6, pitch: 0.95),
        room: 'arbeiten',
        dark: dark,
      );
    }
  });
}
