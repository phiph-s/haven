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
const _linen = Color(0xFFD4C8B4);
const _mustard = Color(0xFFC9A04A);
const _rose = Color(0xFFC79A96);
const _navy = Color(0xFF2F3E56);
const _olive = Color(0xFF6F7A4E);

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
  'kitchen': (
    room: 1.7,
    wall: 2.3,
    objects: (c) {
      final base = c
          ? const {'fronts': _petrol, 'worktop': _oak, 'handles': _chalk}
          : const <String, Color>{};
      final upper = c
          ? const {'fronts': _sage, 'handles': _anthracite}
          : const <String, Color>{};
      const y = -1.7 + 0.3;
      return [
        _f('dishwasher', 0.6, 0.6, at: const Offset(-1.2, y), colors: base),
        _f('sink', 0.8, 0.6, at: const Offset(-0.5, y), colors: base),
        _f('kitchen_counter', 0.6, 0.6, at: const Offset(0.2, y), colors: base),
        _f('stove', 0.6, 0.6, at: const Offset(0.8, y), colors: base),
        _f(
          'wall_cabinet',
          1.2,
          0.35,
          at: const Offset(-0.9, -1.7 + 0.175),
          colors: upper,
        ),
        _f(
          'wall_cabinet',
          0.8,
          0.35,
          at: const Offset(0.6, -1.7 + 0.175),
          colors: upper,
        ),
        _f(
          'waste_bin',
          0.4,
          0.4,
          at: const Offset(1.4, -1.2),
          colors: c ? const {'body': _chalk, 'lid': _petrol} : const {},
        ),
        _f(
          'worktop',
          1.2,
          0.6,
          at: const Offset(-0.1, 0.4),
          colors: c ? const {'worktop': _walnut} : const {},
        ),
      ];
    },
    markers: (_) => const [],
  ),
  'bath': (
    room: 1.3,
    wall: 2.2,
    objects: (c) => [
      _f(
        'washbasin',
        0.6,
        0.5,
        at: const Offset(-0.6, -1.05),
        colors: c ? const {'ceramic': _chalk} : const {},
      ),
      _f(
        'mirror',
        0.6,
        0.15,
        at: const Offset(-0.6, -1.225),
        colors: c ? const {'frame': _anthracite} : const {},
      ),
      _f(
        'mirror_cabinet',
        0.7,
        0.2,
        at: const Offset(0.4, -1.2),
        colors: c ? const {'body': _oak, 'fronts': _oak} : const {},
      ),
      _f(
        'washing_machine',
        0.6,
        0.6,
        at: const Offset(0.4, -1.0),
        colors: c ? const {'door': _anthracite} : const {},
      ),
      _f(
        'toilet',
        0.4,
        0.7,
        at: const Offset(1.0, -0.1),
        rot: 90,
        colors: c ? const {'seat': _anthracite} : const {},
      ),
      _f(
        'waste_bin',
        0.3,
        0.3,
        at: const Offset(-0.1, -1.1),
        colors: c ? const {'body': _rose} : const {},
      ),
    ],
    markers: (_) => const [],
  ),
  'living': (
    room: 1.8,
    wall: 0.01,
    objects: (c) => [
      _f(
        'rug',
        2.4,
        1.8,
        at: const Offset(0.1, 0.1),
        colors: c ? const {'rug': _linen} : const {},
      ),
      _f(
        'sofa_corner',
        2.6,
        2.0,
        at: const Offset(-0.3, -0.5),
        colors: c ? const {'frame': _navy, 'cushions': _linen} : const {},
      ),
      _f(
        'coffee_table',
        1.1,
        0.6,
        at: const Offset(0.3, 0.2),
        colors: c ? const {'top': _oak, 'legs': _anthracite} : const {},
      ),
      _f(
        'side_table',
        0.45,
        0.45,
        at: const Offset(1.3, -1.2),
        colors: c ? const {'top': _walnut} : const {},
      ),
      _f(
        'bookcase',
        0.8,
        0.35,
        at: const Offset(1.4, 0.6),
        rot: 270,
        colors: c
            ? const {'body': _chalk, 'back': _sage, 'books': _mustard}
            : const {},
      ),
      _f(
        'plant',
        0.5,
        0.5,
        at: const Offset(-1.4, 1.2),
        colors: c ? const {'pot': _terracotta} : const {},
      ),
    ],
    markers: (_) => const [],
  ),
  'dining': (
    room: 1.4,
    wall: 0.01,
    objects: (c) => [
      _f(
        'dining_table',
        1.8,
        1.5,
        colors: c
            ? const {
                'top': _oak,
                'legs': _anthracite,
                'frame': _anthracite,
                'seat': _rose,
              }
            : const {},
      ),
      _f(
        'dining_chair',
        0.45,
        0.5,
        at: const Offset(1.2, 0.9),
        rot: 200,
        colors: c ? const {'frame': _oak, 'seat': _olive} : const {},
      ),
    ],
    markers: (_) => const [],
  ),
  'bedroom': (
    room: 1.6,
    wall: 0.01,
    objects: (c) => [
      _f(
        'bed_double',
        1.6,
        2.0,
        at: const Offset(-0.3, 0),
        colors: c
            ? const {'frame': _walnut, 'bedding': _sage, 'pillows': _chalk}
            : const {},
      ),
      _f(
        'nightstand',
        0.45,
        0.4,
        at: const Offset(-1.4, -0.75),
        colors: c ? const {'body': _walnut, 'handles': _oak} : const {},
      ),
      _f(
        'dresser',
        1.0,
        0.5,
        at: const Offset(1.15, -0.2),
        rot: 270,
        colors: c
            ? const {'body': _chalk, 'fronts': _rose, 'handles': _oak}
            : const {},
      ),
      _f(
        'wardrobe',
        1.5,
        0.6,
        at: const Offset(0.8, 1.3),
        rot: 180,
        colors: c ? const {'fronts': _smoke} : const {},
      ),
    ],
    markers: (_) => const [],
  ),
  'work': (
    room: 1.1,
    wall: 0.01,
    objects: (c) => [
      _f(
        'desk',
        1.5,
        0.7,
        at: const Offset(0, -0.3),
        colors: c ? const {'top': _oak, 'legs': _chalk} : const {},
      ),
      _f(
        'office_chair',
        0.6,
        0.6,
        at: const Offset(0, 0.35),
        rot: 180,
        colors: c ? const {'cushions': _mustard} : const {},
      ),
    ],
    markers: (_) => const [],
  ),
  'hall': (
    room: 1.2,
    wall: 2.2,
    objects: (c) => [
      _f(
        'coat_rack',
        1.0,
        0.4,
        at: const Offset(-0.3, -1.0),
        colors: c
            ? const {
                'body': _oak,
                'cushion': _olive,
                'coats': _navy,
                'hooks': _anthracite,
              }
            : const {},
      ),
      _f(
        'door',
        0.9,
        0.9,
        at: const Offset(0.7, 0.75),
        colors: c ? const {'leaf': _sage} : const {},
      ),
      _f(
        'shelf',
        0.8,
        0.3,
        at: const Offset(1.05, -0.4),
        rot: 270,
        colors: c ? const {'back': _terracotta} : const {},
      ),
    ],
    markers: (_) => const [],
  ),
};

String get _out => Platform.environment['HAVEN_COLORS_OUT'] ?? 'build/preview';

Future<void> shot(WidgetTester tester, String name, {bool dark = false}) async {
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
          color: dark ? const Color(0xFF111316) : const Color(0xFFF1EFEB),
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
                          style: dark
                              ? SceneStyle.evening()
                              : SceneStyle.light(),
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
    File('$_out/closeup2_${name}_${dark ? 'dark' : 'light'}.png')
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
    final only = Platform.environment['HAVEN_CLOSEUPS'];
    for (final name in _cases.keys) {
      if (only != null && !only.split(',').contains(name)) continue;
      await shot(tester, name);
      await shot(tester, name, dark: true);
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
