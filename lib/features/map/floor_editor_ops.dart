import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../../data/models/floor_plan.dart';

/// Rechteck aus zwei Rasterecken (beliebige Reihenfolge).
({int x, int y, int w, int h}) cellRect(int x1, int y1, int x2, int y2) => (
  x: math.min(x1, x2),
  y: math.min(y1, y2),
  w: (x1 - x2).abs(),
  h: (y1 - y2).abs(),
);

/// Verschiebt [r] um ganze Zellen und hält es im Raster. Gibt die
/// tatsächliche Verschiebung zurück.
({FloorRoom room, int dx, int dy}) moveRoom(
  FloorRoom r,
  int dx,
  int dy,
  FloorGrid g,
) {
  final b = r.bounds;
  final cdx = dx.clamp(-b.left.round(), g.cols - b.right.round());
  final cdy = dy.clamp(-b.top.round(), g.rows - b.bottom.round());
  return (room: r.translate(cdx, cdy), dx: cdx, dy: cdy);
}

/// Setzt Ecke [index] auf den Rasterpunkt [to] (im Raster gehalten).
FloorRoom moveVertex(FloorRoom r, int index, GridPoint to, FloorGrid g) {
  final p = GridPoint(to.x.clamp(0, g.cols), to.y.clamp(0, g.rows));
  final pts = [...r.points];
  pts[index] = p;
  return r.copyWith(points: pts);
}

/// Rasterpunkt für eine neue Ecke auf Kante [edge] (von Ecke `edge` zur
/// nächsten): die gerundete Mitte. `null`, wenn die Kante zu kurz ist.
GridPoint? edgeMidpoint(FloorRoom r, int edge) {
  final a = r.points[edge];
  final b = r.points[(edge + 1) % r.points.length];
  final m = GridPoint(((a.x + b.x) / 2).round(), ((a.y + b.y) / 2).round());
  if (m == a || m == b) return null;
  return m;
}

/// Fügt nach Ecke [edge] eine Ecke ein (Standard: Kantenmitte). `null`, wenn
/// die Kante dafür zu kurz ist.
FloorRoom? insertVertex(FloorRoom r, int edge, [GridPoint? at]) {
  final p = at ?? edgeMidpoint(r, edge);
  if (p == null) return null;
  final pts = [...r.points]..insert(edge + 1, p);
  // Kanten hinter der neuen Ecke rücken eins weiter; eine offene Kante
  // bleibt in beiden Hälften offen.
  return r.copyWith(
    points: pts,
    open: {
      for (final i in r.open) ...[
        i > edge ? i + 1 : i,
        if (i == edge) edge + 1,
      ],
    },
  );
}

/// Entfernt Ecke [index]. `null`, wenn dann weniger als drei blieben.
FloorRoom? removeVertex(FloorRoom r, int index) {
  if (r.points.length <= 3) return null;
  final pts = [...r.points]..removeAt(index);
  return r.copyWith(points: pts, open: _mergeOpen(r, index));
}

/// Offene Kanten nach dem Entfernen von Ecke [index]: die Kanten davor und
/// danach werden eine, offen nur, wenn beide offen waren.
Set<int> _mergeOpen(FloorRoom r, int index) {
  final n = r.points.length;
  final before = (index - 1 + n) % n;
  final both = r.isOpen(before) && r.isOpen(index);
  final out = <int>{};
  for (var e = 0; e < n; e++) {
    if (e == index || e == before) continue;
    if (!r.isOpen(e)) continue;
    // Neue Nummer: alles hinter der entfernten Ecke rückt eins vor.
    out.add(e > index ? e - 1 : e);
  }
  if (both) out.add(before > index ? before - 1 : before);
  return out;
}

/// Kante [edge] öffnen oder schließen (Wand oder nur Raumgrenze).
FloorRoom setEdgeOpen(FloorRoom r, int edge, bool open) =>
    r.copyWith(open: open ? {...r.open, edge} : ({...r.open}..remove(edge)));

/// Kanten anderer Räume, die mit Kante [edge] von [r] auf einer Linie liegen
/// und sich mit ihr überdecken (gemeinsame Wand): je Raum die Kanten.
Map<String, List<int>> sharedEdges(
  FloorRoom r,
  int edge,
  Iterable<FloorRoom> rooms,
) {
  final n = r.points.length;
  final a = r.points[edge].offset, b = r.points[(edge + 1) % n].offset;
  final d = b - a;
  final len = d.distance;
  if (len == 0) return const {};
  final u = d / len;
  final out = <String, List<int>>{};
  for (final q in rooms) {
    if (q.id == r.id) continue;
    final m = q.points.length;
    for (var k = 0; k < m; k++) {
      final c = q.points[k].offset, e = q.points[(k + 1) % m].offset;
      // Auf derselben Geraden?
      double off(Offset p) => ((p - a).dx * u.dy - (p - a).dy * u.dx).abs();
      if (off(c) > 1e-6 || off(e) > 1e-6) continue;
      double t(Offset p) => (p - a).dx * u.dx + (p - a).dy * u.dy;
      final lo = math.max(0.0, math.min(t(c), t(e)));
      final hi = math.min(len, math.max(t(c), t(e)));
      if (hi - lo > 1e-6) (out[q.id] ??= []).add(k);
    }
  }
  return out;
}

/// Ecken, die auf einer Geraden zwischen ihren Nachbarn liegen, fallen weg
/// (z. B. nach dem Zurückziehen einer eingefügten Ecke).
FloorRoom simplifyRoom(FloorRoom r) {
  final pts = [...r.points];
  var open = r.open;
  var changed = true;
  while (changed && pts.length > 3) {
    changed = false;
    for (var i = 0; i < pts.length; i++) {
      final a = pts[(i - 1 + pts.length) % pts.length];
      final b = pts[i];
      final c = pts[(i + 1) % pts.length];
      final cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
      final dot = (b.x - a.x) * (c.x - b.x) + (b.y - a.y) * (c.y - b.y);
      // Eine Ecke zwischen offener und geschlossener Wand bleibt.
      final cur = FloorRoom(id: r.id, name: r.name, points: pts, open: open);
      final mixed =
          cur.isOpen((i - 1 + pts.length) % pts.length) != cur.isOpen(i);
      if (b == a || (cross == 0 && dot >= 0 && !mixed)) {
        open = _mergeOpen(cur, i);
        pts.removeAt(i);
        changed = true;
        break;
      }
    }
  }
  return pts.length == r.points.length
      ? r
      : r.copyWith(points: pts, open: open);
}

/// Was am Pixel [p] unter dem gewählten Raum liegt.
sealed class RoomHandle {
  const RoomHandle();
}

class VertexHandle extends RoomHandle {
  const VertexHandle(this.index);
  final int index;
}

class EdgeHandle extends RoomHandle {
  const EdgeHandle(this.index);
  final int index;
}

/// Nächster Griff (Ecke vor Kantenmitte) innerhalb von [radius] Pixeln.
/// [px] sind die Ecken in Pixeln.
RoomHandle? handleAt(List<Offset> px, Offset p, {double radius = 26}) {
  var best = radius;
  RoomHandle? out;
  for (var i = 0; i < px.length; i++) {
    final d = (px[i] - p).distance;
    if (d <= best) {
      best = d;
      out = VertexHandle(i);
    }
  }
  if (out != null) return out;
  best = radius * 0.85;
  for (var i = 0; i < px.length; i++) {
    final m = (px[i] + px[(i + 1) % px.length]) / 2;
    final d = (m - p).distance;
    if (d <= best) {
      best = d;
      out = EdgeHandle(i);
    }
  }
  return out;
}
