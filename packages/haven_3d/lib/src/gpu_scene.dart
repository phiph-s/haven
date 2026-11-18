import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, Offset, Size;

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import 'camera.dart';
import 'edges.dart';
import 'heatmap.dart';
import 'lightbake.dart';
import 'model.dart';
import 'quality.dart';
import 'scene.dart';
import 'shape.dart';
import 'style.dart';
import 'triangulate.dart';

/// Haven-Koordinaten (x Osten, y Süden, z oben) → flutter_scene (y oben,
/// z Norden). Eine echte Drehung, keine Spiegelung, sonst wäre das Bild
/// seitenverkehrt zu den Overlays. Die Dreiecke werden trotzdem nach den
/// Normalen ausgerichtet, nicht nach der Eckenreihenfolge.
vm.Vector3 toFs(V3 p) => vm.Vector3(p.x, p.z, -p.y);

/// Farbe (sRGB) als lineares RGBA für flutter_scene.
vm.Vector4 linearColor(Color c, [double? alpha]) {
  double lin(double v) =>
      v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return vm.Vector4(lin(c.r), lin(c.g), lin(c.b), alpha ?? c.a);
}

/// Die flutter_scene-Szene zu einer Haven-[Scene]: baut die Knoten einmal
/// und passt je Bild nur Sichtbarkeit (weggeschnittene Wände, Fokus-Raum),
/// Kantenbreite und Auswahl an.
class GpuScene {
  GpuScene(this.source, this.style, {this.quality = SceneQuality.high}) {
    _build();
  }

  /// Qualitätsstufe; ändert sich nur mit einem neuen [GpuScene] (Baking).
  final SceneQuality quality;

  final Scene source;
  SceneStyle style;
  final fs.Scene scene = fs.Scene();

  final List<_WallNode> _walls = [];
  final Map<String, _ObjectNode> _objects = {};
  final Map<String, fs.Node> _roomNodes = {};

  /// Heatmap-Flächen je Raum und die zuletzt gezeigte Heatmap.
  final Map<String, fs.Node> _heatNodes = {};
  SceneHeatmap? _heat;

  /// Akzent-Umrandung je Raum (sichtbar beim gewählten Raum).
  final Map<String, fs.Node> _roomOutlines = {};
  final List<fs.LineSegmentsGeometry> _outlineGeometries = [];
  String? _selectedRoom;
  final List<fs.LineSegmentsGeometry> _edgeGeometries = [];

