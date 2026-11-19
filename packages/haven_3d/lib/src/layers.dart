import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_scene/scene.dart' as fs;

import 'camera.dart';
import 'gpu_scene.dart';
import 'quality.dart';
import 'scene.dart';
import 'style.dart';

// Lichtebenen: fertige Bilder der Wohnung für Widgets und Displays, ohne
// GPU beim Zeigen. Je Perspektive und Design entstehen
//   * ein Grundbild (alle Lampen aus),
//   * je Raum mit Lampen ein Ausschnitt „Raum an, ohne Licht“ (die
//     Möbellinien blenden in hellen Räumen aus, an/aus je Raum),
//   * je Lampe ein Ausschnitt mit nur dieser Lampe in gedämpftem Weiß.
// Ein Server setzt daraus jeden Lichtzustand zusammen (Licht ist additiv):
//   start = Grundbild, darin die Raumausschnitte der hellen Räume
//   hdr   = T⁻¹(start)/e + Σ farbe·helligkeit/gain · (T⁻¹(ebene) − T⁻¹(raum))/e
//   bild  = T(hdr)
// mit T = Tone-Mapping PBR Neutral auf linearem Licht und e = Belichtung.

/// Version des Formats (siehe [LayerSet.meta]).
const int kLayerFormat = 1;

/// Standard-Helligkeit der Lampen in den Ebenen: bei voller Helligkeit
/// brennen Lichtflecke aus (Weiß lässt sich nicht zurückrechnen), zu wenig
/// verliert Genauigkeit (8 Bit, beim Zusammensetzen ×1/gain).
const double kLayerGain = 0.25;

/// Eine Perspektive für fertige Bilder.
@immutable
class LayerView {
  const LayerView({
    required this.id,
    this.name,
    this.yaw = 0,
    this.pitch = 0,
    this.roomId,
    this.flat = false,
    this.width = 1024,
    this.height = 768,
    this.padding = 24,
  });

  final String id;

  /// Anzeigename (z. B. für die Bild-Entity in Home Assistant).
  final String? name;
  final double yaw;
  final double pitch;

  /// Nur dieser Raum (die anderen ausgeblendet), eingepasst auf ihn.
  final String? roomId;

  /// Alle Räume flach (Draufsicht wie die 2D-Karte).
  final bool flat;
  final int width;
  final int height;
  final double padding;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name ?? id,
    'yaw': yaw,
    'pitch': pitch,
    'room': roomId,
    'flat': flat,
    'width': width,
    'height': height,
  };

  @override
  bool operator ==(Object other) =>
      other is LayerView &&
      other.id == id &&
      other.name == name &&
      other.yaw == yaw &&
      other.pitch == pitch &&
      other.roomId == roomId &&
      other.flat == flat &&
      other.width == width &&
      other.height == height &&
      other.padding == padding;

  @override
  int get hashCode =>
      Object.hash(id, name, yaw, pitch, roomId, flat, width, height, padding);
}

/// Ein Design der fertigen Bilder.
@immutable
class LayerTheme {
  const LayerTheme(
    this.id,
    this.style, {
    this.exposure = 1,
    this.gain = kLayerGain,
  });

  final String id;
  final SceneStyle style;

  /// Belichtung vor dem Tone-Mapping. Helle Designs unter 1, sonst brennen
  /// helle Böden schon ohne Lampe fast aus.
  final double exposure;

  /// Helligkeit der Lampen in den Ebenen (siehe [kLayerGain]). Mit geringer
  /// Belichtung höher, damit das Licht genug 8-Bit-Stufen behält.
  final double gain;

  static final light = LayerTheme(
    'light',
    opaque(SceneStyle.light()),
    exposure: 0.5,
    gain: 0.5,
  );
  // Dunkel wie die Karte im dunklen Design ohne Himmel.
  static final dark = LayerTheme('dark', opaque(SceneStyle.evening()));

