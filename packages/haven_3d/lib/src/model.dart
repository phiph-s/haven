import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

/// Punkt oder Richtung im Raum, in Metern.
///
/// Koordinaten wie im Grundriss: [x] nach rechts (Osten), [y] nach unten im
/// Plan (Süden), [z] nach oben. Eine Draufsicht zeigt also genau das Bild des
/// 2D-Plans.
@immutable
class V3 {
  const V3(this.x, this.y, this.z);

  static const zero = V3(0, 0, 0);
  static const up = V3(0, 0, 1);

  final double x;
  final double y;
  final double z;

  V3 operator +(V3 o) => V3(x + o.x, y + o.y, z + o.z);
  V3 operator -(V3 o) => V3(x - o.x, y - o.y, z - o.z);
  V3 operator *(double f) => V3(x * f, y * f, z * f);
  V3 operator -() => V3(-x, -y, -z);

  double dot(V3 o) => x * o.x + y * o.y + z * o.z;
  V3 cross(V3 o) => V3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  double get length => math.sqrt(x * x + y * y + z * z);
  V3 get normalized {
    final l = length;
    return l < 1e-12 ? this : this * (1 / l);
  }

  /// Gedreht um die senkrechte Achse, [rad] im Uhrzeigersinn auf dem Plan
  /// (wie `FloorFurniture.rotation` in der App).
  V3 rotateZ(double rad) {
    final c = math.cos(rad), s = math.sin(rad);
    return V3(x * c - y * s, x * s + y * c, z);
  }

  Offset get xy => Offset(x, y);

  static V3 lerp(V3 a, V3 b, double t) => a + (b - a) * t;

  @override
  bool operator ==(Object other) =>
      other is V3 && other.x == x && other.y == y && other.z == z;

  @override
  int get hashCode => Object.hash(x, y, z);

  @override
  String toString() =>
      'V3(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)}, '
      '${z.toStringAsFixed(3)})';
}

/// Oberfläche einer Fläche oder Linie. Der Stil ([SceneStyle]) macht daraus
/// Farben, das Modell beschreibt nur, *was* es ist.
enum Mat {
  /// Korpus, Gestell, Platten: die normale Möbelfläche.
  body,

  /// Polster, Matratze, Kissen, Decke: etwas heller und weicher.
  soft,

  /// Glas (Fenster, Duschwand): fast durchsichtig.
  glass,

  /// Dunkle Teile (Bildschirm, Kochfeld, Griffe).
  dark,

  /// Pflanzen.
  green,

  /// Bodennahe Textilien (Teppich): sehr leise.
  rug,

  /// Wände (nur der Raum selbst).
  wall,
}

/// Ebene, ausgefüllte Fläche (konvex oder einfach, Punkte in Reihenfolge).
///
/// [normal] zeigt nach außen. Flächen mit [twoSided] gelten immer als
/// sichtbar (dünne Platten, Glas); die übrigen fallen weg bzw. werden nur
/// leise gezeichnet, wenn sie von der Kamera wegzeigen.
@immutable
class Face3 {
  const Face3(
    this.points,
    this.normal, {
    this.mat = Mat.body,
    this.twoSided = false,
    this.smooth = false,
    this.solid = -1,
  });

  final List<V3> points;
  final V3 normal;
  final Mat mat;
  final bool twoSided;

  /// Seitenstück einer runden Fläche (Zylinder, Kegel): die senkrechten
  /// Kanten (1 und 3) zeichnet der Renderer nur am Umriss kräftig.
  final bool smooth;

  /// Kennung des geschlossenen Körpers (Quader, Prisma, Loft), zu dem die
  /// Fläche gehört; -1 für einzelne Flächen und Platten. Damit erkennt
  /// [featureEdges] Kanten, die in einem anderen Körper stecken.
  final int solid;

  V3 get centroid {
    var s = V3.zero;
    for (final p in points) {
      s = s + p;
    }
    return s * (1 / points.length);
  }

  Face3 map(V3 Function(V3) f, V3 Function(V3) fn) => Face3(
    [for (final p in points) f(p)],
    fn(normal),
    mat: mat,
    twoSided: twoSided,
    smooth: smooth,
    solid: solid,
  );
}

/// Detaillinie (Naht, Kante, Griff), wird ohne Fläche gezeichnet.
@immutable
class Line3 {
  const Line3(this.a, this.b, {this.mat = Mat.body});
  final V3 a;
  final V3 b;
  final Mat mat;

  V3 get mid => V3.lerp(a, b, 0.5);

