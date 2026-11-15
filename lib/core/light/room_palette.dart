import 'dart:ui';

import 'color_math.dart';

/// Eingang des Farbmotors: eine eingeschaltete Lampe.
class LampLight {
  const LampLight(this.color, this.brightness);

  /// Lampenfarbe (roh, vor der UI-Klemmung).
  final Rgb color;

  /// Helligkeit 0..100.
  final int brightness;
}

Color colorOf(Rgb c) => Color.fromARGB(255, c.$1, c.$2, c.$3);

Rgb rgbOf(Color c) => (
  (c.r * 255).round().clamp(0, 255),
  (c.g * 255).round().clamp(0, 255),
  (c.b * 255).round().clamp(0, 255),
);

/// Ergebnis des Farbmotors für einen Raum oder das ganze Haus.
///
/// Alle Farben sind bereits UI-Farben (geklemmt für Hell oder Dunkel).
/// [intensity] ist die Basis-Deckkraft der Glow-Ebene (0 bei Licht aus), die
/// Oberfläche multipliziert sie mit dem Modusfaktor aus den Tokens.
class RoomPalette {
  const RoomPalette({
    required this.isOn,
    required this.primary,
    required this.secondary,
    required this.mix,
    required this.onAccent,
    required this.intensity,
    required this.brightness,
  });

  /// Licht aus: Farben bleiben neutral, nichts leuchtet.
  static const RoomPalette off = RoomPalette(
    isOn: false,
    primary: Color(0xFFB9AAFF),
    secondary: Color(0xFF8F7BFF),
    mix: Color(0xFFB9AAFF),
    onAccent: Color(0xFF17121F),
    intensity: 0,
    brightness: 0,
  );

  final bool isOn;
  final Color primary;
  final Color secondary;
  final Color mix;

  /// Schrift auf [accent]-Flächen.
  final Color onAccent;

  /// 0 wenn aus, sonst `.3 + .7 * hellsteLampe`.
  final double intensity;

  /// Helligkeit der hellsten Lampe, 0..1.
  final double brightness;

  Color get accent => primary;
  Color get accent2 => secondary;

  /// Drei Farben für den Mesh-Verlauf: oben links, rechts, unten.
  List<Color> get mesh => [primary, secondary, mix];

  /// Zarter Farbton für Flächen (Kachel-Hintergrund).
  Color get tileTint => mix.withValues(alpha: 0.10);

  /// Weicher Übergang. Aus und an blenden nur die Deckkraft, die Farben
  /// bleiben dabei auf der Seite, die leuchtet.
  static RoomPalette lerp(RoomPalette a, RoomPalette b, double t) {
    if (t <= 0) return a;
    if (t >= 1) return b;
    final src = a.isOn ? a : b;
    final dst = b.isOn ? b : a;
    return RoomPalette(
      isOn: t < 0.5 ? a.isOn : b.isOn,
      primary: Color.lerp(src.primary, dst.primary, t)!,
      secondary: Color.lerp(src.secondary, dst.secondary, t)!,
      mix: Color.lerp(src.mix, dst.mix, t)!,
      onAccent: Color.lerp(src.onAccent, dst.onAccent, t)!,
      intensity: a.intensity + (b.intensity - a.intensity) * t,
      brightness: a.brightness + (b.brightness - a.brightness) * t,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RoomPalette &&
      other.isOn == isOn &&
      other.primary == primary &&
      other.secondary == secondary &&
      other.mix == mix &&
      other.onAccent == onAccent &&
      other.intensity == intensity &&
      other.brightness == brightness;

  @override
  int get hashCode => Object.hash(
    isOn,
    primary,
    secondary,
    mix,
    onAccent,
    intensity,
    brightness,
  );
}

/// Mischt die Lampen eines Raums (oder des Hauses) zur [RoomPalette].
///
/// Spec 2.3: primär = hellste Lampe, sekundär = erste Lampe mit mehr als
/// 40 Grad Farbtonabstand, sonst die zweite, sonst primär. Der Mix ist der
/// gewichtete quadratische Mittelwert der UI-Farben mit Gewicht
/// `Helligkeit + 10`.
RoomPalette computePalette(Iterable<LampLight> lamps, {required bool dark}) {
  final on = lamps.where((l) => l.brightness > 0).toList();
  if (on.isEmpty) return RoomPalette.off;
  // sort ist nicht stabil garantiert, deshalb Index als Tiebreaker.
  final indexed = [for (var i = 0; i < on.length; i++) (i, on[i])]
    ..sort((a, b) {
      final c = b.$2.brightness.compareTo(a.$2.brightness);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
  final sorted = [for (final e in indexed) e.$2];

  final p = sorted.first;
  LampLight s = p;
  final far = sorted.skip(1).where((l) => hueDistance(p.color, l.color) > 40);
  if (far.isNotEmpty) {
    s = far.first;
  } else if (sorted.length > 1) {
    s = sorted[1];
  }

  final primary = uiColor(p.color, dark: dark);
  final secondary = uiColor(s.color, dark: dark);
  final mix = weightedQuadraticMean([
    for (final l in sorted) (uiColor(l.color, dark: dark), l.brightness + 10.0),
  ]);
  return RoomPalette(
    isOn: true,
    primary: colorOf(primary),
    secondary: colorOf(secondary),
    mix: colorOf(mix),
    onAccent: colorOf(onColorFor(primary)),
    intensity: 0.3 + 0.7 * (p.brightness.clamp(0, 100) / 100),
    brightness: p.brightness.clamp(0, 100) / 100,
  );
}