  /// Für fertige Bilder: Wände und Böden deckend. Wände zur Kamera hin
  /// schneidet die Szene weiter weg (man sieht hinein), alle anderen
  /// verdecken, was dahinter liegt. So hat das Bild keine halbdurchsichtigen
  /// Flächen, und das Zusammensetzen bleibt genau.
  static SceneStyle opaque(SceneStyle s) =>
      s.copyWith(wallOpacity: 1, floorOpacity: 1);
}

/// Ausschnitt (PNG, RGBA ohne Vormultiplikation) an seiner Stelle im Bild.
@immutable
class LayerPatch {
  const LayerPatch(this.x, this.y, this.width, this.height, this.png);
  final int x, y, width, height;
  final Uint8List png;

  Map<String, Object?> toJson() => {'x': x, 'y': y, 'w': width, 'h': height};
}

/// Alle Bilder einer Perspektive in einem Design.
class LayerSet {
  LayerSet({
    required this.view,
    required this.theme,
    required this.exposure,
    required this.gain,
    required this.base,
    required this.rooms,
    required this.lamps,
    required this.lampRooms,
  });

  final LayerView view;
  final String theme;
  final double exposure;

  /// Helligkeit der Lampen in [lamps] (weißes Licht).
  final double gain;

  /// Grundbild (PNG), alle Lampen aus.
  final Uint8List base;

  /// Raum-ID → „Raum an, ohne Licht“.
  final Map<String, LayerPatch> rooms;

  /// Lampen-ID → nur diese Lampe, weiß mit [gain].
  final Map<String, LayerPatch> lamps;

  /// Lampen-ID → Raum ihrer Möbellinien (`null`: draußen). Auch Lampen ohne
  /// sichtbare Wirkung (dann ohne Eintrag in [lamps]).
  final Map<String, String?> lampRooms;

  /// Beschreibung für den Server (ohne die Bilder).
  Map<String, Object?> meta() => {
    'format': kLayerFormat,
    'view': view.toJson(),
    'theme': theme,
    'width': view.width,
    'height': view.height,
    'exposure': exposure,
    'gain': gain,
    'tone': 'pbr_neutral',
    'rooms': {for (final e in rooms.entries) e.key: e.value.toJson()},
    'lamps': {
      for (final e in lampRooms.entries)
        e.key: {...?lamps[e.key]?.toJson(), 'room': e.value},
    },
  };

  /// Größe aller Bilder in Bytes.
  int get bytes =>
      base.length +
      rooms.values.fold<int>(0, (a, p) => a + p.png.length) +
      lamps.values.fold<int>(0, (a, p) => a + p.png.length);
}

/// Fortschritt: [done] von [total] Bildern, [roomId] der Raum, der gerade
/// entsteht (`null`: Grundbild oder Vorbereitung).
typedef LayerProgress = void Function(int done, int total, String? roomId);

/// Rendert [LayerSet]s ohne sichtbares Widget (eigene Szene, nicht die der
/// Karte). Einmal gebaken für alle Perspektiven und Designs.
class LayerRenderer {
  LayerRenderer(
    this.scene, {
    this.quality = SceneQuality.high,
    List<LayerTheme>? themes,
  }) : themes = themes ?? [LayerTheme.light, LayerTheme.dark];

  final Scene scene;
  final SceneQuality quality;
  final List<LayerTheme> themes;

  bool _cancelled = false;

  /// Abbrechen: [render] endet nach dem laufenden Bild mit [LayerCancelled].
  void cancel() => _cancelled = true;

  /// Szene mit eingepassten Räumen wie in der Karte (Lampen-Räume und
  /// Lichtzonen gelten dort).
  late final Scene _fitted = scene.fittedToRooms(
    inset: themes.first.style.roomGap / 2,
    radius: themes.first.style.roomRadius,
  );

  late final List<String> _allLamps = [
    for (final m in _fitted.markers)
      if (m.lamp != null) m.id,
  ];

  /// Lampen, die in [v] wirken können: alle, in einem Raum nur die seiner
  /// Lichtzone (Licht geht nur durch offene Wände und Türen).
  List<String> lampsFor(LayerView v) {
    final room = v.roomId;
    if (room == null) return _allLamps;
    final zone = _fitted.lightZones[room];
    return [
      for (final id in _allLamps)
        if (_fitted.markerRoom[id] case final r?)
          if (r == room || (zone != null && _fitted.lightZones[r] == zone)) id,
    ];
  }

