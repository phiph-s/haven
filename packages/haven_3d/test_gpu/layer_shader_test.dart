// Shader der Lichtebenen gegen den Zusammensetzer der Integration: setzt
// einen Bildsatz aus build/concept/arbeiten (siehe layer_renderer_test bzw.
// eigener Satz) mit festen Lampen zusammen und schreibt
// build/layer_shader/shader.png; compare_layer_sets.py --shader vergleicht.
//   flutter test --enable-flutter-gpu --enable-impeller test_gpu/layer_shader_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';

const states = {
  'licht_arbeiten_rot': LampState(color: Color(0xFFFF4D6D)),
  'licht_arbeiten_blau': LampState(brightness: 0.6, color: Color(0xFF4D8DFF)),
  'licht_arbeiten_gruen': LampState(brightness: 0.8, color: Color(0xFF5DFF8A)),
};

void main() {
  testWidgets('Shader setzt Ebenen zusammen', (tester) async {
    final dir = Directory('build/concept/arbeiten');
    if (!dir.existsSync()) {
      markTestSkipped('build/concept/arbeiten fehlt');
      return;
    }
    final meta =
        jsonDecode(File('${dir.path}/meta.json').readAsStringSync())
            as Map<String, dynamic>;
    await tester.runAsync(() async {
      final images = await LayerImages.decode(
        meta: meta,
        base: File('${dir.path}/base.png').readAsBytesSync(),
        rooms: {
          for (final f in dir.listSync().whereType<File>())
            if (f.path.contains('/room_'))
              f.path.split('/room_').last.replaceAll('.png', ''): f
                  .readAsBytesSync(),
        },
        lamps: {
          for (final f in dir.listSync().whereType<File>())
            if (f.path.contains('/lamp_'))
              f.path.split('/lamp_').last.replaceAll('.png', ''): f
                  .readAsBytesSync(),
        },
      );
      final program = await LayerShader.program();
      final shader = program.fragmentShader();
      final rec = ui.PictureRecorder();
      final w = images.width.toDouble(), h = images.height.toDouble();
      paintLayers(Canvas(rec), Rect.fromLTWH(0, 0, w, h), images, shader, {
        for (final e in states.entries)
          e.key: layerFactor(e.value, images.gain),
      });
      final img = await rec.endRecording().toImage(images.width, images.height);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File('build/layer_shader/shader.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(png!.buffer.asUint8List());
      File('build/layer_shader/states.json').writeAsStringSync(
        jsonEncode({
          for (final e in states.entries)
            e.key: {
              'on': true,
              'brightness': e.value.brightness,
              'color':
                  '#${(e.value.color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
            },
        }),
      );
    });
  });
}
