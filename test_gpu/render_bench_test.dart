// Messung der 3D-Ansicht am Beispielgrundriss: Aufbau, Baking, Neumischen
// des Lichts und Kosten je Bild (CPU-Zeit, Draw-Calls je Pass). Keine
// Bilder, nur Zahlen in der Ausgabe.
//   flutter test --enable-flutter-gpu --enable-impeller test_gpu/render_bench_test.dart
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_scene/scene.dart' as fs;
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/features/map/map_3d.dart';
import 'package:haven_3d/haven_3d.dart';
// ignore: implementation_imports
import 'package:haven_3d/src/gpu_scene.dart';

void main() {
  Scene3DSupport.debugOverride = true;
  testWidgets('Messung 3D', (tester) async {
    await tester.runAsync(() async {
      await fs.Scene.initializeStaticResources();
      final style = SceneStyle.dark();
      final scene = sceneOfPlan(kFakeFloorPlan)
          .fittedToRooms(inset: style.roomGap / 2, radius: style.roomRadius);
      final lamps = [
        for (final m in scene.markers)
          if (m.lamp != null) m.id,
      ];
      // ignore: avoid_print
      void log(String s) => print('BENCH $s');
      log(
        'Räume ${scene.rooms.length}, Möbel ${scene.objects.length}, '
        'Geräte ${scene.markers.length}, Lampen ${lamps.length}',
      );

      double ms(Stopwatch sw) => sw.elapsedMicroseconds / 1000;

      // Aufbau ohne und mit Baking.
      for (final q in [
        SceneQuality.draft,
        SceneQuality.low,
        SceneQuality.medium,
        SceneQuality.high,
      ]) {
        var best = double.infinity;
        for (var i = 0; i < 3; i++) {
          final sw = Stopwatch()..start();
          GpuScene(scene, style, quality: q);
          best = best < ms(sw) ? best : ms(sw);
        }
        log('Aufbau ${q.name}: ${best.toStringAsFixed(1)} ms');
      }

      final gpu = GpuScene(scene, style, quality: SceneQuality.high);
      gpu.scene.maxGpuFramesInFlight = 0;
      const size = ui.Size(430, 800);
      const dpr = 2.0;
      Future<void> frames(
        String name,
        OrbitCamera cam, {
        int n = 60,
        bool sync = true,
      }) async {
        final c = cam.fit(scene.points(), size, padding: 24);
        final cpu = <int>[];
        final syncUs = <int>[];
        fs.RenderFrameStats? last;
        for (var i = 0; i < n; i++) {
          final sw = Stopwatch()..start();
          if (sync) gpu.sync(c, size: size);
          gpu.flushLight();
          syncUs.add(sw.elapsedMicroseconds);
          final rec = ui.PictureRecorder();
          gpu.scene.render(
            fsCamera(c, size),
            ui.Canvas(rec),
            viewport: ui.Offset.zero & size,
            pixelRatio: dpr,
          );
          final pic = rec.endRecording();
          final img = await pic.toImage(860, 1600);
          pic.dispose();
          img.dispose();
          await gpuIdle();
          last = gpu.scene.renderStats.latest;
          cpu.add(last?.cpuMicros ?? 0);
        }
        cpu.sort();
        syncUs.sort();
        final co = last!.counters;
        log(
          '$name: render-CPU Median ${(cpu[n ~/ 2] / 1000).toStringAsFixed(2)} ms, '
          'sync+flush Median ${(syncUs[n ~/ 2] / 1000).toStringAsFixed(3)} ms, '
          'Draws ${co.draws}, Instanzen ${co.instances}, '
          'Ecken ${co.vertices}, Pipeline-Wechsel ${co.pipelineBinds}, '
          'verworfen ${co.culled}',
        );
        for (final v in last.views) {
          for (final p in v.passes) {
            log(
              '   ${v.width}x${v.height} ${p.name}: '
              '${(p.cpuMicros / 1000).toStringAsFixed(2)} ms, '
              'Draws ${p.counters.draws}, Ecken ${p.counters.vertices}',
            );
          }
        }
      }

      await frames('Draufsicht, Lampen aus', const OrbitCamera());
      // Draw-Calls nach Art des Knotens.
      final kinds = <String, int>{};
      void walk(fs.Node n, bool vis) {
        final v = vis && n.visible;
        final prims = n.mesh?.primitives.length ?? 0;
        if (prims > 0) {
          final k = '${n.name.split(':').first}${v ? '' : ' (unsichtbar)'}';
          kinds[k] = (kinds[k] ?? 0) + prims;
        }
        for (final c in n.children) {
          walk(c, v);
        }
      }

      walk(gpu.scene.root, true);
      log('Primitive je Art: $kinds');
      if (const bool.fromEnvironment('ABLATE')) {
        for (final kind in [
          'edges',
          'details',
          'wall-edges',
          'top',
          'object',
          'wall',
          'floor',
          'bulb',
        ]) {
          final hidden = <fs.Node>[];
          void hide(fs.Node n) {
            if (n.name.split(':').first == kind &&
                n.visible &&
                n.mesh != null) {
              if (kind == 'object' || kind == 'wall') {
                hidden.add(n);
              } else {
                n.visible = false;
                hidden.add(n);
              }
            }
            for (final c in n.children) {
              hide(c);
            }
          }

          hide(gpu.scene.root);
          final saved = [for (final n in hidden) n.mesh];
          if (kind == 'object' || kind == 'wall') {
            for (final n in hidden) {
              n.mesh = null;
            }
          }
          await frames(
            'ohne $kind (${hidden.length})',
            const OrbitCamera(),
            n: 30,
            sync: false,
          );
          for (var i = 0; i < hidden.length; i++) {
            hidden[i].visible = true;
            hidden[i].mesh = saved[i];
          }
        }
      }
      for (final id in lamps) {
        gpu.setLamp(id, const LampState(color: Color(0xFFFFC98A)));
      }
      final sw = Stopwatch()..start();
      while (gpu.flushLight(budget: const Duration(seconds: 5))) {}
      log('Neumischen aller Flächen (alle Lampen an): ${ms(sw)} ms');
      await frames('Draufsicht, Lampen an', const OrbitCamera());
      await frames(
        'Schräg, Lampen an',
        const OrbitCamera(yaw: kMapTiltYaw, pitch: kMapTiltPitch),
      );
      // Eine Lampe schalten: Kosten des Neumischens.
      final t = <double>[];
      for (var i = 0; i < 10; i++) {
        gpu.setLamp(
          lamps.first,
          i.isEven ? LampState.off : const LampState(color: Color(0xFFFFC98A)),
        );
        final sw = Stopwatch()..start();
        while (gpu.flushLight(budget: const Duration(seconds: 5))) {}
        t.add(ms(sw));
      }
      t.sort();
      log('Eine Lampe schalten, Neumischen: Median ${t[5]} ms');
      // Sonne drehen: neu backen.
      gpu.setSunDirection(const V3(-0.5, 0.2, -1));
      final sw2 = Stopwatch()..start();
      while (gpu.flushLight(budget: const Duration(seconds: 30))) {}
      log('Sonne neu backen: ${ms(sw2)} ms');
      // Mit Himmel (Echtzeitschatten).
      gpu.setSky(SceneSky.at(dayOfYear: 172, hour: 15));
      gpu.setGround(const SceneGround(color: Color(0xFF6E8B5A)));
      while (gpu.flushLight(budget: const Duration(seconds: 5))) {}
      await frames(
        'Schräg, Himmel',
        const OrbitCamera(yaw: kMapTiltYaw, pitch: kMapTiltPitch),
      );
    });
  }, timeout: const Timeout(Duration(minutes: 10)));
}