  /// Räume mit Lampen in [v], deren Möbellinien ausblenden können.
  List<String> roomsFor(LayerView v) => {
    for (final id in lampsFor(v))
      if (_fitted.markerRoom[id] case final r?)
        if (v.roomId == null || r == v.roomId) r,
  }.toList();

  /// Anzahl der Bilder für [views] (für den Fortschritt).
  int steps(List<LayerView> views) =>
      1 +
      themes.length *
          views.fold(
            0,
            (a, v) => a + 1 + roomsFor(v).length + lampsFor(v).length,
          );

  Future<List<LayerSet>> render(
    List<LayerView> views, {
    LayerProgress? onProgress,
  }) async {
    final total = steps(views);
    var done = 0;
    void tick(String? room) => onProgress?.call(++done, total, room);
    onProgress?.call(0, total, null);

    await fs.Scene.initializeStaticResources();
    final fitted = _fitted;
    final gpu = GpuScene(
      fitted,
      themes.first.style,
      quality: quality,
      deferBake: true,
    )..instantLight = true;
    // Immer neu rendern: sonst zeigt flutter_scene das vorige Bild, solange
    // die GPU noch an einem arbeitet (Bildrate der Karte, hier schädlich).
    gpu.scene.maxGpuFramesInFlight = 0;
    for (final id in _allLamps) {
      gpu.setLamp(id, LampState.off);
    }
    await gpu.bakeInBackground();
    tick(null);

    final out = <LayerSet>[];
    for (final theme in themes) {
      gpu.restyle(theme.style);
      gpu.scene.exposure = theme.exposure;
      for (final v in views) {
        _check();
        out.add(await _renderView(gpu, fitted, v, theme, tick));
      }
    }
    return out;
  }

  void _check() {
    if (_cancelled) throw const LayerCancelled();
  }

