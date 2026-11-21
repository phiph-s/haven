// 2D-Symbole aller Möbel (Editor-Stift, hell und dunkel, mit und ohne
// eigene Farben) als Übersicht nach build/gpu/furniture_icons_*.png (oder
// HAVEN_COLORS_OUT). Braucht keine GPU.
//   flutter test test_gpu/furniture_icons_test.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show Color, Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/core/theme/tokens.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/features/map/furniture_painter.dart';
import 'package:haven_3d/haven_3d.dart' as h3;

const _palette = [
  Color(0xFF61758A),
  Color(0xFFC49A6C),
  Color(0xFF93A68A),
  Color(0xFFB86B4F),
];

void main() {
  for (final dark in [false, true]) {
    test('Symbole ${dark ? 'dunkel' : 'hell'}', () async {
      final hv = dark ? HavenColors.dark : HavenColors.light;
      const cell = 150.0, cols = 8;
      final types = kFurnitureCatalog;
      final rows = (types.length / cols).ceil() * 2;
      final rec = ui.PictureRecorder();
      final canvas = ui.Canvas(rec);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, cell * cols, cell * 20),
        ui.Paint()..color = hv.bg,
      );
      for (var i = 0; i < types.length; i++) {
        final t = types[i];
        final zones = h3.furnitureSpec(t.id).zones;
        for (final colored in [false, true]) {
          final r = (i ~/ cols) * 2 + (colored ? 1 : 0);
          final at = Offset((i % cols) * cell, r * cell);
          final s = math.min((cell - 30) / t.w, (cell - 30) / t.h);
          final size = Size(t.w * s, t.h * s);
          canvas.save();
          canvas.translate(
            at.dx + (cell - size.width) / 2,
            at.dy + (cell - size.height) / 2,
          );
          paintFurnitureShape(
            canvas,
            t.id,
            size,
            FurnitureInk.editor(hv),
            colors: colored
                ? {
                    for (var z = 0; z < zones.length; z++)
                      zones[z].id: _palette[z % _palette.length],
                  }
                : const {},
          );
          canvas.restore();
        }
      }
      final img = await rec.endRecording().toImage(
        (cell * cols).toInt(),
        (cell * rows).toInt(),
      );
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      final out =
          Platform.environment['HAVEN_COLORS_OUT'] ?? 'build/gpu/colors';
      File('$out/icons_${dark ? 'dark' : 'light'}.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(png!.buffer.asUint8List());
    });
  }
}
