import 'dart:math' as math;

import '../../core/light/color_math.dart';
import '../../data/models/lamp.dart';
import '../../data/models/lamp_calibration.dart';
import '../../data/models/light_groups.dart';
import '../../data/models/snapshot.dart';

/// Ein Lampentyp mit allen Lampen dieses Modells (für „Lampen kalibrieren“).
class LampType {
  const LampType(this.model, this.lamps);

  final LampModel model;

  /// Nach Name sortiert, mindestens eine.
  final List<Lamp> lamps;

  String get key => model.key;

  /// Mindestens eine Lampe kann Weißtöne (Farbtemperatur oder Farbe).
  bool get hasKelvin => lamps.any((l) => l.supportsKelvin);

  int get minKelvin => hasKelvin
      ? lamps
            .where((l) => l.supportsKelvin)
            .map((l) => l.minKelvin)
            .reduce(math.min)
      : assumedWhiteKelvin;

  int get maxKelvin => hasKelvin
      ? lamps
            .where((l) => l.supportsKelvin)
            .map((l) => l.maxKelvin)
            .reduce(math.max)
      : assumedWhiteKelvin;

  /// Stützpunkte, die bei diesem Typ vorkommen. Lampen mit fester
  /// Lichtfarbe haben nur einen ([assumedWhiteKelvin]).
  List<int> get anchors {
    if (!hasKelvin) return const [assumedWhiteKelvin];
    final a = [
      for (final k in calibrationAnchors)
        if (k >= minKelvin - 150 && k <= maxKelvin + 150) k,
    ];
    return a.isEmpty ? const [assumedWhiteKelvin] : a;
  }

  /// Weißtöne der Vorschau, warm nach kalt.
  List<int> get previewKelvins {
    if (!hasKelvin) return const [assumedWhiteKelvin];
    final out = [
      for (final k in const [2200, 2700, 3500, 4500, 6500])
        if (k >= minKelvin - 150 && k <= maxKelvin + 150) k,
    ];
    return out.isEmpty ? [minKelvin] : out;
  }
}

/// Alle Lampentypen der Installation, die häufigsten zuerst. Lichtgruppen
/// und Lampen ohne bekanntes Modell fehlen.
List<LampType> lampTypesOf(HavenSnapshot s) {
  final byKey = <String, (LampModel, List<Lamp>)>{};
  for (final e in s.lampModels.entries) {
    final entity = s.entity(e.key);
    if (entity == null || isLightGroup(entity) || !e.value.isKnown) continue;
    final lamp = s.lamp(e.key)!;
    byKey.putIfAbsent(e.value.key, () => (e.value, <Lamp>[])).$2.add(lamp);
  }
  final out = [
    for (final v in byKey.values)
      LampType(v.$1, v.$2..sort((a, b) => a.name.compareTo(b.name))),
  ];
  out.sort((a, b) {
    final c = b.lamps.length.compareTo(a.lamps.length);
    return c != 0 ? c : a.model.label.compareTo(b.model.label);
  });
  return out;
}

/// Farbe eines Vorschaufelds: [rgb] mit der Helligkeit [level] (0..1,5) auf
/// Schwarz, linear gerechnet wie das Licht in der Karte. 100 % liegt bei drei
/// Vierteln, damit „heller als 100 %“ sichtbar bleibt.
Rgb swatchAt(Rgb rgb, double level) {
  double lin(int c) {
    final x = c / 255;
    return x <= 0.04045
        ? x / 12.92
        : math.pow((x + 0.055) / 1.055, 2.4).toDouble();
  }

  int srgb(double v) {
    final x = v.clamp(0.0, 1.0);
    final s = x <= 0.0031308 ? x * 12.92 : 1.055 * math.pow(x, 1 / 2.4) - 0.055;
    return (s * 255).round().clamp(0, 255);
  }

  final k = level.clamp(0.0, maxShownLevel) * 0.75;
  return (srgb(lin(rgb.$1) * k), srgb(lin(rgb.$2) * k), srgb(lin(rgb.$3) * k));
}

/// „10 % wirkt wie 6 %“: angezeigte Helligkeit in Prozent.
int shownPercent(LampCalibration c, int percent) =>
    (c.mapLevel(percent / 100) * 100).round();
