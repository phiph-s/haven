import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';

void main() {
  test('Quader hat genau seine zwölf Kanten', () {
    final m = (ModelBuilder()..box(0, 0, 0, 1, 1, 1)).build();
    expect(featureEdges(m), hasLength(12));
  });

  test('Zwei bündige Quader: keine Linie auf der gemeinsamen Oberseite', () {
    final m =
        (ModelBuilder()
              ..box(0, 0, 0, 1, 1, 0.5)
              ..box(1, 0, 0, 2, 1, 0.5))
            .build();
    final edges = featureEdges(m);
    // Auf der Oberseite (z = 0.5) darf keine Kante bei x = 1 quer laufen.
    final seam = edges.where(
      (e) =>
          (e.a.z - 0.5).abs() < 1e-6 &&
          (e.b.z - 0.5).abs() < 1e-6 &&
          (e.a.x - 1).abs() < 1e-6 &&
          (e.b.x - 1).abs() < 1e-6,
    );
    expect(seam, isEmpty);
    // Die langen Oberkanten sind je eine durchgehende Linie.
    final long = edges.where((e) => (e.length - 2).abs() < 1e-3);
    expect(long.length, 4);
  });

  test('Überlappende Teile (Pfosten im Sturz): keine Linien im Inneren', () {
    // Pfosten 0..0.1 × 0..0.1 × 0..2, Sturz 0..1 × 0..0.1 × 1.9..2.
    final m =
        (ModelBuilder()
              ..box(0, 0, 0, 0.1, 0.1, 2)
              ..box(0, 0, 1.9, 1, 0.1, 2))
            .build();
    final edges = featureEdges(m);
    bool inCorner(Edge3 e) {
      final mid = V3.lerp(e.a, e.b, 0.5);
      // Innenkante des Pfostens (x = 0.1) oberhalb der Sturz-Unterkante.
      return (mid.x - 0.1).abs() < 1e-6 && mid.z > 1.9 + 1e-6;
    }

    expect(edges.where(inCorner), isEmpty);
  });

  test('Bündige Teile (Pfosten unter dem Sturz): Innenecke bleibt', () {
    final m =
        (ModelBuilder()
              ..box(0, 0, 0, 0.1, 0.1, 1.9)
              ..box(0, 0, 1.9, 1, 0.1, 2))
            .build();
    expect(
      featureEdges(m).any(
        (e) =>
            (e.a.z - 1.9).abs() < 1e-6 &&
            (e.b.z - 1.9).abs() < 1e-6 &&
            (e.a.x - 0.1).abs() < 1e-6 &&
            (e.b.x - 0.1).abs() < 1e-6,
      ),
      isTrue,
    );
  });

  test('Kissen auf der Matratze: Auflagekanten bleiben', () {
    final m =
        (ModelBuilder()
              ..box(0, 0, 0, 2, 2, 0.5)
              ..box(0.5, 0.5, 0.5, 1, 1, 0.6))
            .build();
    final contact = featureEdges(m).where(
      (e) =>
          (e.a.z - 0.5).abs() < 1e-6 &&
          (e.b.z - 0.5).abs() < 1e-6 &&
          e.a.x > 0.4 &&
          e.a.x < 1.1 &&
          e.a.y > 0.4 &&
          e.a.y < 1.1,
    );
    final len = contact.fold(0.0, (s, e) => s + e.length);
    expect(len, closeTo(2.0, 1e-3), reason: 'Umfang 4 × 0,5 m');
  });

  test('Zylinder: keine senkrechten Linien auf der Mantelfläche', () {
    final m = (ModelBuilder()..cylinder(0, 0, 0.5, 0, 1)).build();
    final vertical = featureEdges(m).where((e) => (e.a.z - e.b.z).abs() > 0.5);
    expect(vertical, isEmpty);
  });

  test('L-förmiger Boden wird vollständig trianguliert', () {
    const pts = [
      V3(0, 0, 0),
      V3(2, 0, 0),
      V3(2, 1, 0),
      V3(1, 1, 0),
      V3(1, 2, 0),
      V3(0, 2, 0),
    ];
    final tris = triangulate(pts, V3.up);
    expect(tris, hasLength(4));
    var area = 0.0;
    for (final (a, b, c) in tris) {
      final u = pts[b] - pts[a], v = pts[c] - pts[a];
      final z = u.cross(v).z;
      expect(z, greaterThan(0), reason: 'zeigt zur Normalen');
      area += z / 2;
    }
    expect(area, closeTo(3, 1e-9));
  });
}
