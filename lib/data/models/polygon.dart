import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';

/// Ein Rasterpunkt (Ecke zwischen Zellen) oder eine Rasterzelle, je nach
/// Zusammenhang. Ganze Zahlen, Wertgleichheit.
@immutable
class GridPoint {
  const GridPoint(this.x, this.y);

  factory GridPoint.fromJson(Object? j) {
    if (j is List && j.length >= 2) {
      return GridPoint((j[0] as num).round(), (j[1] as num).round());
    }
    if (j is Map) {
      return GridPoint((j['x'] as num).round(), (j['y'] as num).round());
    }
    throw const FormatException('Punkt erwartet');
  }

  final int x;
  final int y;

  Offset get offset => Offset(x.toDouble(), y.toDouble());

  /// Mitte der Zelle (x, y).
  Offset get center => Offset(x + 0.5, y + 0.5);

  GridPoint translate(int dx, int dy) => GridPoint(x + dx, y + dy);

  List<int> toJson() => [x, y];

  @override
  bool operator ==(Object other) =>
      other is GridPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => '($x, $y)';
}

/// Lage eines Punkts zu einem Polygon.
enum PointLocation { inside, boundary, outside }

const double _eps = 1e-9;

double _cross(Offset a, Offset b, Offset c) =>
    (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);

/// Vorzeichenbehaftete Fläche (Schnürsenkelformel).
double signedArea(List<Offset> p) {
  var s = 0.0;
  for (var i = 0; i < p.length; i++) {
    final a = p[i];
    final b = p[(i + 1) % p.length];
    s += a.dx * b.dy - b.dx * a.dy;
  }
  return s / 2;
}

double polygonArea(List<Offset> p) => signedArea(p).abs();

/// Flächenschwerpunkt, bei entarteten Polygonen das Mittel der Ecken.
Offset polygonCentroid(List<Offset> p) {
  final a = signedArea(p);
  if (a.abs() < _eps) {
    if (p.isEmpty) return Offset.zero;
    return p.reduce((x, y) => x + y) / p.length.toDouble();
  }
  var cx = 0.0;
  var cy = 0.0;
  for (var i = 0; i < p.length; i++) {
    final s = p[i];
    final t = p[(i + 1) % p.length];
    final f = s.dx * t.dy - t.dx * s.dy;
    cx += (s.dx + t.dx) * f;
    cy += (s.dy + t.dy) * f;
  }
  return Offset(cx / (6 * a), cy / (6 * a));
}

Rect polygonBounds(List<Offset> p) {
  if (p.isEmpty) return Rect.zero;
  var l = p.first.dx, r = l, t = p.first.dy, b = t;
  for (final o in p) {
    l = math.min(l, o.dx);
    r = math.max(r, o.dx);
    t = math.min(t, o.dy);
    b = math.max(b, o.dy);
  }
  return Rect.fromLTRB(l, t, r, b);
}

double _distToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (len2 < _eps) return (p - a).distance;
  final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

