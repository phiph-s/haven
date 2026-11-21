import 'package:flutter/foundation.dart';

import '../../core/light/color_math.dart';
import '../../core/light/room_palette.dart';
import 'entity_state.dart';
import 'lamp_calibration.dart';

/// Eine Lampe in der Sicht der App (abgeleitet aus einer `light.*`-Entity).
@immutable
class Lamp {
  const Lamp({
    required this.entityId,
    required this.name,
    required this.on,
    required this.brightness,
    required this.color,
    this.kelvin,
    this.supportsColor = false,
    this.supportsKelvin = false,
    this.supportsBrightness = true,
    this.minKelvin = 2000,
    this.maxKelvin = 6535,
    this.available = true,
    this.colorMode,
    this.calibration = LampCalibration.none,
  });

  /// Aus einer HA-Entity. Ist die Lampe aus, fehlen die Attribute. Dann gilt
  /// ein warmes Weiß als Anzeigewert.
  ///
  /// [calibration] ändert nur die Anzeige ([displayColor], [displayLevel]),
  /// nicht die gemeldeten Werte, mit denen die Regler arbeiten.
  factory Lamp.fromEntity(
    EntityState e, {
    LampCalibration calibration = LampCalibration.none,
  }) {
    final a = e.attributes;
    final modes = ((a['supported_color_modes'] as List?) ?? const [])
        .map((m) => m.toString())
        .toSet();
    final colorModes = {'hs', 'xy', 'rgb', 'rgbw', 'rgbww'};
    final supportsColor = modes.intersection(colorModes).isNotEmpty;
    final supportsKelvin = modes.contains('color_temp') || supportsColor;
    final supportsBri = modes.isEmpty || !modes.every((m) => m == 'onoff');
    final on = e.isOn;
    final b255 = (a['brightness'] as num?)?.toDouble();
    final bri = !on
        ? 0
        : b255 == null
        ? 100
        : (b255 / 255 * 100).round().clamp(1, 100);
    final kelvin = (a['color_temp_kelvin'] as num?)?.round();
    final rgbList = a['rgb_color'] as List?;
    final Rgb color;
    if (rgbList != null && rgbList.length >= 3) {
      color = (
        (rgbList[0] as num).round(),
        (rgbList[1] as num).round(),
        (rgbList[2] as num).round(),
      );
    } else {
      color = kelvinToRgb(kelvin ?? 2700);
    }
    return Lamp(
      entityId: e.entityId,
      name: e.name,
      on: on,
      brightness: bri,
      color: color,
      kelvin: kelvin,
      supportsColor: supportsColor,
      supportsKelvin: supportsKelvin,
      supportsBrightness: supportsBri,
      minKelvin: (a['min_color_temp_kelvin'] as num?)?.round() ?? 2000,
      maxKelvin: (a['max_color_temp_kelvin'] as num?)?.round() ?? 6535,
      available: e.state != 'unavailable',
      colorMode: a['color_mode'] as String?,
      calibration: calibration,
    );
  }

  final String entityId;
  final String name;
  final bool on;

  /// 0..100, 0 wenn aus.
  final int brightness;
  final Rgb color;
  final int? kelvin;
  final bool supportsColor;
  final bool supportsKelvin;
  final bool supportsBrightness;
  final int minKelvin;
  final int maxKelvin;
  final bool available;

  /// `color_mode` aus HA (`color_temp`, `xy`, `hs` …), falls gemeldet.
  final String? colorMode;

  /// Korrektur des Lampentyps (siehe Einstellungen › Lampen kalibrieren).
  final LampCalibration calibration;

  static const _colorModes = {'hs', 'xy', 'rgb', 'rgbw', 'rgbww'};

  /// Leuchtet die Lampe gerade weiß (Farbtemperatur oder feste Lichtfarbe)?
  /// Nur dann greift die Weißkorrektur, Farben bleiben, wie sie sind.
  bool get isWhite => kelvin != null
      ? !_colorModes.contains(colorMode)
      : !supportsColor && !supportsKelvin;

  /// Farbe, wie die Lampe wirklich aussieht (mit Kalibrierung). Ohne
  /// Korrektur des Weißtons gleich [color].
  Rgb get displayColor {
    if (!calibration.correctsWhite || !isWhite) return color;
    return kelvinToRgb(calibration.mapKelvin(kelvin ?? assumedWhiteKelvin));
  }

  /// Helligkeit, wie sie wirkt: 0..[maxShownLevel], 0 wenn aus.
  double get displayLevel => on ? calibration.mapLevel(brightness / 100) : 0;

  LampLight? get asLight => on
      ? LampLight(
          displayColor,
          calibration.correctsBrightness
              ? (displayLevel * 100).round().clamp(1, 100)
              : brightness,
        )
      : null;

  @override
  bool operator ==(Object other) =>
      other is Lamp &&
      other.entityId == entityId &&
      other.name == name &&
      other.on == on &&
      other.brightness == brightness &&
      other.color == color &&
      other.kelvin == kelvin &&
      other.supportsColor == supportsColor &&
      other.supportsKelvin == supportsKelvin &&
      other.available == available &&
      other.colorMode == colorMode &&
      other.calibration == calibration;

  @override
  int get hashCode => Object.hash(
    entityId,
    name,
    on,
    brightness,
    color,
    kelvin,
    supportsColor,
    available,
    colorMode,
    calibration,
  );
}
