import 'dart:math' as math;
import 'dart:ui' show Color, Offset;

import 'package:flutter/foundation.dart';

import 'devices.dart';
import 'furniture/catalog.dart';
import 'model.dart';
import 'shape.dart';

/// Standardhöhe der Wände in Metern.
const double kDefaultWallHeight = 2.5;

/// Ein Raum: Grundriss-Polygon in Metern (Ecken in Reihenfolge), Wände bis
/// [wallHeight].
@immutable
class SceneRoom {
  SceneRoom({
    required this.id,
    required List<Offset> outline,
    this.wallHeight = kDefaultWallHeight,
    this.label,
    this.openEdges = const {},
  }) : outline = List.unmodifiable(outline);

  final String id;
  final List<Offset> outline;
  final double wallHeight;

  /// Ankerpunkt (Meter) für die Beschriftung, z. B. die obere linke Ecke der
  /// Innenfläche wie in der 2D-Karte. `null`: ein Punkt im Raum nahe der
  /// Mitte.
  final Offset? label;

  /// Offene Kanten des Umrisses (Kante i von Ecke i zur nächsten): dort ist
  /// eine Raumgrenze, aber keine Wand.
  final Set<int> openEdges;

  /// Kante des Umrisses, zu der das Stück [a]–[b] gehört (z. B. ein Stück des
  /// abgerundeten, eingerückten Umrisses): die nächste, möglichst parallele.
  int edgeNear(Offset a, Offset b) {
    final m = (a + b) / 2;
    final d = b - a;
    final n = outline.length;
    var best = 0;
    var bestScore = double.infinity;
    for (var i = 0; i < n; i++) {
      final p = outline[i], q = outline[(i + 1) % n];
      final e = q - p;
      final len2 = e.distanceSquared;
      final t = len2 == 0
          ? 0.0
          : (((m - p).dx * e.dx + (m - p).dy * e.dy) / len2).clamp(0.0, 1.0);
      final dist = (m - (p + e * t)).distance;
      // Quer zur Kante liegende Stücke (Rundung) zählen etwas weniger.
      final par = d.distance == 0 || e.distance == 0
          ? 0.0
          : ((d.dx * e.dy - d.dy * e.dx) / (d.distance * e.distance)).abs();
      final score = dist + par * 0.05;
      if (score < bestScore) {
        bestScore = score;
        best = i;
      }
    }
    return best;
  }

  /// Ist das Stück [a]–[b] eine offene Raumgrenze?
  bool isOpenAt(Offset a, Offset b) =>
      openEdges.isNotEmpty && openEdges.contains(edgeNear(a, b));

  /// Wo die Beschriftung sitzt: [label] oder ein innerer Punkt.
  late final Offset labelAt = label ?? _inner();

  Offset _inner() {
    final c = centroid;
    if (contains(c)) return c;
    // Nicht konvex: waagerechter Schnitt durch die Mitte, längstes Stück.
    final xs = <double>[];
    for (var i = 0, j = outline.length - 1; i < outline.length; j = i++) {
      final a = outline[i], b = outline[j];
      if ((a.dy > c.dy) != (b.dy > c.dy)) {
        xs.add(a.dx + (b.dx - a.dx) * (c.dy - a.dy) / (b.dy - a.dy));
      }
    }
    xs.sort();
    var best = c;
    var len = -1.0;
    for (var i = 0; i + 1 < xs.length; i += 2) {
      if (xs[i + 1] - xs[i] > len) {
        len = xs[i + 1] - xs[i];
        best = Offset((xs[i] + xs[i + 1]) / 2, c.dy);
      }
    }
    return best;
  }

  late final Offset centroid = _centroid(outline);

  /// Wände als Flächen mit Außennormale, eine je Kante.
  late final List<Face3> walls = _walls();

  bool contains(Offset p) {
    var inside = false;
    for (var i = 0, j = outline.length - 1; i < outline.length; j = i++) {
      final a = outline[i], b = outline[j];
      if ((a.dy > p.dy) != (b.dy > p.dy) &&
          p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
        inside = !inside;
      }
    }
    return inside;
  }

