import '../core/light/color_math.dart';
import 'models/lamp.dart';

/// Wie eine Szene aussieht: bis zu drei Farben, mittlere Helligkeit und, wenn
/// alle eingeschalteten Lampen weiß leuchten, die Farbtemperatur. Haven merkt
/// sich das beim Speichern einer Szene (`look` in der Integration), damit die
/// Szenenkarten echte Farben zeigen statt erfundener.
class SceneLook {
  const SceneLook({
    required this.colors,
    required this.brightness,
    this.kelvin,
  });

  /// 1 bis 3 Farben, die hellste Lampe zuerst.
  final List<Rgb> colors;

  /// 0..100, 0 = alles aus.
  final int brightness;
  final int? kelvin;

  bool get allOff => brightness == 0;

  /// Immer drei Farben für den Verlauf der Karte.
  List<Rgb> get cardColors => [
    for (var i = 0; i < 3; i++) colors[i % colors.length],
  ];

  Map<String, dynamic> toJson() => {
    'colors': [for (final c in colors) hexOf(c)],
    'brightness': brightness,
    'kelvin': kelvin,
  };

  /// `null`, wenn [json] kein gültiger Look ist.
  static SceneLook? fromJson(Object? json) {
    if (json is! Map) return null;
    final raw = json['colors'];
    final b = json['brightness'];
    if (raw is! List || raw.isEmpty || b is! num) return null;
    final colors = <Rgb>[];
    for (final c in raw.take(3)) {
      if (c is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(c)) {
        return null;
      }
      colors.add(rgbFromHex(c));
    }
    return SceneLook(
      colors: colors,
      brightness: b.round().clamp(0, 100),
      kelvin: (json['kelvin'] as num?)?.round(),
    );
  }
}

/// Grau für „alles aus“.
const Rgb sceneOffColor = (0x4A, 0x46, 0x52);

/// Look aus dem aktuellen Zustand der [lamps] (alle Lampen der Raumgruppe).
SceneLook sceneLookOf(List<Lamp> lamps) {
  final on = lamps.where((l) => l.on).toList()
    ..sort((a, b) => b.brightness.compareTo(a.brightness));
  if (on.isEmpty) {
    return const SceneLook(colors: [sceneOffColor], brightness: 0);
  }
  final colors = <Rgb>[];
  for (final l in on) {
    if (colors.length == 3) break;
    // Fast gleiche Farben zählen einmal, sonst zeigt die Karte drei Mal Weiß.
    if (colors.any((c) => _close(c, l.color))) continue;
    colors.add(l.color);
  }
  final brightness = (on.fold<int>(0, (s, l) => s + l.brightness) / on.length)
      .round()
      .clamp(1, 100);
  final white = on.every((l) => l.kelvin != null);
  final kelvin = white
      ? ((on.fold<int>(0, (s, l) => s + l.kelvin!) / on.length) / 100).round() *
            100
      : null;
  return SceneLook(colors: colors, brightness: brightness, kelvin: kelvin);
}

bool _close(Rgb a, Rgb b) =>
    (a.$1 - b.$1).abs() + (a.$2 - b.$2).abs() + (a.$3 - b.$3).abs() < 24;

String hexOf(Rgb c) =>
    '#${c.$1.toRadixString(16).padLeft(2, '0')}${c.$2.toRadixString(16).padLeft(2, '0')}${c.$3.toRadixString(16).padLeft(2, '0')}';