  static double _smooth(double a, double b, double x) {
    final t = ((x - a) / (b - a)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  final Map<String, fs.PointLightComponent> _lamps = {};
  final Map<String, LampState> _lampState = {};

  /// Gebakenes Lampenlicht: Empfangsflächen (Böden, Möbel-Oberseiten) und
  /// je Fläche die Beleuchtung jeder Lampe im Raum.
  final List<_Receiver> _receivers = [];
  final Map<String, fs.Node> _bulbs = {};
  final Map<String, int> _lampMask = {};
  final Map<String, String?> _bulbRoom = {};
  final Map<String, List<Offset>> _shapes = {};
  final Map<String, List<int>> _roomReceivers = {};
  final Map<String, double> _heights = {};
  String? _lastFadeKey;

  /// Kleinste Höhe flacher Räume (ganz 0 würde Normalen entarten lassen).
  static const double kFlat = 0.02;

  late _Materials _mat;
  String? _focus;
  Set<String> _selected = const {};
  double _edgeScale = -1;

  /// Ausgeblendete Objekte (für den Treffertest).
  Set<String> get hidden => {
    for (final e in _objects.entries)
      if (!e.value.node.visible) e.key,
  };

  /// Lichtkanal (Bit) je Raum: benachbarte Räume bekommen verschiedene
  /// Bits, eine Lampe leuchtet nur in ihrem Kanal. So bleibt Licht im Raum,
  /// ohne Schatten (die flutter_scene nur für vier Punktlichter rechnet).
  late final Map<String, int> _channel = roomChannels(source.rooms);

  int _maskOf(String? roomId) =>
      roomId == null ? kOutsideChannel : _channel[roomId] ?? 0xFF;

  void _build() {
    _mat = _Materials(style);
    _applyLighting();

    // Räume: Boden und Wände entlang des abgerundeten, eingerückten
    // Umrisses (Spalt zwischen Nachbarräumen wie in der 2D-Karte). Der
    // Raumknoten wird für flache Räume in der Höhe gestaucht.
    for (final r in source.rooms) {
      final roomNode = fs.Node(name: 'room:${r.id}');
      _roomNodes[r.id] = roomNode;
      scene.add(roomNode);
      final lines = _mat.lines(r.id);

      final shape = roundedInset(
        r.outline,
        inset: style.roomGap / 2,
        radius: style.roomRadius,
      );
      _shapes[r.id] = shape;
      final floor = [for (final o in shape) V3(o.dx, o.dy, 0)];
      final firstReceiver = _receivers.length;
      roomNode.add(
        _receiverNode(
          'floor:${r.id}',
          floor,
          (s) => s.floor.withValues(alpha: s.floorOpacity),
        ),
      );
      _roomReceivers[r.id] = [firstReceiver];

      final rounded = style.roomRadius > 0;
      final openLines = <Edge3>[];
      for (final w in SceneRoom.wallsAlong(shape, r.wallHeight)) {
        // Offene Wand: nur die Raumgrenze als leise Linie am Boden.
        if (r.isOpenAt(w.points[0].xy, w.points[1].xy)) {
          openLines.add(
            Edge3(
              V3(w.points[0].x, w.points[0].y, 0.012),
              V3(w.points[1].x, w.points[1].y, 0.012),
            ),
          );
          continue;
        }
        final acc = _MeshAcc()..addFace(w, twoSided: true);
        final geo = acc.geometry();
        final normal = fs.Mesh(geo, _mat.wall);
        final node = fs.Node(name: 'wall:${r.id}', mesh: normal)
          ..lightChannelMask = _maskOf(r.id);
        node.shadowCastingMode = fs.ShadowCastingMode.off;
        // Nur die Oberkante: von oben ist sie der Raumumriss (eine Linie,
        // kein doppelter Boden). Senkrechte Ecken nur bei eckigen Räumen.
        node.add(
          _edgesNode('wall-edges', [
            Edge3(w.points[3], w.points[2]),
            if (!rounded) Edge3(w.points[0], w.points[3]),
          ], lines.wall),
        );
        roomNode.add(node);
        _walls.add(
          _WallNode(r, w, node)
            ..normal = normal
            ..selected = fs.Mesh(geo, _mat.wallSelected)
            ..front = fs.Mesh(geo, _mat.wallFront),
        );
      }
      if (openLines.isNotEmpty) {
        roomNode.add(_edgesNode('open-edges', openLines, lines.detail));
      }
    }

    // Akzent-Umrandung je Raum, knapp über dem Boden, breiter als Kanten.
    for (final r in source.rooms) {
      final shape = _shapes[r.id]!;
      final pts = [for (final o in shape) V3(o.dx, o.dy, 0.01)];
      final node = _edgesNode(
        'room-outline:${r.id}',
        [
          for (var i = 0; i < pts.length; i++)
            Edge3(pts[i], pts[(i + 1) % pts.length]),
        ],
        _mat.accentEdge,
        outline: true,
      )..visible = false;
      _roomNodes[r.id]!.add(node);
      _roomOutlines[r.id] = node;
    }

    // Möbel.
    for (final o in source.objects) {
      final roomId = source.objectRoom[o.id];
      final parent = roomId == null ? null : _roomNodes[roomId];
      final node = fs.Node(name: 'object:${o.id}')
        ..lightChannelMask = _maskOf(roomId);
      final byMat = <Mat, _MeshAcc>{};
      final tops = <Face3>[];
      for (final f in o.world.faces) {
        // Waagerechte Oberseiten bekommen gebakenes Lampenlicht (eigene
        // Fläche), der Rest Echtzeitlicht.
        if (roomId != null &&
            !f.twoSided &&
            f.mat != Mat.glass &&
            f.normal.z > 0.95) {
          tops.add(f);
          continue;
        }
        byMat
            .putIfAbsent(f.mat, () => _MeshAcc())
            .addFace(f, twoSided: f.twoSided);
      }
      final parts = [
        for (final e in byMat.entries)
          if (!e.value.isEmpty) (e.value.geometry(), e.key),
      ];
      final mesh = fs.Mesh.primitives(
        primitives: [
          for (final (g, m) in parts) fs.MeshPrimitive(g, _mat.surface(m)),
        ],
      );
      node.mesh = mesh;
      final topPolys = <List<V3>>[];
      for (final f in tops) {
        final z =
            f.points.map((p) => p.z).reduce((a, b) => a + b) / f.points.length;
        final poly = [for (final p in f.points) V3(p.x, p.y, z)];
        topPolys.add(poly);
        _roomReceivers[roomId]!.add(_receivers.length);
        node.add(_receiverNode('top:${o.id}', poly, (s) => s.base(f.mat)));
      }
      // Keine Echtzeit-Schatten: Sonne und Lampen sind auf Böden und
      // Oberseiten gebaken (mit voller Möbelhöhe, auch in flachen Räumen).
      node.shadowCastingMode = fs.ShadowCastingMode.off;
      final lines = _mat.lines(roomId);
      final edges = featureEdges(o.world);
      // Türen und Fenster gehören zur Wand: ihre Linien bleiben auch bei
      // Licht, Möbellinien blenden dann aus.
      final wall = o.wallMounted;
      final normal = _edgesNode(
        'edges',
        edges,
        wall ? lines.structureEdge : lines.edge,
      );
      final accent = _edgesNode('edges-selected', edges, _mat.accentEdge)
        ..visible = false;
      node.add(normal);
      node.add(accent);
      // Detaillinien (Kissen, Fugen, Türaufschlag): leiser als Kanten.
      final details = liftedLines(o.world);
      if (details.isNotEmpty) {
        node.add(
          _edgesNode(
            'details',
            details,
            wall ? lines.structureDetail : lines.detail,
          ),
        );
      }
      (parent ?? scene.root).add(node);
      _objects[o.id] = _ObjectNode(o, roomId, node, normal, accent)
        ..mesh = mesh
        ..parts = parts
        ..tops = topPolys;
    }

    // Leuchten.
    for (final m in source.markers) {
      final lamp = m.lamp;
      if (m.kind != MarkerKind.light || lamp == null) continue;
      final node = fs.Node(name: 'lamp:${m.id}')..position = toFs(m.position);
      final roomId = source.markerRoom[m.id];
      _lampMask[m.id] = roomId == null ? 0xFF : _maskOf(roomId);
      _lampState[m.id] = lamp;
      final light = fs.PointLightComponent(_pointLight(lamp, _lampMask[m.id]!));
      node.addComponent(light);
      final bulb = fs.Node(
        name: 'bulb:${m.id}',
        mesh: fs.Mesh(fs.SphereGeometry(radius: 0.07), _mat.bulb(lamp)),
      );
      node.add(bulb);
      _lamps[m.id] = light;
      _bulbs[m.id] = bulb;
      _bulbRoom[m.id] = roomId;
      // Nicht im Raumknoten: Lampen bleiben auf Deckenhöhe, auch wenn der
      // Raum flach ist, und beleuchten ihn von oben wie der Lichtschein der
      // 2D-Karte.
      scene.add(node);
    }

    if (quality.bakes) {
      for (final e in _roomReceivers.entries) {
        _bakeRoom(e.key, [for (final i in e.value) _receivers[i]]);
      }
    }
  }

  fs.PointLight _pointLight(LampState s, int mask) => fs.PointLight(
    color: linearColor(s.color).xyz,
    intensity: s.on && quality.realtimeLamps
        ? 40.0 * s.brightness * style.lampGlow
        : 0,
    range: 7,
    // Schatten der Lampen sind gebaken (Böden, Oberseiten); in Echtzeit
    // rechnet flutter_scene sie nur für vier Lampen.
    // Nur der eigene Raum (siehe roomChannels).
    channelMask: mask,
  );

  /// Leuchte [id] umschalten (an/aus, Helligkeit, Farbe): Echtzeitlicht
  /// für Wände und Möbelseiten, gebakenes Licht auf Böden und Oberseiten.
  ///
  /// Das Echtzeitlicht wechselt sofort. Die gebakenen Flächen werden nur
  /// vorgemerkt und in [flushLight] neu gemischt: mehrere Lampen im selben
  /// Bild kosten so je Fläche nur ein Mischen.
  void setLamp(String id, LampState s) {
    final l = _lamps[id];
    if (l == null) return;
    if (_lampState[id] == s) return;
    _lampState[id] = s;
    _applyLamp(id, s);
    for (final r in _receivers) {
      if (r.lamps.containsKey(id)) _dirty.add(r);
    }
  }

  /// Echtzeitlicht und Glühbirne einer Lampe (ohne Baking).
  void _applyLamp(String id, LampState s) {
    _lamps[id]!.light = _pointLight(s, _lampMask[id] ?? 0xFF);
    _bulbs[id]!.mesh = fs.Mesh(_bulbGeometry, _mat.bulb(s));
  }

  late final fs.Geometry _bulbGeometry = fs.SphereGeometry(radius: 0.07);

  /// Vorgemerkte Flächen, die neu gemischt werden müssen (Reihenfolge der
  /// Anmeldung).
  final Set<_Receiver> _dirty = <_Receiver>{};

  /// Gibt es noch vorgemerkte Flächen?
  bool get lightPending => _dirty.isNotEmpty;

  /// Vorgemerkte Flächen neu mischen, höchstens etwa [budget] lang (der
  /// Rest folgt im nächsten Bild). `true`: es bleibt noch etwas übrig.
  bool flushLight({Duration budget = const Duration(milliseconds: 5)}) {
    if (_dirty.isEmpty) return false;
    final sw = Stopwatch()..start();
    while (_dirty.isNotEmpty) {
      final r = _dirty.first;
      _dirty.remove(r);
      _relight(r);
      if (sw.elapsed >= budget) break;
    }
    return _dirty.isNotEmpty;
  }

  /// Gebakene Beleuchtung einer Fläche neu zusammensetzen.
  void _relight(_Receiver r) {
    // Wie das Echtzeitlicht: diffuse Reflexion albedo/π · Intensität · E.
    final k = 40.0 * style.lampGlow / math.pi;
    final albedo = linearColor(r.color(style));
    final parts = <(Float32List, double, double, double)>[];
    // Streulicht: ein Anteil [fill] jeder Quelle kommt ohne Schatten an,
    // in ihrer Farbe. Schatten werden so weicher und nehmen das Licht auf.
    final fill = style.shadowFill.clamp(0.0, 1.0);
    void add(
      Float32List lit,
      Float32List? open,
      double r0,
      double g0,
      double b0,
    ) {
      parts.add((lit, r0 * (1 - fill), g0 * (1 - fill), b0 * (1 - fill)));
      if (open != null && fill > 0) {
        parts.add((open, r0 * fill, g0 * fill, b0 * fill));
      }
    }

    final sun = r.sun;
    if (sun != null && style.sun > 0) {
      final ks = kSunIntensity * style.sun / math.pi;
      add(sun, r.sunOpen, ks * albedo.x, ks * albedo.y, ks * albedo.z);
    }
    for (final e in r.lamps.entries) {
      final s = _lampState[e.key];
      if (s == null || !s.on) continue;
      final c = linearColor(s.color);
      final f = k * s.brightness;
      add(
        e.value,
        r.lampsOpen[e.key],
        c.x * f * albedo.x,
        c.y * f * albedo.y,
        c.z * f * albedo.z,
      );
    }
    final (px, max) = combineLamps(r.bake.width * r.bake.height, parts);
    if (max <= 0) {
      r.material
        ..emissiveTexture = null
        ..emissiveFactor = vm.Vector4.zero();
      return;
    }
    r.material
      ..emissiveTexture = fs.Texture2D.fromPixels(
        px,
        r.bake.width,
        r.bake.height,
      )
      ..emissiveFactor = vm.Vector4(1, 1, 1, 1)
      ..emissiveStrength = max;
  }

  /// Heatmap-Flächen neu aufbauen: je Raum mit Messwerten eine eingefärbte,
  /// unbeleuchtete Fläche über dem Boden.
  void _setHeatmap(SceneHeatmap? h) {
    _heat = h;
    for (final e in _heatNodes.entries) {
      _roomNodes[e.key]?.remove(e.value);
    }
    _heatNodes.clear();
    for (final o in _objects.values) {
      for (final n in o.heat) {
        o.node.remove(n);
      }
      o.heat.clear();
      if (o.mesh != null) o.node.mesh = o.mesh;
    }
    if (h == null) return;
    for (final r in source.rooms) {
      final samples = h.byRoom[r.id];
      if (samples == null || samples.isEmpty) continue;
      final shape = _shapes[r.id]!;
      final node = _heatNode('heat:${r.id}', h, r.id, [
        for (final o in shape) V3(o.dx, o.dy, 0.004),
      ]);
      if (node == null) continue;
      _roomNodes[r.id]!.add(node);
      _heatNodes[r.id] = node;
      // Möbel färben mit: Oberseiten mit derselben Fläche wie der Boden,
      // die Seiten in der Farbe an ihrer Mitte.
      for (final o in _objects.values) {
        if (o.roomId != r.id) continue;
        for (final top in o.tops) {
          final n = _heatNode('heat-top:${o.object.id}', h, r.id, [
            for (final p in top) V3(p.x, p.y, p.z + 0.003),
          ]);
          if (n == null) continue;
          o.node.add(n);
          o.heat.add(n);
        }
        final v = h.valueAt(r.id, o.object.center.xy);
        if (!v.isFinite || o.parts.isEmpty) continue;
        final heat = h.colorOf(v);
        final mix = h.opacity * heat.a * 0.85;
        o.node.mesh = fs.Mesh.primitives(
          primitives: [
            for (final (g, m) in o.parts)
              fs.MeshPrimitive(
                g,
                m == Mat.glass ? _mat.surface(m) : _tinted(m, heat, mix),
              ),
          ],
        );
      }
    }
  }

  fs.PhysicallyBasedMaterial _tinted(Mat m, Color heat, double mix) {
    final base = m == Mat.dark ? style.dark : style.base(m);
    final c = Color.lerp(base, heat.withValues(alpha: 1), mix)!;
    return fs.PhysicallyBasedMaterial()
      ..metallicFactor = 0
      ..roughnessFactor = 0.9
      ..baseColorFactor = linearColor(c, 1)
      // Etwas Eigenleuchten, damit die Farbe auch im Dunkeln trägt.
      ..emissiveFactor = (() {
        final l = linearColor(heat.withValues(alpha: 1), 1);
        return vm.Vector4(l.x, l.y, l.z, 1);
      })()
      ..emissiveStrength = 0.18 * mix;
  }

  /// Unbeleuchtete, eingefärbte Fläche über [polygon] (Heatmap).
  fs.Node? _heatNode(
    String name,
    SceneHeatmap h,
    String roomId,
    List<V3> polygon,
  ) {
    final rec = LightReceiver(polygon, texel: 0.1, maxSide: 96);
    final px = Uint8List(rec.width * rec.height * 4);
    for (var iy = 0; iy < rec.height; iy++) {
      for (var ix = 0; ix < rec.width; ix++) {
        final c = rec.texelCenter(ix, iy);
        final v = h.valueAt(roomId, Offset(c.x, c.y));
        if (!v.isFinite) continue;
        final col = h.colorOf(v);
        final i = (iy * rec.width + ix) * 4;
        px[i] = (col.r * 255).round();
        px[i + 1] = (col.g * 255).round();
        px[i + 2] = (col.b * 255).round();
        px[i + 3] = (col.a * 255).round();
      }
    }
    final mat = fs.UnlitMaterial()
      ..baseColorTexture = fs.Texture2D.fromPixels(px, rec.width, rec.height)
      ..baseColorFactor = vm.Vector4(1, 1, 1, h.opacity)
      ..alphaMode = fs.AlphaMode.blend
      ..depthLayer = 1;
    return fs.Node(name: name, mesh: fs.Mesh(_receiverGeometry(rec), mat))
      ..shadowCastingMode = fs.ShadowCastingMode.off;
  }

  /// Fläche als eigener Knoten mit UVs und eigenem Material (für die
  /// Emissive-Textur), nur vom Sonnenlicht erreicht.
  fs.Node _receiverNode(
    String name,
    List<V3> polygon,
    Color Function(SceneStyle) color,
  ) {
    final bake = LightReceiver(polygon, texel: quality.bakeTexel);
    final mat = fs.PhysicallyBasedMaterial()
      ..metallicFactor = 0
      ..roughnessFactor = 1;
    final r = _Receiver(bake, mat, color);
    _paintReceiver(r);
    _receivers.add(r);
    return fs.Node(name: name, mesh: fs.Mesh(_receiverGeometry(bake), mat))
      // Ohne Baking (Entwurf) bescheint die Sonne die Fläche in Echtzeit.
      ..lightChannelMask = quality.bakes ? kBakedChannel : 0xFF;
  }

  void _paintReceiver(_Receiver r) {
    final c = r.color(style);
    r.material.baseColorFactor = linearColor(c, c.a);
    r.material.alphaMode = c.a < 1 ? fs.AlphaMode.blend : fs.AlphaMode.opaque;
  }

  /// Bake aller Lampen eines Raums auf seine Flächen.
  void _bakeRoom(String roomId, List<_Receiver> receivers) {
    final occ = LightOccluders([
      for (final o in source.objects)
        if (source.objectRoom[o.id] == roomId) o.world,
    ]);
    for (final r in receivers) {
      r.sun = bakeSun(
        r.bake,
        -kSunDirection,
        occ,
        samples: quality.bakeSamples,
      );
      final cos = (-kSunDirection).normalized.z;
      r.sunOpen = Float32List(r.bake.width * r.bake.height)
        ..fillRange(0, r.bake.width * r.bake.height, cos);
    }
    for (final m in source.markers) {
      if (m.kind != MarkerKind.light || m.lamp == null) continue;
      if (source.markerRoom[m.id] != roomId) continue;
      for (final r in receivers) {
        final open = Float32List(r.bake.width * r.bake.height);
        r.lamps[m.id] = bakeLamp(
          r.bake,
          m.position,
          occ,
          samples: quality.bakeSamples,
          unshadowed: open,
        );
        r.lampsOpen[m.id] = open;
      }
    }
    for (final r in receivers) {
      _relight(r);
    }
  }

  void _applyLighting() {
    scene.skybox = null; // durchsichtiger Hintergrund
    scene.antiAliasingMode = quality.msaa
        ? fs.AntiAliasingMode.auto
        : fs.AntiAliasingMode.fxaa;
    scene.toneMapping = fs.ToneMappingMode.pbrNeutral;
    scene.environmentIntensity = 0.9 * style.ambient;
    scene.directionalLight = style.sun <= 0
        ? null
        : fs.DirectionalLight(
            // Von oben links hinten, etwas schräg: Schatten fallen nach
            // rechts unten wie bei den Karten-Schatten der App.
            direction: toFs(kSunDirection).normalized(),
            intensity: kSunIntensity * style.sun,
            // Böden und Oberseiten bekommen die Sonne gebaken (mit weichen
            // Schatten), die Echtzeit-Sonne nur Wände und Möbelseiten.
            channelMask: 0xFF ^ kBakedChannel,
            castsShadow: false,
            shadowSoftness: 0.6,
            // Die orthographische Kamera steht kCameraDistance vor dem
            // Ziel; die Schatten müssen von dort bis hinter die Wohnung
            // reichen, sonst fehlen sie ganz.
            shadowMaxDistance: kCameraDistance + 20,
            shadowCascadeCount: 1,
            // Glatt statt gekörnt (rotierte Poisson-Muster rauschen auf
            // großen, hellen Böden).
            shadowFilter: fs.DirectionalShadowFilter.fixedPcf,
          );
  }

  /// Neuer Stil: Materialien und Licht tauschen, Geometrie bleibt.
  void restyle(SceneStyle s) {
    if (s == style) return;
    // Nur der Akzent (folgt in der App animiert der Lichtfarbe): Umrandung
    // umfärben, kein neues Baking.
    if (s.copyWith(accent: style.accent) == style) {
      style = s;
      _mat.setAccent(s);
      return;
    }
    style = s;
    _edgeScale = -1;
    _lastFadeKey = null;
    _mat.update(s);
    _applyLighting();
    for (final r in _receivers) {
      _paintReceiver(r);
      _dirty.add(r);
    }
    // Aktuellen Lampenzustand behalten (nicht den aus der Szene: sonst
    // ginge eine ausgeschaltete Lampe bei jeder Stiländerung wieder an).
    for (final e in _lampState.entries) {
      _applyLamp(e.key, e.value);
    }
    // Getönte Möbel hängen am Stil.
    if (_heat != null) _setHeatmap(_heat);
  }

  fs.Node _edgesNode(
    String name,
    List<Edge3> edges,
    fs.Material material, {
    bool outline = false,
  }) {
    final pos = Float32List(edges.length * 6);
    for (var i = 0; i < edges.length; i++) {
      final a = toFs(edges[i].a), b = toFs(edges[i].b);
      pos.setAll(i * 6, [a.x, a.y, a.z, b.x, b.y, b.z]);
    }
    final geo = fs.LineSegmentsGeometry(fs.LineSegmentData(positions: pos));
    (outline ? _outlineGeometries : _edgeGeometries).add(geo);
    return fs.Node(name: name, mesh: fs.Mesh(geo, material))
      ..shadowCastingMode = fs.ShadowCastingMode.off;
  }

  /// Vor jedem Bild: Sichtbarkeit und Kantenbreite zur Kamera passend.
  void sync(
    OrbitCamera cam, {
    String? focusRoomId,
    Set<String> selected = const {},
    Map<String, double> heights = const {},
    Size? size,
    String? selectedRoomId,
    SceneHeatmap? heatmap,
    Set<String> hiddenObjects = const {},
  }) {
    if (selectedRoomId != _selectedRoom) {
      _roomOutlines[_selectedRoom]?.visible = false;
      _selectedRoom = selectedRoomId;
      _roomOutlines[selectedRoomId]?.visible = true;
    }
    if (!identical(heatmap, _heat)) _setHeatmap(heatmap);
    // Sonnenschatten müssen von der Kamera bis hinter die Wohnung reichen;
    // bei Perspektive steht die Kamera je nach Zoom unterschiedlich weit weg.
    final sun = scene.directionalLight;
    if (sun != null && size != null) {
      final d = cam.isPerspective ? cam.distance(size) : kCameraDistance;
      final want = d + 20;
      if ((sun.shadowMaxDistance - want).abs() > 1) {
        sun.shadowMaxDistance = want;
      }
    }
    // Raumhöhe (0 flach … 1 voll): Raumknoten in der Höhe stauchen.
    for (final e in _roomNodes.entries) {
      final h = (heights[e.key] ?? 1).clamp(0.0, 1.0);
      if (_heights[e.key] != h) {
        _heights[e.key] = h;
        e.value.scale = vm.Vector3(1, math.max(h, kFlat), 1);
      }
    }
    if (focusRoomId != _focus) {
      _focus = focusRoomId;
      for (final e in _roomNodes.entries) {
        e.value.visible = focusRoomId == null || e.key == focusRoomId;
      }
      for (final o in _objects.values) {
        if (o.roomId == null) o.node.visible = focusRoomId == null;
      }
    }
    if (cam.scale != _edgeScale) {
      _edgeScale = cam.scale;
      final w = style.edgeWidthAt(cam.scale);
      for (final g in _edgeGeometries) {
        g.width = w;
      }
      for (final g in _outlineGeometries) {
        g.width = w * 1.8;
      }
    }
    if (!_setEquals(selected, _selected)) {
      _selected = {...selected};
      for (final e in _objects.entries) {
        final sel = selected.contains(e.key);
        e.value.edges.visible = !sel;
        e.value.accentEdges.visible = sel;
      }
    }
    // Kanten und Linien gehören zur Draufsicht: beim Kippen blenden sie in
    // 3D-Räumen weich aus, schräg bleibt nur die Schattierung. Flache Räume
    // sind eine Zeichnung und behalten ihre Linien.
    final tilt = style.edgesOnlyFromAbove
        ? 1 - _smooth(0.06, 0.42, cam.pitch)
        : 1.0;
    // Möbellinien nur bei ausgeschaltetem Licht: in einem hellen Raum
    // zeichnen Licht und Schatten die Möbel, es bleibt die Wand. Der
    // Wechsel blendet weich über.
    _stepLit();
    final fadeKey =
        '$tilt|${_heights.values.join(',')}|${_lit.values.join(',')}';
    if (fadeKey != _lastFadeKey) {
      _lastFadeKey = fadeKey;
      _mat.fadeLines(null, tilt);
      for (final e in _heights.entries) {
        _mat.fadeLines(
          e.key,
          1 - e.value * (1 - tilt),
          furniture: 1 - (_lit[e.key] ?? 0),
        );
      }
    }
    // Glühbirnen nur über aufgerichteten Räumen.
    for (final e in _bulbs.entries) {
      final room = _bulbRoom[e.key];
      final h = room == null ? 1.0 : _heights[room] ?? 1;
      e.value.visible = h > 0.5 && (_focus == null || room == _focus);
    }
    // Wände zur Kamera hin ausblenden, Türen und Fenster darin mit.
    final cut = <_WallNode>{};
    for (final w in _walls) {
      final raised = (_heights[w.room.id] ?? 1) > 0.5;
      final near = raised && style.cutaway && cam.facing(w.face.normal) > 0.02;
      // Gewählter Raum: Wände deutlich, die vorderen durchscheinend statt
      // weggeschnitten (Türen und Fenster darin bleiben).
      if (raised && w.room.id == _selectedRoom) {
        final m = near ? w.front : w.selected;
        if (!identical(w.node.mesh, m)) w.node.mesh = m;
        w.node.visible = true;
        continue;
      }
      if (!identical(w.node.mesh, w.normal)) w.node.mesh = w.normal;
      w.node.visible = !near;
      if (near) cut.add(w);
    }
    for (final o in _objects.values) {
      if (!o.object.wallMounted) continue;
      final room = o.roomId;
      var hide = false;
      for (final w in cut) {
        if (w.room.id == room && _onWall(o.object, w.face)) hide = true;
      }
      o.node.visible = !hide && (_focus == null || room == _focus);
    }
    // Ausgeblendete Möbel (z. B. gerade gezogen, ein Overlay zeigt sie).
    if (!_setEquals(hiddenObjects, _hiddenObjects)) {
      for (final id in {...hiddenObjects, ..._hiddenObjects}) {
        final o = _objects[id];
        if (o == null || o.object.wallMounted) continue;
        o.node.visible =
            !hiddenObjects.contains(id) &&
            (_focus == null || o.roomId == _focus);
      }
      _hiddenObjects = {...hiddenObjects};
    }
    for (final id in hiddenObjects) {
      _objects[id]?.node.visible = false;
    }
  }

  Set<String> _hiddenObjects = const {};

  /// Je Raum: wie weit sein Licht an ist (0 … 1, weich nachgeführt).
  final Map<String, double> _lit = {};
  final Stopwatch _litClock = Stopwatch()..start();

  /// Blenden die Möbellinien noch (Licht wurde geschaltet)?
  bool get fading => _fading;
  bool _fading = false;

  /// Dauer der Überblendung der Möbellinien.
  static const double kLitFade = 0.35;

  void _stepLit() {
    final dt = _litClock.elapsedMicroseconds / 1e6;
    _litClock.reset();
    final on = <String>{
      for (final e in _lampState.entries)
        if (e.value.on && e.value.brightness > 0) ?_bulbRoom[e.key],
    };
    _fading = false;
    for (final r in _roomNodes.keys) {
      final target = on.contains(r) ? 1.0 : 0.0;
      final cur = _lit[r];
      if (cur == null) {
        // Erstes Bild: ohne Überblendung.
        _lit[r] = target;
        continue;
      }
      if (cur == target) continue;
      final step = math.min(dt, 0.1) / kLitFade;
      final next = cur < target
          ? math.min(target, cur + step)
          : math.max(target, cur - step);
      _lit[r] = next;
      if (next != target) _fading = true;
    }
  }

  static bool _onWall(SceneObject o, Face3 wall) {
    final a = wall.points[0].xy, b = wall.points[1].xy;
    for (final p in [
      o.position.xy,
      o.toWorld(Offset(0, o.depth / 2)),
      o.toWorld(Offset(0, -o.depth / 2)),
    ]) {
      if (_segDist(p, a, b) < 0.15) return true;
    }
    return false;
  }

  static double _segDist(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final l2 = ab.distanceSquared;
    if (l2 < 1e-12) return (p - a).distance;
    final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / l2).clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }

  static bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}

/// Abstand der orthographischen Kamera vom Ziel (Meter): weit genug für
/// jede Wohnung, nah genug für scharfe Schattenkaskaden.
const double kCameraDistance = 30;

/// flutter_scene-Kamera zu einer [OrbitCamera] (gleiche Projektion, damit
/// Overlay-Widgets über [OrbitCamera.project] genau sitzen).
fs.Camera fsCamera(OrbitCamera c, Size size) {
  final b = c.basis;
  final target = c.panTarget;
  final up = -b.down;
  if (c.isPerspective) {
    final d = c.distance(size);
    return fs.PerspectiveCamera(
      position: toFs(target + b.toCam * d),
      target: toFs(target),
      up: toFs(up),
      fovRadiansY: c.fov,
      fovNear: math.max(0.05, d - 60),
      fovFar: d + 60,
    );
  }
  const dist = kCameraDistance;
  return fs.OrthographicCamera(
    position: toFs(target + b.toCam * dist),
    target: toFs(target),
    up: toFs(up),
    projection: fs.OrthographicProjection(
      size: fs.OrthographicSize.pixelsPerUnit(c.scale),
      near: 0.1,
      far: dist * 2,
    ),
  );
}

class _WallNode {
  _WallNode(this.room, this.face, this.node);
  final SceneRoom room;
  final Face3 face;
  final fs.Node node;

