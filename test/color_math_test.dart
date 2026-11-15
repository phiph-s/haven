import 'package:flutter_test/flutter_test.dart';
import 'package:haven/core/light/color_math.dart';

void main() {
  group('kelvinToRgb', () {
    test('warmes Licht ist orange', () {
      final (r, g, b) = kelvinToRgb(2700);
      expect(r, 255);
      expect(g, inInclusiveRange(155, 180));
      expect(b, inInclusiveRange(70, 100));
    });

    test('Tageslicht ist fast weiß', () {
      final (r, g, b) = kelvinToRgb(6500);
      expect(r, greaterThan(250));
      expect(g, greaterThan(245));
      expect(b, greaterThan(245));
    });

    test('kaltes Licht ist bläulich', () {
      final (r, _, b) = kelvinToRgb(10000);
      expect(b, 255);
      expect(r, lessThan(210));
    });

    test('klemmt außerhalb von 1000 bis 40000', () {
      expect(kelvinToRgb(100), kelvinToRgb(1000));
      expect(kelvinToRgb(90000), kelvinToRgb(40000));
    });

    test('Umkehrung liegt nah an der Eingabe', () {
      for (final k in [2200, 2700, 4000, 5600]) {
        expect(rgbToKelvinApprox(kelvinToRgb(k)), closeTo(k, 120));
      }
    });
  });

  group('HSL und HSV', () {
    test('Rundreise RGB nach HSL und zurück', () {
      for (final c in <Rgb>[
        (255, 0, 0),
        (12, 200, 99),
        (40, 40, 40),
        (255, 168, 90),
      ]) {
        final back = hslToRgb(rgbToHsl(c));
        expect((back.$1 - c.$1).abs(), lessThanOrEqualTo(1));
        expect((back.$2 - c.$2).abs(), lessThanOrEqualTo(1));
        expect((back.$3 - c.$3).abs(), lessThanOrEqualTo(1));
      }
    });

    test('Grundfarben haben den richtigen Farbton', () {
      expect(rgbToHsl((255, 0, 0)).$1, 0);
      expect(rgbToHsl((0, 255, 0)).$1, 120);
      expect(rgbToHsl((0, 0, 255)).$1, 240);
    });

    test('HSV für das Farbrad', () {
      expect(hsvToRgb(0, 1, 1), (255, 0, 0));
      expect(hsvToRgb(120, 1, 1), (0, 255, 0));
      expect(hsvToRgb(0, 0, 1), (255, 255, 255));
      final (h, s, v) = rgbToHsv((0, 0, 255));
      expect((h, s, v), (240.0, 1.0, 1.0));
    });
  });

  group('uiColor', () {
    test('Dunkel: Helligkeit im Fenster .52 bis .70', () {
      for (final c in <Rgb>[
        (0, 0, 40),
        (255, 255, 255),
        (255, 0, 0),
        (20, 20, 20),
      ]) {
        final l = rgbToHsl(uiColor(c, dark: true)).$3;
        expect(l, inInclusiveRange(0.515, 0.705));
      }
    });

    test('Hell: Helligkeit im Fenster .50 bis .62', () {
      for (final c in <Rgb>[
        (0, 0, 40),
        (255, 255, 255),
        (255, 255, 0),
        (20, 20, 20),
      ]) {
        final l = rgbToHsl(uiColor(c, dark: false)).$3;
        expect(l, inInclusiveRange(0.495, 0.625));
      }
    });

    test('Hell und Dunkel unterscheiden sich bei hellem Licht', () {
      const white = (255, 244, 230);
      expect(uiColor(white, dark: true), isNot(uiColor(white, dark: false)));
    });

    test('kräftige Farben behalten Sättigung, weiche bleiben getönt', () {
      final vivid = rgbToHsl(uiColor((255, 30, 30), dark: true)).$2;
      expect(vivid, greaterThanOrEqualTo(0.45));
      final soft = rgbToHsl(uiColor((200, 190, 185), dark: true)).$2;
      expect(soft, lessThan(0.45));
    });

    test('Schrift auf der UI-Farbe hat mindestens 4,5:1 Kontrast', () {
      for (final dark in [true, false]) {
        for (var h = 0; h < 360; h += 5) {
          for (final s in [0.3, 0.6, 1.0]) {
            for (final l in [0.1, 0.5, 0.9]) {
              final ui = uiColor(hslToRgb((h.toDouble(), s, l)), dark: dark);
              final on = onColorFor(ui);
              expect(
                contrastRatio(ui, on),
                greaterThanOrEqualTo(4.5),
                reason: 'h=$h s=$s l=$l dark=$dark',
              );
            }
          }
        }
      }
    });
  });

  group('onColorFor', () {
    test(
      'Weiß auf dunklem Blau',
      () => expect(onColorFor((42, 47, 143)), whiteRgb),
    );
    test('Tinte auf Gelb', () => expect(onColorFor((255, 210, 63)), inkRgb));
    test('Tinte auf Weiß', () => expect(onColorFor((255, 255, 255)), inkRgb));
  });

  group('Mischung', () {
    test('gleiche Farben ergeben dieselbe Farbe', () {
      expect(
        weightedQuadraticMean([((100, 150, 200), 1), ((100, 150, 200), 5)]),
        (100, 150, 200),
      );
    });

    test('Gewicht zieht zur hellen Lampe', () {
      final m = weightedQuadraticMean([((255, 0, 0), 90), ((0, 0, 255), 10)]);
      expect(m.$1, greaterThan(m.$3));
    });

    test('quadratisch: Rot und Blau gleich gewichtet bleiben kräftig', () {
      final m = weightedQuadraticMean([((255, 0, 0), 1), ((0, 0, 255), 1)]);
      expect(m.$1, closeTo(180, 1));
    });
  });

  test('rgbFromHex', () => expect(rgbFromHex('#FF8A1F'), (255, 138, 31)));
}
