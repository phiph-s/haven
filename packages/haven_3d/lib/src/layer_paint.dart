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
    required this.lampPoints,
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

  /// Lampen-ID → Lage im Bild (Pixel): aus dem Satz oder, bei älteren
  /// Sätzen, die Mitte des Lampenausschnitts.
  final Map<String, ui.Offset> lampPoints;

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
    final points = <String, ui.Offset>{};
    for (final e in lampMeta.entries) {
      final id = '${e.key}';
      final m = Map<String, dynamic>.from(e.value as Map);
      lampRooms[id] = m['room'] as String?;
      if (m['px'] is num && m['py'] is num) {
        points[id] = ui.Offset(
          (m['px'] as num).toDouble(),
          (m['py'] as num).toDouble(),
        );
      } else if (m['x'] is num) {
        points[id] = ui.Offset(
          (m['x'] as num) + (m['w'] as num) / 2,
          (m['y'] as num) + (m['h'] as num) / 2,
        );
      }
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
      lampPoints: points,
    );
  }

  bool _disposed = false;

  /// Freigegeben: nicht mehr zeichnen.
  bool get disposed => _disposed;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
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
    if (!kIsWeb) return img;
    // Im Browser (CanvasKit) sind dekodierte Bilder „lazy“ GPU-Texturen:
    // die Quelle wird nach dem ersten Hochladen freigegeben und kann
    // danach nicht erneut hochgeladen werden (Bild fehlt oder zeigt
    // Speichermüll). Aus Pixeln gebaute Bilder hält CanvasKit selbst.
    final px = (await img.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
    final w = img.width, h = img.height;
    img.dispose();
    return _fromPixels(px, w, h);
  }

  /// Bild aus vormultiplizierten RGBA-Pixeln.
  static Future<ui.Image> _fromPixels(Uint8List px, int w, int h) async {
    final buf = await ui.ImmutableBuffer.fromUint8List(px);
    final desc = ui.ImageDescriptor.raw(
      buf,
      width: w,
      height: h,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await desc.instantiateCodec();
    final img = (await codec.getNextFrame()).image;
    codec.dispose();
    desc.dispose();
    buf.dispose();
    return img;
  }

  /// [base] mit dem Raumausschnitt [patch] bei [box] (wie beim Server).
  /// Auf der GPU gezeichnet: aus Rohpixeln gebaute Bilder kamen auf manchen
  /// Handys (Mali, Vulkan) mit Speichermüll an.
  static Future<ui.Image> _withPatch(
    ui.Image base,
    ui.Image patch,
    Map<dynamic, dynamic> box,
  ) async {
    final rec = ui.PictureRecorder();
    final c = ui.Canvas(rec);
    final none = ui.Paint()
      ..blendMode = ui.BlendMode.src
      ..filterQuality = ui.FilterQuality.none;
    c.drawImage(base, ui.Offset.zero, none);
    c.drawImageRect(
      patch,
      ui.Rect.fromLTWH(0, 0, patch.width.toDouble(), patch.height.toDouble()),
      ui.Rect.fromLTWH(
        (box['x'] as num).toDouble(),
        (box['y'] as num).toDouble(),
        patch.width.toDouble(),
        patch.height.toDouble(),
      ),
      none,
    );
    final pic = rec.endRecording();
    final img = await pic.toImage(base.width, base.height);
    pic.dispose();
    patch.dispose();
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
/// Verkleinert wird mit Mipmaps ([filter]), sonst flimmern die Kanten.
void paintLayers(
  ui.Canvas canvas,
  ui.Rect dst,
  LayerImages images,
  ui.FragmentShader shader,
  Map<String, LayerFactor> factors, {
  ui.FilterQuality filter = ui.FilterQuality.medium,
}) {
  if (images.disposed) return;
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
  shader.setImageSampler(0, images.base, filterQuality: filter);
  shader.setImageSampler(1, images.lit, filterQuality: filter);
  for (var k = 0; k < kLayerShaderLamps; k++) {
    shader.setImageSampler(
      2 + k,
      k < used.length ? used[k].$1.image : images.base,
      filterQuality: filter,
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

/// Lichtschein hinter dem Bild: je brennender Lampe des Raums der
/// Perspektive ein weicher Fleck in ihrer Farbe an ihrer Stelle (darf über
/// [dst] hinausreichen). [factors] wie bei [paintLayers], [strength] 0 … 1.
void paintLampGlows(
  ui.Canvas canvas,
  ui.Rect dst,
  LayerImages images,
  Map<String, LayerFactor> factors, {
  double strength = 1,
}) {
  if (strength <= 0) return;
  final scale = dst.width / images.width;
  double srgb(double l) => l <= 0.0031308
      ? l * 12.92
      : 1.055 * math.pow(l, 1 / 2.4).toDouble() - 0.055;
  for (final e in factors.entries) {
    final room = images.lampRooms[e.key];
    if (images.viewRoom != null && room != images.viewRoom) continue;
    final p = images.lampPoints[e.key];
    if (p == null) continue;
    final f = e.value;
    final peak = math.max(f.r, math.max(f.g, f.b));
    if (peak <= 0) continue;
    // Faktor = Farbe (linear) · Helligkeit / gain.
    final level = (peak * images.gain).clamp(0.0, 1.0);
    final c = ui.Color.from(
      alpha: 1,
      red: srgb(f.r / peak),
      green: srgb(f.g / peak),
      blue: srgb(f.b / peak),
    );
    final center = dst.topLeft + p * scale;
    final r = dst.shortestSide * (0.34 + 0.22 * level);
    final a = strength * (0.35 + 0.4 * math.sqrt(level));
    canvas.drawCircle(
      center,
      r,
      ui.Paint()
        ..shader = ui.Gradient.radial(
          center,
          r,
          [
            c.withValues(alpha: a),
            c.withValues(alpha: a * 0.35),
            c.withValues(alpha: 0),
          ],
          const [0, 0.45, 1],
        ),
    );
  }
}