  Line3 map(V3 Function(V3) f) => Line3(f(a), f(b), mat: mat);
}

/// Unveränderliches Drahtmodell: Flächen und Detaillinien in Metern.
@immutable
class Model3 {
  const Model3(this.faces, this.lines);

  static const empty = Model3([], []);

  final List<Face3> faces;
  final List<Line3> lines;

  bool get isEmpty => faces.isEmpty && lines.isEmpty;

  Iterable<V3> get points sync* {
    for (final f in faces) {
      yield* f.points;
    }
    for (final l in lines) {
      yield l.a;
      yield l.b;
    }
  }

  /// Gedreht ([rotation] Grad im Uhrzeigersinn auf dem Plan) und verschoben.
  Model3 placed(V3 offset, double rotation) {
    final rad = rotation * math.pi / 180;
    V3 p(V3 v) => v.rotateZ(rad) + offset;
    V3 n(V3 v) => v.rotateZ(rad);
    return Model3(
      [for (final f in faces) f.map(p, n)],
      [for (final l in lines) l.map(p)],
    );
  }
}

/// Baut ein [Model3] aus einfachen Körpern.
///
/// Konvention für Möbel: lokales System mit der **Mitte der Grundfläche im
/// Ursprung**, `x` entlang der Breite (`-w/2 … w/2`), `y` entlang der Tiefe
/// (`-d/2 … d/2`, negativ ist die Oberkante des 2D-Symbols), `z` von 0 (Unterkante
/// des Möbels) nach oben. Alles in Metern.
class ModelBuilder {
  final List<Face3> _faces = [];
  final List<Line3> _lines = [];

  Model3 build() =>
      Model3(List.unmodifiable(_faces), List.unmodifiable(_lines));

  /// Einzelne Fläche mit gegebener Außennormale.
  void face(
    List<V3> points,
    V3 normal, {
    Mat mat = Mat.body,
    bool smooth = false,
  }) => _face(points, normal, mat: mat, smooth: smooth);

  int _solids = 0;

  void _face(
    List<V3> points,
    V3 normal, {
    Mat mat = Mat.body,
    bool smooth = false,
    int solid = -1,
  }) {
    if (points.length < 3) return;
    _faces.add(
      Face3(
        List.unmodifiable(points),
        normal.normalized,
        mat: mat,
        smooth: smooth,
        solid: solid,
      ),
    );
  }

  /// Dünne, beidseitig sichtbare Platte (Glas, Tür, Bild, Teppich).
  void panel(List<V3> points, {Mat mat = Mat.body}) {
    if (points.length < 3) return;
    _faces.add(
      Face3(
        List.unmodifiable(points),
        _newell(points),
        mat: mat,
        twoSided: true,
      ),
    );
  }

  /// Quader zwischen zwei Ecken.
  void box(
    double x0,
    double y0,
    double z0,
    double x1,
    double y1,
    double z1, {
    Mat mat = Mat.body,
  }) {
    final ax = math.min(x0, x1), bx = math.max(x0, x1);
    final ay = math.min(y0, y1), by = math.max(y0, y1);
    final az = math.min(z0, z1), bz = math.max(z0, z1);
    prism(
      [Offset(ax, ay), Offset(bx, ay), Offset(bx, by), Offset(ax, by)],
      az,
      bz,
      mat: mat,
    );
  }

  /// Quader mit Mitte ([cx], [cy]) der Grundfläche, Breite [w], Tiefe [d].
  void boxC(
    double cx,
    double cy,
    double w,
    double d,
    double z0,
    double z1, {
    Mat mat = Mat.body,
  }) => box(cx - w / 2, cy - d / 2, z0, cx + w / 2, cy + d / 2, z1, mat: mat);

  /// Senkrecht hochgezogenes Polygon (Grundriss [poly], von [z0] bis [z1]).
  void prism(List<Offset> poly, double z0, double z1, {Mat mat = Mat.body}) =>
      loft(poly, z0, poly, z1, mat: mat);

