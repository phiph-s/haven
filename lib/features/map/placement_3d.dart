import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:haven_3d/haven_3d.dart' as h3;

import '../../data/models/floor_plan.dart';
import 'furniture_ops.dart';

// Platzieren in 3D: Bildschirm → Boden, Einrasten (Halbraster, Wand) und
// Treffertest der Möbel. Alles reine Rechnung (Zellen, wo nicht anders
// angegeben), damit Editor und Tests dieselben Regeln nutzen.

/// Möbel, die mit der Rückseite (lokal `-y`) an die Wand rücken.
const Set<String> kWallHuggers = {
  'bed_double',
  'bed_single',
  'nightstand',
  'wardrobe',
  'sofa',
  'tv_board',
  'shelf',
  'kitchen_counter',
  'stove',
  'sink',
  'fridge',
  'bathtub',
  'shower',
  'toilet',
  'washbasin',
  'desk',
};

/// Rückt [kind] mit der Rückseite an die Wand?
bool hugsWall(String kind) => kWallHuggers.contains(kind);

/// Wie nah (Zellen, Rückseite bis Wand) ein Möbelstück an eine Wand kommen
/// muss, damit es einrastet (etwa 60 cm).
const double kWallReach = 1.2;

/// Drehung in 15°-Schritten (wie die Griffe), [free] ohne Raster.
double snapRotation(double deg, {bool free = false}) => normalizeDegrees(
  free
      ? deg
      : (deg / kFurnitureRotationStep).roundToDouble() * kFurnitureRotationStep,
);

double _clean(double v) => (v * 1e6).roundToDouble() / 1e6;

/// Punkt auf dem Boden unter [screen] in Zellen (Kamera [cam] in einer
/// Fläche [size], Zellen zu [cellMeters] Metern). [z] ist die Höhe der
/// Ebene in Metern (z. B. die Oberseite eines gegriffenen Möbelstücks:
/// dann bleibt es genau unter dem Finger). `null`, wenn der Sehstrahl die
/// Ebene nicht trifft.
Offset? floorCellAt(
  h3.OrbitCamera cam,
  Size size,
  Offset screen,
  double cellMeters, {
  double z = 0,
}) {
  final p = cam.unprojectOnPlane(screen, size, z: z);
  return p == null ? null : p.xy / cellMeters;
}

/// Geschlossene Wand eines Raums: Ecken [a], [b] (Zellen), Richtung [u]
/// (Einheitsvektor von [a] nach [b]) und Normale [inward] in den Raum.
typedef WallEdge = ({Offset a, Offset b, Offset u, double len, Offset inward});

/// Geschlossene Wände von [room] (offene Kanten fallen weg).
List<WallEdge> wallsOf(FloorRoom room) {
  final pts = room.offsets;
  final n = pts.length;
  if (n < 3) return const [];
  var area = 0.0;
  for (var i = 0; i < n; i++) {
    final a = pts[i], b = pts[(i + 1) % n];
    area += a.dx * b.dy - b.dx * a.dy;
  }
  final sign = area >= 0 ? 1.0 : -1.0;
  final out = <WallEdge>[];
  for (var i = 0; i < n; i++) {
    final a = pts[i], b = pts[(i + 1) % n];
    final len = (b - a).distance;
    if (room.isOpen(i) || len < 1e-9) continue;
    final u = (b - a) / len;
    out.add((a: a, b: b, u: u, len: len, inward: Offset(-u.dy, u.dx) * sign));
  }
  return out;
}

/// Nächste Wand zu [p] und ihr Abstand (Zellen), `null` ohne Wände.
(WallEdge, double)? nearestWall(Iterable<WallEdge> walls, Offset p) {
  (WallEdge, double)? best;
  for (final w in walls) {
    final t = ((p - w.a).dx * w.u.dx + (p - w.a).dy * w.u.dy).clamp(0.0, w.len);
    final d = (p - (w.a + w.u * t)).distance;
    if (best == null || d < best.$2) best = (w, d);
  }
  return best;
}

