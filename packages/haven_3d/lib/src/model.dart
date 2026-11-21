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

  /// Gedreht um die x-Achse (y zeigt bei positivem [rad] nach oben).
  V3 rotateX(double rad) {
    final c = math.cos(rad), s = math.sin(rad);
    return V3(x, y * c - z * s, y * s + z * c);
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

  /// Bildschirm (Fernseher, Monitor): dunkel und glatt.
  screen,

  /// Keramik (WC, Waschbecken, Wanne): hell und leicht glänzend.
  ceramic,

  /// Metall (Griffe, Armaturen, Gestelle): mittleres Grau, glatt.
  metal,
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
    this.zone,
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

  /// Farbzone (siehe [ColorZone]), z. B. `frame` oder `cushion`: eine
  /// eigene Farbe für diese Zone ersetzt die Grundfarbe von [mat]. `null`:
  /// keine Zone (nicht einfärbbar).
  final String? zone;

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
    zone: zone,
  );
}

/// Einfärbbarer Teil eines Modells: Kennung [id] (steht im Plan), Name
/// [label] für die Auswahl und [mat], dessen Grundfarbe ohne eigene Farbe
/// gilt (Standard wie bisher).
@immutable
class ColorZone {
  const ColorZone(this.id, this.label, [this.mat = Mat.body]);
  final String id;
  final String label;
  final Mat mat;
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

  /// Jeder Punkt (und jede Normale) durch [f] gedreht.
  Model3 rotated(V3 Function(V3) f) => Model3(
    [for (final face in faces) face.map(f, f)],
    [for (final l in lines) l.map(f)],
  );

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
  ModelBuilder({this.open});

  /// Zustand von Türen und Fenstern mit Sensor: `true` offen, `false` zu,
  /// `null` unbekannt (Tür offen gezeichnet, Fenster mit Aufgehwinkel).
  final bool? open;

  final List<Face3> _faces = [];
  final List<Line3> _lines = [];

  /// Farbzone für alle folgenden Flächen (siehe [Face3.zone]).
  String? zone;

  /// [build] mit Farbzone [id], danach wieder die vorige.
  void inZone(String id, void Function() build) {
    final prev = zone;
    zone = id;
    build();
    zone = prev;
  }

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

  V3 _shift = V3.zero;

  List<V3> _shifted(List<V3> p) =>
      _shift == V3.zero ? p : [for (final q in p) q + _shift];

  /// [build] um [by] verschoben (z. B. ein Fernseher auf einem Board).
  void shifted(V3 by, void Function() build) {
    final prev = _shift;
    _shift = prev + by;
    build();
    _shift = prev;
  }