  /// Normal, im gewählten Raum (kräftig) und vorn im gewählten Raum
  /// (durchscheinend statt weggeschnitten).
  late final fs.Mesh normal;
  late final fs.Mesh selected;
  late final fs.Mesh front;
}

class _ObjectNode {
  _ObjectNode(
    this.object,
    this.roomId,
    this.node,
    this.edges,
    this.accentEdges,
  );
  final SceneObject object;
  final String? roomId;
  final fs.Node node;
  final fs.Node edges;
  final fs.Node accentEdges;

  /// Körper mit den gemeinsamen Materialien (ohne Heatmap-Tönung).
  fs.Mesh? mesh;
  List<(fs.Geometry, Mat)> parts = const [];

  /// Waagerechte Oberseiten (gebakene Flächen), für die Heatmap-Färbung.
  List<List<V3>> tops = const [];

  /// Heatmap-Flächen über den Oberseiten.
  final List<fs.Node> heat = [];
}

/// Sammelt Dreiecke mit Normalen. Runde Flächen ([Face3.smooth]) bekommen
/// gemittelte Normalen je Ecke, damit Zylinder weich schattiert wirken.
class _MeshAcc {
  final List<double> _pos = [];
  final List<double> _nrm = [];
  final List<(V3, V3, bool)> _pending = [];

