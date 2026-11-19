import 'package:flutter/foundation.dart';

/// Woher Haven das Wetter für die Karte nimmt (für alle Geräte gleich, in HA
/// über `haven/prefs` unter `weather`).
///
/// Standard ist die erste Wetter-Entity von Home Assistant (meist
/// „Forecast Home“ von Met.no, eine offene API). Temperatur und Schneehöhe
/// lassen sich auf eigene Sensoren legen, z. B. ein Außenthermometer.
@immutable
class WeatherConfig {
  const WeatherConfig({this.entity, this.temperature, this.snowDepth});

  factory WeatherConfig.fromJson(Object? j) {
    if (j is! Map) return const WeatherConfig();
    String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
    return WeatherConfig(
      entity: s(j['entity']),
      temperature: s(j['temperature']),
      snowDepth: s(j['snow_depth']),
    );
  }

  /// `weather.*`; `null`: die erste Wetter-Entity.
  final String? entity;

  /// Sensor für die Außentemperatur; `null`: Temperatur der Wetter-Entity.
  final String? temperature;

  /// Sensor für die Schneehöhe (cm, m oder mm); `null`: keine.
  final String? snowDepth;

  bool get isEmpty =>
      entity == null && temperature == null && snowDepth == null;

  Map<String, dynamic> toJson() => {
    'entity': ?entity,
    'temperature': ?temperature,
    'snow_depth': ?snowDepth,
  };

  WeatherConfig copyWith({
    String? entity,
    bool clearEntity = false,
    String? temperature,
    bool clearTemperature = false,
    String? snowDepth,
    bool clearSnowDepth = false,
  }) => WeatherConfig(
    entity: clearEntity ? null : (entity ?? this.entity),
    temperature: clearTemperature ? null : (temperature ?? this.temperature),
    snowDepth: clearSnowDepth ? null : (snowDepth ?? this.snowDepth),
  );

  @override
  bool operator ==(Object other) =>
      other is WeatherConfig &&
      other.entity == entity &&
      other.temperature == temperature &&
      other.snowDepth == snowDepth;

  @override
  int get hashCode => Object.hash(entity, temperature, snowDepth);
}
