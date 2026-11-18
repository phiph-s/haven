import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Umriss eines Raums, wie ihn die 2D-Karte zeichnet: um [inset] Meter nach
/// innen versetzt (zwischen Nachbarräumen entsteht so ein Spalt von
/// 2 × [inset]) und mit Radius [radius] an allen Ecken abgerundet, auch an
/// einspringenden Ecken (L-Form). Bögen bestehen aus [segments] Stücken.
///
/// Der Umlaufsinn bleibt erhalten. Zu enge Ecken (kurze Kanten) bekommen
/// automatisch einen kleineren Radius.
///
/// [open] sind offene Kanten (Kante i von Ecke i zur nächsten): Sie bleiben
/// auf dem Umriss (kein Spalt, der Nachbarraum schließt direkt an) und ihre
/// Ecken bleiben spitz. Zwei Räume mit offener Wand wirken so wie eine Form.
///
/// [convexOnly]: nur nach außen zeigende Ecken runden, einspringende bleiben
/// spitz (Außenseite einer Wand mit Stärke, sonst schnitte die Rundung in
/// die Wand).
List<Offset> roundedInset(
  List<Offset> outline, {
  double inset = 0,
  double radius = 0,
  int segments = 6,
  Set<int> open = const {},
  bool convexOnly = false,
}) {
  final (pts, openAfter) = _dedupe(outline, open);
  if (pts.length < 3) return pts;
  final ccw = _area(pts) > 0;
  final inner = inset > 0 ? _offset(pts, inset, ccw, openAfter) : pts;
  if (radius <= 0) return inner;
  final n = pts.length;
  bool reflex(int i) {
    final a = pts[(i - 1 + n) % n], b = pts[i], c = pts[(i + 1) % n];
    final cross = (b - a).dx * (c - b).dy - (b - a).dy * (c - b).dx;
    return ccw ? cross < 0 : cross > 0;
  }

  return _fillet(inner, radius, segments, {
    for (var i = 0; i < n; i++)
      if (openAfter.contains(i) ||
          openAfter.contains((i - 1 + n) % n) ||
          (convexOnly && reflex(i)))
        i,
  });
}

/// Stärke der Wände in Metern: innen eckig (Möbel passen in die Ecken),
/// außen rund wie der Umriss der 2D-Karte.
const double kWallThickness = 0.08;

/// Bodenfläche eines Raums: innen an den Wänden, eckig. Offene Kanten
/// reichen bis zur Raumgrenze.
List<Offset> roomFloor(
  List<Offset> outline, {
  required double gap,
  Set<int> open = const {},
}) => roundedInset(outline, inset: gap / 2 + kWallThickness, open: open);

/// Doppelte Punkte entfernen; offene Kanten behalten ihre (neue) Nummer.
(List<Offset>, Set<int>) _dedupe(List<Offset> p, Set<int> open) {
  final out = <Offset>[];
  final outOpen = <int>{};
  for (var i = 0; i < p.length; i++) {
    final q = p[i];
    if (out.isEmpty || (out.last - q).distance > 1e-6) {
      out.add(q);
    }
    // Die Kante ab diesem Punkt gehört zum zuletzt behaltenen Punkt.
    if (open.contains(i)) outOpen.add(out.length - 1);
  }
  if (out.length > 1 && (out.first - out.last).distance <= 1e-6) {
    out.removeLast();
    if (outOpen.remove(out.length)) outOpen.add(out.length - 1);
  }
  return (out, outOpen);
}

double _area(List<Offset> p) {
  var a = 0.0;
  for (var i = 0; i < p.length; i++) {
    final j = (i + 1) % p.length;
    a += p[i].dx * p[j].dy - p[j].dx * p[i].dy;
  }
  return a / 2;
}

/// Jede Kante um [d] nach innen schieben (offene Kanten nicht), neue Ecken
/// als Schnittpunkte.
List<Offset> _offset(List<Offset> p, double d, bool ccw, Set<int> open) {
  final n = p.length;
  Offset inward(Offset a, Offset b) {
    final e = b - a;
    final len = e.distance;
    // Innen liegt links der Kante, wenn der Umlauf positiv ist.
    final left = Offset(-e.dy / len, e.dx / len);
    return ccw ? left : -left;
  }

  final out = <Offset>[];
  for (var i = 0; i < n; i++) {
    final prev = p[(i - 1 + n) % n], cur = p[i], next = p[(i + 1) % n];
    final n0 = inward(prev, cur), n1 = inward(cur, next);
    final d0 = open.contains((i - 1 + n) % n) ? 0.0 : d;
    final d1 = open.contains(i) ? 0.0 : d;
    final a0 = prev + n0 * d0, a1 = cur + n0 * d0;
    final b0 = cur + n1 * d1, b1 = next + n1 * d1;
    out.add(_intersect(a0, a1, b0, b1) ?? cur + (n0 * d0 + n1 * d1) / 2);
  }
  return out;
}

Offset? _intersect(Offset a0, Offset a1, Offset b0, Offset b1) {
  final r = a1 - a0, s = b1 - b0;
  final den = r.dx * s.dy - r.dy * s.dx;
  if (den.abs() < 1e-12) return null;
  final t = ((b0 - a0).dx * s.dy - (b0 - a0).dy * s.dx) / den;
  return a0 + r * t;
}