/// Stelle entlang der Wand [w] für ein Stück der Breite [width], dessen
/// Mitte bei [p] liegt: Anfang auf dem Halbraster (die Ecken der Räume
/// liegen auf ganzen Zellen), ganz auf der Wand, wenn es passt.
double _alongWall(WallEdge w, Offset p, double width, {bool snap = true}) {
  var t = (p - w.a).dx * w.u.dx + (p - w.a).dy * w.u.dy;
  if (snap) t = snapTo(t - width / 2, kFurnitureSnap) + width / 2;
  if (w.len < width) return w.len / 2;
  return t.clamp(width / 2, w.len - width / 2);
}

/// Raum, in dem [p] liegt (ohne „Ohne Raum“), oder `null`.
FloorRoom? roomOf(Iterable<FloorRoom> rooms, Offset p) {
  for (final r in rooms) {
    if (!r.detached && r.contains(p)) return r;
  }
  return null;
}

/// Rückt [f] mit der Rückseite (lokal `-y`) an die nächste geschlossene
/// Wand seines Raums, wenn die Rückseite höchstens [reach] Zellen entfernt
/// wäre: gedreht wie die Wand, entlang der Wand auf dem Halbraster ([snap])
/// und ganz auf ihr. Sonst (oder außerhalb der Räume) unverändert.
FloorFurniture snapBackToWall(
  FloorFurniture f,
  Iterable<FloorRoom> rooms, {
  double reach = kWallReach,
  bool snap = true,
}) {
  final room = roomOf(rooms, f.center);
  if (room == null) return f;
  final near = nearestWall(wallsOf(room), f.center);
  if (near == null) return f;
  final (w, d) = near;
  if (d > f.h / 2 + reach) return f;
  // Rückseite zeigt nach außen: (sin r, -cos r) = -inward.
  final out = -w.inward;
  final deg = math.atan2(out.dx, -out.dy) * 180 / math.pi;
  final t = _alongWall(w, f.center, f.w, snap: snap);
  final c = w.a + w.u * t + w.inward * (f.h / 2);
  return f
      .copyWith(rotation: _clean(normalizeDegrees(deg)))
      .moveTo(Offset(_clean(c.dx), _clean(c.dy)));
}

/// Setzt ein Fenster mittig in die nächste geschlossene Wand (höchstens
/// [reach] Zellen entfernt), längs zur Wand. Die Szene dreht es selbst zur
/// Raumseite; hier bleibt die Richtung, die näher an der bisherigen liegt.
FloorFurniture snapWindowToWall(
  FloorFurniture f,
  Iterable<FloorRoom> rooms, {
  double reach = 1.0,
  bool snap = true,
}) {
  if (f.kind != 'window') return f;
  (WallEdge, double)? best;
  for (final r in rooms) {
    if (r.detached) continue;
    final near = nearestWall(wallsOf(r), f.center);
    if (near != null && (best == null || near.$2 < best.$2)) best = near;
  }
  if (best == null || best.$2 > reach) return f;
  final w = best.$1;
  var deg = math.atan2(w.u.dy, w.u.dx) * 180 / math.pi;
  final turn = normalizeDegrees(deg - f.rotation);
  if (turn > 90 && turn < 270) deg += 180;
  final t = _alongWall(w, f.center, f.w, snap: snap);
  final c = w.a + w.u * t;
  return f
      .copyWith(rotation: _clean(normalizeDegrees(deg)))
      .moveTo(Offset(_clean(c.dx), _clean(c.dy)));
}

/// Wand-Regeln je Art: Türen und Fenster in die Wand, Schränke, Betten,
/// Sofas und Co. mit dem Rücken an die Wand, alles andere bleibt.
FloorFurniture snapToWalls(FloorFurniture f, Iterable<FloorRoom> rooms) {
  if (f.kind == 'door') return snapDoorToWall(f, rooms);
  if (f.kind == 'window') return snapWindowToWall(f, rooms);
  if (hugsWall(f.kind)) return snapBackToWall(f, rooms);
  return f;
}

