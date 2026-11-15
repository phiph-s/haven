import 'package:flutter/foundation.dart';

import '../../core/light/color_math.dart';
import '../../core/light/room_palette.dart';
import 'entity_state.dart';

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
  });

  /// Aus einer HA-Entity. Ist die Lampe aus, fehlen die Attribute. Dann gilt
  /// ein warmes Weiß als Anzeigewert.
  factory Lamp.fromEntity(EntityState e) {
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

  LampLight? get asLight => on ? LampLight(color, brightness) : null;

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
      other.available == available;

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
  );
}
