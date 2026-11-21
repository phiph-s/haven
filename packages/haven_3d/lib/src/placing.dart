import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart';

import 'camera.dart';
import 'model.dart';
import 'scene.dart';
import 'shape.dart' show kWallThickness;

/// Sehstrahl durch einen Bildpunkt: [origin] + t · [dir] (Weltkoordinaten,
/// Meter). Orthographisch liegt [origin] auf der Bildebene durch das Ziel,
/// Punkte vor ihr haben negatives t; die Reihenfolge entlang des Strahls
/// stimmt trotzdem (kleineres t ist näher an der Kamera).
@immutable
class SceneRay {
  const SceneRay(this.origin, this.dir, {this.perspective = false});
  final V3 origin;
  final V3 dir;

  /// Bei Perspektive zählen nur Punkte vor der Kamera (t > 0).
  final bool perspective;

  V3 at(double t) => origin + dir * t;

  /// Strahlparameter auf der Ebene `z = [z]`, `null` ohne Treffer.
  double? tOnPlane(double z) {
    if (dir.z.abs() < 1e-9) return null;
    final t = (z - origin.z) / dir.z;
    if (perspective && t <= 0) return null;
    return t;
  }
}

/// Sehstrahl der Kamera [cam] durch den Bildpunkt [screen] in [size].
/// Trifft die Ebene `z` an derselben Stelle wie [OrbitCamera.unprojectOnPlane].
SceneRay rayAt(OrbitCamera cam, Offset screen, Size size) {
  final b = cam.basis;
  final t0 = cam.panTarget;
  final sx = (screen.dx - size.width / 2) / cam.scale;
  final sy = (screen.dy - size.height / 2) / cam.scale;
  final q = t0 + b.right * sx + b.down * sy;
  if (cam.isPerspective) {
    final origin = t0 + b.toCam * cam.distance(size);
    return SceneRay(origin, q - origin, perspective: true);
  }
  return SceneRay(q, -b.toCam);
}

/// Treffer eines Sehstrahls auf der Innenseite einer Wand.
@immutable
class WallHit {
  const WallHit({
    required this.roomId,
    required this.edge,
    required this.point,
    required this.inward,
    required this.t,
  });

  /// Raum, zu dem die Wand gehört (der Treffer liegt auf seiner Innenseite).
  final String roomId;

  /// Kante des Umrisses (von Ecke [edge] zur nächsten).
  final int edge;

  /// Treffpunkt auf der Innenfläche der Wand (Meter, `z` ist die Höhe).
  final V3 point;

  /// Einheitsnormale der Wand in den Raum hinein (waagerecht).
  final Offset inward;

  /// Strahlparameter (kleiner: näher an der Kamera).
  final double t;

  /// Punkt auf dem Boden, [by] Meter vor der Wand im Raum.
  Offset inFront(double by) => point.xy + inward * by;

  @override
  String toString() =>
      'WallHit($roomId#$edge @ ${point.x.toStringAsFixed(2)}, '
      '${point.y.toStringAsFixed(2)}, ${point.z.toStringAsFixed(2)})';
}

/// Abstand der Innenfläche einer Wand von der Raumgrenze bei [roomGap]
/// (siehe `SceneStyle.roomGap`): halber Spalt plus Wandstärke.
double wallInset(double roomGap) => roomGap / 2 + kWallThickness;

/// Vorderste Wand unter [screen], deren Innenseite zur Kamera zeigt, oder
/// `null`. Getroffen wird die Innenfläche [inset] Meter innerhalb der
/// Raumgrenze (siehe [wallInset]); offene Kanten haben keine Wand. Wände
/// von Räumen in [flat] (flach gelegt) zählen nicht. Weil nur Treffer
/// zwischen Boden und Wandoberkante gelten, liegt eine getroffene Wand immer
/// vor dem Boden dahinter.
WallHit? wallAt(
  Scene scene,
  OrbitCamera cam,
  Size size,
  Offset screen, {
  double inset = 0,
  Set<String> flat = const {},
}) {
  final ray = rayAt(cam, screen, size);
  WallHit? best;
  for (final r in scene.rooms) {
    if (flat.contains(r.id)) continue;
    final pts = r.outline;
    final n = pts.length;
    if (n < 3) continue;
    // Umlaufsinn: links der Kante liegt innen bei positiver Fläche.
    var area = 0.0;
    for (var i = 0; i < n; i++) {
      final a = pts[i], b = pts[(i + 1) % n];
      area += a.dx * b.dy - b.dx * a.dy;
    }
    final sign = area >= 0 ? 1.0 : -1.0;
    for (var i = 0; i < n; i++) {
      if (r.openEdges.contains(i)) continue;
      final a = pts[i], b = pts[(i + 1) % n];
      final e = b - a;
      final len = e.distance;
      if (len < 1e-6) continue;
      final u = e / len;
      final inward = Offset(-u.dy, u.dx) * sign;
      // Innenfläche: um [inset] in den Raum gerückt.
      final a2 = a + inward * inset;
      final nrm = V3(inward.dx, inward.dy, 0);
      final denom = ray.dir.dot(nrm);
      // Nur die Innenseite, von innen gesehen (Strahl läuft zur Wand hin).
      if (denom >= -1e-9) continue;
      final t = (V3(a2.dx, a2.dy, 0) - ray.origin).dot(nrm) / denom;
      if (ray.perspective && t <= 0) continue;
      final p = ray.at(t);
      if (p.z < 0 || p.z > r.wallHeight) continue;
      final along = (p.xy - a2).dx * u.dx + (p.xy - a2).dy * u.dy;
      // Ecken: die Innenflächen sind um [inset] kürzer.
      if (along < inset - 1e-6 || along > len - inset + 1e-6) continue;
      if (best == null || t < best.t) {
        best = WallHit(roomId: r.id, edge: i, point: p, inward: inward, t: t);
      }
    }
  }
  return best;
}
