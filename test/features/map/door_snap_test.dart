import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/features/map/furniture_ops.dart';

void main() {
  // Zwei Räume mit gemeinsamer Wand bei x = 8.
  final a = FloorRoom.rect(id: 'a', name: 'A', x: 0, y: 0, w: 8, h: 6);
  final b = FloorRoom.rect(id: 'b', name: 'B', x: 8, y: 0, w: 6, h: 6);
  const door = FloorFurniture(
    id: 't',
    kind: 'door',
    x: 7.2,
    y: 3,
    w: 1.8,
    h: 1.8,
    rotation: 20,
  );

  Offset wallMid(FloorFurniture f) {
    final r = math.min(f.w, f.h);
    return f.toWorld(Offset(-f.w / 2 + r / 2, f.h / 2));
  }

  test('Tür nahe der gemeinsamen Wand rastet auf der Wand ein', () {
    final s = snapDoorToWall(door, [a, b]);
    // Wandlinie liegt auf x = 8, die Tür bleibt auf der Seite von A.
    expect(wallMid(s).dx, closeTo(8, 1e-9));
    expect(s.center.dx, lessThan(8));
    // Wandlinie (lokal y = h/2) parallel zur Kante: beide Enden auf x = 8.
    final r = math.min(s.w, s.h);
    expect(s.toWorld(Offset(-s.w / 2, s.h / 2)).dx, closeTo(8, 1e-9));
    expect(s.toWorld(Offset(-s.w / 2 + r, s.h / 2)).dx, closeTo(8, 1e-9));
  });

  test('Auf die andere Seite gezogen öffnet sie in den Nachbarraum', () {
    final s = snapDoorToWall(door.moveTo(const Offset(8.9, 3)), [a, b]);
    expect(wallMid(s).dx, closeTo(8, 1e-9));
    expect(s.center.dx, greaterThan(8));
  });

  test('Weit weg von Wänden und andere Möbel bleiben, wie sie sind', () {
    final far = door.moveTo(const Offset(4, 3));
    expect(snapDoorToWall(far, [a, b]), far);
    const sofa = FloorFurniture(
      id: 's',
      kind: 'sofa',
      x: 7.5,
      y: 3,
      w: 2,
      h: 1,
    );
    expect(snapDoorToWall(sofa, [a, b]), sofa);
  });
}
