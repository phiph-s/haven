import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/core/light/color_math.dart';
import 'package:haven/core/light/room_palette.dart';

void main() {
  const warm = LampLight((255, 168, 90), 80);
  const blue = LampLight((40, 80, 255), 50);
  const pink = LampLight((255, 46, 147), 30);

  test('ohne Lampen ist die Palette aus', () {
    final p = computePalette(const [], dark: true);
    expect(p.isOn, isFalse);
    expect(p.intensity, 0);
    expect(p, RoomPalette.off);
  });

  test('Lampe mit Helligkeit 0 zählt als aus', () {
    expect(
      computePalette(const [LampLight((255, 0, 0), 0)], dark: true).isOn,
      isFalse,
    );
  });

  test('einzelne Lampe: alle drei Farben gleich', () {
    final p = computePalette(const [warm], dark: true);
    expect(p.isOn, isTrue);
    expect(p.primary, p.secondary);
    expect(p.primary, p.mix);
    expect(p.primary, colorOf(uiColor(warm.color, dark: true)));
  });

  test('Intensität folgt der hellsten Lampe: .3 + .7 * Helligkeit', () {
    expect(
      computePalette(const [warm], dark: true).intensity,
      closeTo(0.3 + 0.7 * 0.8, 1e-9),
    );
    expect(
      computePalette(const [warm, blue], dark: true).intensity,
      closeTo(0.86, 1e-9),
    );
    expect(
      computePalette(const [LampLight((255, 0, 0), 100)], dark: true).intensity,
      closeTo(1.0, 1e-9),
    );
  });

  test('primär ist die hellste Lampe', () {
    final p = computePalette(const [blue, warm, pink], dark: true);
    expect(p.primary, colorOf(uiColor(warm.color, dark: true)));
  });

  test('sekundär: erste Lampe mit mehr als 40 Grad Abstand', () {
    // warm (Hue ~28) -> blau (Hue ~230) ist weit weg, pink (~330) auch, blau kommt zuerst nach Helligkeit.
    final p = computePalette(const [warm, pink, blue], dark: true);
    expect(p.secondary, colorOf(uiColor(blue.color, dark: true)));
  });

  test('sekundär: ohne weit entfernte Farbe die zweite Lampe', () {
    const a = LampLight((255, 168, 90), 80);
    const b = LampLight((255, 180, 100), 60);
    final p = computePalette(const [a, b], dark: true);
    expect(p.secondary, colorOf(uiColor(b.color, dark: true)));
  });

  test(
    'Mix liegt zwischen den UI-Farben und ist von der hellen Lampe geprägt',
    () {
      final p = computePalette(const [warm, blue], dark: true);
      final a = rgbOf(p.primary);
      final b = rgbOf(p.secondary);
      final m = rgbOf(p.mix);
      expect(
        m.$1,
        inInclusiveRange(b.$1 < a.$1 ? b.$1 : a.$1, b.$1 < a.$1 ? a.$1 : b.$1),
      );
      // Die warme Lampe ist heller: Rot im Mix liegt näher an ihr.
      expect((m.$1 - a.$1).abs(), lessThan((m.$1 - b.$1).abs()));
    },
  );

  test('Schrift auf Akzent hat genug Kontrast, hell und dunkel', () {
    for (final dark in [true, false]) {
      for (final c in <Rgb>[
        (255, 210, 63),
        (42, 47, 143),
        (255, 255, 255),
        (30, 200, 140),
      ]) {
        final p = computePalette([LampLight(c, 70)], dark: dark);
        expect(
          contrastRatio(rgbOf(p.accent), rgbOf(p.onAccent)),
          greaterThanOrEqualTo(4.5),
        );
      }
    }
  });

  test('hell und dunkel liefern getrennte Farben', () {
    final d = computePalette(const [
      LampLight((255, 250, 240), 100),
    ], dark: true);
    final l = computePalette(const [
      LampLight((255, 250, 240), 100),
    ], dark: false);
    expect(d.primary, isNot(l.primary));
  });

  group('lerp', () {
    final a = computePalette(const [warm], dark: true);
    final b = computePalette(const [blue], dark: true);

    test('Endpunkte', () {
      expect(RoomPalette.lerp(a, b, 0), a);
      expect(RoomPalette.lerp(a, b, 1), b);
    });

    test('Mitte liegt zwischen den Farben', () {
      final m = RoomPalette.lerp(a, b, 0.5);
      expect(m.primary, Color.lerp(a.primary, b.primary, 0.5));
      expect(m.intensity, closeTo((a.intensity + b.intensity) / 2, 1e-9));
    });

    test('Aus nach An: Farben springen nicht, nur die Deckkraft wächst', () {
      final m = RoomPalette.lerp(RoomPalette.off, a, 0.5);
      expect(m.primary, a.primary);
      expect(m.intensity, closeTo(a.intensity / 2, 1e-9));
    });

    test('An nach Aus: Farbe bleibt, Deckkraft sinkt', () {
      final m = RoomPalette.lerp(a, RoomPalette.off, 0.5);
      expect(m.primary, a.primary);
      expect(m.intensity, closeTo(a.intensity / 2, 1e-9));
    });
  });
}
