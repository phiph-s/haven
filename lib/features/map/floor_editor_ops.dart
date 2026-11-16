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
  return r.copyWith(points: pts);
}

/// Entfernt Ecke [index]. `null`, wenn dann weniger als drei blieben.
FloorRoom? removeVertex(FloorRoom r, int index) {
  if (r.points.length <= 3) return null;
  final pts = [...r.points]..removeAt(index);
  return r.copyWith(points: pts);
}

/// Ecken, die auf einer Geraden zwischen ihren Nachbarn liegen, fallen weg
/// (z. B. nach dem Zurückziehen einer eingefügten Ecke).
FloorRoom simplifyRoom(FloorRoom r) {
  final pts = [...r.points];
  var changed = true;
  while (changed && pts.length > 3) {
    changed = false;
    for (var i = 0; i < pts.length; i++) {
      final a = pts[(i - 1 + pts.length) % pts.length];
      final b = pts[i];
      final c = pts[(i + 1) % pts.length];
      final cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
      final dot = (b.x - a.x) * (c.x - b.x) + (b.y - a.y) * (c.y - b.y);
      if (b == a || (cross == 0 && dot >= 0)) {
        pts.removeAt(i);
        changed = true;
        break;
      }
    }
  }
  return pts.length == r.points.length ? r : r.copyWith(points: pts);
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
