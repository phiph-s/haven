import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'scene.dart';

// Lichtebenen live zeichnen (Raumkacheln, Vorschau): ein Fragment-Shader
// setzt Grundbild, „Raum an“ und die Lampen auf der GPU zusammen, mit
// derselben Rechnung wie der Server (render_compose.py). Farbe und
// Helligkeit sind nur Faktoren, also lassen sich Übergänge animieren.

/// Höchstens so viele Lampen je Bild (Slots im Shader).
const int kLayerShaderLamps = 8;

/// Faktor einer Lampe je Kanal (linear, mit Helligkeit und gain).
typedef LayerFactor = ({double r, double g, double b});

/// Faktor für Lampe [s] in einem Satz mit [gain]; [fade] blendet sie ein
/// (0 aus … 1 voll).
LayerFactor layerFactor(LampState s, double gain, {double fade = 1}) {
  if (!s.on || s.brightness <= 0 || fade <= 0) return (r: 0, g: 0, b: 0);
  final k = s.brightness / gain * fade;
  double lin(double c) =>
      c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  return (r: lin(s.color.r) * k, g: lin(s.color.g) * k, b: lin(s.color.b) * k);
}

/// Ausschnitt einer Lampe: wo im Bild, ihr Bild und der Raum ihrer
/// Möbellinien.
class LayerLamp {
  const LayerLamp(this.id, this.rect, this.image, this.room);
  final String id;
  final ui.Rect rect;
  final ui.Image image;
  final String? room;
}

/// Ein Bildsatz als Texturen (siehe `LayerSet`).
class LayerImages {
  LayerImages._({
    required this.width,
    required this.height,
    required this.exposure,
    required this.gain,
    required this.viewRoom,
    required this.base,
    required this.lit,
    required this.lamps,
    required this.lampRooms,
  });

  final int width;
  final int height;
  final double exposure;
  final double gain;

  /// Raum der Perspektive (`null`: Übersicht).
  final String? viewRoom;

  /// Alle Lampen aus.
  final ui.Image base;

  /// Grundbild mit „Raum an“ des Raums der Perspektive (ohne: [base]).
  final ui.Image lit;
  final List<LayerLamp> lamps;

  /// Alle Lampen der Perspektive mit ihrem Raum (auch ohne Ausschnitt).
  final Map<String, String?> lampRooms;

  double get aspect => width / height;

  /// Aus den Dateien eines Satzes: [meta] (`meta.json`), [base] und die
  /// PNGs je Raum ([rooms]) und Lampe ([lamps]).
  static Future<LayerImages> decode({
    required Map<String, dynamic> meta,
    required Uint8List base,
    Map<String, Uint8List> rooms = const {},
    Map<String, Uint8List> lamps = const {},
  }) async {
    final w = (meta['width'] as num).toInt();
    final h = (meta['height'] as num).toInt();
    final view = (meta['view'] as Map?) ?? const {};
    final viewRoom = view['room'] as String?;
    final baseImg = await _decode(base);
    var lit = baseImg;
    final roomMeta = (meta['rooms'] as Map?) ?? const {};
    final patch = viewRoom == null ? null : rooms[viewRoom];
    final box = viewRoom == null ? null : roomMeta[viewRoom] as Map?;
    if (patch != null && box != null) {
      lit = await _withPatch(baseImg, await _decode(patch), box);
    }
    final lampMeta = (meta['lamps'] as Map?) ?? const {};
    final out = <LayerLamp>[];
    final lampRooms = <String, String?>{};
    for (final e in lampMeta.entries) {
      final id = '${e.key}';
      final m = Map<String, dynamic>.from(e.value as Map);
      lampRooms[id] = m['room'] as String?;
      final png = lamps[id];
      if (png == null || m['x'] == null) continue;
      out.add(
        LayerLamp(
          id,
          ui.Rect.fromLTWH(
            (m['x'] as num).toDouble(),
            (m['y'] as num).toDouble(),
            (m['w'] as num).toDouble(),
            (m['h'] as num).toDouble(),
          ),
          await _decode(png),
          m['room'] as String?,
        ),
      );
    }
    return LayerImages._(
      width: w,
      height: h,
      exposure: (meta['exposure'] as num?)?.toDouble() ?? 1,
      gain: (meta['gain'] as num?)?.toDouble() ?? 0.25,
      viewRoom: viewRoom,
      base: baseImg,
      lit: lit,
      lamps: out,
      lampRooms: lampRooms,
    );
  }

  void dispose() {
    if (!identical(lit, base)) lit.dispose();
    base.dispose();
    for (final l in lamps) {
      l.image.dispose();
    }
  }

  static Future<ui.Image> _decode(Uint8List png) async {
    final codec = await ui.instantiateImageCodec(png);
    final img = (await codec.getNextFrame()).image;
    codec.dispose();
    return img;
  }