  /// Körper zwischen zwei Polygonen gleicher Eckenzahl ([bottom] auf [z0],
  /// [top] auf [z1]), z. B. Kegelstumpf oder abgeschrägte Lehne.
  void loft(
    List<Offset> bottom,
    double z0,
    List<Offset> top,
    double z1, {
    Mat mat = Mat.body,
    bool smooth = false,
  }) {
    assert(bottom.length == top.length && bottom.length >= 3);
    final n = bottom.length;
    // Umlaufsinn bestimmen, damit die Seitennormalen nach außen zeigen.
    final ccw = _signedArea(bottom) > 0;
    final b = [for (final p in bottom) V3(p.dx, p.dy, z0)];
    final t = [for (final p in top) V3(p.dx, p.dy, z1)];
    final id = _solids++;
    _face(t, V3.up, mat: mat, solid: id);
    _face(b.reversed.toList(), -V3.up, mat: mat, solid: id);
    for (var i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final q = [b[i], b[j], t[j], t[i]];
      var nn = _newell(q);
      final out = ccw
          ? V3(b[j].y - b[i].y, -(b[j].x - b[i].x), 0)
          : V3(-(b[j].y - b[i].y), b[j].x - b[i].x, 0);
      if (nn.dot(out) < 0) nn = -nn;
      if (nn.length < 1e-9) nn = out.normalized;
      _face(q, nn, mat: mat, smooth: smooth, solid: id);
    }
  }

  /// Zylinder mit [segments] Seiten.
  void cylinder(
    double cx,
    double cy,
    double r,
    double z0,
    double z1, {
    int segments = 12,
    Mat mat = Mat.body,
  }) => cone(cx, cy, r, r, z0, z1, segments: segments, mat: mat);

  /// Kegelstumpf: Radius [r0] unten, [r1] oben.
  void cone(
    double cx,
    double cy,
    double r0,
    double r1,
    double z0,
    double z1, {
    int segments = 12,
    Mat mat = Mat.body,
  }) {
    loft(
      circle(cx, cy, r0, segments: segments),
      z0,
      circle(cx, cy, r1, segments: segments),
      z1,
      mat: mat,
      smooth: true,
    );
  }

  /// Detaillinie.
  ///
  /// Detaillinien deuten Merkmale an, die keine eigene Geometrie bekommen
  /// (Kissen und Deckenkante auf dem Bett, Fugen, Kochfeld). Wie alle
  /// Linien blenden sie beim Kippen aus (siehe `SceneStyle.edgesOnlyFromAbove`).
  void line(V3 a, V3 b, {Mat mat = Mat.body}) =>
      _lines.add(Line3(a, b, mat: mat));

  /// Linienzug, mit [closed] geschlossen.
  void polyline(List<V3> pts, {bool closed = false, Mat mat = Mat.body}) {
    for (var i = 0; i + 1 < pts.length; i++) {
      line(pts[i], pts[i + 1], mat: mat);
    }
    if (closed && pts.length > 2) {
      line(pts.last, pts.first, mat: mat);
    }
  }

  /// Ellipse (oder Kreis) als Linienzug auf Höhe [z], z. B. Kochfeldring,
  /// Becken oder Teller von oben.
  void ellipseLines(
    double cx,
    double cy,
    double rx,
    double ry,
    double z, {
    int segments = 20,
  }) {
    polyline([
      for (var i = 0; i < segments; i++)
        V3(
          cx + rx * math.cos(2 * math.pi * i / segments),
          cy + ry * math.sin(2 * math.pi * i / segments),
          z,
        ),
    ], closed: true);
  }

  /// Achsparalleles Rechteck als Linien auf Höhe [z].
  void rectLines(
    double x0,
    double y0,
    double x1,
    double y1,
    double z, {
    Mat mat = Mat.body,
  }) {
    polyline(
      [V3(x0, y0, z), V3(x1, y0, z), V3(x1, y1, z), V3(x0, y1, z)],
      closed: true,
      mat: mat,
    );
  }

  /// Kreis als Polygon in der Ebene (für [prism], [loft]).
  static List<Offset> circle(
    double cx,
    double cy,
    double r, {
    int segments = 12,
  }) => [
    for (var i = 0; i < segments; i++)
      Offset(
        cx + r * math.cos(2 * math.pi * i / segments),
        cy + r * math.sin(2 * math.pi * i / segments),
      ),
  ];

  static double _signedArea(List<Offset> p) {
    var a = 0.0;
    for (var i = 0; i < p.length; i++) {
      final j = (i + 1) % p.length;
      a += p[i].dx * p[j].dy - p[j].dx * p[i].dy;
    }
    return a / 2;
  }

  static V3 _newell(List<V3> p) {
    var x = 0.0, y = 0.0, z = 0.0;
    for (var i = 0; i < p.length; i++) {
      final a = p[i], b = p[(i + 1) % p.length];
      x += (a.y - b.y) * (a.z + b.z);
      y += (a.z - b.z) * (a.x + b.x);
      z += (a.x - b.x) * (a.y + b.y);
    }
    return V3(x, y, z).normalized;
  }
}