/// Punkt im Polygon (Strahlverfahren). Liegt er auf einer Kante (Toleranz
/// [tolerance]), ist das Ergebnis [PointLocation.boundary].
PointLocation locatePoint(
  List<Offset> poly,
  Offset p, {
  double tolerance = 1e-7,
}) {
  final n = poly.length;
  if (n < 3) return PointLocation.outside;
  for (var i = 0; i < n; i++) {
    if (_distToSegment(p, poly[i], poly[(i + 1) % n]) <= tolerance) {
      return PointLocation.boundary;
    }
  }
  var inside = false;
  for (var i = 0, j = n - 1; i < n; j = i++) {
    final a = poly[i];
    final b = poly[j];
    if ((a.dy > p.dy) != (b.dy > p.dy)) {
      final x = (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx;
      if (p.dx < x) inside = !inside;
    }
  }
  return inside ? PointLocation.inside : PointLocation.outside;
}

/// Ob sich die Strecken [a]–[b] und [c]–[d] echt kreuzen: in einem Punkt,
/// der für beide im Inneren liegt, und nicht parallel.
bool segmentsProperlyCross(Offset a, Offset b, Offset c, Offset d) {
  final d1 = _cross(c, d, a);
  final d2 = _cross(c, d, b);
  final d3 = _cross(a, b, c);
  final d4 = _cross(a, b, d);
  return ((d1 > _eps && d2 < -_eps) || (d1 < -_eps && d2 > _eps)) &&
      ((d3 > _eps && d4 < -_eps) || (d3 < -_eps && d4 > _eps));
}

bool _onSegment(Offset p, Offset a, Offset b) =>
    _distToSegment(p, a, b) <= 1e-9;

/// Ob sich die Strecken überhaupt berühren (auch an Enden oder kollinear).
bool segmentsTouch(Offset a, Offset b, Offset c, Offset d) {
  if (segmentsProperlyCross(a, b, c, d)) return true;
  return _onSegment(a, c, d) ||
      _onSegment(b, c, d) ||
      _onSegment(c, a, b) ||
      _onSegment(d, a, b);
}

/// Parameter (0..1) auf [a]–[b], an denen [c]–[d] sie trifft.
List<double> _hits(Offset a, Offset b, Offset c, Offset d) {
  final r = b - a;
  final s = d - c;
  final den = r.dx * s.dy - r.dy * s.dx;
  final len2 = r.dx * r.dx + r.dy * r.dy;
  if (len2 < _eps) return const [];
  final out = <double>[];
  if (den.abs() < _eps) {
    // Parallel: nur kollinear interessant, dann die Enden von c–d.
    if (_cross(a, b, c).abs() > 1e-9) return const [];
    for (final q in [c, d]) {
      final t = ((q - a).dx * r.dx + (q - a).dy * r.dy) / len2;
      if (t > -1e-9 && t < 1 + 1e-9) out.add(t.clamp(0.0, 1.0));
    }
    return out;
  }
  final ac = c - a;
  final t = (ac.dx * s.dy - ac.dy * s.dx) / den;
  final u = (ac.dx * r.dy - ac.dy * r.dx) / den;
  if (t > -1e-9 && t < 1 + 1e-9 && u > -1e-9 && u < 1 + 1e-9) {
    out.add(t.clamp(0.0, 1.0));
  }
  return out;
}

/// Ob ein Stück des Rands von [a] im Inneren von [b] liegt. Jede Kante von
/// [a] wird an allen Berührpunkten mit [b] geteilt, die Mitte jedes Stücks
/// wird geprüft. Gemeinsame Kanten liegen auf dem Rand, zählen also nicht.
bool _boundaryEnters(List<Offset> a, List<Offset> b) {
  for (var i = 0; i < a.length; i++) {
    final p = a[i];
    final q = a[(i + 1) % a.length];
    final ts = <double>[0, 1];
    for (var j = 0; j < b.length; j++) {
      ts.addAll(_hits(p, q, b[j], b[(j + 1) % b.length]));
    }
    ts.sort();
    for (var k = 0; k + 1 < ts.length; k++) {
      if (ts[k + 1] - ts[k] < 1e-7) continue;
      final m = Offset.lerp(p, q, (ts[k] + ts[k + 1]) / 2)!;
      if (locatePoint(b, m) == PointLocation.inside) return true;
    }
  }
  return false;
}

/// Ein Punkt knapp im Inneren von [p] (neben der Mitte der ersten Kante).
Offset? _innerProbe(List<Offset> p) {
  for (var i = 0; i < p.length; i++) {
    final a = p[i];
    final b = p[(i + 1) % p.length];
    final d = b - a;
    if (d.distance < 1e-6) continue;
    final n = Offset(-d.dy, d.dx) / d.distance * 1e-4;
    final m = (a + b) / 2;
    for (final c in [m + n, m - n]) {
      if (locatePoint(p, c, tolerance: 1e-9) == PointLocation.inside) return c;
    }
  }
  return null;
}

/// Überlappen sich die Flächen zweier einfacher Polygone? Gemeinsame Kanten
/// und Ecken zählen nicht. Prüft echte Kantenkreuzungen, Randstücke im
/// Inneren des anderen und deckungsgleiche Flächen.
bool polygonsOverlap(List<Offset> a, List<Offset> b) {
  if (a.length < 3 || b.length < 3) return false;
  final ba = polygonBounds(a);
  final bb = polygonBounds(b);
  if (ba.right <= bb.left + 1e-9 ||
      bb.right <= ba.left + 1e-9 ||
      ba.bottom <= bb.top + 1e-9 ||
      bb.bottom <= ba.top + 1e-9) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    for (var j = 0; j < b.length; j++) {
      if (segmentsProperlyCross(
        a[i],
        a[(i + 1) % a.length],
        b[j],
        b[(j + 1) % b.length],
      )) {
        return true;
      }
    }
  }
  if (_boundaryEnters(a, b) || _boundaryEnters(b, a)) return true;
  // Deckungsgleich (alle Ränder aufeinander): ein Punkt im Inneren reicht.
  final pa = _innerProbe(a);
  if (pa != null && locatePoint(b, pa) == PointLocation.inside) return true;
  final pb = _innerProbe(b);
  if (pb != null && locatePoint(a, pb) == PointLocation.inside) return true;
  return false;
}

