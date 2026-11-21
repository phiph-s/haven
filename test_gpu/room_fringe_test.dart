// Raumbilder verkleinert zusammensetzen (wie die Raumkacheln der
// Startseite): an Kanten und dünnen Linien dürfen keine Farbsäume
// entstehen. Vergleicht jede Kachel mit dem in voller Größe
// zusammengesetzten und danach verkleinerten Bild und schreibt beide nach
// build/gpu/fringe/.
//   flutter test --enable-flutter-gpu --enable-impeller test_gpu/room_fringe_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/features/map/map_3d.dart';
import 'package:haven/features/map/map_render.dart';
import 'package:haven_3d/haven_3d.dart';

void main() {
  Scene3DSupport.debugOverride = true;
  testWidgets('Raumkacheln ohne Farbsäume', (tester) async {
    await tester.runAsync(() async {
      // Dazu Salon und Kochbereich offen verbunden: Raumbilder mit
      // Nachbarraum dahinter und Lampen des Nachbarn.
      var open = kFakeFloorPlan;
      open = open.withRoom(open.room('salon')!.copyWith(open: {1}));
      open = open.withRoom(open.room('kochbereich')!.copyWith(open: {4}));
      final sets = <(String, LayerSet)>[];
      for (final (tag, plan) in [('', kFakeFloorPlan), ('offen_', open)]) {
        final views = [
          for (final v in mapLayerViews(plan))
            if (v.roomId != null &&
                (tag.isEmpty ||
                    const {'salon', 'kochbereich'}.contains(v.roomId)))
              v,
        ];
        for (final s in await LayerRenderer(sceneOfPlan(plan)).render(views)) {
          sets.add((tag, s));
        }
      }
      final program = await LayerShader.program();
      // Orange, voll: dort fielen die Säume (Türkis) am stärksten auf.
      const lamp = LampState(color: Color(0xFFFF8A2A));
      var worst = 0;
      for (final (tag, s) in sets) {
        final images = await LayerImages.decode(
          meta: s.meta(),
          base: s.base,
          rooms: {for (final e in s.rooms.entries) e.key: e.value.png},
          lamps: {for (final e in s.lamps.entries) e.key: e.value.png},
        );
        final factors = {
          for (final id in s.lamps.keys.take(kLayerShaderLamps))
            id: layerFactor(lamp, images.gain),
        };
        final w = images.width.toDouble(), h = images.height.toDouble();
        Future<ui.Image> paint(double scale) async {
          final rec = ui.PictureRecorder();
          paintLayers(
            Canvas(rec),
            Rect.fromLTWH(0, 0, w * scale, h * scale),
            images,
            program.fragmentShader(),
            factors,
          );
          final pic = rec.endRecording();
          final img = await pic.toImage(
            (w * scale).round(),
            (h * scale).round(),
          );
          pic.dispose();
          return img;
        }

        final full = await paint(1);
        for (final scale in [0.5, 0.33, 0.25]) {
          final small = await paint(scale);
          // Bezug: in voller Größe zusammengesetzt, dann verkleinert.
          final rec = ui.PictureRecorder();
          Canvas(rec).drawImageRect(
            full,
            Rect.fromLTWH(0, 0, w, h),
            Rect.fromLTWH(
              0,
              0,
              small.width.toDouble(),
              small.height.toDouble(),
            ),
            Paint()..filterQuality = FilterQuality.medium,
          );
          final pic = rec.endRecording();
          final ref = await pic.toImage(small.width, small.height);
          pic.dispose();
          final a = (await small.toByteData())!.buffer.asUint8List();
          final b = (await ref.toByteData())!.buffer.asUint8List();
          // Türkiser Saum: deutlich weniger Rot als im Bezug, bei warmem
          // Licht.
          var bad = 0;
          for (var i = 0; i < a.length; i += 4) {
            if (b[i] - a[i] > 60 && a[i + 2] > a[i] + 30) bad++;
          }
          final name = '$tag${s.view.id}_${s.theme}_${(scale * 100).round()}';
          // ignore: avoid_print
          print('FRINGE $name: $bad Pixel mit Saum');
          if (bad > worst) worst = bad;
          for (final (img, tag) in [(small, 'kachel'), (ref, 'bezug')]) {
            final png = await img.toByteData(format: ui.ImageByteFormat.png);
            File('build/gpu/fringe/${name}_$tag.png')
              ..createSync(recursive: true)
              ..writeAsBytesSync(png!.buffer.asUint8List());
          }
          small.dispose();
          ref.dispose();
        }
        full.dispose();
        images.dispose();
      }
      expect(worst, lessThan(20));
    });
  }, timeout: const Timeout(Duration(minutes: 10)));
}
