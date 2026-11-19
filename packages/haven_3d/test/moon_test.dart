import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/src/sky_view.dart' show moonLitPath;

void main() {
  const c = Offset(50, 50);
  const r = 40.0;

  test('Zunehmende Sichel: nur rechts am Rand hell', () {
    final p = moonLitPath(c, r, 0.15, waxing: true);
    expect(p.contains(c + const Offset(36, 0)), isTrue);
    expect(p.contains(c), isFalse);
    expect(p.contains(c - const Offset(30, 0)), isFalse);
  });

  test('Halbmond: rechte Hälfte, Dreiviertel: auch die Mitte', () {
    final half = moonLitPath(c, r, 0.5, waxing: true);
    expect(half.contains(c + const Offset(20, 0)), isTrue);
    expect(half.contains(c - const Offset(20, 0)), isFalse);
    final gibbous = moonLitPath(c, r, 0.85, waxing: true);
    expect(gibbous.contains(c), isTrue);
    expect(gibbous.contains(c - const Offset(36, 0)), isFalse);
  });

  test('Abnehmend: gespiegelt, links hell', () {
    final p = moonLitPath(c, r, 0.15, waxing: false);
    expect(p.contains(c - const Offset(36, 0)), isTrue);
    expect(p.contains(c + const Offset(36, 0)), isFalse);
  });

  test('Vollmond: ganze Scheibe', () {
    final p = moonLitPath(c, r, 1, waxing: true);
    for (final d in const [Offset(30, 0), Offset(-30, 0), Offset(0, 30)]) {
      expect(p.contains(c + d), isTrue, reason: '$d');
    }
  });
}