/// [f] mit der Mitte bei [cell] (Punkt unter dem Finger): im Raster,
/// mit [snap] auf dem Halbraster und an der Wand (siehe [snapToWalls]).
FloorFurniture placeFurnitureAt(
  FloorFurniture f,
  Offset cell,
  HavenFloorPlan plan, {
  bool snap = true,
}) {
  var next = f.moveTo(clampToGrid(cell, plan.grid));
  if (!snap) return next;
  next = snapFurniture(next);
  return snapToWalls(next, plan.rooms);
}

/// Verschiebt [base] um [delta] Zellen wie `moveFurniture`, mit [snap]
/// zusätzlich an die Wand.
FloorFurniture moveFurniture3d(
  FloorFurniture base,
  Offset delta,
  HavenFloorPlan plan, {
  bool snap = true,
}) {
  final next = moveFurniture(base, delta, plan.grid, snap: snap);
  return snap ? snapToWalls(next, plan.rooms) : next;
}

/// Ecken des Möbelstücks [f] als Quader in Metern (unten, dann oben), mit
/// Höhe und Bodenabstand aus dem 3D-Katalog.
List<h3.V3> furnitureBox(FloorFurniture f, double cellMeters) {
  final spec = h3.furnitureSpec(f.kind);
  final z0 = spec.elevation, z1 = spec.elevation + spec.height;
  final cs = [for (final c in f.corners) c * cellMeters];
  return [
    for (final c in cs) h3.V3(c.dx, c.dy, z0),
    for (final c in cs) h3.V3(c.dx, c.dy, z1),
  ];
}

/// Oberkante (Meter) von [f]: Höhe der Ebene, auf der es beim Ziehen unter
/// dem Finger bleibt.
double furnitureTop(FloorFurniture f) {
  final spec = h3.furnitureSpec(f.kind);
  return spec.elevation + spec.height;
}

/// Strahlparameter, an dem [ray] in den Quader von [f] eintritt (Meter,
/// waagerecht um [slop] erweitert), `null` ohne Treffer.
double? rayIntoFurniture(
  h3.SceneRay ray,
  FloorFurniture f,
  double cellMeters, {
  double slop = 0.03,
}) {
  final spec = h3.furnitureSpec(f.kind);
  final c = f.center * cellMeters;
  final r = f.rotation * math.pi / 180;
  final co = math.cos(r), si = math.sin(r);
  // Strahl ins eigene System des Möbelstücks (wie `FloorFurniture.toLocal`).
  (double, double) local(double x, double y) =>
      (x * co + y * si, -x * si + y * co);
  final (ox, oy) = local(ray.origin.x - c.dx, ray.origin.y - c.dy);
  final (dx, dy) = local(ray.dir.x, ray.dir.y);
  final hw = f.w * cellMeters / 2 + slop, hd = f.h * cellMeters / 2 + slop;
  final z0 = spec.elevation, z1 = spec.elevation + math.max(spec.height, 0.02);
  var lo = double.negativeInfinity, hi = double.infinity;
  for (final (o, d, a, b) in [
    (ox, dx, -hw, hw),
    (oy, dy, -hd, hd),
    (ray.origin.z, ray.dir.z, z0, z1),
  ]) {
    if (d.abs() < 1e-12) {
      if (o < a || o > b) return null;
      continue;
    }
    var t1 = (a - o) / d, t2 = (b - o) / d;
    if (t1 > t2) (t1, t2) = (t2, t1);
    lo = math.max(lo, t1);
    hi = math.min(hi, t2);
    if (lo > hi) return null;
  }
  if (ray.perspective && hi <= 0) return null;
  return ray.perspective ? math.max(lo, 0) : lo;
}

/// Vorderstes Möbelstück unter [screen] in der 3D-Ansicht (Quader mit
/// Höhe aus dem Katalog), `null` ohne Treffer. Teppiche nur, wenn sonst
/// nichts getroffen ist.
FloorFurniture? furnitureAt3d(
  Iterable<FloorFurniture> items,
  h3.OrbitCamera cam,
  Size size,
  Offset screen,
  double cellMeters,
) {
  final ray = h3.rayAt(cam, screen, size);
  FloorFurniture? best, rug;
  var bestT = double.infinity, rugT = double.infinity;
  for (final f in items) {
    final t = rayIntoFurniture(ray, f, cellMeters);
    if (t == null) continue;
    if (f.kind == 'rug') {
      if (t < rugT) (rug, rugT) = (f, t);
    } else if (t < bestT) {
      (best, bestT) = (f, t);
    }
  }
  return best ?? rug;
}