  Future<LayerSet> _renderView(
    GpuScene gpu,
    Scene fitted,
    LayerView v,
    LayerTheme theme,
    void Function(String?) tick,
  ) async {
    final size = ui.Size(v.width.toDouble(), v.height.toDouble());
    final cam = OrbitCamera(
      yaw: v.yaw,
      pitch: v.pitch,
    ).fit(fitted.points(roomId: v.roomId), size, padding: v.padding);
    final heights = {for (final r in fitted.rooms) r.id: v.flat ? 0.0 : 1.0};
    final lamps = lampsFor(v);
    final rooms = roomsFor(v);

    Future<(Uint8List, ui.Image)> shot(Map<String, LampState> on) async {
      _check();
      for (final id in _allLamps) {
        gpu.setLamp(id, on[id] ?? LampState.off);
      }
      while (gpu.flushLight(budget: const Duration(milliseconds: 30))) {
        await Future<void>.delayed(Duration.zero);
      }
      gpu.sync(cam, focusRoomId: v.roomId, heights: heights, size: size);
      final rec = ui.PictureRecorder();
      gpu.scene.render(
        fsCamera(cam, size),
        ui.Canvas(rec),
        viewport: ui.Offset.zero & size,
        pixelRatio: 1,
      );
      final pic = rec.endRecording();
      final img = await pic.toImage(v.width, v.height);
      pic.dispose();
      final px = await img.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      // Der Oberfläche Luft lassen (Fortschritt, Animation).
      await Future<void>.delayed(Duration.zero);
      return (px!.buffer.asUint8List(), img);
    }

    final (basePx, baseImg) = await shot(const {});
    final basePng = (await baseImg.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    baseImg.dispose();
    tick(null);

    // Raum an, (fast) ohne Licht: nur die Möbellinien ändern sich.
    final roomPatches = <String, LayerPatch>{};
    final roomPx = <String, Uint8List>{};
    for (final room in rooms) {
      final id = lamps.firstWhere((l) => fitted.markerRoom[l] == room);
      final (px, img) = await shot({
        id: const LampState(brightness: 1e-4, color: ui.Color(0xFFFFFFFF)),
      });
      roomPx[room] = px;
      final p = await _patch(img, px, basePx, threshold: 0);
      img.dispose();
      if (p != null) roomPatches[room] = p;
      tick(room);
    }

    final lampPatches = <String, LayerPatch>{};
    final lampRooms = <String, String?>{};
    for (final id in lamps) {
      final room = fitted.markerRoom[id];
      lampRooms[id] = room;
      final (px, img) = await shot({
        id: LampState(
          brightness: theme.gain,
          color: const ui.Color(0xFFFFFFFF),
        ),
      });
      final ref = roomPx[room] ?? basePx;
      final p = await _patch(img, px, ref, threshold: 1);
      img.dispose();
      if (p != null) lampPatches[id] = p;
      tick(room);
    }
    return LayerSet(
      view: v,
      theme: theme.id,
      exposure: theme.exposure,
      gain: theme.gain,
      base: basePng,
      rooms: roomPatches,
      lamps: lampPatches,
      lampRooms: lampRooms,
    );
  }

  /// Ausschnitt von [img] (Pixel [a]), wo es sich von [ref] um mehr als
  /// [threshold] Stufen unterscheidet; `null` ohne Unterschied.
  ///
  /// Zugeschnitten wird in der Engine: rohe Pixel über
  /// `ImageDescriptor.raw` gelten dort als vormultipliziert, halb
  /// durchsichtige Wände kämen so zu hell ins PNG.
  static Future<LayerPatch?> _patch(
    ui.Image img,
    Uint8List a,
    Uint8List ref, {
    required int threshold,
  }) async {
    final box = diffBox(a, ref, img.width, img.height, threshold: threshold);
    if (box == null) return null;
    final (x0, y0, x1, y1) = box;
    final cw = x1 - x0 + 1, ch = y1 - y0 + 1;
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawImageRect(
      img,
      ui.Rect.fromLTWH(
        x0.toDouble(),
        y0.toDouble(),
        cw.toDouble(),
        ch.toDouble(),
      ),
      ui.Rect.fromLTWH(0, 0, cw.toDouble(), ch.toDouble()),
      ui.Paint()
        ..blendMode = ui.BlendMode.src
        ..filterQuality = ui.FilterQuality.none,
    );
    final pic = rec.endRecording();
    final crop = await pic.toImage(cw, ch);
    pic.dispose();
    final png = await crop.toByteData(format: ui.ImageByteFormat.png);
    crop.dispose();
    return LayerPatch(x0, y0, cw, ch, png!.buffer.asUint8List());
  }
}

/// [render] wurde mit [LayerRenderer.cancel] abgebrochen.
class LayerCancelled implements Exception {
  const LayerCancelled();
  @override
  String toString() => 'Abgebrochen';
}

/// Hülle (x0, y0, x1, y1, inklusive) der Pixel, in denen sich [a] und [b]
/// (RGBA, [w]×[h]) in einem Kanal um mehr als [threshold] unterscheiden.
@visibleForTesting
(int, int, int, int)? diffBox(
  Uint8List a,
  Uint8List b,
  int w,
  int h, {
  int threshold = 0,
}) {
  var x0 = w, y0 = h, x1 = -1, y1 = -1;
  for (var y = 0; y < h; y++) {
    final row = y * w * 4;
    for (var x = 0; x < w; x++) {
      final i = row + x * 4;
      if ((a[i] - b[i]).abs() > threshold ||
          (a[i + 1] - b[i + 1]).abs() > threshold ||
          (a[i + 2] - b[i + 2]).abs() > threshold ||
          (a[i + 3] - b[i + 3]).abs() > threshold) {
        x0 = math.min(x0, x);
        x1 = math.max(x1, x);
        y0 = math.min(y0, y);
        y1 = math.max(y1, y);
      }
    }
  }
  return x1 < 0 ? null : (x0, y0, x1, y1);
}