  Iterable<V3> get points sync* {
    for (final p in outline) {
      yield V3(p.dx, p.dy, 0);
      yield V3(p.dx, p.dy, wallHeight);
    }
  }

  List<Face3> _walls() => wallsAlong(outline, wallHeight);

  /// Wände entlang eines beliebigen Umrisses (z. B. des abgerundeten
  /// Darstellungsumrisses), eine Fläche je Kante, Normale nach außen.
  static List<Face3> wallsAlong(List<Offset> outline, double height) {
    final n = outline.length;
    var area = 0.0;
    for (var i = 0; i < n; i++) {
      final a = outline[i], b = outline[(i + 1) % n];
      area += a.dx * b.dy - b.dx * a.dy;
    }
    final ccw = area > 0;
    return [
      for (var i = 0; i < n; i++)
        if ((outline[(i + 1) % n] - outline[i]).distance > 1e-6)
          _wall(outline[i], outline[(i + 1) % n], ccw, height),
    ];
  }

  static Face3 _wall(Offset a, Offset b, bool ccw, double height) {
    final e = b - a;
    final out = ccw ? V3(e.dy, -e.dx, 0) : V3(-e.dy, e.dx, 0);
    return Face3(
      [
        V3(a.dx, a.dy, 0),
        V3(b.dx, b.dy, 0),
        V3(b.dx, b.dy, height),
        V3(a.dx, a.dy, height),
      ],
      out.normalized,
      mat: Mat.wall,
    );
  }

  static Offset _centroid(List<Offset> p) {
    var a = 0.0, cx = 0.0, cy = 0.0;
    for (var i = 0; i < p.length; i++) {
      final j = (i + 1) % p.length;
      final f = p[i].dx * p[j].dy - p[j].dx * p[i].dy;
      a += f;
      cx += (p[i].dx + p[j].dx) * f;
      cy += (p[i].dy + p[j].dy) * f;
    }
    if (a.abs() < 1e-9) {
      var s = Offset.zero;
      for (final q in p) {
        s += q;
      }
      return s / p.length.toDouble();
    }
    return Offset(cx / (3 * a), cy / (3 * a));
  }
}

/// Ein Objekt im Raum: Modell im lokalen System, gedreht um [rotation] Grad
/// (Uhrzeigersinn auf dem Plan) und mit der Mitte der Unterkante auf
/// [position] gesetzt.
@immutable
class SceneObject {
  SceneObject({
    required this.id,
    required this.kind,
    required this.model,
    required this.position,
    this.rotation = 0,
    this.roomId,
    this.wallMounted = false,
    this.depth = 0,
    this.width = 0,
    this.sensor,
  });

  /// Möbelstück aus dem Katalog: Mitte [center] und Maße [w] × [d] in
  /// Metern; Höhe und Abstand zum Boden aus dem Katalog, wenn nicht gesetzt.
  factory SceneObject.furniture({
    required String id,
    required String kind,
    required Offset center,
    required double w,
    required double d,
    double rotation = 0,
    double? height,
    double? elevation,
    String? roomId,
    bool? open,
    String? sensor,
  }) {
    final spec = furnitureSpec(kind);
    return SceneObject(
      id: id,
      kind: kind,
      model: buildFurniture(kind, w, d, height: height, open: open),
      position: V3(center.dx, center.dy, elevation ?? spec.elevation),
      rotation: rotation,
      roomId: roomId,
      wallMounted: spec.wallMounted,
      depth: d,
      width: w,
      sensor: sensor,
    );
  }

  final String id;
  final String kind;
  final Model3 model;
  final V3 position;
  final double rotation;
  final String? roomId;

  /// Sitzt in einer Wand (siehe `FurnitureSpec.wallMounted`).
  final bool wallMounted;

  /// Tiefe (lokales `y`) in Metern, für die Zuordnung zum Raum.
  final double depth;

  /// Breite (lokales `x`) in Metern.
  final double width;

