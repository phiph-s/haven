import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'model.dart';

/// Eine Kante (Strecke) im Raum.
@immutable
class Edge3 {
  const Edge3(this.a, this.b);
  final V3 a;
  final V3 b;

  double get length => (b - a).length;

  @override
  String toString() => 'Edge3($a, $b)';
}

/// Die *echten* Kanten eines Modells: Knicke und offene Ränder.
///
/// Kanten, an denen die Fläche eben (oder fast eben, unter [creaseDegrees])
/// weiterläuft, fallen weg, auch wenn das Modell dort aus mehreren Teilen
/// zusammengesetzt ist (Arbeitsplatte aus vier Quadern, Zylinder aus zwölf
/// Seiten). Dafür wird jede Polygonkante in kurzen Stücken abgetastet: Liegt
/// knapp jenseits der Kante eine Fläche mit fast gleicher Normale in
/// derselben Ebene, ist das Stück keine Kante. Überlappende Stücke auf
/// derselben Geraden (aus beiden Nachbarflächen) werden vereinigt, damit
/// nichts doppelt (und mit Transparenz doppelt dunkel) gezeichnet wird.
///
/// Senkrechte Kanten zwischen zwei runden Seitenflächen ([Face3.smooth])
/// zählen nie als Kante.
List<Edge3> featureEdges(
  Model3 model, {
  double creaseDegrees = 35,
  double step = 0.04,
}) {
  final all = [
    for (final f in model.faces)
      if (f.points.length >= 3) _Plane.of(f),
  ];
  // Innenflächen weglassen: Flächen, die ganz auf einer gegenüberliegenden
  // Fläche derselben Ebene liegen (zwei bündige Quader berühren sich dort).
  final faces = [
    for (final f in all)
      if (!_isInternal(all, f)) f,
  ];
  final cosCrease = math.cos(creaseDegrees * math.pi / 180);
  // Flächen je geschlossenem Körper, für den Test „steckt in einem anderen“.
  final solids = <int, List<_Plane>>{};
  for (final f in all) {
    if (f.face.solid >= 0) solids.putIfAbsent(f.face.solid, () => []).add(f);
  }
  final pieces = <Edge3>[];

  for (final f in faces) {
    final pts = f.face.points;
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i], b = pts[(i + 1) % pts.length];
      final d = b - a;
      final len = d.length;
      if (len < 1e-5) continue;
      // Senkrechte Kanten runder Seitenflächen (1 und 3) überspringen.
      if (f.face.smooth && (i == 1 || i == 3)) continue;
      // Richtung in der Ebene, von der Fläche weg.
      // (Bei nicht konvexen Flächen zeigt die Mitte nicht verlässlich nach
      // innen: die Seite nehmen, auf der die Fläche selbst nicht liegt.)
      var out = d.cross(f.n).normalized;
      final mid = V3.lerp(a, b, 0.5);
      if (f.contains(mid + out * 0.004)) {
        out = -out;
      } else if (!f.contains(mid - out * 0.004) &&
          out.dot(f.centroid - mid) > 0) {
        out = -out;
      }

      final k = math.max(1, (len / step).ceil());
      int? runStart;
      for (var s = 0; s <= k; s++) {
        var visible = false;
        if (s < k) {
          final t = (s + 0.5) / k;
          final onEdge = a + d * t;
          final q = onEdge + out * 0.004;
          visible =
              !_continues(faces, f, q, cosCrease) &&
              !_buried(solids, f, onEdge + f.n * 0.003 - out * 0.003);
        }
        if (visible && runStart == null) runStart = s;
        if (!visible && runStart != null) {
          pieces.add(Edge3(a + d * (runStart / k), a + d * (s / k)));
          runStart = null;
        }
      }
    }
  }
  return _mergeCollinear(pieces);
}

/// Liegt [p] (knapp vor der Fläche [f], neben ihrer Kante) in einem anderen
/// Körper? Dann ist die Fläche dort verdeckt (überlappende Teile, z. B.
/// Pfosten im Sturz einer Zarge) und ihre Kante keine sichtbare Kante.
bool _buried(Map<int, List<_Plane>> solids, _Plane f, V3 p) {
  for (final e in solids.entries) {
    if (e.key == f.face.solid) continue;
    if (_insideSolid(e.value, p)) return true;
  }
  return false;
}

