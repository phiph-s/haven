import '../core/light/color_math.dart';

/// Erfundene Szenenfarben aus dem Entwurf (design/entwurf-2.html). Echt sind
/// nur die Namen. Haven schreibt später echte Szenendefinitionen. Bis dahin
/// gilt: bekannter Name, sonst eine stabile Farbe aus dem Namen.
class SceneStyle {
  const SceneStyle(this.hex, this.brightness, [this.kelvin]);
  final List<String> hex;
  final int brightness;
  final int? kelvin;

  List<Rgb> get colors => [for (final h in hex) rgbFromHex(h)];
}

const Map<String, SceneStyle> sceneStyles = {
  'golden hour': SceneStyle(['#FFB347', '#FF7A3D', '#FFD08A'], 85),
  'neon tokyo': SceneStyle(['#FF2E93', '#00D5FF', '#7B2FFF'], 90),
  'nordlicht': SceneStyle(['#2BFFA3', '#1EB8FF', '#8A5BFF'], 75),
  'lagerfeuer': SceneStyle(['#FF5A1F', '#FF8A2A', '#C93A12'], 60),
  'kinoabend': SceneStyle(['#2A2F8F', '#6A3FD0', '#14183F'], 20),
  'halloween': SceneStyle(['#FF6A00', '#7A2CFF', '#1A1022'], 70),
  'fokus': SceneStyle(['#DDEBFF', '#FFFFFF', '#BFD9FF'], 100, 5600),
  'dinner': SceneStyle(['#FFC48A', '#E8836B', '#8F3B4A'], 45),
  'full': SceneStyle(['#FFF1D6', '#FFE2B8', '#FFFFFF'], 100, 3800),
  'calm': SceneStyle(['#7A5CFF', '#C58BFF', '#4B3AA8'], 35),
  'chill': SceneStyle(['#FF8A5C', '#FF5C9A', '#B8407A'], 45),
  'lichtleiste': SceneStyle(['#7A5CFF', '#FF4FA3', '#3AA8FF'], 80),
  'normal': SceneStyle(['#FFE9C8', '#FFF4E2', '#FFD9A0'], 70, 3500),
  'hell': SceneStyle(['#EAF2FF', '#FFFFFF', '#CFE2FF'], 100, 5000),
  'nachts/bewegung': SceneStyle(['#FF9A4A', '#FF7A2A', '#C4501A'], 10),
};

SceneStyle sceneStyleFor(String name) {
  final known = sceneStyles[name.toLowerCase()];
  if (known != null) return known;
  var h = 0;
  for (final c in name.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  final hue = (h % 360).toDouble();
  return SceneStyle([
    _hex(hslToRgb((hue, 0.8, 0.62))),
    _hex(hslToRgb(((hue + 40) % 360, 0.75, 0.58))),
    _hex(hslToRgb(((hue + 320) % 360, 0.65, 0.45))),
  ], 70);
}

String _hex(Rgb c) =>
    '#${c.$1.toRadixString(16).padLeft(2, '0')}${c.$2.toRadixString(16).padLeft(2, '0')}${c.$3.toRadixString(16).padLeft(2, '0')}';

/// HA-Slug wie `slugify`: Umlaute und ß werden umgeschrieben.
String slugify(String s) {
  const map = {
    'ä': 'a',
    'ö': 'o',
    'ü': 'u',
    'ß': 'ss',
    'Ä': 'a',
    'Ö': 'o',
    'Ü': 'u',
  };
  final b = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    b.write(map[ch] ?? ch.toLowerCase());
  }
  return b
      .toString()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
}