  bool get isEmpty => _pos.isEmpty && _pending.isEmpty;

  void addFace(Face3 f, {bool twoSided = false}) {
    final tris = triangulate(f.points, f.normal);
    for (final (a, b, c) in tris) {
      _tri(f.points[a], f.points[b], f.points[c], f.normal, f.smooth);
      if (twoSided) {
        _tri(f.points[a], f.points[c], f.points[b], -f.normal, f.smooth);
      }
    }
  }

  void _tri(V3 a, V3 b, V3 c, V3 n, bool smooth) {
    for (final p in [a, b, c]) {
      _pending.add((p, n, smooth));
    }
  }

  fs.Geometry geometry() {
    // Weiche Normalen: je (gerundeter) Ecke die Normalen runder Flächen mitteln.
    final sums = <String, V3>{};
    String key(V3 p) =>
        '${(p.x * 1000).round()},${(p.y * 1000).round()},${(p.z * 1000).round()}';
    for (final (p, n, smooth) in _pending) {
      if (!smooth) continue;
      sums[key(p)] = (sums[key(p)] ?? V3.zero) + n;
    }
    for (var i = 0; i < _pending.length; i += 3) {
      final tri = _pending.sublist(i, i + 3);
      // In flutter_scene-Koordinaten so ausrichten, dass das Kreuzprodukt
      // zur Normalen zeigt (gegen den Uhrzeigersinn = Vorderseite).
      final fa = toFs(tri[0].$1), fb = toFs(tri[1].$1), fc = toFs(tri[2].$1);
      final fn = toFs(tri[0].$2);
      final cross = (fb - fa).cross(fc - fa);
      final order = cross.dot(fn) >= 0 ? [0, 1, 2] : [0, 2, 1];
      for (final k in order) {
        final (p, n, smooth) = tri[k];
        final q = toFs(p);
        var nn = n;
        if (smooth) {
          final s = sums[key(p)];
          // Nur mitteln, wo die Nachbarn ähnlich zeigen (keine Deckelkante).
          if (s != null && s.normalized.dot(n) > 0.7) nn = s.normalized;
        }
        final qn = toFs(nn);
        _pos.addAll([q.x, q.y, q.z]);
        _nrm.addAll([qn.x, qn.y, qn.z]);
      }
    }
    _pending.clear();
    return fs.MeshGeometry.fromArrays(
      positions: Float32List.fromList(_pos),
      normals: Float32List.fromList(_nrm),
    );
  }
}

/// Gemeinsame Materialien je Oberfläche.
class _Materials {
  _Materials(SceneStyle s) {
    update(s);
  }

