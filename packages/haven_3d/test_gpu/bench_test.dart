// Misst die Kosten von Lampenwechseln und Stiländerungen (CPU, ohne Rendern).
//   flutter test --enable-flutter-gpu --enable-impeller test_gpu/bench_test.dart
import 'dart:ui';

import 'package:flutter_scene/scene.dart' as fs;
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';
import 'package:haven_3d/src/gpu_scene.dart';

void main() {
  // Echte GPU (flutter test --enable-flutter-gpu), nicht ohne Bild.
  Scene3DSupport.debugOverride = true;
  testWidgets('bench', (tester) async {
    await tester.runAsync(() => fs.Scene.initializeStaticResources());
    for (final q in SceneQuality.values) {
      final sw = Stopwatch()..start();
      final g = GpuScene(sampleScene(), SceneStyle.dark(), quality: q);
      final build = sw.elapsedMilliseconds;
      // Nur Geometrie (Licht später im Hintergrund).
      sw.reset();
      GpuScene(sampleScene(), SceneStyle.dark(), quality: q, deferBake: true);
      final geo = sw.elapsedMilliseconds;
      sw.reset();
      const n = 20;
      for (var i = 0; i < n; i++) {
        g.setLamp('licht_wohnen', LampState(brightness: (i % 10) / 10 + 0.05));
        g.flushLight(budget: const Duration(seconds: 1));
      }
      final lamp = sw.elapsedMicroseconds / n / 1000;
      sw.reset();
      for (var i = 0; i < 5; i++) {
        g.restyle(
          SceneStyle.dark().copyWith(accent: Color(0xFF000000 + i * 4111)),
        );
      }
      final accent = sw.elapsedMicroseconds / 5 / 1000;
      // Zehn Lampen im selben Bild (z. B. „Alle aus“): ein Mischen je Fläche.
      final ids = [
        for (final m in sampleScene().markers)
          if (m.lamp != null) m.id,
      ];
      sw.reset();
      for (final id in ids) {
        g.setLamp(id, LampState.off);
      }
      var frames = 0;
      var worst = 0.0;
      while (g.lightPending) {
        final f = Stopwatch()..start();
        g.flushLight();
        frames++;
        if (f.elapsedMicroseconds / 1000 > worst) {
          worst = f.elapsedMicroseconds / 1000;
        }
      }
      final all = sw.elapsedMicroseconds / 1000;
      // Theme-Wechsel (Hell/Dunkel): alles neu, in Scheiben.
      sw.reset();
      g.restyle(SceneStyle.light());
      final theme = sw.elapsedMicroseconds / 1000;
      // ignore: avoid_print
      print(
        '${q.name}: Aufbau $build ms (ohne Baking $geo ms), setLamp ${lamp.toStringAsFixed(1)} ms, '
        'Akzentwechsel ${accent.toStringAsFixed(2)} ms, '
        '${ids.length} Lampen aus: ${all.toStringAsFixed(1)} ms in $frames '
        'Bildern (max ${worst.toStringAsFixed(1)} ms), '
        'Theme ${theme.toStringAsFixed(1)} ms + Scheiben',
      );
    }
  });
}