  /// Sensor (frei wählbare ID), der den Zustand offen/zu meldet.
  final String? sensor;

  /// Dasselbe Objekt mit Modell im Zustand [open] (nur Kataloggrößen).
  SceneObject withOpen(bool? open) => SceneObject(
    id: id,
    kind: kind,
    model: buildFurniture(kind, width, depth, open: open),
    position: position,
    rotation: rotation,
    roomId: roomId,
    wallMounted: wallMounted,
    depth: depth,
    width: width,
    sensor: sensor,
  );

  /// Türöffnung in der Wand: Anfang und Ende auf der Wandlinie (Welt) und
  /// Höhe. Die Wand liegt an der Unterkante der Tür (lokal `y = d/2`), die
  /// Öffnung beginnt an der Angel und ist `min(w, d)` breit. `null` für
  /// alles außer Türen.
  ({Offset a, Offset b, double height})? get doorOpening {
    if (kind != 'door' || width <= 0) return null;
    final r = math.min(width, depth);
    final x0 = -width / 2;
    return (
      a: toWorld(Offset(x0, depth / 2)),
      b: toWorld(Offset(x0 + r, depth / 2)),
      height: furnitureSpec(kind).height,
    );
  }

  /// Punkt [local] (lokales System, ohne Höhe) in Weltkoordinaten.
  Offset toWorld(Offset local) {
    final v = V3(local.dx, local.dy, 0).rotateZ(rotation * math.pi / 180);
    return Offset(v.x + position.x, v.y + position.y);
  }

  /// Modell in Weltkoordinaten.
  late final Model3 world = model.placed(position, rotation);

  /// Mitte der umschließenden Box in Weltkoordinaten.
  late final V3 center = _center();

  V3 _center() {
    var lo = const V3(double.infinity, double.infinity, double.infinity);
    var hi = -lo;
    for (final p in world.points) {
      lo = V3(math.min(lo.x, p.x), math.min(lo.y, p.y), math.min(lo.z, p.z));
      hi = V3(math.max(hi.x, p.x), math.max(hi.y, p.y), math.max(hi.z, p.z));
    }
    return lo.x.isFinite ? V3.lerp(lo, hi, 0.5) : position;
  }
}

/// Art eines Geräts für die Standardhöhe, entspricht `FloorKind` der App.
enum MarkerKind { light, temperature, presence, remote, contact, media, device }

/// Standardhöhe (Meter über Boden) je Geräteart.
const Map<MarkerKind, double> kDefaultMarkerHeight = {
  MarkerKind.light: 2.35, // Deckenleuchte
  MarkerKind.temperature: 1.5, // Wand, Augenhöhe
  MarkerKind.presence: 2.2, // Melder oben an der Wand oder Decke
  MarkerKind.remote: 1.05, // Lichtschalter
  MarkerKind.contact: 1.4, // Fenster- oder Türkontakt
  MarkerKind.media: 0.6, // Lautsprecher, TV auf dem Board
  MarkerKind.device: 0.8,
};

/// Zustand einer Leuchte: an/aus, Helligkeit 0…1, Lichtfarbe.
@immutable
class LampState {
  const LampState({
    this.on = true,
    this.brightness = 1,
    this.color = const Color(0xFFFFC98A),
  });

  static const off = LampState(on: false);

  final bool on;
  final double brightness;
  final Color color;

  @override
  bool operator ==(Object other) =>
      other is LampState &&
      other.on == on &&
      other.brightness == brightness &&
      other.color == color;

  @override
  int get hashCode => Object.hash(on, brightness, color);
}

/// Ein Gerät als Punkt im Raum. Die App legt später ihre Marker-Widgets
/// auf die projizierte Position ([OrbitCamera.project]). Leuchten
/// ([MarkerKind.light]) mit [lamp] werden zu Punktlichtern.
@immutable
class SceneMarker {
  SceneMarker({
    required this.id,
    required Offset at,
    this.kind = MarkerKind.device,
    double? height,
    this.roomId,
    this.lamp,
    this.model,
  }) : position = V3(
         at.dx,
         at.dy,
         height ??
             (model != null
                 ? deviceSpec(model).height
                 : kDefaultMarkerHeight[kind]!),
       );

