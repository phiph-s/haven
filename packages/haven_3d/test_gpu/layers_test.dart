// Prototyp: Bild der Karte aus Lichtebenen zusammensetzen statt live
// rendern (Widgets, Displays). Je Perspektive ein Grundbild (alle Lampen
// aus) und je Lampe eine Ebene (nur diese Lampe weiß an). Das Bild für
// beliebige Lichtzustände entsteht dann ohne GPU:
//   hdr = T⁻¹(grund) + Σ farbe·helligkeit · (T⁻¹(ebene) − T⁻¹(grund))
// mit T = Tone-Mapping (PBR Neutral) nach linearem Licht. Der Test
// vergleicht das mit echten Renders und schreibt Bilder nach build/layers/.
//   flutter test --enable-flutter-gpu --enable-impeller test_gpu/layers_test.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';

const _lamps = [
  'licht_wohnen',
  'licht_kueche',
  'licht_arbeiten_rot',
  'licht_arbeiten_blau',
  'licht_arbeiten_gruen',
];
// Ebenen mit gedämpftem Weiß: volle Helligkeit brennt an Lichtflecken
// aus (Weiß lässt sich nicht zurückrechnen).
const _gain = 0.25;

// Grundbild und Ebenen im hellen Design unterbelichtet: helle Böden
// brennen sonst schon ohne Lampe fast aus, das Lampenlicht ginge verloren.
// Im dunklen Design voll belichtet (genauer in den Tiefen).
double _exposure = 1;
const _white = LampState(brightness: _gain, color: Color(0xFFFFFFFF));

class _Shot {
  _Shot(this.px, this.w, this.h);
  final Uint8List px; // RGBA, nicht vormultipliziert
  final int w, h;
}

Future<void> _settle(WidgetTester t, {int frames = 24}) async {
  for (var i = 0; i < frames; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 16));
  }
}

Future<_Shot> _grab(WidgetTester t, GlobalKey key) async {
  late _Shot s;
  await t.runAsync(() async {
    final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final img = await b.toImage();
    final d = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    s = _Shot(d!.buffer.asUint8List(), img.width, img.height);
  });
  return s;
}

