// Nahaufnahmen mit Farbzonen: oben Standardfarben, unten eigene Farben, je
// Draufsicht, schräg von vorn links und von hinten rechts. Bilder nach
// build/preview/colors_<name>.png (oder HAVEN_COLORS_OUT).
//
//   flutter test --enable-flutter-gpu --enable-impeller \
//     test_gpu/colors_preview_test.dart --plain-name tv
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';

const _oak = Color(0xFFC49A6C);
const _walnut = Color(0xFF7B5B45);
const _terracotta = Color(0xFFB86B4F);
const _anthracite = Color(0xFF3B3F45);
const _petrol = Color(0xFF3F6B70);
const _sage = Color(0xFF93A68A);
const _chalk = Color(0xFFF2EFE8);
const _smoke = Color(0xFF61758A);

typedef _Case = ({
  double room,
  double wall,
  List<SceneObject> Function(bool colored) objects,
  List<SceneMarker> Function(bool colored) markers,
});

SceneObject _f(
  String kind,
  double w,
  double d, {
  Offset at = Offset.zero,
  double rot = 0,
  Map<String, Color> colors = const {},
}) => SceneObject.furniture(
  id: '$kind${at.dx}${at.dy}',
  kind: kind,
  center: at,
  w: w,
  d: d,
  rotation: rot,
  colors: colors,
  roomId: 'r',
);

final Map<String, _Case> _cases = {
  // Fernseher auf dem Sideboard und einer an der Wand darüber.
  'tv': (
    room: 1.6,
    wall: 2.2,
    objects: (c) => [
      _f(
        'sideboard',
        1.8,
        0.45,
        at: const Offset(0, -1.3),
        colors: c
            ? const {'body': _walnut, 'fronts': _oak, 'handles': _anthracite}
            : const {},
      ),
    ],
    markers: (c) => [
      SceneMarker(
        id: 'tv_stand',
        model: 'tv',
        mount: DeviceMount.stand,
        at: const Offset(-0.45, -1.3),
        height: 0.55,
        roomId: 'r',
        size: 43,
        colors: c ? const {'housing': _chalk} : const {},
      ),
      SceneMarker(
        id: 'tv_wall',
        model: 'tv',
        mount: DeviceMount.wall,
        at: const Offset(0.45, -1.55),
        height: 1.15,
        roomId: 'r',
        size: 32,
        colors: c ? const {'housing': _smoke} : const {},
      ),
    ],
  ),
  'plant': (
    room: 0.9,
    wall: 0.01,
    objects: (c) => [
      _f('plant', 0.5, 0.5, colors: c ? const {'pot': _terracotta} : const {}),
    ],
    markers: (_) => const [],
  ),
  'toilet': (
    room: 0.8,
    wall: 1.2,
    objects: (c) => [
      _f(
        'toilet',
        0.4,
        0.7,
        at: const Offset(0, -0.45),
        colors: c ? const {'seat': _anthracite} : const {},
      ),
    ],
    markers: (_) => const [],
  ),
  'washbasin': (
    room: 0.8,
    wall: 1.3,
    objects: (c) => [
      _f(
        'washbasin',
        0.6,
        0.5,
        at: const Offset(0, -0.55),
        colors: c ? const {'ceramic': _sage} : const {},
      ),
    ],
    markers: (_) => const [],
  ),
  'sink': (
    room: 1.0,
    wall: 1.3,
    objects: (c) => [
      _f(
        'sink',
        0.8,
        0.6,
        at: const Offset(-0.2, -0.7),
        colors: c ? const {'fronts': _petrol, 'worktop': _oak} : const {},
      ),
      _f(
        'stove',
        0.6,
        0.6,
        at: const Offset(0.5, -0.7),
        colors: c ? const {'fronts': _petrol, 'worktop': _oak} : const {},
      ),
    ],
    markers: (_) => const [],
  ),
  'sideboard': (
    room: 1.3,
    wall: 0.01,
    objects: (c) => [
      _f(
        'sideboard',
        1.8,
        0.45,
        colors: c
            ? const {'body': _anthracite, 'fronts': _sage, 'handles': _oak}
            : const {},
      ),
    ],
    markers: (_) => const [],
  ),
  'sofa': (
    room: 1.5,
    wall: 0.01,
    objects: (c) => [
      _f(
        'sofa',
        2.2,
        0.9,
        colors: c
            ? const {'frame': _smoke, 'cushions': Color(0xFFD4C8B4)}
            : const {},
      ),
    ],
    markers: (_) => const [],
  ),
  'bed': (
    room: 1.5,
    wall: 0.01,
    objects: (c) => [
      _f(
        'bed_double',
        1.8,
        2.1,
        colors: c ? const {'frame': _oak, 'bedding': _sage} : const {},
      ),
    ],
    markers: (_) => const [],
  ),
};

String get _out => Platform.environment['HAVEN_COLORS_OUT'] ?? 'build/preview';

Future<void> shot(WidgetTester tester, String name) async {
  final c = _cases[name]!;
  const cell = Size(340, 300);
  final views = [
    (yaw: 0.0, pitch: 0.0),
    (yaw: -math.pi / 6, pitch: 1.0),
    (yaw: math.pi * 5 / 6, pitch: 1.0),
  ];
  final m = c.room;
  Scene scene(bool colored) => Scene(
    rooms: [
      SceneRoom(
        id: 'r',
        outline: [Offset(-m, -m), Offset(m, -m), Offset(m, m), Offset(-m, m)],
        wallHeight: c.wall,
      ),
    ],
    objects: c.objects(colored),
    markers: c.markers(colored),
  );
  // Kamera auf die Möbel und Geräte (mit etwas Rand), nicht den Raum.
  final sc = scene(false);
  final box = [
    for (final o in sc.objects) ...o.world.points,
    for (final mk in sc.markers) ...[
      for (final dx in [-0.6, 0.6])
        for (final dz in [0.0, 0.75]) mk.position + V3(dx, 0, dz),
    ],
  ];
  tester.view.physicalSize = Size(cell.width * views.length, cell.height * 2);
  tester.view.devicePixelRatio = 1;
  final key = GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: key,
        child: ColoredBox(
          color: const Color(0xFFF1EFEB),
          child: Column(
            children: [
              for (final colored in [false, true])
                Row(
                  children: [
                    for (final v in views)
                      SizedBox.fromSize(
                        size: cell,
                        child: Scene3DView(
                          scene: scene(colored),
                          markers: const [],
                          controller: SceneController(
                            OrbitCamera(
                              yaw: v.yaw,
                              pitch: v.pitch,
                            ).fit(box, cell, padding: 34),
                          ),
                          style: SceneStyle.light(),
                          fitOnStart: false,
                        ),
                      ),
                  ],
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
    final img = await b.toImage(pixelRatio: 1);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    File('$_out/closeup_$name.png')
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
  Scene3DSupport.debugOverride = true;
  testWidgets('alle Nahaufnahmen', (tester) async {
    addTearDown(tester.view.reset);
    for (final name in _cases.keys) {
      await shot(tester, name);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
