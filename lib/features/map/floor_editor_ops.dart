import 'dart:math' as math;

import '../../data/models/floor_plan.dart';

/// Seiten eines Raums als Bitmaske für das Größenziehen.
abstract final class FloorSide {
  static const left = 1;
  static const right = 2;
  static const top = 4;
  static const bottom = 8;
}

/// Rechteck aus zwei Rasterecken (beliebige Reihenfolge).
({int x, int y, int w, int h}) cellRect(int x1, int y1, int x2, int y2) => (
  x: math.min(x1, x2),
  y: math.min(y1, y2),
  w: (x1 - x2).abs(),
  h: (y1 - y2).abs(),
);

/// Verschiebt [r] um ganze Zellen und hält es im Raster.
FloorRoom moveRoom(FloorRoom r, int dx, int dy, FloorGrid g) => r.copyWith(
  x: (r.x + dx).clamp(0, g.cols - r.w),
  y: (r.y + dy).clamp(0, g.rows - r.h),
);

/// Zieht die Seiten aus [mask] von [r] zur Rasterzelle ([cx], [cy]). Die
/// Mindestgröße bleibt erhalten, das Ergebnis liegt im Raster.
FloorRoom resizeRoom(FloorRoom r, int mask, int cx, int cy, FloorGrid g) {
  var x1 = r.x;
  var y1 = r.y;
  var x2 = r.x + r.w;
  var y2 = r.y + r.h;
  if (mask & FloorSide.left != 0) {
    x1 = math.max(0, math.min(cx, x2 - kMinRoomCells));
  }
  if (mask & FloorSide.right != 0) {
    x2 = math.min(g.cols, math.max(cx, x1 + kMinRoomCells));
  }
  if (mask & FloorSide.top != 0) {
    y1 = math.max(0, math.min(cy, y2 - kMinRoomCells));
  }
  if (mask & FloorSide.bottom != 0) {
    y2 = math.min(g.rows, math.max(cy, y1 + kMinRoomCells));
  }
  return r.copyWith(x: x1, y: y1, w: x2 - x1, h: y2 - y1);
}
