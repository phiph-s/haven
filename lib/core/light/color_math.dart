import 'dart:math' as math;

/// Reine Farbmathematik ohne Flutter-Abhängigkeit. Alle Funktionen sind
/// deterministisch und in test/color_math_test.dart abgedeckt.

/// Eine sRGB-Farbe, Komponenten 0..255.
typedef Rgb = (int r, int g, int b);

/// Farbton (0..360), Sättigung und Helligkeit (0..1).
typedef Hsl = (double h, double s, double l);

int _clamp255(num v) => v.isNaN ? 0 : v.round().clamp(0, 255);

double clampDouble(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);

/// Kelvin nach RGB (Näherung nach Tanner Helland, gültig 1000..40000 K).
Rgb kelvinToRgb(num kelvin) {
  final k = clampDouble(kelvin.toDouble(), 1000, 40000) / 100;
  final double r;
  final double g;
  final double b;
  if (k <= 66) {
    r = 255;
    g = 99.4708025861 * math.log(k) - 161.1195681661;
  } else {
    r = 329.698727446 * math.pow(k - 60, -0.1332047592);
    g = 288.1221695283 * math.pow(k - 60, -0.0755148492);
  }
  if (k >= 66) {
    b = 255;
  } else if (k <= 19) {
    b = 0;
  } else {
    b = 138.5177312231 * math.log(k - 10) - 305.0447927307;
  }
  return (_clamp255(r), _clamp255(g), _clamp255(b));
}

