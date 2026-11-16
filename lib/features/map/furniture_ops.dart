import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../../data/models/floor_plan.dart';

/// Raster für Möbel: halbe Zellen (etwa 25 cm).
const double kFurnitureSnap = 0.5;

/// Drehung rastet in diesen Schritten (Grad), mit Shift frei.
const double kFurnitureRotationStep = 15;

double snapTo(double v, double step) => (v / step).roundToDouble() * step;

double _clean(double v) => (v * 1e6).roundToDouble() / 1e6;

Offset _cleanOffset(Offset o) => Offset(_clean(o.dx), _clean(o.dy));

/// Hält die Mitte im Raster.
Offset clampToGrid(Offset c, FloorGrid g) => Offset(
  c.dx.clamp(0.0, g.cols.toDouble()),
  c.dy.clamp(0.0, g.rows.toDouble()),
);

/// Rastet so ein, dass die linke obere Ecke des umschließenden Rechtecks auf
/// einer halben Zelle liegt. Bei geraden Winkeln liegen damit alle Kanten
/// auf dem Halbraster.
FloorFurniture snapFurniture(FloorFurniture f) {
  final b = f.bounds;
  final dx = snapTo(b.left, kFurnitureSnap) - b.left;
  final dy = snapTo(b.top, kFurnitureSnap) - b.top;
  return f.moveTo(_cleanOffset(f.center + Offset(dx, dy)));
}

/// Neues Möbelstück mit Mitte bei [at] (Zellen), eingerastet und im Raster.
FloorFurniture placeFurniture(
  FurnitureType type,
  Offset at,
  FloorGrid grid, {
  required String id,
  bool snap = true,
}) {
  final f = FloorFurniture.of(type, id: id, center: clampToGrid(at, grid));
  return snap ? snapFurniture(f) : f;
}

/// Verschiebt [base] (Stand bei Gestenbeginn) um [delta] Zellen.
FloorFurniture moveFurniture(
  FloorFurniture base,
  Offset delta,
  FloorGrid grid, {
  bool snap = true,
}) {
  var f = base.moveTo(clampToGrid(base.center + delta, grid));
  if (snap) f = snapFurniture(f);
  return f.moveTo(_cleanOffset(clampToGrid(f.center, grid)));
}

/// Griff zum Skalieren: [sx], [sy] in {-1, 0, 1} im eigenen
/// Koordinatensystem (−1 links bzw. oben). Beide 0: der Dreh-Griff.
class FurnitureHandle {
  const FurnitureHandle(this.sx, this.sy);
  const FurnitureHandle.rotate() : sx = 0, sy = 0;
  final int sx;
  final int sy;

  bool get isRotate => sx == 0 && sy == 0;
  bool get isCorner => sx != 0 && sy != 0;

  static const resize = [
    FurnitureHandle(-1, -1),
    FurnitureHandle(1, -1),
    FurnitureHandle(1, 1),
    FurnitureHandle(-1, 1),
    FurnitureHandle(0, -1),
    FurnitureHandle(1, 0),
    FurnitureHandle(0, 1),
    FurnitureHandle(-1, 0),
  ];

  @override
  bool operator ==(Object other) =>
      other is FurnitureHandle && other.sx == sx && other.sy == sy;

  @override
  int get hashCode => Object.hash(sx, sy);

  @override
  String toString() => isRotate ? 'Handle(rotate)' : 'Handle($sx, $sy)';
}

/// Skaliert [base] am Griff [h] zum Zeiger [pointer] (Zellen). Die
/// gegenüberliegende Kante bzw. Ecke bleibt stehen. Mit [snap] rasten Breite
/// und Tiefe auf halbe Zellen.
FloorFurniture resizeFurniture(
  FloorFurniture base,
  FurnitureHandle h,
  Offset pointer, {
  bool snap = true,
  double minSide = kFurnitureMinSide,
}) {
  if (h.isRotate) return base;
  final local = base.toLocal(pointer);
  final ax = -h.sx * base.w / 2;
  final ay = -h.sy * base.h / 2;
  var w = base.w, ht = base.h;
  var cx = 0.0, cy = 0.0;
  final minS = snap ? math.max(minSide, kFurnitureSnap) : minSide;
  if (h.sx != 0) {
    w = h.sx * (local.dx - ax);
    if (snap) w = snapTo(w, kFurnitureSnap);
    w = math.max(minS, w);
    cx = ax + h.sx * w / 2;
  }
  if (h.sy != 0) {
    ht = h.sy * (local.dy - ay);
    if (snap) ht = snapTo(ht, kFurnitureSnap);
    ht = math.max(minS, ht);
    cy = ay + h.sy * ht / 2;
  }
  final c = base.toWorld(Offset(cx, cy));
  return base.copyWith(
    x: _clean(c.dx),
    y: _clean(c.dy),
    w: _clean(w),
    h: _clean(ht),
  );
}

