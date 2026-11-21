import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';

void main() {
  const size = Size(400, 300);

  test('Draufsicht entspricht dem 2D-Plan', () {
    const cam = OrbitCamera(target: V3(2, 3, 0), scale: 50);
    final p = cam.project(const V3(4, 5, 1.7), size);
    expect(p.x, closeTo(200 + 2 * 50, 1e-9));
    expect(p.y, closeTo(150 + 2 * 50, 1e-9));
    // Höhe ändert die Lage nicht, nur die Tiefe.
    expect(cam.project(const V3(4, 5, 0), size).offset, p.offset);
    expect(p.depth, closeTo(1.7, 1e-9));
  });

  test('Seitenansicht: oben ist oben, Süden ist vorn', () {
    const cam = OrbitCamera(pitch: math.pi / 2, scale: 10);
    final low = cam.project(V3.zero, size), high = cam.project(V3.up, size);
    expect(high.y, lessThan(low.y));
    final south = cam.project(const V3(0, 1, 0), size);
    expect(south.depth, greaterThan(low.depth));
  });

  test('unprojectOnPlane kehrt project um', () {
    const cam = OrbitCamera(
      target: V3(1, 2, 1),
      yaw: 0.7,
      pitch: 0.9,
      scale: 37,
      pan: Offset(12, -5),
    );
    const p = V3(3.2, -1.5, 0);
    final s = cam.project(p, size);
    final back = cam.unprojectOnPlane(s.offset, size)!;
    expect(back.x, closeTo(p.x, 1e-9));
    expect(back.y, closeTo(p.y, 1e-9));
  });

  test('fit zeigt alle Punkte innerhalb des Rands', () {
    final pts = sampleScene().points().toList();
    for (final v in [SceneViews.top, SceneViews.iso, SceneViews.side]) {
      final cam = OrbitCamera(
        yaw: v.yaw,
        pitch: v.pitch,
      ).fit(pts, size, padding: 20);
      for (final p in pts) {
        final s = cam.project(p, size);
        expect(s.x, inInclusiveRange(19.999, 380.001));
        expect(s.y, inInclusiveRange(19.999, 280.001));
      }
    }
  });

  test('Perspektive: Maßstab am Ziel gleich, Rückprojektion stimmt', () {
    const ortho = OrbitCamera(
      target: V3(1, 2, 0),
      yaw: 0.4,
      pitch: 0.8,
      scale: 50,
      pan: Offset(20, -10),
    );
    final persp = ortho.copyWith(fov: OrbitCamera.perspectiveFov);
    // Ein Punkt in der Bildebene durch das Ziel liegt in beiden gleich.
    final b = ortho.basis;
    final onPlane = ortho.panTarget + b.right * 0.7 + b.down * -0.4;
    final a = ortho.project(onPlane, size), p = persp.project(onPlane, size);
    expect(p.x, closeTo(a.x, 1e-6));
    expect(p.y, closeTo(a.y, 1e-6));
    // Näher an der Kamera erscheint größer.
    final near = onPlane + b.toCam * 1.0;
    expect(
      (persp.project(near, size).offset - const Offset(200, 150)).distance,
      greaterThan(
        (ortho.project(near, size).offset - const Offset(200, 150)).distance,
      ),
    );
    // Rückprojektion auf den Boden.
    const floor = V3(2.5, 3.1, 0);
    final s = persp.project(floor, size);
    final back = persp.unprojectOnPlane(s.offset, size)!;
    expect(back.x, closeTo(floor.x, 1e-6));
    expect(back.y, closeTo(floor.y, 1e-6));
  });

  test('lerp dreht auf dem kürzeren Weg', () {
    const a = OrbitCamera(yaw: 0.1);
    const b = OrbitCamera(yaw: 2 * math.pi - 0.1);
    expect(OrbitCamera.lerp(a, b, 0.5).yaw, closeTo(0, 1e-9));
  });

  test('Wände zeigen nach außen, egal wie herum der Umriss läuft', () {
    for (final outline in [
      const [Offset(0, 0), Offset(4, 0), Offset(4, 3), Offset(0, 3)],
      const [Offset(0, 0), Offset(0, 3), Offset(4, 3), Offset(4, 0)],
    ]) {
      final r = SceneRoom(id: 'r', outline: outline);
      for (final w in r.walls) {
        final c = w.centroid;
        final probe = Offset(c.x + w.normal.x * 0.1, c.y + w.normal.y * 0.1);
        expect(r.contains(probe), isFalse, reason: '$outline');
      }
    }
  });

  test('Quader: Normalen nach außen', () {
    final b = ModelBuilder()..box(-1, -1, 0, 1, 1, 2);
    final m = b.build();
    expect(m.faces, hasLength(6));
    for (final f in m.faces) {
      final c = f.centroid;
      expect(
        c.x * f.normal.x + c.y * f.normal.y + (c.z - 1) * f.normal.z,
        greaterThan(0),
      );
    }
  });

  test('Treffer: Gerät vor Möbel vor Raum', () {
    final scene = sampleScene();
    final cam = const OrbitCamera().fit(scene.points(), size);
    SceneHit? hit(Offset p) => hitTestScene(scene, cam, size, p);
    final m = scene.markers.first;
    expect(
      hit(cam.project(m.position, size).offset),
      SceneHit(HitKind.marker, m.id),
    );
    final bed = scene.objects.firstWhere((o) => o.kind == 'bed_double');
    expect(
      hit(cam.project(bed.position, size).offset),
      SceneHit(HitKind.object, bed.id),
    );
    expect(
      hit(cam.project(const V3(7.5, 10.0, 0), size).offset),
      const SceneHit(HitKind.room, 'arbeiten'),
    );
    expect(hit(const Offset(-50, -50)), isNull);
  });

  test('Katalog: Körper bleiben in ihrer Box (auch bei anderen Maßen)', () {
    final bad = <String>{};
    for (final e in kFurnitureModels.entries) {
      for (final (w, d) in [(1.3, 0.9), (0.6, 0.6), (2.4, 1.8)]) {
        final m = buildFurniture(e.key, w, d);
        final h = e.value.height;
        expect(m.isEmpty, isFalse, reason: e.key);
        // Nur die Körper: Hilfslinien (Aufgehwinkel) dürfen hinausragen,
        // Armaturen (Metall) etwas über die Oberkante.
        for (final f in m.faces) {
          final top = h + (f.mat == Mat.metal ? 0.3 : 0) + 1e-6;
          final p = f.points.firstWhere(
            (p) =>
                p.x.abs() > w / 2 + 1e-6 ||
                p.y.abs() > d / 2 + 1e-6 ||
                p.z < -1e-6 ||
                p.z > top,
            orElse: () => V3.zero,
          );
          if (p != V3.zero) {
            bad.add('${e.key} ${w}x$d: $p');
            break;
          }
        }
      }
    }
    expect(bad, isEmpty);
  });

  test('Tür zu (Sensor): Blatt in der Zarge, kein Aufschlag', () {
    final open = buildFurniture('door', 0.9, 0.9);
    final shut = buildFurniture('door', 0.9, 0.9, open: false);
    // Offen: Aufschlag-Bogen als Linien; zu: keine.
    expect(open.lines, isNotEmpty);
    expect(shut.lines, isEmpty);
    // Zu reicht das Blatt nicht mehr in den Raum (lokal y < 0).
    double minY(Model3 m) => m.faces
        .expand((f) => f.points)
        .map((p) => p.y)
        .reduce((a, b) => a < b ? a : b);
    expect(minY(open), lessThan(-0.3));
    expect(minY(shut), greaterThan(0.3));
    // Fenster zu: ohne Aufgehwinkel.
    expect(
      buildFurniture('window', 1.2, 0.2, open: false).lines.length,
      lessThan(buildFurniture('window', 1.2, 0.2).lines.length),
    );
  });
}
