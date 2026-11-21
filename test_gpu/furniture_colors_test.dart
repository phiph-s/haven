// Möbelfarben (Farbzonen) im Beispielgrundriss: hell und dunkel, Tag und
// Nacht mit Himmel, dazu ohne Himmel. Bilder nach build/gpu/colors_*.png
// (oder in den Ordner aus HAVEN_COLORS_OUT).
//   flutter test --enable-flutter-gpu --enable-impeller \
//     test_gpu/furniture_colors_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/features/map/furniture_colors.dart';
import 'package:haven/features/map/map_3d.dart';
import 'package:haven/features/map/map_sky.dart';
import 'package:haven_3d/haven_3d.dart';

/// Beispielplan mit einigen eingefärbten Möbeln und einem Fernseher auf dem
/// Sideboard.
HavenFloorPlan coloredPlan() {
  var plan = kFakeFloorPlan;
  Color c(String name) =>
      kFurniturePalette.firstWhere((p) => p.name == name).color;
  for (final (id, zone, color) in [
    ('sofa', 'frame', c('Rauchblau')),
    ('sofa', 'cushions', c('Leinen')),
    ('chair', 'frame', c('Terrakotta')),
    ('chair', 'cushions', c('Creme')),
    ('plant', 'pot', c('Terrakotta')),
    ('tv', 'body', c('Nussbaum')),
    ('tv', 'fronts', c('Eiche')),
    ('tv', 'handles', c('Anthrazit')),
    ('rug', 'rug', c('Salbei')),
    ('table', 'top', c('Eiche')),
    ('dining', 'top', c('Eiche')),
    ('dining', 'chairs', c('Anthrazit')),
    ('counter', 'fronts', c('Petrol')),
    ('counter', 'worktop', c('Eiche')),
    ('sink', 'fronts', c('Petrol')),
    ('sink', 'worktop', c('Eiche')),
    ('stove', 'fronts', c('Petrol')),
    ('stove', 'worktop', c('Eiche')),
    ('bed', 'frame', c('Eiche')),
    ('bed', 'bedding', c('Salbei')),
    ('wardrobe', 'fronts', c('Altrosa')),
    ('desk', 'top', c('Nussbaum')),
    ('ochair', 'cushions', c('Senf')),
    ('wc', 'seat', c('Anthrazit')),
    ('door1', 'leaf', c('Salbei')),
  ]) {
    plan = plan.withFurnitureColor(id, zone, color);
  }
  return plan.copyWith(
    placements: [
      ...plan.placements,
      const FloorPlacement(
        entityId: 'media_player.fernseher_salon',
        x: 7,
        y: 3,
        model: 'tv',
        mount: 'stand',
        height: 0.55,
        size: 55,
      ),
    ],
  );
}

String get _out =>
    Platform.environment['HAVEN_COLORS_OUT'] ?? 'build/gpu/colors';

Future<void> shot(
  WidgetTester tester,
  String name, {
  required bool dark,
  SceneSky? sky,
  bool lamps = false,
}) async {
  const size = Size(900, 700);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  final plan = coloredPlan();
  final scene = sceneOfPlan(plan);
  final key = GlobalKey();
  final c = SceneController(
    const OrbitCamera(yaw: kMapTiltYaw, pitch: kMapTiltPitch),
  );
  c.setSky(sky);
  if (sky != null) {
    c.setGround(const SceneGround(color: Color(0x00FFFFFF)));
  }
  for (final m in scene.markers) {
    if (m.lamp == null) continue;
    final on =
        lamps &&
        (m.id.contains('salon') ||
            m.id.contains('ruheraum') ||
            m.id.contains('lichtleiste'));
    c.setLamp(
      m.id,
      on
          ? const LampState(brightness: 0.85, color: Color(0xFFFFC98A))
          : LampState.off,
    );
  }
  // Wie die Karte (map_3d.dart): mit Himmel hell und dunkel dieselben
  // Farben, im dunklen Design nachts helle Linien und weniger Grundlicht;
  // ohne Himmel im dunklen Design der Abendstil.
  final night = sky != null && dark
      ? 1 - (mapSkyDaylight(sky) * 20).round() / 20
      : 0.0;
  final light = SceneStyle.light();
  final darkStyle = SceneStyle.dark();
  final style = (sky != null || !dark ? light : SceneStyle.evening()).copyWith(
    ink: night > 0 ? Color.lerp(light.ink, darkStyle.ink, night) : null,
    roomEdgeOpacity: night > 0
        ? ui.lerpDouble(light.roomEdgeOpacity, darkStyle.roomEdgeOpacity, night)
        : null,
    wallOpacity: 1,
    floorOpacity: 1,
    skyMinAmbient: dark ? 0.24 : null,
  );
  final bounds = planBoundsMeters(plan);
  Widget view = Scene3DView(
    scene: scene,
    controller: c,
    style: style,
    quality: SceneQuality.medium,
    markers: const [],
  );
  if (sky != null) {
    view = SkyLayers(
      sky: sky,
      dark: dark,
      animate: false,
      controller: c,
      center: V3(bounds.center.dx, bounds.center.dy, 0),
      extent: bounds,
      child: view,
    );
  }
  final top = sky == null
      ? (dark ? const Color(0xFF111316) : const Color(0xFFF2F1EE))
      : Color.lerp(
          const Color(0xFF0B1020),
          const Color(0xFF8DB7E8),
          ((sky.sunElevation + 8) / 20).clamp(0.0, 1.0),
        )!;
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
              colors: [
                top,
                if (dark) const Color(0xFF07080B) else const Color(0xFFF4F3F0),
              ],
            ),
          ),
          child: view,
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
    final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final img = await b.toImage(pixelRatio: 1);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    File('$_out/$name.png')
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
  testWidgets('Möbelfarben hell, dunkel, Tag, Nacht', (tester) async {
    addTearDown(tester.view.reset);
    final day = SceneSky.at(dayOfYear: 300, hour: 14);
    final night = SceneSky.at(dayOfYear: 300, hour: 22, moonPhase: 0.3);
    await shot(tester, 'light_day', dark: false, sky: day);
    await shot(tester, 'light_night', dark: false, sky: night, lamps: true);
    await shot(tester, 'dark_day', dark: true, sky: day);
    await shot(tester, 'dark_night', dark: true, sky: night, lamps: true);
    await shot(tester, 'light_nosky', dark: false);
    await shot(tester, 'dark_nosky', dark: true, lamps: true);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