/// Ecken durch tangentiale Kreisbögen ersetzen, außer den [sharp].
List<Offset> _fillet(
  List<Offset> p,
  double radius,
  int segments, [
  Set<int> sharp = const {},
]) {
  final n = p.length;
  final out = <Offset>[];
  for (var i = 0; i < n; i++) {
    final prev = p[(i - 1 + n) % n], cur = p[i], next = p[(i + 1) % n];
    if (sharp.contains(i)) {
      out.add(cur);
      continue;
    }
    final u = prev - cur, v = next - cur;
    final lu = u.distance, lv = v.distance;
    if (lu < 1e-9 || lv < 1e-9) {
      out.add(cur);
      continue;
    }
    final du = u / lu, dv = v / lv;
    final cosA = (du.dx * dv.dx + du.dy * dv.dy).clamp(-1.0, 1.0);
    final angle = math.acos(cosA); // Winkel zwischen den Kanten
    if (angle > math.pi - 1e-3) {
      out.add(cur); // gerade weiter, keine Ecke
      continue;
    }
    final half = angle / 2;
    // Höchstens die halbe Kantenlänge verbrauchen.
    final maxT = math.min(lu, lv) / 2;
    var r = radius;
    var t = r / math.tan(half);
    if (t > maxT) {
      t = maxT;
      r = t * math.tan(half);
    }
    final p1 = cur + du * t, p2 = cur + dv * t;
    final bis = du + dv;
    final center = cur + bis / bis.distance * (r / math.sin(half));
    final a1 = math.atan2(p1.dy - center.dy, p1.dx - center.dx);
    final a2 = math.atan2(p2.dy - center.dy, p2.dx - center.dx);
    // Kürzeren Bogen nehmen.
    var sweep = a2 - a1;
    while (sweep > math.pi) {
      sweep -= 2 * math.pi;
    }
    while (sweep < -math.pi) {
      sweep += 2 * math.pi;
    }
    for (var k = 0; k <= segments; k++) {
      final a = a1 + sweep * k / segments;
      out.add(center + Offset(math.cos(a), math.sin(a)) * r);
    }
  }
  return out;
}

/// Verschiebung, die die Punkte [footprint] (Grundfläche eines Möbelstücks)
/// ganz in das Polygon [shape] bringt, mit [margin] Abstand zum Rand.
///
/// Iterativ: Punkte außerhalb ziehen zum nächsten Randpunkt (plus Abstand);
/// je Achse zählt die stärkste Korrektur. Passt das Möbelstück gar nicht
/// hinein (größer als der Raum), bleibt die bisher beste Verschiebung.
Offset fitInside(
  List<Offset> footprint,
  List<Offset> shape, {
  double margin = 0.005,
  int iterations = 12,
}) {
  var delta = Offset.zero;
  for (var it = 0; it < iterations; it++) {
    var dxPos = 0.0, dxNeg = 0.0, dyPos = 0.0, dyNeg = 0.0;
    var outside = false;
    for (final p0 in footprint) {
      final p = p0 + delta;
      final (q, dist) = _nearestOnRing(shape, p);
      final inside = _contains(shape, p);
      if (inside && dist >= margin) continue;
      outside = true;
      // Richtung nach innen: von p zum Rand (außen) bzw. vom Rand weg (innen).
      var dir = inside ? p - q : q - p;
      final len = dir.distance;
      if (len < 1e-9) {
        // Genau auf dem Rand: zur Raummitte hin.
        dir = _centroid(shape) - p;
      }
      dir = dir / dir.distance;
      final push = inside ? margin - dist : dist + margin;
      final c = dir * push;
      dxPos = math.max(dxPos, c.dx);
      dxNeg = math.min(dxNeg, c.dx);
      dyPos = math.max(dyPos, c.dy);
      dyNeg = math.min(dyNeg, c.dy);
    }
    if (!outside) break;
    // Gegenläufige Korrekturen auf einer Achse: passt nicht, Mitte nehmen.
    final step = Offset(dxPos + dxNeg, dyPos + dyNeg);
    if (step.distance < 1e-6) break;
    delta += step;
  }
  return delta;
}

(Offset, double) _nearestOnRing(List<Offset> ring, Offset p) {
  var best = ring.first;
  var bestD = double.infinity;
  for (var i = 0; i < ring.length; i++) {
    final a = ring[i], b = ring[(i + 1) % ring.length];
    final ab = b - a;
    final l2 = ab.distanceSquared;
    final t = l2 < 1e-12
        ? 0.0
        : (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / l2).clamp(0.0, 1.0);
    final q = a + ab * t;
    final d = (p - q).distance;
    if (d < bestD) {
      bestD = d;
      best = q;
    }
  }
  return (best, bestD);
}

bool _contains(List<Offset> poly, Offset p) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.dy > p.dy) != (b.dy > p.dy) &&
        p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
}

Offset _centroid(List<Offset> p) {
  var s = Offset.zero;
  for (final q in p) {
    s += q;
  }
  return s / p.length.toDouble();
}