/// Gegenstück zu [kelvinToRgb]: schätzt Kelvin aus einer weißlichen Farbe
/// (für die Anzeige, wenn nur RGB bekannt ist). Ergebnis 1000..40000.
int rgbToKelvinApprox(Rgb c) {
  var lo = 1000.0;
  var hi = 40000.0;
  final ratio = c.$3 / math.max(1, c.$1);
  for (var i = 0; i < 24; i++) {
    final mid = (lo + hi) / 2;
    final m = kelvinToRgb(mid);
    final r = m.$3 / math.max(1, m.$1);
    if (r < ratio) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return ((lo + hi) / 2).round();
}

Hsl rgbToHsl(Rgb c) {
  final r = c.$1 / 255;
  final g = c.$2 / 255;
  final b = c.$3 / 255;
  final mx = math.max(r, math.max(g, b));
  final mn = math.min(r, math.min(g, b));
  final l = (mx + mn) / 2;
  final d = mx - mn;
  var h = 0.0;
  var s = 0.0;
  if (d > 0) {
    s = d / (1 - (2 * l - 1).abs());
    if (mx == r) {
      h = ((g - b) / d + 6) % 6;
    } else if (mx == g) {
      h = (b - r) / d + 2;
    } else {
      h = (r - g) / d + 4;
    }
    h *= 60;
  }
  return (h, s, l);
}

Rgb hslToRgb(Hsl c) {
  final h = ((c.$1 % 360) + 360) % 360;
  final s = c.$2;
  final l = c.$3;
  final ch = (1 - (2 * l - 1).abs()) * s;
  final x = ch * (1 - ((h / 60) % 2 - 1).abs());
  final m = l - ch / 2;
  final (double r, double g, double b) = h < 60
      ? (ch, x, 0.0)
      : h < 120
      ? (x, ch, 0.0)
      : h < 180
      ? (0.0, ch, x)
      : h < 240
      ? (0.0, x, ch)
      : h < 300
      ? (x, 0.0, ch)
      : (ch, 0.0, x);
  return (
    _clamp255((r + m) * 255),
    _clamp255((g + m) * 255),
    _clamp255((b + m) * 255),
  );
}

/// HSV (Farbrad) nach RGB. [h] in Grad, [s] und [v] 0..1.
Rgb hsvToRgb(double h, double s, double v) {
  final l = v * (1 - s / 2);
  final sl = (l == 0 || l == 1) ? 0.0 : (v - l) / math.min(l, 1 - l);
  return hslToRgb((h, sl, l));
}

/// RGB nach HSV: (Farbton in Grad, Sättigung, Wert).
(double, double, double) rgbToHsv(Rgb c) {
  final r = c.$1 / 255;
  final g = c.$2 / 255;
  final b = c.$3 / 255;
  final mx = math.max(r, math.max(g, b));
  final mn = math.min(r, math.min(g, b));
  final d = mx - mn;
  var h = 0.0;
  if (d > 0) {
    if (mx == r) {
      h = ((g - b) / d + 6) % 6;
    } else if (mx == g) {
      h = (b - r) / d + 2;
    } else {
      h = (r - g) / d + 4;
    }
    h *= 60;
  }
  return (h, mx == 0 ? 0.0 : d / mx, mx);
}

/// UI-Farbe nach Spec 2.2: Lampenfarbe so klemmen, dass sie lesbar bleibt.
/// Hell und dunkel haben unterschiedliche Helligkeitsfenster. Danach folgt
/// die Kontrastsicherung: Die Schrift auf der Farbe (Weiß oder Tinte, siehe
/// [onColorFor]) soll mindestens 4,5:1 erreichen. Die Auswahl der besseren
/// Seite allein schafft im ungünstigsten Fall nur etwa 4,3:1. Deshalb wird
/// die Helligkeit innerhalb des Fensters so wenig wie nötig verschoben.
Rgb uiColor(Rgb c, {required bool dark}) {
  final (h, s0, l0) = rgbToHsl(c);
  final s = s0 < 0.25 ? s0 * 1.8 : clampDouble(s0, 0.45, 0.95);
  final lo = dark ? 0.52 : 0.50;
  final hi = dark ? 0.70 : 0.62;
  final l = clampDouble(l0, lo, hi);
  final base = hslToRgb((h, s, l));
  if (_bestOnContrast(base) >= minTextContrast) return base;
  for (var step = 1; step <= 40; step++) {
    for (final dir in const [1.0, -1.0]) {
      final cand = l + dir * step * 0.005;
      if (cand < lo || cand > hi) continue;
      final rgb = hslToRgb((h, s, cand));
      if (_bestOnContrast(rgb) >= minTextContrast) return rgb;
    }
  }
  return base;
}

/// Mindestkontrast für Schrift auf Farbflächen (WCAG AA, normaler Text).
const double minTextContrast = 4.5;

double _bestOnContrast(Rgb surface) =>
    math.max(contrastRatio(surface, whiteRgb), contrastRatio(surface, inkRgb));

/// Relative Luminanz nach WCAG.
double relativeLuminance(Rgb c) {
  double f(int v) {
    final x = v / 255;
    return x <= 0.03928
        ? x / 12.92
        : math.pow((x + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * f(c.$1) + 0.7152 * f(c.$2) + 0.0722 * f(c.$3);
}

/// Schriftfarbe der Tinte auf hellen Flächen (#17121F).
const Rgb inkRgb = (0x17, 0x12, 0x1F);
const Rgb whiteRgb = (255, 255, 255);

/// WCAG-Kontrast zweier Farben (1..21).
double contrastRatio(Rgb a, Rgb b) {
  final la = relativeLuminance(a);
  final lb = relativeLuminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// Schrift auf Farbfläche (Spec 2.5): Weiß oder Tinte, je nachdem, was mehr
/// Kontrast bringt.
Rgb onColorFor(Rgb surface) =>
    contrastRatio(surface, whiteRgb) >= contrastRatio(surface, inkRgb)
    ? whiteRgb
    : inkRgb;

/// Kleinster Farbtonabstand in Grad (0..180).
double hueDistance(Rgb a, Rgb b) {
  final d = (rgbToHsl(a).$1 - rgbToHsl(b).$1).abs();
  return math.min(d, 360 - d);
}

/// Gewichteter quadratischer Mittelwert (vermeidet Schlammfarben).
Rgb weightedQuadraticMean(List<(Rgb, double)> items) {
  if (items.isEmpty) return whiteRgb;
  var total = 0.0;
  var r = 0.0;
  var g = 0.0;
  var b = 0.0;
  for (final (c, w) in items) {
    total += w;
    r += c.$1 * c.$1 * w;
    g += c.$2 * c.$2 * w;
    b += c.$3 * c.$3 * w;
  }
  if (total <= 0) return items.first.$1;
  return (
    _clamp255(math.sqrt(r / total)),
    _clamp255(math.sqrt(g / total)),
    _clamp255(math.sqrt(b / total)),
  );
}

/// '#RRGGBB' nach [Rgb].
Rgb rgbFromHex(String hex) {
  final h = hex.replaceFirst('#', '');
  return (
    int.parse(h.substring(0, 2), radix: 16),
    int.parse(h.substring(2, 4), radix: 16),
    int.parse(h.substring(4, 6), radix: 16),
  );
}