  final Map<Mat, fs.PhysicallyBasedMaterial> _surfaces = {};
  final fs.PhysicallyBasedMaterial floor = fs.PhysicallyBasedMaterial();
  final fs.PhysicallyBasedMaterial wall = fs.PhysicallyBasedMaterial()
    ..doubleSided = true;

  /// Wände des gewählten Raums: hinten fast deckend, vorn durchscheinend.
  final fs.PhysicallyBasedMaterial wallSelected = fs.PhysicallyBasedMaterial()
    ..doubleSided = true;
  final fs.PhysicallyBasedMaterial wallFront = fs.PhysicallyBasedMaterial()
    ..doubleSided = true;

  final Map<String?, _LineSet> _lines = {};

  /// Linienmaterialien eines Raums (null: außerhalb), je Raum eigene
  /// Deckkraft (flache Räume behalten ihre Linien, 3D-Räume blenden aus).
  _LineSet lines(String? roomId) => _lines.putIfAbsent(roomId, () {
    final l = _LineSet();
    _paintLines(l);
    return l;
  });

  /// Deckkraft der Linien eines Raums.
  void fadeLines(String? roomId, double alpha, {double furniture = 1}) {
    final l = lines(roomId);
    if (l.alpha == alpha && l.furniture == furniture) return;
    l.alpha = alpha;
    l.furniture = furniture;
    _paintLines(l);
  }

