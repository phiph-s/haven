// 3D-Vorschau der Lampen-Kalibrierung: das Beispielzimmer bei 2700 K und
// 50 %, einmal wie gemeldet, einmal mit warmer Korrektur (2700 K wirkt wie
// 2200 K, etwas dunkler). Bilder nach build/gpu/lamp_calibration_*.png.
//   flutter test --enable-flutter-gpu --enable-impeller \
//     test_gpu/lamp_calibration_preview_test.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/models/lamp_calibration.dart';
import 'package:haven/features/settings/lamp_preview_3d.dart';
import 'package:haven_3d/haven_3d.dart';

const _size = Size(420, 260);
const _dpr = 2.0;

Future<void> _settle(WidgetTester tester, [int n = 40]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<ui.Image> _grab(WidgetTester tester, GlobalKey key, String name) async {
  late ui.Image img;
  await tester.runAsync(() async {
    final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    img = await b.toImage(pixelRatio: _dpr);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    File('build/gpu/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
  return img;
}

/// Mittlere Farbe (0..255) aller nicht fast schwarzen Pixel.
Future<(double, double, double)> _mean(
  WidgetTester tester,
  ui.Image img,
) async {
  late ByteData data;
  await tester.runAsync(() async {
    data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  });
  var r = 0.0, g = 0.0, b = 0.0, n = 0;
  for (var i = 0; i < data.lengthInBytes; i += 4) {
    final pr = data.getUint8(i), pg = data.getUint8(i + 1);
    final pb = data.getUint8(i + 2);
    if (pr + pg + pb < 40) continue;
    r += pr;
    g += pg;
    b += pb;
    n++;
  }
  return n == 0 ? (0.0, 0.0, 0.0) : (r / n, g / n, b / n);
}

void main() {
  // Echte GPU (flutter test --enable-flutter-gpu), nicht ohne Bild.
  Scene3DSupport.debugOverride = true;

  testWidgets('Kalibrierung: Beispielzimmer gemeldet und korrigiert', (
    tester,
  ) async {
    tester.view.physicalSize = _size * _dpr;
    tester.view.devicePixelRatio = _dpr;
    addTearDown(tester.view.reset);

    const warm = LampCalibration(
      white: {2700: 2200, 4000: 4000, 6500: 6500},
      gain: 0.85,
    );
    final reported = previewLampState(kelvin: 2700, level: 50, hasKelvin: true);
    final corrected = previewLampState(
      kelvin: 2700,
      level: 50,
      hasKelvin: true,
      calibration: warm,
    );
    expect(corrected.color, isNot(reported.color));
    expect(corrected.brightness, lessThan(reported.brightness));

    final ctrl = SceneController(kPreviewCamera);
    for (final id in kPreviewLampIds) {
      ctrl.setLamp(id, reported);
    }
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: key,
          child: ColoredBox(
            color: const Color(0xFF101114),
            child: Scene3DView(
              scene: calibrationPreviewScene,
              controller: ctrl,
              style: SceneStyle.evening(),
              quality: SceneQuality.medium,
              gestures: SceneGestures.none,
              lightReach: LightReach.room,
              markers: const [],
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    final a = await _grab(tester, key, 'lamp_calibration_gemeldet');

    // Umschalten ohne Neuaufbau: nur setLamp.
    for (final id in kPreviewLampIds) {
      ctrl.setLamp(id, corrected);
    }
    await _settle(tester, 20);
    final b = await _grab(tester, key, 'lamp_calibration_korrigiert');

    final (ar, _, ab) = await _mean(tester, a);
    final (br, _, bb) = await _mean(tester, b);
    // Wärmer: mehr Rot im Verhältnis zu Blau.
    expect(br / bb, greaterThan(ar / ab));

    // Beide nebeneinander für den Blick.
    await tester.runAsync(() async {
      final rec = ui.PictureRecorder();
      final c = ui.Canvas(rec);
      c.drawImage(a, Offset.zero, ui.Paint());
      c.drawImage(b, Offset(a.width.toDouble() + 8, 0), ui.Paint());
      final img = await rec.endRecording().toImage(a.width * 2 + 8, a.height);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File('build/gpu/lamp_calibration_vergleich.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(png!.buffer.asUint8List());
    });

    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(seconds: 3));
    }
  });
}
