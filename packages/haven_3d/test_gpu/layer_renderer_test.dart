// Lichtebenen über den LayerRenderer (ohne Widget) für drei Perspektiven
// und beide Designs nach build/layer_sets/, dazu echte Vergleichsbilder
// über Scene3DView. Der Zusammensetzer der Integration (render_compose.py)
// prüft damit die ganze Kette:
//   flutter test --enable-flutter-gpu --enable-impeller test_gpu/layer_renderer_test.dart
//   python3 ../../../integration/tests/compare_layer_sets.py build/layer_sets
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';

const _views = [
  LayerView(id: 'flach', flat: true, width: 900, height: 700),
  LayerView(id: '3d', yaw: -0.42, pitch: 0.92, width: 900, height: 700),
  LayerView(
    id: 'arbeiten',
    roomId: 'arbeiten',
    yaw: -0.3,
    pitch: 0.92,
    width: 700,
    height: 700,
  ),
];

String _hex(ui.Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

void main() {
  Scene3DSupport.debugOverride = true;
  final out = Directory('build/layer_sets');

  testWidgets('Ebenen rendern', (tester) async {
    if (out.existsSync()) out.deleteSync(recursive: true);
    final scene = sampleScene();
    final r = LayerRenderer(scene);
    final sw = Stopwatch()..start();
    var last = 0;
    late List<LayerSet> sets;
    await tester.runAsync(() async {
      sets = await r.render(
        _views,
        onProgress: (done, total, _) {
          last = done;
          expect(done, lessThanOrEqualTo(total));
        },
      );
    });
    sw.stop();
    expect(last, r.steps(_views));
    var bytes = 0;
    for (final s in sets) {
      final dir = Directory('${out.path}/${s.view.id}_${s.theme}')
        ..createSync(recursive: true);
      File('${dir.path}/meta.json').writeAsStringSync(jsonEncode(s.meta()));
      File('${dir.path}/base.png').writeAsBytesSync(s.base);
      for (final e in s.rooms.entries) {
        File('${dir.path}/room_${e.key}.png').writeAsBytesSync(e.value.png);
      }
      for (final e in s.lamps.entries) {
        File('${dir.path}/lamp_${e.key}.png').writeAsBytesSync(e.value.png);
      }
      bytes += s.bytes;
      // ignore: avoid_print
      print(
        '${s.view.id}/${s.theme}: ${s.rooms.length} Räume, '
        '${s.lamps.length}/${s.lampRooms.length} Lampen, '
        '${(s.bytes / 1024).round()} KB',
      );
    }
    // ignore: avoid_print
    print(
      '${r.steps(_views)} Bilder in ${sw.elapsedMilliseconds} ms, '
      '${(bytes / 1024).round()} KB',
    );
    expect(sets, hasLength(_views.length * 2));
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('Vergleichsbilder', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    final scene = sampleScene();
    final states = <String, Map<String, LampState>>{
      'alle': {
        for (final m in scene.markers)
          if (m.lamp != null) m.id: m.lamp!,
      },
      'farben': {
        'licht_wohnen': const LampState(
          brightness: 0.3,
          color: ui.Color(0xFF7AA8FF),
        ),
        'licht_kueche': const LampState(color: ui.Color(0xFFFF8A3D)),
        'licht_arbeiten_blau': const LampState(brightness: 0.15),
      },
      // Genau der Zustand der Ebene: muss ihr gleichen.
      'ebene': {
        'licht_arbeiten_blau': const LampState(
          brightness: kLayerGain,
          color: ui.Color(0xFFFFFFFF),
        ),
      },
    };
    for (final v in _views) {
      for (final dark in [false, true]) {
        tester.view.physicalSize = ui.Size(
          v.width.toDouble(),
          v.height.toDouble(),
        );
        final key = GlobalKey();
        final ctrl = SceneController(OrbitCamera(yaw: v.yaw, pitch: v.pitch));
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: RepaintBoundary(
              key: key,
              child: Scene3DView(
                key: ValueKey('${v.id}$dark'),
                scene: scene,
                controller: ctrl,
                style: (dark ? LayerTheme.dark : LayerTheme.light).style,
                raisedRooms: v.flat ? const {} : null,
                focusRoomId: v.roomId,
              ),
            ),
          ),
        );
        for (final st in states.entries) {
          for (final m in scene.markers) {
            if (m.lamp == null) continue;
            ctrl.setLamp(m.id, st.value[m.id] ?? LampState.off);
          }
          for (var i = 0; i < 50; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 40)),
            );
            await tester.pump(const Duration(milliseconds: 16));
          }
          final dir = '${out.path}/${v.id}_${dark ? 'dark' : 'light'}';
          await tester.runAsync(() async {
            final b =
                key.currentContext!.findRenderObject() as RenderRepaintBoundary;
            final img = await b.toImage();
            final png = await img.toByteData(format: ui.ImageByteFormat.png);
            File('$dir/ref_${st.key}.png')
              ..createSync(recursive: true)
              ..writeAsBytesSync(png!.buffer.asUint8List());
          });
          File('$dir/ref_${st.key}.json').writeAsStringSync(
            jsonEncode({
              for (final e in st.value.entries)
                e.key: {
                  'on': e.value.on,
                  'brightness': e.value.brightness,
                  'color': _hex(e.value.color),
                },
            }),
          );
        }
        await tester.pumpWidget(const SizedBox());
        ctrl.dispose();
        for (var i = 0; i < 6; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump(const Duration(seconds: 3));
        }
      }
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
