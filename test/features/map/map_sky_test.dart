import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/models/entity_state.dart';
import 'package:haven/data/models/snapshot.dart';
import 'package:haven/data/models/weather.dart';
import 'package:haven/features/map/map_sky.dart';

LiveSkyInputs _in({
  String? condition,
  double? temperature,
  double? cloud,
  double? snowCm,
}) => (
  sunAzimuth: 180.0,
  sunElevation: 30.0,
  latitude: 50.0,
  condition: condition,
  cloudCoverage: cloud,
  temperature: temperature,
  snowCm: snowCm,
);

void main() {
  test('WeatherConfig: JSON hin und zurück, leere Werte fallen weg', () {
    const c = WeatherConfig(
      entity: 'weather.home',
      temperature: 'sensor.aussen',
    );
    expect(c.toJson(), {
      'entity': 'weather.home',
      'temperature': 'sensor.aussen',
    });
    expect(WeatherConfig.fromJson(c.toJson()), c);
    expect(
      WeatherConfig.fromJson({'entity': '', 'snow_depth': 3}).isEmpty,
      isTrue,
    );
    expect(WeatherConfig.fromJson(null), const WeatherConfig());
    final cleared = c.copyWith(clearTemperature: true, snowDepth: 'sensor.s');
    expect(cleared.temperature, isNull);
    expect(cleared.entity, 'weather.home');
    expect(cleared.snowDepth, 'sensor.s');
  });

  test('HA-Wetterlagen werden zu Wolken, Regen, Schnee und Gewitter', () {
    expect(weatherOf('sunny', night: false).cloud, lessThan(0.2));
    expect(weatherOf('cloudy', night: false).cloud, greaterThan(0.7));
    expect(
      weatherOf('pouring', night: false).rain,
      greaterThan(weatherOf('rainy', night: false).rain),
    );
    expect(weatherOf('snowy', night: false).snow, greaterThan(0.3));
    expect(weatherOf('lightning-rainy', night: false).storm, greaterThan(0.5));
    expect(weatherOf('lightning-rainy', night: false).rain, greaterThan(0));
    // Unbekannt oder nicht verfügbar: ruhiger Himmel.
    final none = weatherOf(null, night: true);
    expect(none.rain + none.snow + none.storm, 0);
  });

  test('Live: Sonne aus sun.sun, Bedeckung aus cloud_coverage', () {
    final w = liveWeather(
      _in(condition: 'partlycloudy', cloud: 80),
      now: DateTime(2026, 6, 21, 14),
    );
    expect(w.live, isTrue);
    expect(w.sky.sunAzimuth, 180);
    expect(w.sky.sunElevation, 30);
    expect(w.sky.cloud, closeTo(0.8, 1e-9));
    expect(w.label, isNotEmpty);
  });

  test('Live: bei Frost wird aus Regen Schnee (Außenthermometer)', () {
    final warm = liveWeather(_in(condition: 'rainy', temperature: 6));
    expect(warm.sky.rain, greaterThan(0));
    expect(warm.sky.snow, 0);
    final cold = liveWeather(_in(condition: 'rainy', temperature: -1));
    expect(cold.sky.rain, 0);
    expect(cold.sky.snow, greaterThan(0));
    expect(cold.temperature, -1);
  });

  test('Live-Eingaben: Sensoren aus der Konfiguration, Schnee in cm', () {
    final s = HavenSnapshot(
      entities: {
        'sun.sun': const EntityState('sun.sun', 'above_horizon', {
          'azimuth': 120.0,
          'elevation': 12.0,
        }),
        'weather.b': const EntityState('weather.b', 'snowy', {
          'temperature': 3.0,
        }),
        'weather.a': const EntityState('weather.a', 'sunny', {
          'temperature': 9.0,
          'cloud_coverage': 10,
        }),
        'sensor.aussen': const EntityState('sensor.aussen', '-2.5', {
          'device_class': 'temperature',
        }),
        'sensor.schnee': const EntityState('sensor.schnee', '0.12', {
          'unit_of_measurement': 'm',
        }),
      },
    );
    // Ohne Einstellung: erste Wetter-Entity, Temperatur von dort.
    final a = liveSkyInputsOf(s);
    expect(a.condition, 'sunny');
    expect(a.temperature, 9);
    expect(a.cloudCoverage, 10);
    expect(a.sunAzimuth, 120);
    expect(a.snowCm, isNull);
    // Eingestellt: andere Wetter-Entity, Außenthermometer, Schneehöhe in m.
    final b = liveSkyInputsOf(
      s.copyWith(
        weather: const WeatherConfig(
          entity: 'weather.b',
          temperature: 'sensor.aussen',
          snowDepth: 'sensor.schnee',
        ),
      ),
    );
    expect(b.condition, 'snowy');
    expect(b.temperature, -2.5);
    expect(b.snowCm, closeTo(12, 1e-9));
  });

  test('Eigene Werte: Uhrzeit und Wetter wie eingestellt', () {
    final w = manualWeather(
      const ManualSky(hour: 23, day: 172, cloud: 0, rain: 0.8, snowCm: 10),
    );
    expect(w.live, isFalse);
    expect(w.sky.sunElevation, lessThan(0));
    expect(w.sky.rain, closeTo(0.8, 1e-9));
    expect(w.snowCm, 10);
    final j = ManualSky.fromJson(const ManualSky(hour: 7, storm: 0.4).toJson());
    expect(j.hour, 7);
    expect(j.storm, 0.4);
  });
}