  final fs.UnlitMaterial accentEdge = fs.UnlitMaterial();
  late SceneStyle _style;

  fs.PhysicallyBasedMaterial surface(Mat m) =>
      _surfaces.putIfAbsent(m, () => _surfaceFor(m));

  fs.PhysicallyBasedMaterial _surfaceFor(Mat m) {
    final mat = fs.PhysicallyBasedMaterial();
    _paint(mat, m);
    return mat;
  }

  void _paint(fs.PhysicallyBasedMaterial mat, Mat m) {
    final s = _style;
    mat.metallicFactor = 0;
    switch (m) {
      case Mat.glass:
        mat.baseColorFactor = linearColor(s.glass, 0.28);
        mat.alphaMode = fs.AlphaMode.blend;
        mat.roughnessFactor = 0.15;
        mat.doubleSided = true;
      case Mat.dark:
        mat.baseColorFactor = linearColor(s.dark, 1);
        mat.roughnessFactor = 0.45;
      default:
        mat.baseColorFactor = linearColor(s.base(m), 1);
        mat.roughnessFactor = m == Mat.soft || m == Mat.rug ? 1.0 : 0.85;
    }
  }

  fs.PhysicallyBasedMaterial bulb(LampState l) {
    final mat = fs.PhysicallyBasedMaterial()..metallicFactor = 0;
    final c = linearColor(l.color, 1);
    if (l.on) {
      mat.baseColorFactor = c;
      mat.emissiveFactor = vm.Vector4(c.x, c.y, c.z, 1);
      mat.emissiveStrength = 3 * l.brightness;
    } else {
      mat.baseColorFactor = linearColor(_style.surface, 1);
    }
    return mat;
  }

