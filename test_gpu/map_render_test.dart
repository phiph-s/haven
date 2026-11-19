// Bilder für Widgets in der App: echter MapRenderJob (Fake-Grundriss, GPU,
// Upload in den Speicher der Entwicklungsdaten) und der Ladedialog als Bild
// nach build/gpu/ (mit Roboto aus ~/.fonts, falls vorhanden).
//   flutter test --enable-flutter-gpu --enable-impeller test_gpu/map_render_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/core/theme/theme.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/map/map_render.dart';
import 'package:haven_3d/haven_3d.dart' show Scene3DSupport;
import 'package:material_ui/material_ui.dart';

Future<void> _fonts() async {
  final home = Platform.environment['HOME'];
  final dir = Directory('$home/.fonts');
  if (!dir.existsSync()) return;
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => RegExp(r'Roboto-[A-Za-z]+\.ttf$').hasMatch(f.path))
      .toList();
  if (files.isEmpty) return;
  final loader = FontLoader('Roboto');
  for (final f in files) {
    loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  }
  await loader.load();
}

void main() {
  Scene3DSupport.debugOverride = true;

  testWidgets('MapRenderJob rendert und lädt hoch', (tester) async {
    final repo = FakeRepository(simulate: false);
    final job = MapRenderJob(repo, kFakeFloorPlan);
    final seen = <MapRenderPhase>{};
    var last = 0.0;
    final rooms = <String>{};
    final sw = Stopwatch()..start();
    await tester.runAsync(
      () => job.run((p) {
        seen.add(p.phase);
        expect(p.fraction, greaterThanOrEqualTo(last - 1e-9));
        last = p.fraction;
        if (p.roomId != null) rooms.add(p.roomId!);
      }),
    );
    sw.stop();
    final s = (await repo.renderStatus())!;
    expect(s.key, job.key);
    expect(s.sets, hasLength(job.views.length * 2));
    expect(seen, containsAll(MapRenderPhase.values));
    expect(last, 1.0);
    // ignore: avoid_print
    print(
      '${job.views.length} Perspektiven × 2 Designs in '
      '${sw.elapsedMilliseconds} ms, Räume im Fortschritt: ${rooms.length}',
    );
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('Ladedialog (Bild)', (tester) async {
    await tester.runAsync(_fonts);
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(412, 760) * 2;
    tester.view.devicePixelRatio = 2;
    for (final (name, theme) in [
      ('dunkel', havenDarkTheme),
      ('hell', havenLightTheme),
    ]) {
      final key = GlobalKey<MapRenderDialogState>();
      final shot = GlobalKey();
      final job = MapRenderJob(FakeRepository(simulate: false), kFakeFloorPlan);
      await tester.pumpWidget(
        RepaintBoundary(
          key: shot,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showDialog<bool>(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) =>
                          MapRenderDialog(key: key, job: job, autoStart: false),
                    ),
                    child: const Text('los'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('los'));
      await tester.pump(const Duration(milliseconds: 400));
      final room = kFakeFloorPlan.rooms[1];
      key.currentState!.show((
        phase: MapRenderPhase.render,
        fraction: 0.46,
        roomId: room.id,
      ));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.runAsync(() async {
        final b =
            shot.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final img = await b.toImage(pixelRatio: 2);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('build/gpu/render_dialog_$name.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(png!.buffer.asUint8List());
      });
      await tester.pumpWidget(const SizedBox());
    }
  });
}