/// Grund, warum die Ecken kein brauchbares Raum-Polygon ergeben, sonst `null`.
String? polygonShapeProblem(List<Offset> p, {double minArea = 4}) {
  final n = p.length;
  if (n < 3) return 'Ein Raum braucht mindestens drei Ecken';
  for (var i = 0; i < n; i++) {
    if ((p[i] - p[(i + 1) % n]).distance < 1e-9) {
      return 'Zwei Ecken liegen aufeinander';
    }
  }
  for (var i = 0; i < n; i++) {
    final a = p[i];
    final b = p[(i + 1) % n];
    for (var j = i + 1; j < n; j++) {
      final c = p[j];
      final d = p[(j + 1) % n];
      final adjacent = j == i + 1 || (i == 0 && j == n - 1);
      if (!adjacent) {
        if (segmentsTouch(a, b, c, d)) return 'Die Wände kreuzen sich';
        continue;
      }
      // Benachbarte Kanten: dürfen nicht zurücklaufen (Spitze ohne Fläche).
      final shared = j == i + 1 ? b : a;
      final other1 = j == i + 1 ? a : b;
      final other2 = j == i + 1 ? d : c;
      final u = other1 - shared;
      final v = other2 - shared;
      final crs = u.dx * v.dy - u.dy * v.dx;
      final dot = u.dx * v.dx + u.dy * v.dy;
      if (crs.abs() < 1e-9 && dot > 0) return 'Die Wände kreuzen sich';
    }
  }
  if (polygonArea(p) < minArea - 1e-9) return 'Der Raum ist zu klein';
  return null;
}

/// Größtes achsenparalleles Rechteck aus ganzen Zellen, die vollständig im
/// Polygon liegen. Für Beschriftung, Mitte und Schnellplatzierung. Ohne
/// volle Zelle ein Rechteck um den Schwerpunkt.
Rect largestInnerRect(List<Offset> poly) {
  final b = polygonBounds(poly);
  final x0 = b.left.floor();
  final y0 = b.top.floor();
  final w = b.right.ceil() - x0;
  final h = b.bottom.ceil() - y0;
  if (w <= 0 || h <= 0) {
    return Rect.fromCenter(center: b.center, width: 1, height: 1);
  }
  bool full(int cx, int cy) {
    final x = (x0 + cx).toDouble();
    final y = (y0 + cy).toDouble();
    if (locatePoint(poly, Offset(x + 0.5, y + 0.5)) != PointLocation.inside) {
      return false;
    }
    for (final c in [
      Offset(x, y),
      Offset(x + 1, y),
      Offset(x, y + 1),
      Offset(x + 1, y + 1),
    ]) {
      if (locatePoint(poly, c) == PointLocation.outside) return false;
    }
    return true;
  }

  final heights = List<int>.filled(w, 0);
  var best = 0;
  Rect? bestRect;
  for (var cy = 0; cy < h; cy++) {
    for (var cx = 0; cx < w; cx++) {
      heights[cx] = full(cx, cy) ? heights[cx] + 1 : 0;
    }
    // Größtes Rechteck im Histogramm (Stapel).
    final stack = <int>[];
    for (var i = 0; i <= w; i++) {
      final hi = i == w ? 0 : heights[i];
      while (stack.isNotEmpty && heights[stack.last] >= hi) {
        final top = stack.removeLast();
        final height = heights[top];
        final left = stack.isEmpty ? 0 : stack.last + 1;
        final width = i - left;
        // Bei gleicher Fläche das quadratischere, damit Text Platz hat.
        final area = width * height;
        final score = area * 1000 - (width - height).abs();
        if (height > 0 && score > best) {
          best = score;
          bestRect = Rect.fromLTWH(
            (x0 + left).toDouble(),
            (y0 + cy - height + 1).toDouble(),
            width.toDouble(),
            height.toDouble(),
          );
        }
      }
      stack.add(i);
    }
  }
  return bestRect ??
      Rect.fromCenter(center: polygonCentroid(poly), width: 1, height: 1);
}

/// Polygon um [d] nach innen versetzt (Gehrung). Für kleine [d] gegenüber den
/// Kantenlängen, z. B. die Fuge zwischen Räumen.
List<Offset> insetPolygon(List<Offset> p, double d) {
  final n = p.length;
  if (n < 3 || d == 0) return p;
  final sign = signedArea(p) > 0 ? 1.0 : -1.0;
  // Innere Normale je Kante.
  final lines = <(Offset, Offset)>[];
  for (var i = 0; i < n; i++) {
    final a = p[i];
    final b = p[(i + 1) % n];
    final e = b - a;
    final len = e.distance;
    if (len < 1e-9) {
      lines.add((a, e));
      continue;
    }
    final nrm = Offset(-e.dy, e.dx) / len * (d * sign);
    lines.add((a + nrm, e));
  }
  final out = <Offset>[];
  for (var i = 0; i < n; i++) {
    final (p1, e1) = lines[(i - 1 + n) % n];
    final (p2, e2) = lines[i];
    final den = e1.dx * e2.dy - e1.dy * e2.dx;
    if (den.abs() < 1e-9) {
      out.add(p2);
      continue;
    }
    final t = ((p2 - p1).dx * e2.dy - (p2 - p1).dy * e2.dx) / den;
    final q = p1 + e1 * t;
    // Spitze Ecken nicht ausufern lassen.
    if ((q - p[i]).distance > d * 4) {
      out.add(p[i] + (q - p[i]) / (q - p[i]).distance * d * 4);
    } else {
      out.add(q);
    }
  }
  return out;
}