  void update(SceneStyle s) {
    _style = s;
    for (final e in _surfaces.entries) {
      _paint(e.value, e.key);
    }
    floor
      ..metallicFactor = 0
      ..roughnessFactor = 1
      ..baseColorFactor = linearColor(s.floor, s.floorOpacity)
      ..alphaMode = s.floorOpacity < 1
          ? fs.AlphaMode.blend
          : fs.AlphaMode.opaque;
    wall
      ..metallicFactor = 0
      ..roughnessFactor = 1
      ..baseColorFactor = linearColor(s.wall, s.wallOpacity)
      ..alphaMode = s.wallOpacity < 1
          ? fs.AlphaMode.blend
          : fs.AlphaMode.opaque;
    for (final (m, a) in [
      (wallSelected, math.max(0.9, s.wallOpacity)),
      (wallFront, 0.22),
    ]) {
      m
        ..metallicFactor = 0
        ..roughnessFactor = 1
        ..baseColorFactor = linearColor(s.wall, a)
        ..alphaMode = fs.AlphaMode.blend;
    }
    _applyLineColors();
  }

  void setAccent(SceneStyle s) {
    _style = s;
    accentEdge.baseColorFactor = linearColor(s.accent, 1);
  }

  void _applyLineColors() {
    for (final l in _lines.values) {
      _paintLines(l);
    }
    accentEdge
      ..baseColorFactor = linearColor(_style.accent, 1)
      ..depthBias = 0.025
      ..depthLayer = 2;
  }