  /// [base] mit dem Raumausschnitt [patch] bei [box], nur wo er sich vom
  /// Grundbild unterscheidet (wie beim Server).
  static Future<ui.Image> _withPatch(
    ui.Image base,
    ui.Image patch,
    Map<dynamic, dynamic> box,
  ) async {
    final b = (await base.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    ))!.buffer.asUint8List();
    final p = (await patch.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    ))!.buffer.asUint8List();
    patch.dispose();
    final out = Uint8List.fromList(b);
    final x0 = (box['x'] as num).toInt(), y0 = (box['y'] as num).toInt();
    final pw = (box['w'] as num).toInt(), ph = (box['h'] as num).toInt();
    for (var y = 0; y < ph; y++) {
      for (var x = 0; x < pw; x++) {
        final s = (y * pw + x) * 4, t = ((y0 + y) * base.width + x0 + x) * 4;
        if (p[s] != b[t] ||
            p[s + 1] != b[t + 1] ||
            p[s + 2] != b[t + 2] ||
            p[s + 3] != b[t + 3]) {
          out.setRange(t, t + 4, p, s);
        }
      }
    }
    final buf = await ui.ImmutableBuffer.fromUint8List(out);
    final desc = ui.ImageDescriptor.raw(
      buf,
      width: base.width,
      height: base.height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await desc.instantiateCodec();
    final img = (await codec.getNextFrame()).image;
    codec.dispose();
    desc.dispose();
    buf.dispose();
    return img;
  }
}

/// Der Shader (einmal geladen).
class LayerShader {
  LayerShader._();

  static Future<ui.FragmentProgram>? _program;

  static Future<ui.FragmentProgram> program() => _program ??= () async {
    try {
      return await ui.FragmentProgram.fromAsset(
        'packages/haven_3d/shaders/layers.frag',
      );
    } catch (_) {
      // Tests im Paket selbst: ohne Paketpräfix.
      return ui.FragmentProgram.fromAsset('shaders/layers.frag');
    }
  }();
}

/// [images] in [dst] zeichnen, Lampen mit [factors] (Lampen-ID → Faktor,
/// fehlende sind aus). Mehr als [kLayerShaderLamps] Lampen: die hellsten.
void paintLayers(
  ui.Canvas canvas,
  ui.Rect dst,
  LayerImages images,
  ui.FragmentShader shader,
  Map<String, LayerFactor> factors,
) {
  double sum(LayerFactor f) => f.r + f.g + f.b;
  final on = [
    for (final l in images.lamps)
      if (factors[l.id] case final f? when sum(f) > 0) (l, f),
  ]..sort((a, b) => sum(b.$2).compareTo(sum(a.$2)));
  final used = on.take(kLayerShaderLamps).toList();
  // Möbellinien aus, sobald eine Lampe des Raums der Perspektive brennt.
  final lit = factors.entries.any(
    (e) =>
        sum(e.value) > 0 &&
        images.viewRoom != null &&
        images.lampRooms[e.key] == images.viewRoom,
  );
  var i = 0;
  void f(double v) => shader.setFloat(i++, v);
  f(dst.left);
  f(dst.top);
  f(dst.width);
  f(dst.height);
  f(images.width.toDouble());
  f(images.height.toDouble());
  f(images.exposure);
  f(lit ? 1 : 0);
  f(used.length.toDouble());
  for (var k = 0; k < kLayerShaderLamps; k++) {
    final r = k < used.length ? used[k].$1.rect : ui.Rect.zero;
    f(r.left);
    f(r.top);
    f(math.max(r.width, 1));
    f(math.max(r.height, 1));
  }
  for (var k = 0; k < kLayerShaderLamps; k++) {
    final l = k < used.length ? used[k] : null;
    f(l?.$2.r ?? 0);
    f(l?.$2.g ?? 0);
    f(l?.$2.b ?? 0);
    f(l != null && lit && l.$1.room == images.viewRoom ? 1 : 0);
  }
  shader.setImageSampler(0, images.base);
  shader.setImageSampler(1, images.lit);
  for (var k = 0; k < kLayerShaderLamps; k++) {
    shader.setImageSampler(
      2 + k,
      k < used.length ? used[k].$1.image : images.base,
    );
  }
  canvas.drawRect(dst, ui.Paint()..shader = shader);
}

/// Rechteck für ein Bild mit [aspect] in [box], ganz sichtbar
/// (`BoxFit.contain`), [alignY] -1 oben … 1 unten.
ui.Rect containRect(ui.Rect box, double aspect, {double alignY = 0}) {
  var w = box.width, h = w / aspect;
  if (h > box.height) {
    h = box.height;
    w = h * aspect;
  }
  final x = box.left + (box.width - w) / 2;
  final y = box.top + (box.height - h) * (alignY + 1) / 2;
  return ui.Rect.fromLTWH(x, y, w, h);
}
