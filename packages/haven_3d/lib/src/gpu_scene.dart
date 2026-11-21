import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, Offset, Size;

import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import 'camera.dart';
import 'devices.dart';
import 'edges.dart';
import 'heatmap.dart';
import 'lightbake.dart';
import 'model.dart';
import 'quality.dart';
import 'sky.dart';
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
  GpuScene(
    this.source,
    this.style, {
    this.quality = SceneQuality.high,
    Map<String, bool?> open = const {},
    V3? sun,
    this.deferBake = false,
    this.reach = LightReach.doors,
  }) : _sunDir = sun ?? kSunDirection {
    _openState.addAll(open);
    _build();
  }

  /// Richtung des Sonnenlichts (von der Sonne zum Boden), siehe
  /// [setSunDirection].
  V3 _sunDir;
  V3 get sunDirection => _sunDir;

  /// Himmel: Sonne, Mond und Wetter (siehe [SceneSky]). Licht und Schatten
  /// kommen dann in Echtzeit, unsichtbare Decken und Wände werfen Schatten,
  /// so fällt Licht nur durch Fenster und Türen. `null`: zurück zum
  /// Kartenlicht (Sonne aus [setSunDirection], gebaken).
  void setSky(SceneSky? sky) {
    if (sky == _sky) return;
    final was = _sky != null;
    _sky = sky;
    if (was != (sky != null)) {
      final on = sky != null;
      for (final r in source.rooms) {
        final c = on ? (_casters[r.id] ??= _casterOf(r)) : _casters[r.id];
        c?.visible = on && (_heights[r.id] ?? 1) > 0.5;
      }
      // Ein Dach über allem: auch über den Spalten zwischen den Räumen
      // (sonst schiene die Sonne durch Spalt und Tür hinein).
      if (on) _roof ??= _roofNode();
      _syncRoof();
      // Flächen behalten den gebakenen Kanal: Sonne und Mond (Kanal 0xFF)
      // erreichen sie trotzdem in Echtzeit, Lampen nur gebaken. Mit allen
      // Kanälen fiele Lampenlicht ungehindert auf die Böden der Nachbarräume.
      for (final r in _receivers) {
        _dirty.add(r);
      }
      for (final o in _objects.values) {
        o.node.shadowCastingMode = on
            ? fs.ShadowCastingMode.on
            : fs.ShadowCastingMode.off;
      }
    }
    _applyLighting();
    _glowSnow();
  }

  SceneSky? _sky;
  SceneSky? get sky => _sky;

  SceneGround? _groundSpec;
  _Ground? _ground;

  /// Oberseiten der Wände je Raum (Schneehauben) und die Hauben selbst.
  final List<(fs.Node, List<V3>)> _capPolys = [];
  final List<(fs.Node, fs.Node)> _snowCaps = [];

  /// Schneehauben [meters] dick auf allen Wandkronen (0: keine).
  void _setSnowCaps(double meters) {
    final on = meters >= 0.005;
    // Einmal gebaut (1 m hoch), danach nur in der Höhe skaliert.
    if (on && _snowCaps.isEmpty) {
      final mat = fs.PhysicallyBasedMaterial()
        ..baseColorFactor = linearColor(const Color(0xFFF5F8FB))
        ..metallicFactor = 0
        ..roughnessFactor = 1
        ..emissiveFactor = vm.Vector4(1, 1, 1, 1)
        ..emissiveStrength = 0.12;
      for (final (wall, c) in _capPolys) {
        final b = ModelBuilder()..prism([for (final p in c) p.xy], 0, 1);
        final acc = _MeshAcc();
        for (final f in b.build().faces) {
          acc.addFace(f, twoSided: true);
        }
        if (acc.isEmpty) continue;
        final node = fs.Node(name: 'snow', mesh: fs.Mesh(acc.geometry(), mat))
          ..position = toFs(V3(0, 0, c.first.z))
          ..lightChannelMask = 0xFF
          ..shadowCastingMode = fs.ShadowCastingMode.off;
        wall.add(node);
        _snowCaps.add((wall, node));
      }
    }
    for (final (_, cap) in _snowCaps) {
      cap.visible = on;
      if (on) cap.scale = vm.Vector3(1, meters, 1);
    }
  }

  /// Boden um die Wohnung (siehe [SceneGround]), `null`: keiner.
  ///
  /// Billig bei Änderungen: Rauschmuster und Randverlauf entstehen einmal.
  /// Wächst der Boden (Dunst), wird er nur skaliert; neue Farbe oder
  /// Schneehöhe mischen nur die Farben der Textur neu.
  void setGround(SceneGround? g) {
    if (g == _groundSpec) return;
    final old = _groundSpec;
    _groundSpec = g;
    if ((old == null) != (g == null)) {
      for (final r in _receivers) {
        _paintReceiver(r);
      }
    }
    if (g == null) {
      final n = _ground?.node;
      if (n != null) scene.root.remove(n);
      _ground = null;
      _setSnowCaps(0);
      return;
    }
    var gr = _ground;
    if (gr == null) {
      gr = _ground = _buildGround(g);
      if (gr == null) return;
      scene.add(gr.node);
    }
    if (old == null || old.color != g.color || old.snow != g.snow) {
      // Erst im nächsten Bild: ein Regler sendet viele Werte je Bild.
      _groundPaint = true;
    }
    if (old?.snow != g.snow) _setSnowCaps(g.snow * kSnowMaxDepth);
    gr.resize(g.margin);
    _glowSnow();
  }

  /// Schnee leuchtet leicht nach Tageslicht (sonst wirkte er grau).
  void _glowSnow() {
    final gr = _ground;
    if (gr == null) return;
    final l = _sky?.light;
    gr.material.emissiveStrength = l == null
        ? 0.3
        // Nur nach dem Himmelslicht, nicht nach der Sonne: Schatten auf dem
        // Schnee bleiben sichtbar.
        : (0.05 + 0.7 * l.ambient) *
              (_groundSpec?.snow ?? 0).clamp(0.0, 1.0).sign;
  }

  _Ground? _buildGround(SceneGround g) {
    if (source.rooms.isEmpty) return null;
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final r in source.rooms) {
      for (final p in r.outline) {
        minX = math.min(minX, p.dx);
        minY = math.min(minY, p.dy);
        maxX = math.max(maxX, p.dx);
        maxY = math.max(maxY, p.dy);
      }
    }
    return _Ground(
      cx: (minX + maxX) / 2,
      cy: (minY + maxY) / 2,
      halfX: (maxX - minX) / 2,
      halfY: (maxY - minY) / 2,
      margin: g.margin,
      fade: g.fade,
      outlines: [for (final r in source.rooms) r.outline],
    );
  }

  fs.Node? _roof;

  /// Das Dach wirft nur Schatten, solange alle Räume aufgerichtet sind:
  /// über flachen Räumen läge es sonst auf Wandhöhe und schattete den Boden
  /// ab (Licht käme nur am Rand darunter durch).
  void _syncRoof() {
    _roof?.visible =
        _sky != null && source.rooms.every((r) => (_heights[r.id] ?? 1) > 0.5);
  }

  fs.Node? _roofNode() {
    if (source.rooms.isEmpty) return null;
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity, h = 0.0;
    for (final r in source.rooms) {
      for (final p in r.outline) {
        minX = math.min(minX, p.dx);
        minY = math.min(minY, p.dy);
        maxX = math.max(maxX, p.dx);
        maxY = math.max(maxY, p.dy);
      }
      h = math.max(h, r.wallHeight);
    }
    const m = 0.3;
    final z = h + 0.01;
    final acc = _MeshAcc()
      ..addFace(
        Face3([
          V3(minX - m, minY - m, z),
          V3(maxX + m, minY - m, z),
          V3(maxX + m, maxY + m, z),
          V3(minX - m, maxY + m, z),
        ], const V3(0, 0, -1)),
        twoSided: true,
      );
    final node = fs.Node(name: 'roof')
      ..mesh = fs.Mesh(
        acc.geometry(),
        fs.PhysicallyBasedMaterial()..alphaMode = fs.AlphaMode.opaque,
      )
      ..shadowCastingMode = fs.ShadowCastingMode.shadowsOnly;
    scene.add(node);
    return node;
  }

  /// Unsichtbare Schattenwerfer eines Raums: Wände (mit Löchern für Türen
  /// und Fenster) und eine Decke auf Wandhöhe.
  final Map<String, fs.Node> _casters = {};

  fs.Node _casterOf(SceneRoom r) {
    final acc = _MeshAcc();
    for (final f in _wallFaces[r.id] ?? const <Face3>[]) {
      acc.addFace(f, twoSided: true);
    }
    final outer = _outer[r.id];
    if (outer != null && outer.length >= 3) {
      final h = r.wallHeight;
      acc.addFace(
        Face3([for (final p in outer) V3(p.dx, p.dy, h)], const V3(0, 0, -1)),
        twoSided: true,
      );
    }
    final node = fs.Node(name: 'casters:${r.id}')
      // Undurchsichtig: durchscheinende Materialien werfen keinen Schatten.
      ..mesh = acc.isEmpty
          ? null
          : fs.Mesh(
              acc.geometry(),
              fs.PhysicallyBasedMaterial()..alphaMode = fs.AlphaMode.opaque,
            )
      ..shadowCastingMode = fs.ShadowCastingMode.shadowsOnly;
    _roomNodes[r.id]?.add(node);
    return node;
  }

  /// Sonne aus einer anderen Richtung (Tageszeit, Lage der Wohnung):
  /// Echtzeitsonne sofort, die gebakenen Schatten in Scheiben (siehe
  /// [flushLight]). Kleine Änderungen unter etwa 2° zählen nicht.
  void setSunDirection(V3 dir) {
    final a = dir.normalized, b = _sunDir.normalized;
    if (a.dot(b) > math.cos(2 * math.pi / 180)) return;
    _sunDir = dir;
    _applyLighting();
    if (!quality.bakes) return;
    if (_baking) _staleSun = true;
    _queueSunBake();
  }

  /// Sonne neu backen, als Aufträge für [flushLight].
  void _queueSunBake() {
    for (final z in _zones()) {
      final occ = _zoneOccluders(z.keys.toSet());
      for (final l in z.values) {
        for (final r in l) {
          final t = _sunTask(r, occ.objects);
          _jobs.add(() {
            _applyBake(runBakeTask(t));
            _dirty.add(r);
          });
        }
      }
    }
  }

  SunBakeTask _sunTask(_Receiver r, LightOccluders occ) => SunBakeTask(
    _receivers.indexOf(r),
    r.bake,
    quality.bakeSamples,
    toSun: -_sunDir,
    occluders: occ,
  );

  /// Ergebnis eines Bake-Auftrags in seine Fläche legen (ohne Neumischen).
  void _applyBake(BakeResult b) {
    if (b.receiver < 0 || b.receiver >= _receivers.length) return;
    final r = _receivers[b.receiver];
    final id = b.lampId;
    if (id == null) {
      r.sun = b.lit;
      r.sunOpen = b.open;
    } else if (b.lit == null) {
      r.lamps.remove(id);
      r.lampsOpen.remove(id);
    } else {
      r.lamps[id] = b.lit!;
      r.lampsOpen[id] = b.open!;
    }
  }

  /// Baking nicht im Konstruktor, sondern über [bakeInBackground].
  final bool deferBake;

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

  /// Lichtquelle je Lampe (Punkt- oder Spotlicht) und was dazu gehört.
  final Map<String, fs.Component> _lampNodes = {};
  final Map<String, double?> _lampCone = {};

  /// Streuung (weicher Rand des Kegels) je Lampe.
  final Map<String, double> _lampSoft = {};
  final Map<String, fs.Geometry> _bulbGeos = {};

  /// Wo das Licht einer Lampe entsteht (Welt, nach dem Ausrichten an der
  /// Wand), für das Baking.
  final Map<String, V3> _lampWorld = {};

  /// Richtung des Lichtkegels je Lampe (Welt).
  final Map<String, V3> _lampAxis = {};

  final Map<String, LampState> _lampState = {};

  /// Gebakenes Lampenlicht: Empfangsflächen (Böden, Möbel-Oberseiten) und
  /// je Fläche die Beleuchtung jeder Lampe im Raum.
  final List<_Receiver> _receivers = [];
  final Map<String, fs.Node> _bulbs = {};
  final Map<String, int> _lampMask = {};
  final Map<String, String?> _bulbRoom = {};
  final Map<String, List<Offset>> _shapes = {};
  final Map<String, List<int>> _roomReceivers = {};

  /// Wandstücke je Raum (ohne offene Wände, mit Türöffnungen) für die
  /// Lichtschatten über Raumgrenzen.
  final Map<String, List<Face3>> _wallFaces = {};

  /// Außenkante der Wände je Raum (runder Umriss).
  final Map<String, List<Offset>> _outer = {};

  /// Wände eines Raums, je Kante des Grundrisses ein Knoten: Außenseite
  /// (rund), Innenseite (eckig), oben eine Abdeckung dazwischen. Türen
  /// schneiden beide Seiten auf, offene Kanten haben keine Wand.
  void _buildWalls(
    SceneRoom r,
    fs.Node roomNode,
    List<Offset> outer,
    List<Offset> inner,
    _LineSet lines,
  ) {
    final h = r.wallHeight;
    final outerFaces = SceneRoom.wallsAlong(outer, h);
    final innerFaces = SceneRoom.wallsAlong(inner, h);
    int edgeOf(Face3 f) => r.edgeNear(f.points[0].xy, f.points[1].xy);
    final byEdge = <int, ({List<Face3> out, List<Face3> inn})>{};
    for (final f in outerFaces) {
      (byEdge[edgeOf(f)] ??= (out: [], inn: [])).out.add(f);
    }
    for (final f in innerFaces) {
      (byEdge[edgeOf(f)] ??= (out: [], inn: [])).inn.add(f);
    }
    final openLines = <Edge3>[];
    for (final e in byEdge.entries) {
      final outs = e.value.out, inns = e.value.inn;
      if (r.openEdges.contains(e.key)) {
        // Offene Wand: keine Wand, nur die Grenze als leise Linie.
        for (final f in [...inns]) {
          openLines.add(
            Edge3(
              V3(f.points[0].x, f.points[0].y, 0.012),
              V3(f.points[1].x, f.points[1].y, 0.012),
            ),
          );
        }
        continue;
      }
      if (outs.isEmpty && inns.isEmpty) continue;
      final faces = [
        for (final f in [...outs, ...inns]) ..._cutDoors(f),
      ];
      (_wallFaces[r.id] ??= []).addAll(faces);
      final acc = _MeshAcc();
      for (final f in faces) {
        acc.addFace(f, twoSided: true);
      }
      // Abdeckung oben: Innenkante hin, Außenkante zurück.
      final cap = [..._chain(inns, h), ..._chain(outs, h).reversed];

      if (cap.length >= 3) {
        acc.addFace(Face3(cap, V3.up), twoSided: true);
      }
      final geo = acc.geometry();
      final normal = fs.Mesh(geo, _mat.wall);
      final node = fs.Node(name: 'wall:${r.id}:${e.key}', mesh: normal)
        ..lightChannelMask = _maskOf(r.id);
      node.shadowCastingMode = fs.ShadowCastingMode.off;
      // Von oben ist die Außenkante der Raumumriss (eine Linie).
      node.add(
        _edgesNode('wall-edges', [
          for (final f in outs) Edge3(f.points[3], f.points[2]),
        ], lines.wall),
      );
      roomNode.add(node);
      // Schneehauben hängen an der Wand: weg, wenn die Wand weggeschnitten
      // ist.
      if (cap.length >= 3) _capPolys.add((node, cap));
      // Für Wegschneiden und „hängt an der Wand“: die längste Außenfläche.
      final rep = (outs.isEmpty ? inns : outs).reduce(
        (a, b) =>
            (a.points[1] - a.points[0]).length >=
                (b.points[1] - b.points[0]).length
            ? a
            : b,
      );
      _walls.add(
        _WallNode(r, rep, node)
          ..normal = normal
          ..selected = fs.Mesh(geo, _mat.wallSelected)
          ..front = fs.Mesh(geo, _mat.wallFront),
      );
    }
    if (openLines.isNotEmpty) {
      roomNode.add(_edgesNode('open-edges', openLines, lines.detail));
    }
  }

  /// Zusammenhängende Kette der Oberkanten von [faces] in Umlaufrichtung.
  static List<V3> _chain(List<Face3> faces, double h) {
    if (faces.isEmpty) return const [];
    // Die Flächen kommen in Umlaufrichtung, evtl. über den Anfang hinweg:
    // beim größten Sprung aufschneiden.
    var start = 0;
    var gap = -1.0;
    for (var i = 0; i < faces.length; i++) {
      final prev = faces[(i - 1 + faces.length) % faces.length];
      final d = (faces[i].points[0] - prev.points[1]).length;
      if (d > gap) {
        gap = d;
        start = i;
      }
    }
    final ordered = [...faces.sublist(start), ...faces.sublist(0, start)];
    return [
      V3(ordered.first.points[0].x, ordered.first.points[0].y, h),
      for (final f in ordered) V3(f.points[1].x, f.points[1].y, h),
    ];
  }

  final Map<String, double> _heights = {};
  String? _lastFadeKey;

  /// Kleinste Höhe flacher Räume (ganz 0 würde Normalen entarten lassen).
  static const double kFlat = 0.02;

  late _Materials _mat;

  /// Wie weit Lampenlicht reicht (siehe [LightReach]).
  final LightReach reach;

  /// Lichtzonen fürs Baking bei [reach].
  late final Map<String, String> _bakeZones = source.bakeZones(reach);

  /// Sichtbare Räume (`null`: alle).
  Set<String>? _focus;

  bool _shows(String? room) =>
      _focus == null || (room != null && _focus!.contains(room));

  bool _showsAny(Iterable<String> rooms) =>
      _focus == null || rooms.any(_focus!.contains);
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
  late final Map<String, int> _channel = roomChannels(
    source.rooms,
    // Nur offene Wände teilen sich das Echtzeitlicht; durch Türen fällt es
    // gebaken (sonst durch die Wände auf Möbel und Wände nebenan).
    source.liveZones(reach),
    lampReach(source),
  );

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

      // Wände mit Stärke: außen der runde Umriss (wie die 2D-Karte),
      // innen eckig (Möbel passen in die Ecken). Der Boden liegt innen.
      final outer = roundedInset(
        r.outline,
        inset: style.roomGap / 2,
        radius: style.roomRadius,
        open: r.openEdges,
        convexOnly: true,
      );
      final shape = roomFloor(r.outline, gap: style.roomGap, open: r.openEdges);
      _shapes[r.id] = shape;
      _outer[r.id] = outer;
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
      _buildWalls(r, roomNode, outer, shape, lines);
    }

    // Akzent-Umrandung je Raum, knapp über dem Boden, breiter als Kanten.
    for (final r in source.rooms) {
      final shape = _outer[r.id]!;
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
      // Türen und Fenster gleich im bekannten Zustand (Sensor).
      _addObject(
        (o.wallMounted || o.sensor != null) && _openState.containsKey(o.id)
            ? o.withOpen(_openState[o.id])
            : o,
      );
    }

    // Geräte (Bauform) und Leuchten.
    for (final m in source.markers) {
      final roomId = source.markerRoom[m.id];
      final spec = m.model == null ? null : deviceSpec(m.model);
      final how = spec?.mountOf(m.mount);
      // Montagepunkt: Wandgeräte an die nächste Wand, zum Raum gedreht.
      var at = m.position.xy;
      // Eigene Drehung nur bei drehbaren Bauformen; an der Wand richtet die
      // Wand aus.
      var rot = spec != null && spec.canRotate(how) ? m.rotation : 0.0;
      if (spec != null && spec.isWall(how) && roomId != null) {
        final pose = _wallPose(at, roomId);
        if (pose != null) (at, rot) = pose;
      }
      final mount = V3(at.dx, at.dy, m.position.z);
      if (spec != null) {
        _addObject(
          SceneObject(
            id: 'device:${m.id}',
            kind: 'device:${spec.id}${spec.isWall(how) ? '@wall' : ''}',
            model: spec.model(how, m.size),
            position: mount,
            rotation: rot,
            roomId: roomId,
            wallMounted: true,
            colors: m.colors,
          ),
        );
      }
      final lamp = m.lamp;
      if (m.kind != MarkerKind.light || lamp == null) continue;
      // Leuchtender Teil und Lichtquelle: nicht im Raumknoten, Lampen
      // bleiben auf ihrer Höhe, auch wenn der Raum flach ist.
      final node = fs.Node(name: 'lamp:${m.id}')
        ..position = toFs(mount)
        ..rotation = vm.Quaternion.axisAngle(
          // (x, y, z) → (x, z, -y): Drehung um z wird Drehung um y, gleicher
          // Sinn.
          vm.Vector3(0, 1, 0),
          rot * math.pi / 180,
        );
      // Lichtquelle und Kegel folgen der Montage: Kind-Knoten gekippt um x
      // (gleicher Sinn wie in haven), der Kegel zeigt dann mit.
      final tilt = switch (how) {
        DeviceMount.wall => -math.pi / 2,
        DeviceMount.up => math.pi,
        _ => 0.0,
      };
      final holder = fs.Node(name: 'mount:${m.id}')
        ..rotation = vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), tilt);
      node.add(holder);
      _lampMask[m.id] = roomId == null ? 0xFF : _maskOf(roomId);
      _lampState[m.id] = lamp;
      _lampCone[m.id] = m.cone;
      _lampSoft[m.id] = m.coneSoftness ?? kConeSoftness;
      final lightNode = fs.Node(name: 'light:${m.id}')
        ..position = toFs(V3(0, 0, spec?.lamp?.lightZ ?? 0));
      final light = _lightComponent(m.id, lamp);
      lightNode.addComponent(light);
      holder.add(lightNode);
      final glow = spec?.glowModel(how);
      final geo = glow == null || glow.faces.isEmpty
          ? _bulbGeometry
          : (() {
              final acc = _MeshAcc();
              for (final f in glow.faces) {
                acc.addFace(f, twoSided: f.twoSided);
              }
              return acc.geometry();
            })();
      _bulbGeos[m.id] = geo;
      final bulb = fs.Node(
        name: 'bulb:${m.id}',
        mesh: fs.Mesh(geo, _mat.bulb(lamp)),
      );
      node.add(bulb);
      _lampNodes[m.id] = light;
      _bulbs[m.id] = bulb;
      _bulbRoom[m.id] = roomId;
      final rad = rot * math.pi / 180;
      _lampWorld[m.id] =
          mount + (spec?.lightOffset(how) ?? V3.zero).rotateZ(rad);
      _lampAxis[m.id] = (spec?.lightAxis(how) ?? const V3(0, 0, -1)).rotateZ(
        rad,
      );
      scene.add(node);
    }

    _buildRoomLights();
    if (quality.bakes) {
      if (deferBake) {
        // Erst die Geometrie zeigen, Licht folgt aus dem Hintergrund.
        _bakePending = true;
        _dirty.addAll(_receivers);
        return;
      }
      // Je Lichtzone: Lampen leuchten in alle Räume der Zone, Wände halten
      // das Licht auf (nur offene Wände und Türen lassen es durch).
      for (final z in _zones()) {
        _bakeZone(z);
      }
    }
  }

  /// Öffnungen von Türen und Fenstern (Welt) für [_cutDoors], einmal je
  /// Szene.
  late final List<({Offset a, Offset b, double z0, double z1})> _doors = [
    for (final o in source.objects) ?o.wallOpening,
  ];

  /// Wand [w] ohne die Türen und Fenster darin: Stücke links und rechts in
  /// voller Höhe, über der Öffnung ein Sturz, unter einem Fenster die
  /// Brüstung. Öffnungen wirken auf alle Wände, die sie berühren (beide
  /// Räume, gleich auf welcher Seite, auch über eine Raumgrenze hinweg).
  List<Face3> _cutDoors(Face3 w) {
    if (_doors.isEmpty) return [w];
    final a = w.points[0].xy, b = w.points[1].xy;
    final h = w.points[2].z;
    final e = b - a;
    final len = e.distance;
    if (len < 1e-6) return [w];
    final u = e / len;
    double along(Offset p) => (p - a).dx * u.dx + (p - a).dy * u.dy;
    double across(Offset p) => ((p - a).dx * u.dy - (p - a).dy * u.dx).abs();
    final cuts = <(double, double, double, double)>[];
    for (final d in _doors) {
      final o = d.b - d.a;
      if (o.distance < 1e-6) continue;
      // Parallel zur Wand und nah an ihr (Wandstärke plus Spalt).
      final par = (o.dx * u.dy - o.dy * u.dx).abs() / o.distance;
      if (par > 0.2 || across(d.a) > 0.3 || across(d.b) > 0.3) continue;
      final t0 = math.max(0.0, math.min(along(d.a), along(d.b)));
      final t1 = math.min(len, math.max(along(d.a), along(d.b)));
      if (t1 - t0 > 0.05) {
        cuts.add((t0, t1, math.min(d.z0, h), math.min(d.z1, h)));
      }
    }
    if (cuts.isEmpty) return [w];
    cuts.sort((x, y) => x.$1.compareTo(y.$1));
    Face3 piece(double t0, double t1, double z0, double z1) {
      final p = a + u * t0, q = a + u * t1;
      return Face3(
        [
          V3(p.dx, p.dy, z0),
          V3(q.dx, q.dy, z0),
          V3(q.dx, q.dy, z1),
          V3(p.dx, p.dy, z1),
        ],
        w.normal,
        mat: w.mat,
      );
    }

    final out = <Face3>[];
    var t = 0.0;
    for (final (t0, t1, bottom, top) in cuts) {
      if (t0 > t + 1e-3) out.add(piece(t, t0, 0, h));
      final from = math.max(t, t0);
      if (t1 > from) {
        if (bottom > 0.02) out.add(piece(from, t1, 0, bottom));
        if (top < h - 0.02) out.add(piece(from, t1, top, h));
      }
      t = math.max(t, t1);
    }
    if (len > t + 1e-3) out.add(piece(t, len, 0, h));
    return out;
  }

  /// Knoten eines Möbelstücks (Körper, gebakene Oberseiten, Kanten) bauen
  /// und in seinen Raum hängen.
  _ObjectNode _addObject(SceneObject o) {
    // Geräte stehen nicht in `source.objects`: ihr Raum kommt mit.
    final roomId = source.objectRoom[o.id] ?? o.roomId;
    // Über mehrere Räume (Tür, Fenster zwischen zwei Räumen oder über eine
    // Raumgrenze): nicht im Raumknoten, steht, solange einer der Räume
    // steht (siehe [sync]).
    final rooms = source.objectRooms[o.id] ?? {?roomId};
    final spans = rooms.length > 1;
    final parent = roomId == null || spans ? null : _roomNodes[roomId];
    final node = fs.Node(name: 'object:${o.id}')
      ..lightChannelMask = spans
          ? rooms.fold<int>(0, (m, r) => m | _maskOf(r))
          : _maskOf(roomId);
    // Je Material und eigener Farbe (Farbzone) ein Teil.
    final byMat = <(Mat, Color?), _MeshAcc>{};
    final tops = <Face3>[];
    for (final f in o.world.faces) {
      // Waagerechte Oberseiten bekommen gebakenes Lampenlicht (eigene
      // Fläche), der Rest Echtzeitlicht.
      // Türen, Fenster und Möbel mit Sensor nicht: sie wechseln mit dem
      // Sensor das Modell.
      if (roomId != null &&
          !o.wallMounted &&
          o.sensor == null &&
          !f.twoSided &&
          f.mat != Mat.glass &&
          f.normal.z > 0.95) {
        tops.add(f);
        continue;
      }
      byMat
          .putIfAbsent((f.mat, o.colorOf(f)), () => _MeshAcc())
          .addFace(f, twoSided: f.twoSided);
    }
    final parts = [
      for (final e in byMat.entries)
        if (!e.value.isEmpty) (e.value.geometry(), e.key.$1, e.key.$2),
    ];
    // Geräte etwas dunkler als Möbel (aber kaum), damit man sie erkennt.
    final device = o.kind.startsWith('device:');
    final mesh = fs.Mesh.primitives(
      primitives: [
        for (final (g, m, c) in parts)
          // Glas wirft keinen Schatten (Sonne durchs Fenster).
          fs.MeshPrimitive(g, device ? _mat.device(m, c) : _mat.surface(m, c))
            ..castsShadow = m != Mat.glass,
      ],
    );
    node.mesh = mesh;
    final topPolys = <List<V3>>[];
    for (final f in tops) {
      final c = o.colorOf(f);
      final z =
          f.points.map((p) => p.z).reduce((a, b) => a + b) / f.points.length;
      final poly = [for (final p in f.points) V3(p.x, p.y, z)];
      topPolys.add(poly);
      _roomReceivers[roomId]!.add(_receivers.length);
      node.add(_receiverNode('top:${o.id}', poly, (s) => s.colorOf(f.mat, c)));
    }
    // Keine Echtzeit-Schatten: Sonne und Lampen sind auf Böden und
    // Oberseiten gebaken (mit voller Möbelhöhe, auch in flachen Räumen).
    // Mit Himmel werfen Möbel echte Schatten (Sonne durchs Fenster).
    node.shadowCastingMode = _sky != null
        ? fs.ShadowCastingMode.on
        : fs.ShadowCastingMode.off;
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
    return _objects[o.id] = _ObjectNode(o, roomId, node, normal, accent)
      ..rooms = rooms
      ..mesh = mesh
      ..parts = parts
      ..tops = topPolys;
  }

  // --- Türen und Fenster mit Sensor --------------------------------------

  final Map<String, bool?> _openState = {};

  /// Tür oder Fenster [id] offen (`true`), zu (`false`) oder unbekannt
  /// zeigen. Baut nur dieses Objekt neu; das Licht der Zone wird danach in
  /// Scheiben neu gebacken (eine geschlossene Tür hält es auf).
  void setObjectOpen(String id, bool? open) {
    final cur = _objects[id];
    if (cur == null || (!cur.object.wallMounted && cur.object.sensor == null)) {
      return;
    }
    if (_openState.containsKey(id) && _openState[id] == open) return;
    _openState[id] = open;
    cur.node.parent?.remove(cur.node);
    final next = _addObject(cur.object.withOpen(open));
    if (cur.height != null) {
      next.node.scale = vm.Vector3(1, math.max(cur.height!, kFlat), 1);
      next.height = cur.height;
    }
    // Auswahl, Ausblendung und Tönung beim nächsten sync neu anwenden.
    _selected = const {'\u0000'};
    _hiddenObjects = const {'\u0000'};
    if (_heat != null) _setHeatmap(_heat);
    // Türen halten Licht auf (ein Kühlschrank nicht).
    if (quality.bakes && cur.roomId != null && cur.object.wallMounted) {
      _rebakeZoneOf(cur.roomId!);
    }
  }

  /// Gebakenes Lampenlicht der Zone von [roomId] neu, als Aufträge für
  /// [flushLight] (wenige Millisekunden je Bild).
  void _rebakeZoneOf(String roomId) {
    if (_baking) _staleRooms.add(roomId);
    final zone = _bakeZones[roomId] ?? roomId;
    final byRoom = {
      for (final e in _roomReceivers.entries)
        if ((_bakeZones[e.key] ?? e.key) == zone)
          e.key: [for (final i in e.value) _receivers[i]],
    };
    final occ = _zoneOccluders(byRoom.keys.toSet());
    for (final m in source.markers) {
      final home = source.markerRoom[m.id];
      if (m.kind != MarkerKind.light || m.lamp == null) continue;
      if (!byRoom.containsKey(home)) continue;
      for (final e in byRoom.entries) {
        for (final r in e.value) {
          _jobs.add(() {
            _bakePair(m, r, own: e.key == home, occ: occ);
            _dirty.add(r);
          });
        }
      }
    }
  }

  /// Ausstehende Bake-Aufträge (siehe [flushLight]).
  final List<void Function()> _jobs = [];

  fs.PointLight _pointLight(LampState s, int mask) => fs.PointLight(
    color: linearColor(s.color).xyz,
    intensity: s.on && quality.realtimeLamps && _lightsOn
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
    if (!_lampNodes.containsKey(id)) return;
    if (_lampState[id] == s) return;
    _lampState[id] = s;
    _applyLamp(id, s);
    for (final r in _receivers) {
      if (r.lamps.containsKey(id)) _dirty.add(r);
    }
    // Raumlicht: der ganze Raum der Lampe.
    final room = _bulbRoom[id];
    if (room != null) {
      _applyRoomLight(room);
      for (final i in _roomReceivers[room] ?? const <int>[]) {
        _dirty.add(_receivers[i]);
      }
    }
  }

  // --- Raumlicht -----------------------------------------------------------

  /// Füll-Licht je Raum mit Lampen (Echtzeit, im Lichtkanal des Raums).
  final Map<String, fs.PointLightComponent> _roomLights = {};

  /// Summe der Lampen eines Raums: Helligkeit · Farbe (linear). Linear in
  /// jeder Lampe, damit die Lichtebenen (eine Lampe je Bild) exakt bleiben.
  vm.Vector3 _roomLightOf(String room) {
    final sum = vm.Vector3.zero();
    if (!_lightsOn) return sum;
    for (final e in _lampState.entries) {
      final s = e.value;
      if (!s.on || s.brightness <= 0 || _bulbRoom[e.key] != room) continue;
      sum.add(linearColor(s.color).xyz * s.brightness);
    }
    return sum;
  }

  void _buildRoomLights() {
    final rooms = {for (final r in _bulbRoom.values) ?r};
    for (final id in rooms) {
      final room = source.room(id);
      if (room == null || room.outline.isEmpty) continue;
      var cx = 0.0, cy = 0.0;
      var x0 = double.infinity, y0 = double.infinity;
      var x1 = -double.infinity, y1 = -double.infinity;
      for (final p in room.outline) {
        cx += p.dx;
        cy += p.dy;
        x0 = math.min(x0, p.dx);
        y0 = math.min(y0, p.dy);
        x1 = math.max(x1, p.dx);
        y1 = math.max(y1, p.dy);
      }
      final n = room.outline.length;
      final range = math.max(
        3.0,
        1.1 * math.sqrt(math.pow(x1 - x0, 2) + math.pow(y1 - y0, 2)),
      );
      final light = fs.PointLightComponent(_roomPointLight(id, range));
      final node = fs.Node(name: 'roomlight:$id')
        ..position = toFs(V3(cx / n, cy / n, room.wallHeight * 0.85));
      node.addComponent(light);
      scene.add(node);
      _roomLights[id] = light;
      _roomLightRange[id] = range;
    }
  }

  final Map<String, double> _roomLightRange = {};

  fs.PointLight _roomPointLight(String room, double range) {
    final f = _roomLightOf(room);
    final peak = math.max(f.x, math.max(f.y, f.z));
    return fs.PointLight(
      color: peak > 0 ? f / peak : vm.Vector3(1, 1, 1),
      intensity: peak > 0 && quality.realtimeLamps
          ? kRoomLightLive * peak * style.lampGlow
          : 0,
      range: range,
      channelMask: _maskOf(room),
    );
  }

  void _applyRoomLight(String room) {
    final c = _roomLights[room];
    if (c == null) return;
    c.light = _roomPointLight(room, _roomLightRange[room] ?? 5);
  }

  /// Raum jeder Fläche (für das gebakene Raumlicht).
  late final Map<_Receiver, String> _receiverRoom = {
    for (final e in _roomReceivers.entries)
      for (final i in e.value) _receivers[i]: e.key,
  };

  final Map<int, Float32List> _ones = {};

  /// Echtzeitlicht und Glühbirne einer Lampe (ohne Baking).
  void _applyLamp(String id, LampState s) {
    final c = _lampNodes[id];
    if (c is fs.SpotLightComponent) {
      c.light = _spotLight(
        s,
        _lampMask[id] ?? 0xFF,
        _lampCone[id]!,
        _lampSoft[id] ?? kConeSoftness,
      );
    } else if (c is fs.PointLightComponent) {
      c.light = _pointLight(s, _lampMask[id] ?? 0xFF);
    }
    _bulbs[id]!.mesh = fs.Mesh(
      _bulbGeos[id] ?? _bulbGeometry,
      _mat.bulb(_lightsOn ? s : LampState.off),
    );
  }

  fs.Component _lightComponent(String id, LampState s) {
    final cone = _lampCone[id];
    final mask = _lampMask[id] ?? 0xFF;
    return cone == null
        ? fs.PointLightComponent(_pointLight(s, mask))
        : fs.SpotLightComponent(
            _spotLight(s, mask, cone, _lampSoft[id] ?? kConeSoftness),
          );
  }

  /// Lichtkegel nach unten (Spot, Pendel, Deckenleuchte).
  fs.SpotLight _spotLight(
    LampState s,
    int mask,
    double cone,
    double softness,
  ) => fs.SpotLight(
    color: linearColor(s.color).xyz,
    intensity: s.on && quality.realtimeLamps && _lightsOn
        ? 40.0 * s.brightness * style.lampGlow
        : 0,
    range: 7,
    // Wie `coneFactor` beim Baking: weicher Rand über [softness].
    innerConeAngle: cone * (1 - softness.clamp(0.02, 1.0)),
    outerConeAngle: cone,
    channelMask: mask,
  );

  // --- Vorschau beim Platzieren ----------------------------------------

  fs.Node? _previewNode;
  String? _previewModel;

  /// Vorschau eines Geräts [model] beim Platzieren: bei [at] (Meter) auf der
  /// Höhe [z]; Wandgeräte rasten an der nächsten Wand von [roomId] ein.
  /// `null` entfernt die Vorschau. Verschieben kostet nur eine Transformation.
  void setPreview(
    String? model, {
    Offset at = Offset.zero,
    double z = 0,
    String? roomId,
    DeviceMount? mount,
  }) {
    if (model == null) {
      final n = _previewNode;
      if (n != null) scene.root.remove(n);
      _previewNode = null;
      _previewModel = null;
      return;
    }
    final spec = deviceSpec(model);
    final how = spec.mountOf(mount);
    final key = '$model@${how?.name}';
    if (key != _previewModel || _previewNode == null) {
      final old = _previewNode;
      if (old != null) scene.root.remove(old);
      final m = spec.model(how);
      final g = spec.glowModel(how);
      final acc = _MeshAcc();
      for (final f in [...m.faces, ...?g?.faces]) {
        acc.addFace(f, twoSided: true);
      }
      final node = fs.Node(name: 'preview')
        ..mesh = acc.isEmpty ? null : fs.Mesh(acc.geometry(), _mat.preview);
      final edges = featureEdges(m);
      if (edges.isNotEmpty) {
        node.add(_edgesNode('preview-edges', edges, _mat.accentEdge));
      }
      scene.add(node);
      _previewNode = node;
      _previewModel = key;
    }
    var pos = at;
    var rot = 0.0;
    if (spec.isWall(how) && roomId != null) {
      final pose = _wallPose(at, roomId);
      if (pose != null) (pos, rot) = pose;
    }
    _previewNode!
      ..position = toFs(V3(pos.dx, pos.dy, z))
      ..rotation = vm.Quaternion.axisAngle(
        vm.Vector3(0, 1, 0),
        rot * math.pi / 180,
      );
  }

  /// Wandgerät an die nächste Wand seines Raums: Punkt auf der Wand und
  /// Drehung (Grad), so dass die Vorderseite (-y) in den Raum zeigt.
  /// `null`, wenn keine Wand nah genug ist (frei stehend).
  (Offset, double)? _wallPose(Offset p, String roomId) {
    final shape = _shapes[roomId];
    if (shape == null || shape.length < 3) return null;
    Offset? best;
    Offset? dir;
    var bestD = 0.8;
    for (var i = 0; i < shape.length; i++) {
      final a = shape[i], b = shape[(i + 1) % shape.length];
      final e = b - a;
      final len2 = e.distanceSquared;
      if (len2 < 1e-9) continue;
      final t = (((p - a).dx * e.dx + (p - a).dy * e.dy) / len2).clamp(
        0.0,
        1.0,
      );
      final q = a + e * t;
      final d = (p - q).distance;
      if (d < bestD) {
        bestD = d;
        best = q;
        dir = e / math.sqrt(len2);
      }
    }
    if (best == null || dir == null) return null;
    // Nach außen zeigende Normale (weg vom Raum).
    var out = Offset(-dir.dy, dir.dx);
    final room = source.room(roomId);
    if (room != null && room.contains(best + out * 0.05)) out = -out;
    final deg = math.atan2(-out.dx, out.dy) * 180 / math.pi;
    return (best, deg);
  }

  /// Lampenlicht zeigen? Aus (z. B. bei Heatmaps): nur Sonne und Umgebung,
  /// Wände und Böden bleiben neutral grau.
  bool _lightsOn = true;

  void _setLightsOn(bool on) {
    if (on == _lightsOn) return;
    _lightsOn = on;
    for (final e in _lampState.entries) {
      _applyLamp(e.key, e.value);
    }
    for (final room in _roomLights.keys) {
      _applyRoomLight(room);
    }
    // Nur neu mischen (in Scheiben), gebacken ist schon alles.
    _dirty.addAll(_receivers);
  }

  late final fs.Geometry _bulbGeometry = fs.SphereGeometry(radius: 0.07);

  /// Vorgemerkte Flächen, die neu gemischt werden müssen (Reihenfolge der
  /// Anmeldung).
  final Set<_Receiver> _dirty = <_Receiver>{};

  /// Gibt es noch vorgemerkte Flächen?
  bool get lightPending => _dirty.isNotEmpty || _jobs.isNotEmpty;

  /// Vorgemerkte Flächen neu mischen, höchstens etwa [budget] lang (der
  /// Rest folgt im nächsten Bild). `true`: es bleibt noch etwas übrig.
  bool flushLight({Duration budget = const Duration(milliseconds: 5)}) {
    if (_dirty.isEmpty && _jobs.isEmpty) return false;
    final sw = Stopwatch()..start();
    while (_jobs.isNotEmpty) {
      _jobs.removeAt(0)();
      if (sw.elapsed >= budget) return true;
    }
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
    // Mit Himmel kommt die Sonne in Echtzeit (mit Schatten durch Fenster).
    if (sun != null && style.sun > 0 && _sky == null) {
      final ks = kSunIntensity * style.sun / math.pi;
      add(sun, r.sunOpen, ks * albedo.x, ks * albedo.y, ks * albedo.z);
    }
    for (final e in r.lamps.entries) {
      final s = _lampState[e.key];
      if (s == null || !s.on || !_lightsOn) continue;
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
    // Raumlicht: gleichmäßig über die ganze Fläche, in der Lampenfarbe.
    final room = _receiverRoom[r];
    if (room != null) {
      final f = _roomLightOf(room);
      if (f.x > 0 || f.y > 0 || f.z > 0) {
        final n = r.bake.width * r.bake.height;
        final ones = _ones.putIfAbsent(
          n,
          () => Float32List(n)..fillRange(0, n, 1),
        );
        final kr = k * kRoomLightBaked;
        parts.add((
          ones,
          kr * f.x * albedo.x,
          kr * f.y * albedo.y,
          kr * f.z * albedo.z,
        ));
      }
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
        // Geräte behalten ihre Farbe.
        if (o.roomId != r.id || o.object.kind.startsWith('device:')) continue;
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
            for (final (g, m, c) in o.parts)
              fs.MeshPrimitive(
                g,
                m == Mat.glass ? _mat.surface(m) : _tinted(m, c, heat, mix),
              ),
          ],
        );
      }
    }
  }

  fs.PhysicallyBasedMaterial _tinted(
    Mat m,
    Color? own,
    Color heat,
    double mix,
  ) {
    final base = style.colorOf(m, own);
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
    return r
        .node = fs.Node(name: name, mesh: fs.Mesh(_receiverGeometry(bake), mat))
      // Lampen nur gebaken (Wände halten ihr Licht auf). Ohne Baking
      // (Entwurf) alles in Echtzeit. Mit Himmel (`setSky`) erreicht die
      // Sonne die Fläche trotzdem in Echtzeit (sie leuchtet in alle Kanäle).
      ..lightChannelMask = quality.bakes ? kBakedChannel : 0xFF;
  }

  void _paintReceiver(_Receiver r) {
    var c = r.color(style);
    // Mit Boden darunter deckend: sonst schienen Wiese und Schnee durch.
    if (_groundSpec != null) c = c.withValues(alpha: 1);
    r.material.baseColorFactor = linearColor(c, c.a);
    r.material.alphaMode = c.a < 1 ? fs.AlphaMode.blend : fs.AlphaMode.opaque;
  }

  /// Bake aller Lampen eines Raums auf seine Flächen.
  /// Hindernisse für das Licht einer Zone: Möbel (Sonne, eigener Raum),
  /// Möbel und Wände (Lampen in Nachbarräumen), nur Wände und Türblätter
  /// (Streulicht in Nachbarräume). Mit dem aktuellen Zustand der Türen.
  ({LightOccluders objects, LightOccluders lamp, LightOccluders walls})
  _zoneOccluders(Set<String> roomIds) {
    final inZone = [
      for (final o in _objects.values)
        if (roomIds.contains(o.roomId) && !o.object.kind.startsWith('device:'))
          o.object,
    ];
    final objects = [for (final o in inZone) o.world];
    final occ = LightOccluders(objects);
    final multi = roomIds.length > 1;
    // Eine Wand je Modell, damit der Hüllquader-Test billig bleibt.
    final walls = [
      if (multi)
        for (final id in roomIds)
          for (final w in _wallFaces[id] ?? const <Face3>[])
            Model3([w], const []),
    ];
    return (
      objects: occ,
      lamp: !multi ? occ : LightOccluders([...objects, ...walls]),
      walls: LightOccluders([
        ...walls,
        if (multi)
          for (final o in inZone)
            if (o.kind == 'door') o.world,
      ]),
    );
  }

  /// Licht von Lampe [m] auf Fläche [r] backen. [own]: die Fläche liegt im
  /// Raum der Lampe (Wände halten dort nichts auf).
  LampBakeTask _lampTask(
    SceneMarker m,
    _Receiver r, {
    required bool own,
    required ({
      LightOccluders objects,
      LightOccluders lamp,
      LightOccluders walls,
    })
    occ,
  }) {
    var pos = _lampWorld[m.id] ?? m.lightPosition;
    final axis = _lampAxis[m.id] ?? m.lightAxis;
    var cone = m.cone;
    final softness = m.coneSoftness ?? kConeSoftness;
    var gain = 1.0;
    if (axis.z > 0.5) {
      // Nach oben (Uplight): Licht kommt erst von der Decke zurück, weich
      // und schwächer, als wäre dort eine Lampe ohne Kegel.
      final room = source.room(source.markerRoom[m.id] ?? '');
      pos = V3(pos.x, pos.y, (room?.wallHeight ?? kDefaultWallHeight) - 0.05);
      cone = null;
      gain = 0.35;
    }
    return LampBakeTask(
      _receivers.indexOf(r),
      r.bake,
      quality.bakeSamples,
      lampId: m.id,
      position: pos,
      axis: axis,
      cone: cone,
      softness: softness,
      gain: gain,
      own: own,
      objects: occ.objects,
      lamp: occ.lamp,
      walls: occ.walls,
    );
  }

  /// Licht von Lampe [m] auf Fläche [r] backen. [own]: die Fläche liegt im
  /// Raum der Lampe (Wände halten dort nichts auf).
  void _bakePair(
    SceneMarker m,
    _Receiver r, {
    required bool own,
    required ({
      LightOccluders objects,
      LightOccluders lamp,
      LightOccluders walls,
    })
    occ,
  }) => _applyBake(runBakeTask(_lampTask(m, r, own: own, occ: occ)));

  /// Alle Bake-Aufträge einer Lichtzone (Sonne und Lampen).
  List<BakeTask> _zoneTasks(Map<String, List<_Receiver>> byRoom) {
    final receivers = [for (final l in byRoom.values) ...l];
    final occ = _zoneOccluders(byRoom.keys.toSet());
    return [
      for (final r in receivers) _sunTask(r, occ.objects),
      for (final m in source.markers)
        if (m.kind == MarkerKind.light &&
            m.lamp != null &&
            byRoom.containsKey(source.markerRoom[m.id]))
          for (final e in byRoom.entries)
            for (final r in e.value)
              _lampTask(m, r, own: e.key == source.markerRoom[m.id], occ: occ),
    ];
  }

  /// Alle Lichtzonen der Szene, Räume mit ihren Flächen.
  List<Map<String, List<_Receiver>>> _zones() {
    final zones = <String, Set<String>>{};
    for (final id in _roomReceivers.keys) {
      (zones[_bakeZones[id] ?? id] ??= {}).add(id);
    }
    return [
      for (final z in zones.values)
        {
          for (final id in z)
            id: [for (final i in _roomReceivers[id]!) _receivers[i]],
        },
    ];
  }

  bool _baking = false;

  /// Das erste Baking läuft noch (siehe [bakeInBackground]).
  bool get baking => _baking;

  /// Während des Bakings im Hintergrund geänderte Räume und Sonne: danach
  /// neu (das Ergebnis aus dem Hintergrund ist für sie veraltet).
  final Set<String> _staleRooms = {};
  bool _staleSun = false;

  /// Erstes Baking (bei `deferBake`) im Hintergrund: in einem eigenen Isolate
  /// über [compute], im Web (ohne Isolates) in Scheiben über [flushLight].
  /// Bis dahin zeigt die Szene ungebakenes Licht.
  Future<void> bakeInBackground() async {
    if (!_bakePending) return;
    _bakePending = false;
    final tasks = [for (final z in _zones()) ..._zoneTasks(z)];
    if (kIsWeb) {
      for (final t in tasks) {
        _jobs.add(() {
          _applyBake(runBakeTask(t));
          _dirty.add(_receivers[t.receiver]);
        });
      }
      return;
    }
    _baking = true;
    try {
      final results = await compute(
        runBakeTasks,
        tasks,
        debugLabel: 'haven_3d bake',
      );
      for (final b in results) {
        _applyBake(b);
      }
      _dirty.addAll(_receivers);
    } finally {
      _baking = false;
    }
    if (_staleSun) {
      _staleSun = false;
      _queueSunBake();
    }
    for (final id in [..._staleRooms]) {
      _rebakeZoneOf(id);
    }
    _staleRooms.clear();
  }

  bool _bakePending = false;

  void _bakeZone(Map<String, List<_Receiver>> byRoom) {
    for (final t in _zoneTasks(byRoom)) {
      _applyBake(runBakeTask(t));
    }
    for (final l in byRoom.values) {
      for (final r in l) {
        _relight(r);
      }
    }
  }

  void _applyLighting() {
    scene.skybox = null; // durchsichtiger Hintergrund
    scene.antiAliasingMode = quality.msaa
        ? fs.AntiAliasingMode.auto
        : fs.AntiAliasingMode.fxaa;
    scene.toneMapping = fs.ToneMappingMode.pbrNeutral;
    final sky = _sky;
    if (sky != null) {
      final l = sky.light;
      scene.environmentIntensity =
          0.9 * math.max(l.ambient, style.skyMinAmbient);
      scene.directionalLight = fs.DirectionalLight(
        direction: toFs(l.direction).normalized(),
        color: linearColor(l.color).xyz,
        intensity: kSunIntensity * kSkySunScale * l.intensity,
        // Alles in Echtzeit, mit Schatten: Decken und Wände (unsichtbar)
        // lassen Licht nur durch Fenster und Türen.
        channelMask: 0xFF,
        castsShadow: l.intensity > 0.002,
        shadowSoftness: l.softness,
        shadowMaxDistance: kCameraDistance + 20,
        shadowCascadeCount: 1,
        shadowMapResolution: 2048,
        shadowCasterFaces: fs.ShadowCasterFaces.both,
        shadowFilter: fs.DirectionalShadowFilter.fixedPcf,
      );
      return;
    }
    scene.environmentIntensity = 0.9 * style.ambient;
    scene.directionalLight = style.sun <= 0
        ? null
        : fs.DirectionalLight(
            // Von oben links hinten, etwas schräg: Schatten fallen nach
            // rechts unten wie bei den Karten-Schatten der App.
            direction: toFs(_sunDir).normalized(),
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
    for (final room in _roomLights.keys) {
      _applyRoomLight(room);
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
  bool _groundPaint = false;

  void sync(
    OrbitCamera cam, {
    String? focusRoomId,
    Set<String>? focusRooms,
    Set<String> selected = const {},
    Map<String, double> heights = const {},
    Size? size,
    String? selectedRoomId,
    SceneHeatmap? heatmap,
    Set<String> hiddenObjects = const {},
    bool lightsOn = true,
  }) {
    if (_groundPaint) {
      _groundPaint = false;
      final g = _groundSpec;
      if (g != null) _ground?.paint(g.color, g.snow);
    }
    if (selectedRoomId != _selectedRoom) {
      _roomOutlines[_selectedRoom]?.visible = false;
      _selectedRoom = selectedRoomId;
      _roomOutlines[selectedRoomId]?.visible = true;
    }
    if (!identical(heatmap, _heat)) _setHeatmap(heatmap);
    _setLightsOn(lightsOn);
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
    var roofChanged = false;
    for (final e in _roomNodes.entries) {
      final h = (heights[e.key] ?? 1).clamp(0.0, 1.0);
      if (_heights[e.key] != h) {
        _heights[e.key] = h;
        e.value.scale = vm.Vector3(1, math.max(h, kFlat), 1);
        // Flache Räume haben keine Decke.
        _casters[e.key]?.visible = _sky != null && h > 0.5;
        roofChanged = true;
      }
    }
    if (roofChanged) _syncRoof();
    // Objekte über mehrere Räume: so hoch wie der höchste ihrer Räume.
    for (final o in _objects.values) {
      if (o.rooms.length < 2) continue;
      var h = 0.0;
      for (final r in o.rooms) {
        h = math.max(h, (heights[r] ?? 1).clamp(0.0, 1.0));
      }
      if (o.height != h) {
        o.height = h;
        o.node.scale = vm.Vector3(1, math.max(h, kFlat), 1);
      }
    }
    // Nur diese Räume zeigen (einer: Raumansicht; mehrere: etwa die
    // Nachbarn eines Raums für fertige Bilder).
    final focus = focusRooms ?? (focusRoomId == null ? null : {focusRoomId});
    if (!(focus == null
        ? _focus == null
        : _focus != null && _setEquals(focus, _focus!))) {
      _focus = focus == null ? null : {...focus};
      for (final e in _roomNodes.entries) {
        e.value.visible = _shows(e.key);
      }
      for (final o in _objects.values) {
        if (o.roomId == null) {
          o.node.visible = _focus == null;
        } else if (o.rooms.length > 1) {
          o.node.visible = _showsAny(o.rooms);
        }
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
    _stepPulse();
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
      e.value.visible = h > 0.5 && _shows(room);
    }
    // Wände zur Kamera hin ausblenden, Türen und Fenster darin mit.
    final cut = <_WallNode>{};
    final ghost = <_WallNode>{};
    for (final w in _walls) {
      final raised = (_heights[w.room.id] ?? 1) > 0.5;
      final near = raised && style.cutaway && cam.facing(w.face.normal) > 0.02;
      // Gewählter Raum: Wände deutlich, die vorderen durchscheinend statt
      // weggeschnitten (Türen und Fenster darin bleiben).
      if (raised && w.room.id == _selectedRoom) {
        final m = near ? w.front : w.selected;
        if (!identical(w.node.mesh, m)) w.node.mesh = m;
        w.node.visible = true;
        if (near) ghost.add(w);
        continue;
      }
      if (!identical(w.node.mesh, w.normal)) w.node.mesh = w.normal;
      w.node.visible = !near;
      if (near) cut.add(w);
    }
    for (final o in _objects.values) {
      final inFocus = _showsAny(o.rooms);
      if (!_onWallThing(o.object)) {
        if (o.object.wallMounted) o.node.visible = inFocus;
        continue;
      }
      // Weg nur, wenn jede stehende Wand, in der es sitzt, ausgeschnitten
      // ist (zwischen zwei Räumen bleibt es an der hinteren Wand).
      final on = _wallsOf[o.object.id] ??= [
        for (final w in _walls)
          if (o.rooms.contains(w.room.id) && _onWall(o.object, w.face)) w,
      ];
      var standing = 0, removed = 0;
      // An einer durchscheinenden Wand (gewählter Raum, vorne): genauso
      // durchscheinend wie die Wand.
      var see = false;
      for (final w in on) {
        if ((_heights[w.room.id] ?? 1) <= 0.5) continue;
        standing++;
        if (cut.contains(w)) removed++;
        if (ghost.contains(w)) see = true;
      }
      _ghostObject(o, see);
      o.node.visible = !(standing > 0 && removed == standing) && inFocus;
    }
    // Ausgeblendete Möbel (z. B. gerade gezogen, ein Overlay zeigt sie).
    if (!_setEquals(hiddenObjects, _hiddenObjects)) {
      for (final id in {...hiddenObjects, ..._hiddenObjects}) {
        final o = _objects[id];
        if (o == null || o.object.wallMounted) continue;
        o.node.visible = !hiddenObjects.contains(id) && _shows(o.roomId);
      }
      _hiddenObjects = {...hiddenObjects};
    }
    for (final id in hiddenObjects) {
      _objects[id]?.node.visible = false;
    }
  }

  Set<String> _hiddenObjects = const {};

  /// Wände, in denen ein Objekt sitzt (je Szene fest).
  final Map<String, List<_WallNode>> _wallsOf = {};

  /// Je Raum: wie weit sein Licht an ist (0 … 1, weich nachgeführt).
  final Map<String, double> _lit = {};
  final Stopwatch _litClock = Stopwatch()..start();

  /// Lichtwechsel ohne Überblendung (für fertige Bilder, siehe
  /// `LayerRenderer`): Möbellinien springen sofort auf den neuen Stand.
  bool instantLight = false;

  /// Raum, dessen Möbellinien Lampe [id] ausblendet (`null`: draußen).
  String? lampRoom(String id) => _bulbRoom[id];

  /// Blenden die Möbellinien noch (Licht wurde geschaltet)?
  bool get fading => _fading || _pulsing.isNotEmpty;
  bool _fading = false;

  // --- Tönung von Geräten (z. B. Heizkörper rot beim Heizen) -----------------

  final Map<String, DeviceTint> _tints = {};

  /// Pulsierende Materialien je Gerät (Stärke wird je Bild gesetzt).
  final Map<String, List<fs.PhysicallyBasedMaterial>> _pulsing = {};
  final Stopwatch _pulseClock = Stopwatch()..start();

  /// Gerät [markerId] einfärben und leuchten lassen ([tint] `null`: normal).
  /// Pulsierend hält die Ansicht in Bewegung, solange es pulsiert.
  void setDeviceTint(String markerId, DeviceTint? tint) {
    if (_tints[markerId] == tint) return;
    if (tint == null) {
      _tints.remove(markerId);
    } else {
      _tints[markerId] = tint;
    }
    _applyTint(markerId);
  }

  void _applyTint(String markerId) {
    final o = _objects['device:$markerId'];
    _pulsing.remove(markerId);
    if (o == null) return;
    o.baseMesh ??= o.mesh;
    final tint = _tints[markerId];
    if (tint == null) {
      o.mesh = o.baseMesh;
    } else {
      final mats = <fs.PhysicallyBasedMaterial>[];
      o.mesh = fs.Mesh.primitives(
        primitives: [
          for (final (g, m, own) in o.parts)
            fs.MeshPrimitive(g, () {
              final base = _mat.surface(m, own);
              final c = linearColor(tint.color);
              final mat = fs.PhysicallyBasedMaterial()
                ..baseColorFactor = linearColor(
                  Color.lerp(style.colorOf(m, own), tint.color, 0.6)!,
                )
                ..metallicFactor = base.metallicFactor
                ..roughnessFactor = base.roughnessFactor
                ..emissiveFactor = vm.Vector4(c.x, c.y, c.z, 1)
                ..emissiveStrength = tint.glow;
              mats.add(mat);
              return mat;
            }()),
        ],
      );
      if (tint.pulse) _pulsing[markerId] = mats;
    }
    if (!o.ghosted) o.node.mesh = o.mesh;
  }

  void _stepPulse() {
    if (_pulsing.isEmpty) return;
    final t = _pulseClock.elapsedMilliseconds / 1000;
    // Etwa alle 1,6 s ein Atemzug.
    final k = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(t * 2 * math.pi / 1.6));
    for (final e in _pulsing.entries) {
      final g = _tints[e.key]?.glow ?? 1;
      for (final m in e.value) {
        m.emissiveStrength = g * k;
      }
    }
  }

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
      if (cur == null || instantLight) {
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

  /// Hängt an einer Wand (Tür, Fenster, Wandgerät)? Decken- und
  /// Bodengeräte nahe einer Wand zählen nicht.
  static bool _onWallThing(SceneObject o) {
    if (!o.wallMounted) return false;
    if (o.kind.startsWith('device:')) {
      return o.kind.endsWith('@wall') || deviceSpec(o.kind.substring(7)).wall;
    }
    return true;
  }

  /// Objekt [o] durchscheinend zeigen wie eine vordere Wand (oder wieder
  /// normal). Kanten blenden dabei aus.
  void _ghostObject(_ObjectNode o, bool on) {
    if (o.ghosted == on) return;
    o.ghosted = on;
    if (on) {
      o.beforeGhost = o.node.mesh;
      o.node.mesh = fs.Mesh.primitives(
        primitives: [
          for (final (g, _, _) in o.parts) fs.MeshPrimitive(g, _mat.wallFront),
        ],
      );
    } else {
      o.node.mesh = o.beforeGhost ?? o.mesh;
      o.beforeGhost = null;
    }
    o.edges.visible = !on;
    for (final c in o.node.children) {
      if (c.name == 'details') c.visible = !on;
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

  /// Alle Räume, die es berührt (siehe `Scene.objectRooms`).
  Set<String> rooms = const {};

  /// Höhe (0 … 1) bei Objekten über mehrere Räume, sonst `null`.
  double? height;

  /// Körper mit den gemeinsamen Materialien (ohne Heatmap-Tönung).
  fs.Mesh? mesh;

  /// Ungetönter Körper (siehe `setDeviceTint`).
  fs.Mesh? baseMesh;
  List<(fs.Geometry, Mat, Color?)> parts = const [];

  /// Waagerechte Oberseiten (gebakene Flächen), für die Heatmap-Färbung.
  List<List<V3>> tops = const [];

  /// Heatmap-Flächen über den Oberseiten.
  final List<fs.Node> heat = [];

  /// Durchscheinend an einer vorderen Wand (siehe `_ghostObject`).
  bool ghosted = false;
  fs.Mesh? beforeGhost;
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

  final Map<(Mat, Color?), fs.PhysicallyBasedMaterial> _surfaces = {};
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

  /// Vorschau beim Platzieren: Akzentfarbe, halb durchsichtig.
  final fs.UnlitMaterial preview = fs.UnlitMaterial();
  late SceneStyle _style;

  /// Material der Oberfläche [m], mit eigener Farbe [own] (Farbzone) ein
  /// eigenes, sonst das gemeinsame.
  fs.PhysicallyBasedMaterial surface(Mat m, [Color? own]) =>
      _surfaces.putIfAbsent((m, own), () => _surfaceFor(m, own));

  fs.PhysicallyBasedMaterial _surfaceFor(Mat m, Color? own) {
    final mat = fs.PhysicallyBasedMaterial();
    _paint(mat, m, own);
    return mat;
  }

  final Map<(Mat, Color?), fs.PhysicallyBasedMaterial> _devices = {};

  /// Material eines Geräts: wie [surface], nur leicht dunkler; dunkle
  /// Teile deutlich weniger dunkel als bei Möbeln (Bildschirm, Kochfeld).
  /// Eigene Farben bleiben, wie sie sind.
  fs.PhysicallyBasedMaterial device(Mat m, [Color? own]) =>
      _devices.putIfAbsent((m, own), () {
        final mat = fs.PhysicallyBasedMaterial();
        _paintDevice(mat, m, own);
        return mat;
      });

  void _paintDevice(fs.PhysicallyBasedMaterial mat, Mat m, Color? own) {
    _paint(mat, m, own);
    if (m == Mat.glass || own != null) return;
    final s = _style;
    final c = switch (m) {
      Mat.dark => Color.lerp(s.surface, s.dark, 0.45)!,
      Mat.screen => s.base(m),
      _ => Color.lerp(s.base(m), s.dark, kDeviceShade)!,
    };
    mat.baseColorFactor = linearColor(c, 1);
  }

  void _paint(fs.PhysicallyBasedMaterial mat, Mat m, [Color? own]) {
    final s = _style;
    mat.metallicFactor = 0;
    mat.baseColorFactor = linearColor(s.colorOf(m, own), 1);
    mat.roughnessFactor = switch (m) {
      Mat.soft || Mat.rug || Mat.wall => 1.0,
      Mat.glass => 0.15,
      Mat.screen => 0.22,
      Mat.ceramic => 0.38,
      Mat.dark || Mat.metal => 0.45,
      Mat.body || Mat.green => 0.85,
    };
    if (m == Mat.glass) {
      mat.baseColorFactor = linearColor(s.glass, 0.28);
      mat.alphaMode = fs.AlphaMode.blend;
      mat.doubleSided = true;
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
      _paint(e.value, e.key.$1, e.key.$2);
    }
    for (final e in _devices.entries) {
      _paintDevice(e.value, e.key.$1, e.key.$2);
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
    final glow = linearColor(s.wall, 1);
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
    for (final m in [wall, wallSelected, wallFront]) {
      m
        ..emissiveFactor = glow
        ..emissiveStrength = s.wallGlow;
    }
    _applyLineColors();
  }

  void setAccent(SceneStyle s) {
    _style = s;
    accentEdge.baseColorFactor = linearColor(s.accent, 1);
    _paintPreview();
  }

  void _paintPreview() {
    preview
      ..baseColorFactor = linearColor(_style.accent, 0.55)
      ..alphaMode = fs.AlphaMode.blend;
  }

  void _applyLineColors() {
    for (final l in _lines.values) {
      _paintLines(l);
    }
    _paintPreview();
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

/// Richtung des Sonnenlichts (von der Sonne zum Boden) aus [azimuth] (Grad,
/// von Norden im Uhrzeigersinn, wie `sun.sun` in Home Assistant) und
/// [elevation] (Grad über dem Horizont). [north]: wohin Norden auf dem Plan
/// zeigt, in Grad im Uhrzeigersinn von oben (0: oben ist Norden).
///
/// Für die Schattierung bleibt die Sonne zwischen [minElevation] und 70°:
/// nachts und tief am Horizont fiele sonst kein sinnvolles Licht.
V3 sunDirectionOf(
  double azimuth,
  double elevation, {
  double north = 0,
  double minElevation = 18,
}) {
  final n = north * math.pi / 180;
  final a = azimuth * math.pi / 180;
  final e = elevation.clamp(minElevation, 70.0) * math.pi / 180;
  // Norden und Osten auf dem Plan (y zeigt nach unten).
  final nx = math.sin(n), ny = -math.cos(n);
  final ex = math.cos(n), ey = math.sin(n);
  final hx = math.sin(a) * ex + math.cos(a) * nx;
  final hy = math.sin(a) * ey + math.cos(a) * ny;
  final toSun = V3(hx * math.cos(e), hy * math.cos(e), math.sin(e));
  return V3(-toSun.x, -toSun.y, -toSun.z);
}

/// Stärke der Sonne (mal `SceneStyle.sun`).
const double kSunIntensity = 2.4;

/// Raumlicht (Echtzeit): Stärke des Füll-Lichts je Raum im Verhältnis zu
/// einer Lampe. Wände und Möbel eines beleuchteten Raums hellen sich
/// gleichmäßig in der Lampenfarbe auf, nicht nur dort, wo der Kegel trifft:
/// so erkennt man auf einen Blick, welcher Raum an ist.
const double kRoomLightLive = 14;

/// Raumlicht auf Böden und Oberseiten (gebaken): gleichmäßige Bestrahlung
/// je Helligkeit, wie ein Lampenanteil.
const double kRoomLightBaked = 0.05;

/// Sonne unter einem Himmel (`setSky`) am klaren Mittag, relativ zu
/// [kSunIntensity]: draußen ist es heller als im Kartenlicht.
const double kSkySunScale = 1.8;

/// Lichtkanal der Flächen mit gebakenem Lampenlicht: nur die Sonne (alle
/// Kanäle) erreicht sie, Lampen nicht (sonst doppelt).
const int kBakedChannel = 0x40;

/// Lichtkanal für alles außerhalb der Räume.
const int kOutsideChannel = 0x80;

/// Wie viel dunkler Geräte als Möbel sind (Anteil zur Farbe `dark`).
const double kDeviceShade = 0.15;

/// Reichweite des Echtzeitlichts einer Lampe in Metern.
const double kLampRange = 7;

/// Ein Bit (von sechs) je Raum, benachbarte Räume (gemeinsames Wandstück)
/// verschieden. Gierige Färbung.
///
/// Mit [zones] (Raum → Zone, siehe `Scene.openZones`) teilen sich die
/// Räume einer Zone ein Bit: Licht geht durch offene Wände.
///
/// [reach] (Raum → Räume, die eine seiner Lampen erreicht): auch diese
/// Räume bekommen ein anderes Bit, sonst leuchtete die Lampe ohne Schatten
/// durch Wände auf Möbel und Wände eines nicht angrenzenden Raums.
Map<String, int> roomChannels(
  List<SceneRoom> rooms, [
  Map<String, String>? zones,
  Map<String, Set<String>> reach = const {},
]) {
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
  // Je Zone (ohne Zonen: je Raum) ein Bit, das kein berührender Raum einer
  // anderen Zone schon hat.
  final groups = <String, List<SceneRoom>>{};
  for (final r in rooms) {
    (groups[zones?[r.id] ?? r.id] ??= []).add(r);
  }
  for (final g in groups.values) {
    var used = 0;
    for (final r in g) {
      for (final o in rooms) {
        final bit = out[o.id];
        if (bit == null || g.contains(o)) continue;
        if ((reach[r.id]?.contains(o.id) ?? false) ||
            (reach[o.id]?.contains(r.id) ?? false) ||
            touches(r, o)) {
          used |= bit;
        }
      }
    }
    var bit = 1;
    while (bit < kBakedChannel && used & bit != 0) {
      bit <<= 1;
    }
    for (final r in g) {
      out[r.id] = bit < kBakedChannel ? bit : 1;
    }
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

/// Räume, die die Lampen eines Raums in Echtzeit erreichen könnten (näher
/// als [kLampRange]), je Raum der Lampe.
Map<String, Set<String>> lampReach(Scene scene) {
  final out = <String, Set<String>>{};
  for (final m in scene.markers) {
    if (m.lamp == null) continue;
    final home = scene.markerRoom[m.id];
    if (home == null) continue;
    final p = m.position.xy;
    for (final r in scene.rooms) {
      if (r.id == home) continue;
      if (_distToOutline(p, r.outline) < kLampRange) {
        (out[home] ??= {}).add(r.id);
      }
    }
  }
  return out;
}

/// Abstand von [p] zum Umriss [poly] (0 innerhalb).
double _distToOutline(Offset p, List<Offset> poly) {
  var inside = false;
  var best = double.infinity;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[j], b = poly[i];
    if ((b.dy > p.dy) != (a.dy > p.dy) &&
        p.dx < (a.dx - b.dx) * (p.dy - b.dy) / (a.dy - b.dy) + b.dx) {
      inside = !inside;
    }
    final d = b - a;
    final len2 = d.dx * d.dx + d.dy * d.dy;
    final t = len2 == 0
        ? 0.0
        : (((p - a).dx * d.dx + (p - a).dy * d.dy) / len2).clamp(0.0, 1.0);
    best = math.min(best, (p - (a + d * t)).distance);
  }
  return inside ? 0 : best;
}

class _Receiver {
  _Receiver(this.bake, this.material, this.color);
  final LightReceiver bake;

  /// Knoten der Fläche (Lichtkanäle umschalten, siehe `setSky`).
  fs.Node? node;
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

/// Glattes Wertrauschen (0 … 1) für Schnee-Flecken, drei Oktaven, fest
/// verteilt (gleiche Flecken bei jedem Aufbau).
double _groundNoise(double x, double y) {
  double hash(int ix, int iy) {
    var h = ix * 374761393 + iy * 668265263;
    h = (h ^ (h >> 13)) * 1274126177;
    return ((h ^ (h >> 16)) & 0xFFFF) / 0xFFFF;
  }

  double layer(double x, double y) {
    final x0 = x.floor(), y0 = y.floor();
    final fx = x - x0, fy = y - y0;
    final sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy);
    final a = hash(x0, y0), b = hash(x0 + 1, y0);
    final c = hash(x0, y0 + 1), d = hash(x0 + 1, y0 + 1);
    return (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy;
  }

  // Flecken etwa 1,5 m groß, dazu feinere Ränder.
  return (layer(x / 1.6, y / 1.6) * 0.6 +
          layer(x / 0.7 + 17, y / 0.7 + 3) * 0.3 +
          layer(x / 0.3 + 5, y / 0.3 + 11) * 0.1)
      .clamp(0.0, 1.0);
}

/// Boden um die Wohnung: Geometrie um den Mittelpunkt (Skalieren statt
/// Neubau), Rauschmuster und Randverlauf einmal berechnet.
class _Ground {
  _Ground({
    required this.cx,
    required this.cy,
    required this.halfX,
    required this.halfY,
    required this.margin,
    required double fade,
    required List<List<Offset>> outlines,
  }) {
    const z = -0.02;
    final ex = halfX + margin, ey = halfY + margin;
    rec = LightReceiver(
      [V3(-ex, -ey, z), V3(ex, -ey, z), V3(ex, ey, z), V3(-ex, ey, z)],
      texel: 0.12,
      maxSide: 180,
    );
    final n = rec.width * rec.height;
    noise = Float32List(n);
    alpha = Float32List(n);
    dist = Float32List(n);
    // Rund auslaufen: Superellipse um die Wohnung, weich auf [fade] Meter.
    final hx = halfX + margin - fade, hy = halfY + margin - fade;
    for (var iy = 0; iy < rec.height; iy++) {
      for (var ix = 0; ix < rec.width; ix++) {
        final p = rec.texelCenter(ix, iy);
        final u = p.x.abs() / hx, v = p.y.abs() / hy;
        final r = math.pow(math.pow(u, 2.6) + math.pow(v, 2.6), 1 / 2.6);
        final d = (r - 1) * math.min(hx, hy);
        final t = (d / math.max(fade, 1e-3)).clamp(0.0, 1.0);
        final i = iy * rec.width + ix;
        alpha[i] = 1 - t * t * (3 - 2 * t);
        noise[i] = _groundNoise(p.x + cx, p.y + cy);
        dist[i] = _distOutside(Offset(p.x + cx, p.y + cy), outlines);
      }
    }
    material = fs.PhysicallyBasedMaterial()
      ..metallicFactor = 0
      ..roughnessFactor = 1
      ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
      ..emissiveFactor = vm.Vector4(1, 1, 1, 1)
      ..emissiveStrength = 0
      ..alphaMode = fs.AlphaMode.blend
      ..depthLayer = -1;
    node =
        fs.Node(name: 'ground', mesh: fs.Mesh(_receiverGeometry(rec), material))
          ..position = toFs(V3(cx, cy, 0))
          // Sonne, Mond und Lampen draußen, nicht die Lampen der Räume (sie
          // schienen sonst durch die Wände).
          ..lightChannelMask = kOutsideChannel | kBakedChannel
          // Durchscheinend wie die Wände: zuerst zeichnen, sonst malt der
          // Boden über die halb durchsichtigen Wände dahinter.
          ..renderOrder = -10
          ..shadowCastingMode = fs.ShadowCastingMode.off;
  }

  final double cx, cy, halfX, halfY, margin;
  late final LightReceiver rec;
  late final Float32List noise;
  late final Float32List alpha;

  /// Abstand zur Wohnung (Meter, 0 innen) je Texel: Schneewehen wachsen
  /// von den Außenwänden nach außen.
  late final Float32List dist;
  late final fs.PhysicallyBasedMaterial material;
  late final fs.Node node;

  /// Farben neu mischen: Boden [color], Schnee-Flecken nach Höhe [snow].
  void paint(Color color, double snow) {
    final n = rec.width * rec.height;
    final base = Uint8List(n * 4);
    const white = Color(0xFFF7F9FC);
    // Schneewehen: ein Saum um das Haus, der mit der Höhe nach außen wächst
    // (welliger Rand aus dem Rauschmuster), bis alles weiß ist.
    // Höchstens knapp 2 m: die Kante bleibt im Bild.
    final band = snow <= 0 ? 0.0 : 0.2 + snow * 1.6;
    for (var i = 0; i < n; i++) {
      final wobble = (noise[i] - 0.5) * (0.35 + band * 0.4);
      final k = snow <= 0
          ? 0.0
          : ((band + wobble - dist[i]) / 0.3 + 0.5).clamp(0.0, 1.0);
      final s = k * k * (3 - 2 * k);
      final o = i * 4;
      // Durchsichtige Bodenfarbe: nur der Schnee ist zu sehen.
      final c = color.a <= 0 ? white : color;
      base[o] = ((c.r + (white.r - c.r) * s) * 255).round();
      base[o + 1] = ((c.g + (white.g - c.g) * s) * 255).round();
      base[o + 2] = ((c.b + (white.b - c.b) * s) * 255).round();
      base[o + 3] = (alpha[i] * (color.a + (1 - color.a) * s) * 255).round();
    }
    // Eine Textur für Farbe und Leuchten (der Schnee ist weiß, das Leuchten
    // folgt der Deckung über den Alphakanal).
    final tex = fs.Texture2D.fromPixels(base, rec.width, rec.height);
    material
      ..baseColorTexture = tex
      ..emissiveTexture = tex;
  }

  /// Auf [m] Meter Rand um die Wohnung skalieren (Dunst wächst mit).
  void resize(double m) {
    final sx = (halfX + m) / (halfX + margin);
    final sy = (halfY + m) / (halfY + margin);
    // Welt (x, y) → flutter_scene (x, -z).
    node.scale = vm.Vector3(sx, 1, sy);
  }
}

/// Wie dick der Schnee höchstens liegt (Meter), bei Schneehöhe 1.
const double kSnowMaxDepth = 0.25;

/// Abstand von [p] zur Wohnung aus [outlines] (0 innerhalb eines Raums).
double _distOutside(Offset p, List<List<Offset>> outlines) {
  var best = double.infinity;
  for (final o in outlines) {
    var inside = false;
    for (var i = 0, j = o.length - 1; i < o.length; j = i++) {
      final a = o[i], b = o[j];
      if ((a.dy > p.dy) != (b.dy > p.dy) &&
          p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
        inside = !inside;
      }
      final ab = b - a;
      final l2 = ab.distanceSquared;
      final t = l2 < 1e-12
          ? 0.0
          : (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / l2).clamp(0.0, 1.0);
      best = math.min(best, (p - (a + ab * t)).distance);
    }
    if (inside) return 0;
  }
  return best;
}