  /// Eine Linienfarbe für alles, wie die 2D-Karte; Details etwas leiser.
  void _paintLines(_LineSet l) {
    final s = _style;
    for (final (m, a) in [
      (l.edge, l.alpha * l.furniture),
      (l.wall, l.alpha * s.roomEdgeOpacity),
      (l.detail, l.alpha * 0.75 * l.furniture),
      (l.structureEdge, l.alpha),
      (l.structureDetail, l.alpha * 0.75),
    ]) {
      m.baseColorFactor = linearColor(s.ink, a);
      m.alphaMode = a < 1 ? fs.AlphaMode.blend : fs.AlphaMode.opaque;
      m.depthBias = 0.025;
      m.depthLayer = 1;
    }
  }
}

class _LineSet {
  final fs.UnlitMaterial edge = fs.UnlitMaterial();
  final fs.UnlitMaterial wall = fs.UnlitMaterial();
  final fs.UnlitMaterial detail = fs.UnlitMaterial();

  /// Türen und Fenster (blenden bei Licht nicht aus).
  final fs.UnlitMaterial structureEdge = fs.UnlitMaterial();
  final fs.UnlitMaterial structureDetail = fs.UnlitMaterial();
  double alpha = 1;

  /// Anteil der Möbellinien (1 Licht aus … 0 Licht an), die Wandlinie bleibt.
  double furniture = 1;
}

/// Richtung des Sonnenlichts (Haven-Koordinaten): von oben links hinten,
/// Schatten fallen nach rechts unten wie bei den Karten-Schatten der App.
const V3 kSunDirection = V3(0.35, 0.45, -1);

/// Stärke der Sonne (mal `SceneStyle.sun`).
const double kSunIntensity = 2.4;

/// Lichtkanal der Flächen mit gebakenem Lampenlicht: nur die Sonne (alle
/// Kanäle) erreicht sie, Lampen nicht (sonst doppelt).
const int kBakedChannel = 0x40;

/// Lichtkanal für alles außerhalb der Räume.
const int kOutsideChannel = 0x80;

/// Ein Bit (von sieben) je Raum, benachbarte Räume (gemeinsames Wandstück)
/// verschieden. Gierige Färbung; Grundrisse sind planar, sieben reichen.
Map<String, int> roomChannels(List<SceneRoom> rooms) {
  bool touches(SceneRoom a, SceneRoom b) {
    for (var i = 0; i < a.outline.length; i++) {
      final a0 = a.outline[i], a1 = a.outline[(i + 1) % a.outline.length];
      for (var j = 0; j < b.outline.length; j++) {
        final b0 = b.outline[j], b1 = b.outline[(j + 1) % b.outline.length];
        if (_overlap(a0, a1, b0, b1) > 0.05) return true;
      }
    }
    return false;
  }

  final out = <String, int>{};
  for (final r in rooms) {
    var used = 0;
    for (final o in rooms) {
      final bit = out[o.id];
      if (bit != null && touches(r, o)) used |= bit;
    }
    var bit = 1;
    while (bit < kBakedChannel && used & bit != 0) {
      bit <<= 1;
    }
    out[r.id] = bit < kBakedChannel ? bit : 1;
  }
  return out;
}

/// Länge, auf der zwei Strecken auf derselben Geraden übereinanderliegen.
double _overlap(Offset a0, Offset a1, Offset b0, Offset b1) {
  final d = a1 - a0;
  final len = d.distance;
  if (len < 1e-9) return 0;
  final u = d / len;
  double cross(Offset p) => (p - a0).dx * u.dy - (p - a0).dy * u.dx;
  if (cross(b0).abs() > 0.01 || cross(b1).abs() > 0.01) return 0;
  double t(Offset p) => (p - a0).dx * u.dx + (p - a0).dy * u.dy;
  final lo = math.max(0.0, math.min(t(b0), t(b1)));
  final hi = math.min(len, math.max(t(b0), t(b1)));
  return hi - lo;
}

class _Receiver {
  _Receiver(this.bake, this.material, this.color);
  final LightReceiver bake;
  final fs.PhysicallyBasedMaterial material;
  final Color Function(SceneStyle) color;
  final Map<String, Float32List> lamps = {};

  /// Lampenlicht ohne Schatten (für das Streulicht in den Schatten).
  final Map<String, Float32List> lampsOpen = {};
  Float32List? sun;

  /// Sonne ohne Schatten: überall derselbe Kosinus.
  Float32List? sunOpen;
}

/// Waagerechte Fläche mit UVs aus [r] (für die Emissive-Textur).
fs.Geometry _receiverGeometry(LightReceiver r) {
  final pts = r.polygon;
  final pos = <double>[], nrm = <double>[], uv = <double>[];
  final up = toFs(V3.up);
  for (final (a, b, c) in triangulate(pts, V3.up)) {
    final fa = toFs(pts[a]), fb = toFs(pts[b]), fc = toFs(pts[c]);
    final order = (fb - fa).cross(fc - fa).dot(up) >= 0 ? [a, b, c] : [a, c, b];
    for (final i in order) {
      final q = toFs(pts[i]);
      pos.addAll([q.x, q.y, q.z]);
      nrm.addAll([up.x, up.y, up.z]);
      final (u, v) = r.uv(pts[i]);
      uv.addAll([u, v]);
    }
  }
  return fs.MeshGeometry.fromArrays(
    positions: Float32List.fromList(pos),
    normals: Float32List.fromList(nrm),
    texCoords: Float32List.fromList(uv),
  );
}