/// Dreht [base] so, dass der Dreh-Griff (über der Oberkante) zum Zeiger
/// zeigt. Mit [snap] in Schritten von [kFurnitureRotationStep].
FloorFurniture rotateFurnitureTo(
  FloorFurniture base,
  Offset pointer, {
  bool snap = true,
}) {
  final d = pointer - base.center;
  if (d.distanceSquared < 1e-9) return base;
  var deg = math.atan2(d.dy, d.dx) * 180 / math.pi + 90;
  if (snap) deg = snapTo(deg, kFurnitureRotationStep);
  return base.copyWith(rotation: _clean(normalizeDegrees(deg)));
}

/// Dreht um [degrees] (z. B. 90 für den Knopf „Drehen“).
FloorFurniture rotateFurnitureBy(FloorFurniture f, double degrees) =>
    f.copyWith(rotation: _clean(normalizeDegrees(f.rotation + degrees)));

/// Kopie mit neuer ID, eine Zelle nach rechts unten versetzt.
FloorFurniture duplicateFurniture(
  FloorFurniture f,
  FloorGrid grid, {
  required String id,
}) =>
    f.copyWith(id: id).moveTo(clampToGrid(f.center + const Offset(1, 1), grid));

/// Lage der Griffe in Pixeln. [toPx] rechnet Zellen in Pixel um. Der
/// Dreh-Griff sitzt [rotateGap] px über der Mitte der Oberkante. Kanten-Griffe
/// fallen bei kleinen Möbeln weg (unter [minEdgePx] Kantenlänge).
List<(FurnitureHandle, Offset)> furnitureHandlePoints(
  FloorFurniture f,
  Offset Function(Offset cell) toPx, {
  double rotateGap = 26,
  double minEdgePx = 44,
}) {
  Offset at(double lx, double ly) => toPx(f.toWorld(Offset(lx, ly)));
  final out = <(FurnitureHandle, Offset)>[];
  final wPx = (at(f.w / 2, 0) - at(-f.w / 2, 0)).distance;
  final hPx = (at(0, f.h / 2) - at(0, -f.h / 2)).distance;
  for (final h in FurnitureHandle.resize) {
    if (!h.isCorner) {
      final edge = h.sx != 0 ? hPx : wPx;
      if (edge < minEdgePx) continue;
    }
    out.add((h, at(h.sx * f.w / 2, h.sy * f.h / 2)));
  }
  final top = at(0, -f.h / 2);
  final c = toPx(f.center);
  var dir = top - c;
  if (dir.distance < 1e-6) dir = const Offset(0, -1);
  out.add((
    const FurnitureHandle.rotate(),
    top + dir / dir.distance * rotateGap,
  ));
  return out;
}

/// Griff unter [p] (Pixel) innerhalb von [radius], der nächste gewinnt.
FurnitureHandle? furnitureHandleAt(
  List<(FurnitureHandle, Offset)> points,
  Offset p, {
  double radius = 16,
}) {
  FurnitureHandle? best;
  var bestD = radius * radius;
  for (final (h, at) in points) {
    final d = (at - p).distanceSquared;
    if (d <= bestD) {
      bestD = d;
      best = h;
    }
  }
  return best;
}

/// Richtung eines Skalier-Griffs auf dem Bildschirm, für die Mausform.
enum ResizeAxis { horizontal, vertical, diagonalDown, diagonalUp }

/// Achse des Griffs [h] bei der Drehung [rotation] (Grad).
ResizeAxis resizeAxisOf(FurnitureHandle h, double rotation) {
  final base = math.atan2(h.sy.toDouble(), h.sx.toDouble()) * 180 / math.pi;
  final a = normalizeDegrees(base + rotation) % 180;
  // 0 waagerecht, 45 von links oben nach rechts unten, 90 senkrecht,
  // 135 von rechts oben nach links unten (y wächst nach unten).
  if (a < 22.5 || a >= 157.5) return ResizeAxis.horizontal;
  if (a < 67.5) return ResizeAxis.diagonalDown;
  if (a < 112.5) return ResizeAxis.vertical;
  return ResizeAxis.diagonalUp;
}

/// Maße für die Anzeige, z. B. `1,8 × 2,1 m`.
String furnitureSizeText(FloorFurniture f, double cellMeters) {
  String m(double v) {
    final x = (v * cellMeters * 100).round() / 100;
    final s = x == x.roundToDouble()
        ? x.toStringAsFixed(0)
        : (x * 10 == (x * 10).roundToDouble()
              ? x.toStringAsFixed(1)
              : x.toStringAsFixed(2));
    return s.replaceAll('.', ',');
  }

  return '${m(f.w)} × ${m(f.h)} m';
}