  /// Bauform in 3D (siehe [kDeviceModels]), `null`: kein Modell, nur der
  /// Punkt (Lampen leuchten trotzdem).
  final String? model;

  /// Wo das Licht einer Lampe entsteht (Montagepunkt plus Versatz der
  /// Bauform, z. B. der Schirm einer Pendelleuchte).
  V3 get lightPosition {
    final m = model;
    if (m == null) return position;
    final l = deviceSpec(m).lamp;
    return l == null ? position : position + V3(0, 0, l.lightZ);
  }

  /// Lichtkegel (halber Winkel nach unten) oder `null` (rundum).
  double? get cone => model == null ? null : deviceSpec(model).lamp?.cone;

  final String id;
  final MarkerKind kind;
  final V3 position;
  final String? roomId;
  final LampState? lamp;
}

/// Die ganze Szene: Räume, Möbel, Geräte. Objekte ohne [SceneObject.roomId]
/// werden dem Raum zugeordnet, in dem ihre Mitte liegt.
@immutable
class Scene {
  Scene({
    List<SceneRoom> rooms = const [],
    List<SceneObject> objects = const [],
    List<SceneMarker> markers = const [],
  }) : rooms = List.unmodifiable(rooms),
       objects = List.unmodifiable(objects),
       markers = List.unmodifiable(markers);

  final List<SceneRoom> rooms;
  final List<SceneObject> objects;
  final List<SceneMarker> markers;

