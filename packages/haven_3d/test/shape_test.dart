import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';

double _area(List<Offset> p) {
  var a = 0.0;
  for (var i = 0; i < p.length; i++) {
    final j = (i + 1) % p.length;
    a += p[i].dx * p[j].dy - p[j].dx * p[i].dy;
  }
  return a / 2;
}

void main() {
  const square = [Offset(0, 0), Offset(4, 0), Offset(4, 3), Offset(0, 3)];

  test('Einrücken verkleinert das Rechteck rundum', () {
    final p = roundedInset(square, inset: 0.1);
    expect(p, hasLength(4));
    expect(p.first.dx, closeTo(0.1, 1e-9));
    expect(p.first.dy, closeTo(0.1, 1e-9));
    expect(_area(p).abs(), closeTo(3.8 * 2.8, 1e-9));
  });

  test('Einrücken geht nach innen, egal wie herum der Umriss läuft', () {
    final p = roundedInset(square.reversed.toList(), inset: 0.1);
    expect(_area(p).abs(), closeTo(3.8 * 2.8, 1e-9));
  });

  test('Runde Ecken: Fläche wie Rechteck minus vier Eckzwickel', () {
    const r = 0.5;
    final p = roundedInset(square, radius: r, segments: 64);
    // Je Ecke fehlt r² − πr²/4.
    final expected = 12 - 4 * (r * r - 3.141592653589793 * r * r / 4);
    expect(_area(p).abs(), closeTo(expected, 1e-3));
    for (final q in p) {
      expect(q.dx, inInclusiveRange(-1e-9, 4 + 1e-9));
      expect(q.dy, inInclusiveRange(-1e-9, 3 + 1e-9));
    }
  });

  test('L-Form: auch die einspringende Ecke wird rund', () {
    const l = [
      Offset(0, 0),
      Offset(2, 0),
      Offset(2, 1),
      Offset(1, 1),
      Offset(1, 2),
      Offset(0, 2),
    ];
    final p = roundedInset(l, inset: 0.05, radius: 0.2);
    // Kein Punkt liegt mehr genau auf der einspringenden Ecke (1, 1),
    // sie ist (eingerückt) durch einen Bogen ersetzt.
    expect(
      p.every((q) => (q - const Offset(1.05, 1.05)).distance > 0.01),
      isTrue,
    );
    expect(_area(p).abs(), lessThan(3));
  });

  test('Möbel an der Wand rückt in den eingerückten Raum', () {
    final shape = roundedInset(square, inset: 0.08, radius: 0.25);
    // Bett in der Ecke unten links, bündig mit der Rohbauwand.
    const foot = [Offset(0, 1), Offset(1.8, 1), Offset(1.8, 3), Offset(0, 3)];
    final d = fitInside(foot, shape);
    expect(d.dx, greaterThan(0.08));
    expect(d.dy, lessThan(-0.08));
    for (final p in foot) {
      final q = p + d;
      expect(q.dx, inInclusiveRange(0.08, 3.92));
      expect(q.dy, inInclusiveRange(0.08, 2.92));
    }
  });

  test('Szene: Möbel rücken ein, Türen und Fenster bleiben', () {
    final s = sampleScene();
    final fitted = s.fittedToRooms(inset: 0.08, radius: 0.25);
    final bed = fitted.objects.firstWhere((o) => o.kind == 'bed_double');
    final bed0 = s.objects.firstWhere((o) => o.kind == 'bed_double');
    expect(bed.position, isNot(bed0.position));
    for (final o in fitted.objects.where((o) => o.wallMounted)) {
      final o0 = s.objects.firstWhere((x) => x.id == o.id);
      expect(o.position, o0.position);
    }
  });

  test('Offene Kante bleibt auf dem Umriss, ihre Ecken spitz', () {
    const sq = [Offset(0, 0), Offset(4, 0), Offset(4, 3), Offset(0, 3)];
    final shape = roundedInset(sq, inset: 0.1, radius: 0.3, open: {1});
    // Rechte Kante (1) offen: Punkte mit x = 4 vorhanden, Ecken genau.
    expect(shape, contains(const Offset(4, 0.1)));
    expect(shape, contains(const Offset(4, 2.9)));
    // Links bleibt eingerückt und gerundet (kein Punkt bei x = 0).
    expect(shape.every((p) => p.dx > 0.05), isTrue);
    expect(shape.length, greaterThan(4));
  });
}