/// Szenenobjekt zu [f] (Meter), z. B. als Vorschau beim Ziehen.
h3.SceneObject furnitureObject(
  FloorFurniture f,
  double cellMeters, {
  String? roomId,
}) => h3.SceneObject.furniture(
  id: f.id,
  kind: f.kind,
  center: f.center * cellMeters,
  w: f.w * cellMeters,
  d: f.h * cellMeters,
  rotation: f.rotation,
  roomId: roomId,
);

/// Radius (Meter) des Drehrings um [f]: etwas weiter als die halbe
/// Diagonale.
double rotationRingRadius(FloorFurniture f, double cellMeters) =>
    math.sqrt(f.w * f.w + f.h * f.h) / 2 * cellMeters + 0.3;

/// Griff des Drehrings (Meter, auf dem Boden): vor der Vorderseite
/// (lokal `+y`), damit er bei Möbeln an der Wand im Raum liegt.
Offset rotationKnob(FloorFurniture f, double cellMeters) {
  final r = f.rotation * math.pi / 180;
  final front = Offset(-math.sin(r), math.cos(r));
  return f.center * cellMeters + front * rotationRingRadius(f, cellMeters);
}

/// Drehung beim Ziehen am Ring: [base] dreht um den Winkel, den der Zeiger
/// von [from] nach [to] (Zellen) um die Mitte überstreicht.
FloorFurniture rotateAround(
  FloorFurniture base,
  Offset from,
  Offset to, {
  bool snap = true,
}) {
  final a = from - base.center, b = to - base.center;
  if (a.distanceSquared < 1e-9 || b.distanceSquared < 1e-9) return base;
  final turn =
      (math.atan2(b.dy, b.dx) - math.atan2(a.dy, a.dx)) * 180 / math.pi;
  return base.copyWith(
    rotation: _clean(snapRotation(base.rotation + turn, free: !snap)),
  );
}

/// Kann ein Gerät der Bauform [spec] an die Wand?
bool wallMountable(h3.DeviceSpec spec) =>
    spec.wall || spec.mounts.contains(h3.DeviceMount.wall);

/// Zelle für ein Gerät an der Wand [hit] (Meter): direkt vor der Wand in
/// ihrem Raum. `null`, wenn dort keine Zelle des Raums liegt.
GridPoint? cellBeforeWall(h3.WallHit hit, HavenFloorPlan plan) {
  final m = plan.grid.cellMeters;
  for (final by in [0.12, m * 0.5, m]) {
    final p = hit.inFront(by) / m;
    final cell = GridPoint(p.dx.floor(), p.dy.floor());
    if (!plan.grid.containsCell(cell.x, cell.y)) continue;
    if (plan.locationOfCell(cell.x, cell.y) == hit.roomId) return cell;
  }
  return null;
}

/// Verschiebung (Meter), mit der die 3D-Szene [f] ganz in seinen Raum rückt
/// (Innenkante der Wände, siehe `Scene.fittedToRooms`), damit Umriss und
/// Griffe über der Szene genau auf dem Möbelstück liegen. [roomGap] wie in
/// `SceneStyle.roomGap`.
Offset sceneFitShift(
  FloorFurniture f,
  HavenFloorPlan plan, {
  double roomGap = 0.16,
}) {
  final spec = h3.furnitureSpec(f.kind);
  if (spec.wallMounted) return Offset.zero;
  final room = roomOf(plan.rooms, f.center);
  if (room == null) return Offset.zero;
  final m = plan.grid.cellMeters;
  final shape = h3.roundedInset(
    [for (final o in room.offsets) o * m],
    inset: h3.wallInset(roomGap),
    open: room.open,
  );
  if (shape.length < 3) return Offset.zero;
  return h3.fitInside([for (final c in f.corners) c * m], shape);
}
