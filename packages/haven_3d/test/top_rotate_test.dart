import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';

// Zwei Finger drehen in der Draufsicht um ihren Mittelpunkt: dieselbe
// Verschiebung wie in Scene3DView._onScaleUpdate.
void main() {
  test('Draufsicht: Punkt unter den Fingern bleibt beim Drehen', () {
    const size = Size(400, 800);
    final s = OrbitCamera(
      yaw: 0.3,
      pitch: 0,
    ).copyWith(scale: 50, pan: const Offset(20, -30));
    const focal = Offset(250, 300);
    final world = s.unprojectOnPlane(focal, size)!;
    const rot = 0.4;
    final mid = size.center(Offset.zero);
    var rel = focal - mid - s.pan;
    final c = math.cos(rot), si = math.sin(rot);
    rel = Offset(rel.dx * c - rel.dy * si, rel.dx * si + rel.dy * c);
    final n = s.copyWith(yaw: s.yaw + rot, pan: focal - mid - rel);
    final p = n.project(world, size);
    expect((p.offset - focal).distance, lessThan(0.5));
  });
}