/// Punkt im geschlossenen Körper? Strahl in schräge Richtung, Schnitte zählen.
bool _insideSolid(List<_Plane> faces, V3 p) {
  const dir = V3(0.3137, 0.4719, 0.8240);
  var hits = 0;
  for (final g in faces) {
    final denom = g.n.dot(dir);
    if (denom.abs() < 1e-9) continue;
    final t = (g.d - g.n.dot(p)) / denom;
    if (t <= 1e-9) continue;
    if (g.contains(p + dir * t)) hits++;
  }
  return hits.isOdd;
}

bool _isInternal(List<_Plane> faces, _Plane f) {
  final samples = [
    f.centroid,
    for (final p in f.face.points) V3.lerp(p, f.centroid, 0.02),
  ];
  for (final q in samples) {
    var covered = false;
    for (final g in faces) {
      if (identical(g, f) || g.n.dot(f.n) > -0.999) continue;
      if ((g.n.dot(q) - g.d).abs() > 0.002) continue;
      if (g.contains(q)) {
        covered = true;
        break;
      }
    }
    if (!covered) return false;
  }
  return true;
}

/// Läuft die Fläche [from] bei [q] (knapp jenseits einer Kante) ohne Knick
/// weiter?
bool _continues(List<_Plane> faces, _Plane from, V3 q, double cosCrease) {
  for (final g in faces) {
    if (identical(g, from)) continue;
    if (g.n.dot(from.n) < cosCrease) continue;
    if ((g.n.dot(q) - g.d).abs() > 0.003) continue;
    if (g.contains(q)) return true;
  }
  return false;
}

class _Plane {
  _Plane(
    this.face,
    this.n,
    this.d,
    this.centroid,
    this._u,
    this._v,
    this._poly,
  );

  factory _Plane.of(Face3 f) {
    var n = _newell(f.points);
    if (n.length < 1e-9) n = f.normal;
    if (n.dot(f.normal) < 0) n = -n;
    final p0 = f.points.first;
    // Basis in der Ebene für den Punkt-im-Polygon-Test.
    final helper = n.z.abs() < 0.9 ? V3.up : const V3(1, 0, 0);
    final u = helper.cross(n).normalized;
    final v = n.cross(u);
    return _Plane(f, n, n.dot(p0), f.centroid, u, v, [
      for (final p in f.points) (u.dot(p), v.dot(p)),
    ]);
  }

  final Face3 face;
  final V3 n;
  final double d;
  final V3 centroid;
  final V3 _u;
  final V3 _v;
  final List<(double, double)> _poly;