  /// Hohlkörper (Becken, Wanne, WC): Außenumriss [outer] von [z0] bis
  /// [zTop], oben ein Rand bis zur Öffnung [inner], darin eine Mulde bis
  /// zum Boden [floor] auf [zFloor]. Ohne [floor] ein Ring mit Loch (Sitz).
  /// Alle Umrisse haben gleich viele Punkte im selben Umlaufsinn, Punkt i
  /// liegt jeweils in derselben Richtung von der Mitte.
  void basin(
    List<Offset> outer,
    List<Offset> inner,
    double z0,
    double zTop, {
    List<Offset>? floor,
    double? zFloor,
    Mat mat = Mat.body,
    bool smoothOuter = false,
  }) {
    final n = outer.length;
    assert(inner.length == n && (floor == null || floor.length == n));
    final id = _solids++;
    final ccw = _signedArea(outer) > 0;
    V3 at(Offset p, double z) => V3(p.dx, p.dy, z);
    // Außen.
    for (var i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final q = [
        at(outer[i], z0),
        at(outer[j], z0),
        at(outer[j], zTop),
        at(outer[i], zTop),
      ];
      final e = outer[j] - outer[i];
      final out = ccw ? V3(e.dy, -e.dx, 0) : V3(-e.dy, e.dx, 0);
      _face(q, out, mat: mat, smooth: smoothOuter, solid: id);
    }
    // Rand oben (und unten beim Ring) in zwei Hälften: einfache Polygone.
    final h = n ~/ 2;
    List<V3> half(int from, int to, double z) => [
      for (var i = from; i <= to; i++) at(outer[i % n], z),
      for (var i = to; i >= from; i--) at(inner[i % n], z),
    ];
    for (final (a, b) in [(0, h), (h, n)]) {
      _face(half(a, b, zTop), V3.up, mat: mat, solid: id);
      if (floor == null) {
        _face(half(a, b, z0).reversed.toList(), -V3.up, mat: mat, solid: id);
      }
    }
    if (floor != null) {
      _face(
        [for (final p in outer) at(p, z0)].reversed.toList(),
        -V3.up,
        mat: mat,
        solid: id,
      );
    }
    // Mulde: Wände nach innen, Boden nach oben.
    final bottom = floor ?? inner;
    final zb = floor == null ? z0 : (zFloor ?? z0);
    var cx = 0.0, cy = 0.0;
    for (final p in inner) {
      cx += p.dx / n;
      cy += p.dy / n;
    }
    for (var i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final q = [
        at(bottom[i], zb),
        at(bottom[j], zb),
        at(inner[j], zTop),
        at(inner[i], zTop),
      ];
      var nn = _newell(q);
      final mid = (inner[i] + inner[j]) / 2;
      if (nn.dot(V3(cx - mid.dx, cy - mid.dy, 0)) < 0) nn = -nn;
      _face(q, nn, mat: mat, smooth: true, solid: id);
    }
    if (floor != null) {
      _face([for (final p in floor) at(p, zb)], V3.up, mat: mat, solid: id);
    }
  }

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
        List.unmodifiable(_shifted(points)),
        normal.normalized,
        mat: mat,
        smooth: smooth,
        solid: solid,
        zone: zone,
      ),
    );
  }

  /// Dünne, beidseitig sichtbare Platte (Glas, Tür, Bild, Teppich).
  void panel(List<V3> points, {Mat mat = Mat.body}) {
    if (points.length < 3) return;
    _faces.add(
      Face3(
        List.unmodifiable(_shifted(points)),
        _newell(points),
        mat: mat,
        twoSided: true,
        zone: zone,
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
      _lines.add(Line3(a + _shift, b + _shift, mat: mat));

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

  /// Quader mit senkrecht abgerundeten Ecken (Radius [r], [segments] Stücke
  /// je Ecke). Die Rundung zeichnet keine Kanten (unter dem Knickwinkel).
  void roundBox(
    double x0,
    double y0,
    double z0,
    double x1,
    double y1,
    double z1,
    double r, {
    Mat mat = Mat.body,
    int segments = 3,
  }) {
    final rr = math.min(r, 0.5 * math.min((x1 - x0).abs(), (y1 - y0).abs()));
    if (rr <= 1e-4) {
      box(x0, y0, z0, x1, y1, z1, mat: mat);
      return;
    }
    prism(
      roundedRect(
        math.min(x0, x1),
        math.min(y0, y1),
        math.max(x0, x1),
        math.max(y0, y1),
        rr,
        segments: segments,
      ),
      math.min(z0, z1),
      math.max(z0, z1),
      mat: mat,
    );
  }

  /// Senkrechter Körper mit elliptischem Grundriss (Mitte [cx], [cy],
  /// Halbachsen [rx], [ry]), unten [rx0]/[ry0]-fach skaliert für eine
  /// Verjüngung.
  void ellipsoid(
    double cx,
    double cy,
    double rx,
    double ry,
    double z0,
    double z1, {
    double bottomScale = 1,
    int segments = 16,
    Mat mat = Mat.body,
  }) => loft(
    ellipse(cx, cy, rx * bottomScale, ry * bottomScale, segments: segments),
    z0,
    ellipse(cx, cy, rx, ry, segments: segments),
    z1,
    mat: mat,
    smooth: true,
  );

  /// Abgerundetes Rechteck als Polygon (gegen den Uhrzeigersinn in x/y).
  static List<Offset> roundedRect(
    double x0,
    double y0,
    double x1,
    double y1,
    double r, {
    int segments = 3,
  }) {
    final out = <Offset>[];
    final corners = [
      (x1 - r, y0 + r, -math.pi / 2),
      (x1 - r, y1 - r, 0.0),
      (x0 + r, y1 - r, math.pi / 2),
      (x0 + r, y0 + r, math.pi),
    ];
    for (final (cx, cy, a0) in corners) {
      for (var i = 0; i <= segments; i++) {
        final a = a0 + math.pi / 2 * i / segments;
        out.add(Offset(cx + r * math.cos(a), cy + r * math.sin(a)));
      }
    }
    return out;
  }

  /// Superellipse (Exponent [exponent]: 2 Ellipse, größer eckiger, etwa 4
  /// ein weich gerundetes Rechteck) als Polygon. Punkt i liegt für alle
  /// Größen in derselben Richtung: passende Umrisse für [basin].
  static List<Offset> superellipse(
    double cx,
    double cy,
    double rx,
    double ry, {
    double exponent = 2,
    int segments = 24,
  }) {
    double f(double v) => v.sign * math.pow(v.abs(), 2 / exponent).toDouble();
    return [
      for (var i = 0; i < segments; i++)
        Offset(
          cx + rx * f(math.cos(2 * math.pi * (i + 0.5) / segments)),
          cy + ry * f(math.sin(2 * math.pi * (i + 0.5) / segments)),
        ),
    ];
  }

  /// Ellipse als Polygon in der Ebene.
  static List<Offset> ellipse(
    double cx,
    double cy,
    double rx,
    double ry, {
    int segments = 16,
  }) => [
    for (var i = 0; i < segments; i++)
      Offset(
        cx + rx * math.cos(2 * math.pi * i / segments),
        cy + ry * math.sin(2 * math.pi * i / segments),
      ),
  ];

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