  SceneRoom? room(String id) {
    for (final r in rooms) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// Szene mit eingerückten Räumen (siehe [roundedInset]): Möbel, die über
  /// den Darstellungsumriss ragen, rücken nach innen, bis ihre Grundfläche
  /// ganz im Raum liegt. Türen und Fenster bleiben in der Wand.
  Scene fittedToRooms({double inset = 0, double radius = 0}) {
    if (inset <= 0 && radius <= 0) return this;
    final shapes = {
      for (final r in rooms)
        // Innenkante der Wände (eckig): Möbel passen in die Ecken.
        r.id: roomFloor(r.outline, gap: inset * 2, open: r.openEdges),
    };
    return Scene(
      rooms: rooms,
      markers: markers,
      objects: [
        for (final o in objects)
          if (o.wallMounted)
            _turnedToRoom(o)
          else if (shapes[objectRoom[o.id]] == null)
            o
          else
            _moved(o, shapes[objectRoom[o.id]]!),
      ],
    );
  }

  /// Fenster so drehen, dass ihre Raumseite (-y) zum Raum zeigt.
  SceneObject _turnedToRoom(SceneObject o) {
    if (!furnitureSpec(o.kind).facesRoom) return o;
    final probe = o.depth / 2 + 0.05;
    if (_roomAt(o.toWorld(Offset(0, -probe))) != null) return o;
    if (_roomAt(o.toWorld(Offset(0, probe))) == null) return o;
    return SceneObject.furniture(
      id: o.id,
      kind: o.kind,
      center: o.position.xy,
      w: _width(o),
      d: o.depth,
      rotation: (o.rotation + 180) % 360,
      elevation: o.position.z,
      roomId: objectRoom[o.id],
    );
  }

  /// Breite eines Möbelstücks aus seinem Modell (lokales x).
  static double _width(SceneObject o) {
    var lo = double.infinity, hi = -double.infinity;
    for (final f in o.model.faces) {
      for (final p in f.points) {
        if (p.x < lo) lo = p.x;
        if (p.x > hi) hi = p.x;
      }
    }
    return hi - lo;
  }

  SceneObject _moved(SceneObject o, List<Offset> shape) {
    final foot = [for (final p in o.world.points) p.xy];
    final d = fitInside(foot, shape);
    if (d.distance < 1e-6) return o;
    return SceneObject(
      id: o.id,
      kind: o.kind,
      model: o.model,
      position: V3(o.position.x + d.dx, o.position.y + d.dy, o.position.z),
      rotation: o.rotation,
      // Zuordnung festhalten (die neue Mitte liegt ohnehin im Raum).
      roomId: objectRoom[o.id],
      wallMounted: o.wallMounted,
      depth: o.depth,
      width: o.width,
      sensor: o.sensor,
    );
  }

  /// Raum-ID je Objekt (oder `null` für draußen).
  late final Map<String, String?> objectRoom = {
    for (final o in objects) o.id: o.roomId ?? _roomOf(o),
  };

  String? _roomOf(SceneObject o) {
    if (!o.wallMounted) return _roomAt(o.position.xy);
    // In der Wand: der Raum knapp hinter der Innenseite (-y), sonst davor.
    final probe = o.depth / 2 + 0.05;
    return _roomAt(o.toWorld(Offset(0, -probe))) ??
        _roomAt(o.toWorld(Offset(0, probe)));
  }

  /// Raum-ID je Gerät (oder `null` für draußen).
  late final Map<String, String?> markerRoom = {
    for (final m in markers) m.id: m.roomId ?? _roomAt(m.position.xy),
  };

  /// Lichtzone je Raum (Raum-ID → ID der Zone): Räume, die eine offene
  /// Wand oder eine Tür verbindet, teilen sich das Licht ihrer Lampen.
  late final Map<String, String> lightZones = _zones();

  Map<String, String> _zones() {
    final parent = {for (final r in rooms) r.id: r.id};
    String find(String x) {
      while (parent[x] != x) {
        x = parent[x] = parent[parent[x]!]!;
      }
      return x;
    }

    void union(String a, String b) {
      final ra = find(a), rb = find(b);
      if (ra != rb) parent[rb] = ra;
    }

    // Offene Wände: eine offene Kante, die mit einer Kante eines anderen
    // Raums auf einer Linie liegt und sich mit ihr überdeckt.
    for (final a in rooms) {
      final n = a.outline.length;
      for (final i in a.openEdges) {
        if (i >= n) continue;
        final a0 = a.outline[i], a1 = a.outline[(i + 1) % n];
        for (final b in rooms) {
          if (b.id == a.id) continue;
          final m = b.outline.length;
          for (var j = 0; j < m; j++) {
            if (_overlap(a0, a1, b.outline[j], b.outline[(j + 1) % m]) > 0.05) {
              union(a.id, b.id);
              break;
            }
          }
        }
      }
    }
    // Türen: die Räume knapp vor und hinter der Öffnung.
    for (final o in objects) {
      final d = o.doorOpening;
      if (d == null) continue;
      final e = d.b - d.a;
      if (e.distance < 1e-6) continue;
      final mid = (d.a + d.b) / 2;
      final nrm = Offset(-e.dy, e.dx) / e.distance;
      final x = _roomAt(mid + nrm * 0.2), y = _roomAt(mid - nrm * 0.2);
      if (x != null && y != null && x != y) union(x, y);
    }
    return {for (final r in rooms) r.id: find(r.id)};
  }

  static double _overlap(Offset a0, Offset a1, Offset b0, Offset b1) {
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

  /// Raum, in dem [p] liegt (oder `null`).
  String? roomAt(Offset p) => _roomAt(p);

  String? _roomAt(Offset p) {
    for (final r in rooms) {
      if (r.contains(p)) return r.id;
    }
    return null;
  }

  /// Alle Punkte (für [OrbitCamera.fit]); mit [roomId] nur die eines Raums.
  Iterable<V3> points({String? roomId}) sync* {
    for (final r in rooms) {
      if (roomId == null || r.id == roomId) yield* r.points;
    }
    for (final o in objects) {
      if (roomId == null || objectRoom[o.id] == roomId) yield* o.world.points;
    }
    for (final m in markers) {
      if (roomId == null || markerRoom[m.id] == roomId) yield m.position;
    }
  }
}