Future<void> _png(WidgetTester t, String name, _Shot s) async {
  await t.runAsync(() async {
    final buf = await ui.ImmutableBuffer.fromUint8List(s.px);
    final desc = ui.ImageDescriptor.raw(
      buf,
      width: s.w,
      height: s.h,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await desc.instantiateCodec();
    final img = (await codec.getNextFrame()).image;
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    File('build/layers/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

// --- Farbräume und Tone-Mapping (wie flutter_scene_resolve.frag) ---------

final _toLin = Float64List.fromList([
  for (var i = 0; i < 256; i++)
    () {
      final c = i / 255;
      return c <= 0.04045
          ? c / 12.92
          : math.pow((c + 0.055) / 1.055, 2.4) as double;
    }(),
]);

int _enc(double l) {
  l = l.clamp(0.0, 1.0);
  final c = l <= 0.0031308 ? l * 12.92 : 1.055 * math.pow(l, 1 / 2.4) - 0.055;
  return (c * 255).round().clamp(0, 255);
}

const _ks = 0.8 - 0.04, _d = 1 - _ks, _desat = 0.15;

/// PBR Neutral (Khronos), in place auf [c] (3 Werte).
void _tone(List<double> c) {
  final x = math.min(c[0], math.min(c[1], c[2]));
  final off = x < 0.08 ? x - 6.25 * x * x : 0.04;
  for (var i = 0; i < 3; i++) {
    c[i] -= off;
  }
  final peak = math.max(c[0], math.max(c[1], c[2]));
  if (peak < _ks) return;
  final np = 1 - _d * _d / (peak + _d - _ks);
  final g = 1 - 1 / (_desat * (peak - np) + 1);
  for (var i = 0; i < 3; i++) {
    c[i] = (c[i] * np / peak) * (1 - g) + np * g;
  }
}

/// Umkehrung von [_tone] (geschlossen, bis auf Sättigung bei 1).
void _untone(List<double> y) {
  var p = math.max(y[0], math.max(y[1], y[2]));
  if (p >= _ks) {
    p = math.min(p, 0.995);
    final peak = _d * _d / (1 - p) - _d + _ks;
    final g = 1 - 1 / (_desat * (peak - p) + 1);
    for (var i = 0; i < 3; i++) {
      y[i] = (y[i] - g * p) * peak / ((1 - g) * p);
    }
  }
  final m = math.max(0.0, math.min(y[0], math.min(y[1], y[2])));
  final x = m >= 0.04 ? m + 0.04 : math.sqrt(m / 6.25);
  final off = x < 0.08 ? x - 6.25 * x * x : 0.04;
  for (var i = 0; i < 3; i++) {
    y[i] += off;
  }
}

enum _Mode { srgb, tone }

/// Licht in der Rechenebene je [mode] (3 Floats je Pixel).
Float32List _field(_Shot s, _Mode mode) {
  final n = s.w * s.h;
  final out = Float32List(n * 3);
  final c = [0.0, 0.0, 0.0];
  for (var p = 0; p < n; p++) {
    for (var i = 0; i < 3; i++) {
      final v = s.px[p * 4 + i];
      c[i] = mode == _Mode.srgb ? v / 255 : _toLin[v];
    }
    if (mode == _Mode.tone) {
      _untone(c);
      for (var i = 0; i < 3; i++) {
        c[i] /= _exposure;
      }
    }
    out[p * 3] = c[0];
    out[p * 3 + 1] = c[1];
    out[p * 3 + 2] = c[2];
  }
  return out;
}

/// Zusammensetzen. Die Möbellinien blenden je Raum aus, sobald dort eine
/// Lampe brennt (an/aus, nicht additiv). Deshalb je Raum eine Aufnahme
/// [lit] „Raum an, ohne Licht“: Sie ersetzt das Grundbild dort, wo sie sich
/// unterscheidet (einmal je Raum), und die Ebenen zählen nur das Licht
/// relativ zu ihr.
_Shot _compose(
  _Shot base,
  Map<String, _Shot> lit,
  Map<String, _Shot> layers,
  Map<String, String> roomOf,
  Map<String, LampState> on,
) {
  final n = base.w * base.h;
  final start = Uint8List.fromList(base.px);
  final active = {
    for (final e in on.entries)
      if (e.value.on && e.value.brightness > 0) e.key,
  };
  for (final room in {for (final id in active) roomOf[id]!}) {
    final r = lit[room]!.px;
    for (var p = 0; p < n; p++) {
      final o = p * 4;
      if (r[o] != base.px[o] ||
          r[o + 1] != base.px[o + 1] ||
          r[o + 2] != base.px[o + 2] ||
          r[o + 3] != base.px[o + 3]) {
        start.setRange(o, o + 4, r, o);
      }
    }
  }
  final first = _Shot(start, base.w, base.h);
  final acc = _field(first, _Mode.tone);
  for (final id in active) {
    final s = on[id]!;
    final l = _field(layers[id]!, _Mode.tone);
    final b = _field(lit[roomOf[id]!]!, _Mode.tone);
    final f = [
      for (final ch in [s.color.r, s.color.g, s.color.b])
        s.brightness / _gain * _toLin[(ch * 255).round()],
    ];
    for (var p = 0; p < n; p++) {
      for (var i = 0; i < 3; i++) {
        acc[p * 3 + i] += f[i] * (l[p * 3 + i] - b[p * 3 + i]);
      }
    }
  }
  final px = Uint8List(n * 4);
  final c = [0.0, 0.0, 0.0];
  for (var p = 0; p < n; p++) {
    for (var i = 0; i < 3; i++) {
      c[i] = math.max(0, acc[p * 3 + i]);
    }
    _tone(c);
    for (var i = 0; i < 3; i++) {
      px[p * 4 + i] = _enc(c[i]);
    }
    px[p * 4 + 3] = start[p * 4 + 3];
  }
  return _Shot(px, base.w, base.h);
}

/// Abweichung über alle sichtbaren Pixel (Alpha > 8), in 8-Bit-Stufen.
String _stats(_Shot real, _Shot comp) {
  final errs = <int>[];
  var alphaDiff = 0;
  for (var p = 0; p < real.w * real.h; p++) {
    final a = real.px[p * 4 + 3];
    alphaDiff = math.max(alphaDiff, (a - comp.px[p * 4 + 3]).abs());
    if (a <= 8) continue;
    var e = 0;
    for (var i = 0; i < 3; i++) {
      e = math.max(e, (real.px[p * 4 + i] - comp.px[p * 4 + i]).abs());
    }
    errs.add(e);
  }
  errs.sort();
  final mean = errs.fold<int>(0, (a, b) => a + b) / errs.length;
  int pct(double q) => errs[((errs.length - 1) * q).round()];
  double over(int t) => 100 * errs.where((e) => e > t).length / errs.length;
  return 'Ø ${mean.toStringAsFixed(2)}  p99 ${pct(0.99)}  max ${errs.last}  '
      '>6: ${over(6).toStringAsFixed(2)} %  >16: ${over(16).toStringAsFixed(2)} %'
      '  ΔAlpha max $alphaDiff';
}

_Shot _diff(_Shot a, _Shot b) {
  final px = Uint8List(a.px.length);
  for (var p = 0; p < a.w * a.h; p++) {
    for (var i = 0; i < 3; i++) {
      px[p * 4 + i] = ((a.px[p * 4 + i] - b.px[p * 4 + i]).abs() * 6).clamp(
        0,
        255,
      );
    }
    px[p * 4 + 3] = 255;
  }
  return _Shot(px, a.w, a.h);
}

/// Anteil des Bilds, den eine Ebene wirklich ändert (Hülle, in %).
String _footprint(_Shot base, _Shot layer) {
  var x0 = layer.w, y0 = layer.h, x1 = -1, y1 = -1, count = 0;
  for (var y = 0; y < layer.h; y++) {
    for (var x = 0; x < layer.w; x++) {
      final p = (y * layer.w + x) * 4;
      var m = 0;
      for (var i = 0; i < 4; i++) {
        m = math.max(m, (layer.px[p + i] - base.px[p + i]).abs());
      }
      if (m <= 2) continue;
      count++;
      x0 = math.min(x0, x);
      y0 = math.min(y0, y);
      x1 = math.max(x1, x);
      y1 = math.max(y1, y);
    }
  }
  if (x1 < 0) return 'keine Änderung';
  final box = (x1 - x0 + 1) * (y1 - y0 + 1);
  final all = layer.w * layer.h;
  return 'Hülle ${(100 * box / all).toStringAsFixed(1)} %, '
      'Pixel ${(100 * count / all).toStringAsFixed(1)} %';
}

class _View {
  const _View(this.name, this.cam, {this.raised, this.room, this.dark = true});
  final String name;
  final OrbitCamera cam;
  final Set<String>? raised;
  final String? room;
  final bool dark;
}

void main() {
  Scene3DSupport.debugOverride = true;
  testWidgets('Lichtebenen', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    final scene = sampleScene();
    final views = [
      // „2D“: flach von oben.
      const _View('flach', OrbitCamera(), raised: {}),
      const _View('iso', OrbitCamera(yaw: -0.5, pitch: 0.95)),
      const _View('iso_tag', OrbitCamera(yaw: -0.5, pitch: 0.95), dark: false),
      const _View(
        'raum_arbeiten',
        OrbitCamera(yaw: 0.4, pitch: 1.0),
        room: 'arbeiten',
      ),
    ];
    final tests = <String, Map<String, LampState>>{
      // Zwei Räume, warm gedimmt und farbig.
      'zwei': {
        'licht_wohnen': const LampState(brightness: 0.6),
        'licht_arbeiten_rot': const LampState(color: Color(0xFFFF4D6D)),
      },
      // Drei Lampen im selben Raum.
      'ein_raum': {
        'licht_arbeiten_rot': const LampState(color: Color(0xFFFF4D6D)),
        'licht_arbeiten_blau': const LampState(color: Color(0xFF4D8DFF)),
        'licht_arbeiten_gruen': const LampState(
          brightness: 0.8,
          color: Color(0xFF5DFF8A),
        ),
      },
      // Andere Farben und Helligkeiten als in den Ebenen (dort Weiß).
      'farben': {
        'licht_wohnen': const LampState(
          brightness: 0.3,
          color: Color(0xFF7AA8FF),
        ),
        'licht_kueche': const LampState(color: Color(0xFFFF8A3D)),
        'licht_arbeiten_blau': const LampState(brightness: 0.15),
      },
      // Alles an wie in der Beispielwohnung.
      'alle': {
        for (final m in scene.markers)
          if (m.lamp != null) m.id: m.lamp!,
      },
    };

    for (final v in views) {
      final key = GlobalKey();
      final ctrl = SceneController(v.cam);
      void only(Map<String, LampState> on) {
        for (final id in _lamps) {
          ctrl.setLamp(id, on[id] ?? LampState.off);
        }
      }

      only(const {});
      _exposure = v.dark ? 1 : 0.5;
      ctrl.exposure = _exposure;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: key,
            child: Scene3DView(
              key: ValueKey(v.name),
              scene: scene,
              controller: ctrl,
              style: v.dark ? SceneStyle.dark() : SceneStyle.light(),
              raisedRooms: v.raised,
              focusRoomId: v.room,
            ),
          ),
        ),
      );
      await _settle(tester, frames: 50);
      final base = await _grab(tester, key);
      await _png(tester, '${v.name}/grund', base);

      // Je Raum: an, aber (fast) ohne Licht.
      final roomOf = {for (final id in _lamps) id: scene.markerRoom[id]!};
      final lit = <String, _Shot>{};
      for (final room in {...roomOf.values}) {
        final id = _lamps.firstWhere((l) => roomOf[l] == room);
        only({id: const LampState(brightness: 1e-4, color: Color(0xFFFFFFFF))});
        await _settle(tester);
        lit[room] = await _grab(tester, key);
      }
      final layers = <String, _Shot>{};
      for (final id in _lamps) {
        only({id: _white});
        await _settle(tester);
        layers[id] = await _grab(tester, key);
        await _png(tester, '${v.name}/ebene_$id', layers[id]!);
      }
      // ignore: avoid_print
      print('\n== ${v.name} (${base.w}×${base.h}) ==');
      for (final id in _lamps) {
        // ignore: avoid_print
        print('  Ebene $id: ${_footprint(base, layers[id]!)}');
      }

      ctrl.exposure = 1;
      for (final t in tests.entries) {
        only(t.value);
        await _settle(tester);
        final real = await _grab(tester, key);
        await _png(tester, '${v.name}/${t.key}_echt', real);
        final sw2 = Stopwatch()..start();
        final comp = _compose(base, lit, layers, roomOf, t.value);
        sw2.stop();
        // ignore: avoid_print
        print(
          '  ${t.key.padRight(9)} ${_stats(real, comp)}  '
          '(${sw2.elapsedMilliseconds} ms in Dart)',
        );
        await _png(tester, '${v.name}/${t.key}_zusammen', comp);
        await _png(tester, '${v.name}/${t.key}_diff6x', _diff(real, comp));
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
  }, timeout: const Timeout(Duration(minutes: 10)));

  // Bodenlicht (gebaken) kommt im selben Bild wie das Licht auf Wänden und
  // Möbeln (Echtzeit), nicht erst, wenn die Ansicht zur Ruhe kommt.
  testWidgets('Bodenlicht gleichzeitig', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    final key = GlobalKey();
    final ctrl = SceneController(const OrbitCamera(yaw: 0.4, pitch: 1.0));
    for (final id in _lamps) {
      ctrl.setLamp(id, LampState.off);
    }
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: key,
          child: Scene3DView(
            scene: sampleScene(),
            controller: ctrl,
            style: SceneStyle.dark(),
            focusRoomId: 'arbeiten',
          ),
        ),
      ),
    );
    await _settle(tester, frames: 50);
    for (final id in ['licht_arbeiten_blau', 'licht_arbeiten_rot']) {
      ctrl.setLamp(id, const LampState());
      await tester.pump(const Duration(milliseconds: 16));
      final first = await _grab(tester, key);
      await _settle(tester);
      final later = await _grab(tester, key);
      var worst = 0;
      for (var i = 0; i < first.px.length; i++) {
        worst = math.max(worst, (first.px[i] - later.px[i]).abs());
      }
      // ignore: avoid_print
      print('$id: erstes Bild vs. später, größte Abweichung $worst');
      expect(worst, lessThanOrEqualTo(4), reason: id);
    }
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