  bool contains(V3 q) {
    final x = _u.dot(q), y = _v.dot(q);
    var inside = false;
    for (var i = 0, j = _poly.length - 1; i < _poly.length; j = i++) {
      final (xi, yi) = _poly[i];
      final (xj, yj) = _poly[j];
      if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    return inside;
  }
}

V3 _newell(List<V3> p) {
  var x = 0.0, y = 0.0, z = 0.0;
  for (var i = 0; i < p.length; i++) {
    final a = p[i], b = p[(i + 1) % p.length];
    x += (a.y - b.y) * (a.z + b.z);
    y += (a.z - b.z) * (a.x + b.x);
    z += (a.x - b.x) * (a.y + b.y);
  }
  return V3(x, y, z).normalized;
}

/// Schließt die Kerben an Knicken eines Linienzugs: Die Linien sind Bänder
/// ohne Kappen, an einem Knick bleibt außen ein Keil offen (bei Rundungen
/// wie feine Zacken). Jedes Stück, das an einem Ende genau ein anderes
/// trifft, wird dort um `halfWidth · tan(Knick/2)` verlängert (höchstens
/// [halfWidth]): die Bänder überlappen gerade so weit, dass der Keil zu ist.
List<Edge3> closeJoints(List<Edge3> edges, double halfWidth) {
  if (edges.length < 2 || halfWidth <= 0) return edges;
  String key(V3 p) =>
      '${(p.x * 2e3).round()},${(p.y * 2e3).round()},${(p.z * 2e3).round()}';
  final at = <String, List<(int, bool)>>{};
  for (var i = 0; i < edges.length; i++) {
    at.putIfAbsent(key(edges[i].a), () => []).add((i, true));
    at.putIfAbsent(key(edges[i].b), () => []).add((i, false));
  }
  final out = <Edge3>[];
  for (var i = 0; i < edges.length; i++) {
    final e = edges[i];
    final len = e.length;
    if (len < 1e-6) {
      out.add(e);
      continue;
    }
    final dir = (e.b - e.a) * (1 / len);
    double grow(V3 p, bool start) {
      final others = at[key(p)]!;
      if (others.length != 2) return 0;
      final (j, jStart) = others.firstWhere(
        (o) => o.$1 != i,
        orElse: () => (i, start),
      );
      if (j == i) return 0;
      final o = edges[j];
      final ol = o.length;
      if (ol < 1e-6) return 0;
      // Richtung vom Knick weg, für beide Stücke.
      final mine = start ? dir : -dir;
      final theirs = (jStart ? o.b - o.a : o.a - o.b) * (1 / ol);
      final cos = mine.dot(theirs).clamp(-1.0, 1.0);
      // Gerade weiter (cos ≈ -1): kein Keil.
      final turn = math.pi - math.acos(cos);
      if (turn < 0.02) return 0;
      return math.min(halfWidth, halfWidth * math.tan(turn / 2));
    }

    final ga = math.min(grow(e.a, true), len / 2);
    final gb = math.min(grow(e.b, false), len / 2);
    out.add(Edge3(e.a - dir * ga, e.b + dir * gb));
  }
  return out;
}

/// Vereinigt Stücke auf derselben Geraden zu möglichst langen Kanten.
List<Edge3> _mergeCollinear(List<Edge3> pieces) {
  final groups = <String, List<(double, double, V3, V3)>>{};
  for (final e in pieces) {
    var dir = (e.b - e.a).normalized;
    // Richtung eindeutig machen.
    if (dir.x < -1e-6 ||
        (dir.x.abs() <= 1e-6 &&
            (dir.y < -1e-6 || (dir.y.abs() <= 1e-6 && dir.z < 0)))) {
      dir = -dir;
    }
    // Fußpunkt der Geraden (nächster Punkt zum Ursprung).
    final foot = e.a - dir * dir.dot(e.a);
    String r(double v) => (v * 500).round().toString();
    final key =
        '${r(dir.x * 4)},${r(dir.y * 4)},${r(dir.z * 4)}|'
        '${r(foot.x)},${r(foot.y)},${r(foot.z)}';
    var t0 = dir.dot(e.a), t1 = dir.dot(e.b);
    if (t0 > t1) (t0, t1) = (t1, t0);
    groups.putIfAbsent(key, () => []).add((t0, t1, dir, foot));
  }
  final out = <Edge3>[];
  for (final g in groups.values) {
    g.sort((p, q) => p.$1.compareTo(q.$1));
    var (s, e, dir, foot) = g.first;
    for (final p in g.skip(1)) {
      if (p.$1 <= e + 1e-4) {
        e = math.max(e, p.$2);
      } else {
        out.add(Edge3(foot + dir * s, foot + dir * e));
        (s, e) = (p.$1, p.$2);
      }
    }
    out.add(Edge3(foot + dir * s, foot + dir * e));
  }
  return out;
}

/// Detaillinien eines Modells, leicht aus ihrer Fläche gehoben.
///
/// Eine Linie, die genau auf einer Fläche liegt (Kissen auf der Matratze,
/// Fuge auf der Front), würde mit ihr um die Tiefe kämpfen und in der
/// Draufsicht verschwinden. Jede Linie wird deshalb um [by] Meter entlang
/// der Normalen der Fläche verschoben, auf der ihre Mitte liegt; Linien auf
/// keiner Fläche (Boden) rücken nach oben.
List<Edge3> liftedLines(Model3 model, {double by = 0.004}) {
  final planes = [
    for (final f in model.faces)
      if (f.points.length >= 3) _Plane.of(f),
  ];
  final out = <Edge3>[];
  for (final l in model.lines) {
    final mid = l.mid;
    var lift = V3.up * by;
    for (final p in planes) {
      if ((p.n.dot(mid) - p.d).abs() > 0.003) continue;
      if (!p.contains(mid)) continue;
      lift = p.n * by;
      break;
    }
    out.add(Edge3(l.a + lift, l.b + lift));
  }
  return out;
}
