import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'camera.dart';
import 'model.dart';
import 'scene.dart';

/// Was unter einem Punkt liegt.
enum HitKind { marker, object, room }

@immutable
class SceneHit {
  const SceneHit(this.kind, this.id);
  final HitKind kind;
  final String id;

  @override
  bool operator ==(Object other) =>
      other is SceneHit && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'SceneHit($kind, $id)';
}

/// Radius, in dem ein Gerätepunkt getroffen wird (logische Pixel).
const double kMarkerHitRadius = 14;

/// Treffertest ohne GPU: Gerät vor Möbel vor Raum, jeweils das vorderste.
///
/// Möbel werden über die Hülle ihrer projizierten Punkte getroffen, unter
/// mehreren das mit der Mitte am nächsten zur Kamera. [hidden] sind
/// ausgeblendete Objekte (Türen in weggeschnittenen Wänden). [markers]
/// ersetzt die Geräte der Szene (z. B. eine Ebene der App über der Szene).
SceneHit? hitTestScene(
  Scene scene,
  OrbitCamera camera,
  Size size,
  Offset point, {
  String? focusRoomId,
  Set<String> hidden = const {},
  double Function(String? roomId)? heightOf,
  List<SceneMarker>? markers,
  double markerRadius = kMarkerHitRadius,
}) {
  // Flache Räume: Höhen mitstauchen, damit der Treffer zum Bild passt.
  V3 lift(V3 p, String? room) =>
      heightOf == null ? p : V3(p.x, p.y, p.z * heightOf(room));
  bool inFocus(String? room) => focusRoomId == null || room == focusRoomId;

  SceneHit? best;
  var bestDepth = double.negativeInfinity;
  String? roomOf(SceneMarker m) =>
      m.roomId ?? scene.markerRoom[m.id] ?? scene.roomAt(m.position.xy);
  for (final m in markers ?? scene.markers) {
    final room = roomOf(m);
    if (!inFocus(room)) continue;
    final p = camera.project(lift(m.position, room), size);
    if ((p.offset - point).distance <= markerRadius && p.depth > bestDepth) {
      best = SceneHit(HitKind.marker, m.id);
      bestDepth = p.depth;
    }
  }
  if (best != null) return best;

  for (final o in scene.objects) {
    if (hidden.contains(o.id) || !inFocus(scene.objectRoom[o.id])) continue;
    final room = scene.objectRoom[o.id];
    final hull = convexHull([
      for (final q in o.world.points)
        camera.project(lift(q, room), size).offset,
    ]);
    if (hull.length < 3 || !pointInPolygon(hull, point)) continue;
    final d = camera.project(lift(o.center, room), size).depth;
    if (d > bestDepth) {
      best = SceneHit(HitKind.object, o.id);
      bestDepth = d;
    }
  }
  if (best != null) return best;

  for (final r in scene.rooms) {
    if (!inFocus(r.id)) continue;
    final floor = [
      for (final q in r.outline) camera.project(V3(q.dx, q.dy, 0), size).offset,
    ];
    if (!pointInPolygon(floor, point)) continue;
    final c = r.centroid;
    final d = camera.project(V3(c.dx, c.dy, 0), size).depth;
    if (d > bestDepth) {
      best = SceneHit(HitKind.room, r.id);
      bestDepth = d;
    }
  }
  return best;
}

/// Konvexe Hülle (monotone Kette), Punkte im Umlauf.
List<Offset> convexHull(List<Offset> pts) {
  if (pts.length < 3) return pts;
  final p = [
    ...pts,
  ]..sort((a, b) => a.dx != b.dx ? a.dx.compareTo(b.dx) : a.dy.compareTo(b.dy));
  double cross(Offset o, Offset a, Offset b) =>
      (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);
  final lower = <Offset>[], upper = <Offset>[];
  for (final q in p) {
    while (lower.length >= 2 &&
        cross(lower[lower.length - 2], lower.last, q) <= 0) {
      lower.removeLast();
    }
    lower.add(q);
  }
  for (final q in p.reversed) {
    while (upper.length >= 2 &&
        cross(upper[upper.length - 2], upper.last, q) <= 0) {
      upper.removeLast();
    }
    upper.add(q);
  }
  return [...lower..removeLast(), ...upper..removeLast()];
}

bool pointInPolygon(List<Offset> poly, Offset p) {
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

/// Räume, die [roomId] aus Sicht von [camera] verdecken würden: ihre
/// aufgerichtete Hülle überdeckt den Boden von [roomId] und sie liegen
/// näher an der Kamera. In der Draufsicht verdeckt nichts.
Set<String> occludersOf(
  Scene scene,
  String roomId,
  OrbitCamera camera,
  Size size,
) {
  final target = scene.room(roomId);
  if (target == null || camera.pitch < 0.05) return const {};
  Offset at(Offset p, double z) =>
      camera.project(V3(p.dx, p.dy, z), size).offset;
  double depth(SceneRoom r) {
    final c = r.labelAt;
    return camera.project(V3(c.dx, c.dy, 0), size).depth;
  }

  final floor = convexHull([for (final p in target.outline) at(p, 0)]);
  final d0 = depth(target);
  final out = <String>{};
  for (final r in scene.rooms) {
    if (r.id == roomId) continue;
    // Nur was vor dem Raum liegt (mit etwas Spielraum für Nachbarn daneben).
    if (depth(r) <= d0 + 0.3) continue;
    final hull = convexHull([
      for (final p in r.outline) ...[at(p, 0), at(p, r.wallHeight)],
    ]);
    if (_convexOverlap(hull, floor)) out.add(r.id);
  }
  return out;
}

/// Überlappen sich zwei konvexe Polygone (Trennachsen)?
bool _convexOverlap(List<Offset> a, List<Offset> b) {
  if (a.length < 3 || b.length < 3) return false;
  bool separated(List<Offset> p, List<Offset> q) {
    for (var i = 0; i < p.length; i++) {
      final e = p[(i + 1) % p.length] - p[i];
      if (e.distance < 1e-9) continue;
      final n = Offset(-e.dy, e.dx) / e.distance;
      double proj(Offset v) => v.dx * n.dx + v.dy * n.dy;
      var pMin = double.infinity, pMax = -double.infinity;
      for (final v in p) {
        final t = proj(v);
        pMin = t < pMin ? t : pMin;
        pMax = t > pMax ? t : pMax;
      }
      var qMin = double.infinity, qMax = -double.infinity;
      for (final v in q) {
        final t = proj(v);
        qMin = t < qMin ? t : qMin;
        qMax = t > qMax ? t : qMax;
      }
      // Kleine Berührungen (gemeinsame Kante) zählen nicht.
      if (pMax <= qMin + 2 || qMax <= pMin + 2) return true;
    }
    return false;
  }

  return !separated(a, b) && !separated(b, a);
}
