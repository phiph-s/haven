import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven_3d/haven_3d.dart' as h3;
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../data/models/snapshot.dart';

/// Himmel der Karte: live (Sonne, Mond, Wetter aus Home Assistant) oder
/// eigene Werte (Uhrzeit, Jahreszeit, Wetter zum Ausprobieren).
enum MapSkyMode { live, manual }

/// Eigene Werte für den Himmel der Karte (nur dieses Gerät).
@immutable
class ManualSky {
  const ManualSky({
    this.hour = 15,
    this.day = 172,
    this.moon = 0.5,
    this.cloud = 0.2,
    this.rain = 0,
    this.snowfall = 0,
    this.snowCm = 0,
    this.storm = 0,
  });

  factory ManualSky.fromJson(Object? j) {
    if (j is! Map) return const ManualSky();
    double d(String k, double f) => (j[k] as num?)?.toDouble() ?? f;
    const z = ManualSky();
    return ManualSky(
      hour: d('hour', z.hour),
      day: d('day', z.day),
      moon: d('moon', z.moon),
      cloud: d('cloud', z.cloud),
      rain: d('rain', z.rain),
      snowfall: d('snowfall', z.snowfall),
      snowCm: d('snow_cm', z.snowCm),
      storm: d('storm', z.storm),
    );
  }

  final double hour;
  final double day;
  final double moon;
  final double cloud;
  final double rain;
  final double snowfall;
  final double snowCm;
  final double storm;

  Map<String, dynamic> toJson() => {
    'hour': hour,
    'day': day,
    'moon': moon,
    'cloud': cloud,
    'rain': rain,
    'snowfall': snowfall,
    'snow_cm': snowCm,
    'storm': storm,
  };

  ManualSky copyWith({
    double? hour,
    double? day,
    double? moon,
    double? cloud,
    double? rain,
    double? snowfall,
    double? snowCm,
    double? storm,
  }) => ManualSky(
    hour: hour ?? this.hour,
    day: day ?? this.day,
    moon: moon ?? this.moon,
    cloud: cloud ?? this.cloud,
    rain: rain ?? this.rain,
    snowfall: snowfall ?? this.snowfall,
    snowCm: snowCm ?? this.snowCm,
    storm: storm ?? this.storm,
  );

  @override
  bool operator ==(Object other) =>
      other is ManualSky &&
      other.hour == hour &&
      other.day == day &&
      other.moon == moon &&
      other.cloud == cloud &&
      other.rain == rain &&
      other.snowfall == snowfall &&
      other.snowCm == snowCm &&
      other.storm == storm;

  @override
  int get hashCode =>
      Object.hash(hour, day, moon, cloud, rain, snowfall, snowCm, storm);
}

@immutable
class MapSkySettings {
  const MapSkySettings({
    this.mode = MapSkyMode.live,
    this.manual = const ManualSky(),
  });
  final MapSkyMode mode;
  final ManualSky manual;

  @override
  bool operator ==(Object other) =>
      other is MapSkySettings && other.mode == mode && other.manual == manual;

  @override
  int get hashCode => Object.hash(mode, manual);
}

class MapSkyNotifier extends Notifier<MapSkySettings> {
  @override
  MapSkySettings build() {
    final j = ref.read(settingsStoreProvider).mapSky;
    return MapSkySettings(
      mode: j['mode'] == 'manual' ? MapSkyMode.manual : MapSkyMode.live,
      manual: ManualSky.fromJson(j['manual']),
    );
  }

  void setMode(MapSkyMode m) =>
      _save(MapSkySettings(mode: m, manual: state.manual));

  void setManual(ManualSky m) =>
      _save(MapSkySettings(mode: MapSkyMode.manual, manual: m));

  void _save(MapSkySettings s) {
    state = s;
    unawaited(
      ref.read(settingsStoreProvider).setMapSky({
        'mode': s.mode.name,
        'manual': s.manual.toJson(),
      }),
    );
  }
}

final mapSkySettingsProvider = NotifierProvider<MapSkyNotifier, MapSkySettings>(
  MapSkyNotifier.new,
);

/// Was die Karte gerade an Himmel zeigt, mit Text und Symbol für den Knopf.
@immutable
class MapWeather {
  const MapWeather({
    required this.sky,
    required this.snowCm,
    required this.label,
    required this.icon,
    required this.live,
    this.temperature,
  });
  final h3.SceneSky sky;
  final double snowCm;
  final String label;
  final IconData icon;
  final bool live;
  final double? temperature;

  @override
  bool operator ==(Object other) =>
      other is MapWeather &&
      other.sky == sky &&
      other.snowCm == snowCm &&
      other.label == label &&
      other.live == live &&
      other.temperature == temperature;

  @override
  int get hashCode => Object.hash(sky, snowCm, label, live, temperature);
}

/// Wetterlage aus dem Zustand einer HA-Wetter-Entity: Bewölkung, Regen,
/// Schnee, Gewitter (0 … 1), Text und Symbol.
({
  double cloud,
  double rain,
  double snow,
  double storm,
  String label,
  IconData icon,
})
weatherOf(String? condition, {required bool night}) => switch (condition) {
  'sunny' => (
    cloud: 0.05,
    rain: 0,
    snow: 0,
    storm: 0,
    label: 'Sonnig',
    icon: Icons.wb_sunny_rounded,
  ),
  'clear-night' => (
    cloud: 0.05,
    rain: 0,
    snow: 0,
    storm: 0,
    label: 'Klar',
    icon: Icons.nightlight_round,
  ),
  'partlycloudy' => (
    cloud: 0.45,
    rain: 0,
    snow: 0,
    storm: 0,
    label: 'Teils bewölkt',
    icon: night ? Icons.nights_stay_rounded : Icons.wb_cloudy_outlined,
  ),
  'cloudy' => (
    cloud: 0.85,
    rain: 0,
    snow: 0,
    storm: 0,
    label: 'Bewölkt',
    icon: Icons.cloud_rounded,
  ),
  'fog' => (
    cloud: 0.9,
    rain: 0,
    snow: 0,
    storm: 0,
    label: 'Nebel',
    icon: Icons.foggy,
  ),
  'windy' || 'windy-variant' => (
    cloud: 0.35,
    rain: 0,
    snow: 0,
    storm: 0,
    label: 'Windig',
    icon: Icons.air_rounded,
  ),
  'rainy' => (
    cloud: 0.8,
    rain: 0.5,
    snow: 0,
    storm: 0,
    label: 'Regen',
    icon: Icons.water_drop_rounded,
  ),
  'pouring' => (
    cloud: 0.95,
    rain: 1,
    snow: 0,
    storm: 0,
    label: 'Starkregen',
    icon: Icons.thunderstorm_outlined,
  ),
  'hail' => (
    cloud: 0.9,
    rain: 0.8,
    snow: 0,
    storm: 0.3,
    label: 'Hagel',
    icon: Icons.grain_rounded,
  ),
  'snowy' => (
    cloud: 0.85,
    rain: 0,
    snow: 0.6,
    storm: 0,
    label: 'Schnee',
    icon: Icons.ac_unit_rounded,
  ),
  'snowy-rainy' => (
    cloud: 0.85,
    rain: 0.4,
    snow: 0.4,
    storm: 0,
    label: 'Schneeregen',
    icon: Icons.ac_unit_rounded,
  ),
  'lightning' => (
    cloud: 0.85,
    rain: 0,
    snow: 0,
    storm: 0.6,
    label: 'Gewitter',
    icon: Icons.flash_on_rounded,
  ),
  'lightning-rainy' => (
    cloud: 0.95,
    rain: 0.8,
    snow: 0,
    storm: 1,
    label: 'Gewitter',
    icon: Icons.thunderstorm_rounded,
  ),
  _ => (
    cloud: 0.3,
    rain: 0,
    snow: 0,
    storm: 0,
    label: 'Wetter',
    icon: night ? Icons.nightlight_round : Icons.wb_sunny_outlined,
  ),
};

/// Die Werte, aus denen der Live-Himmel entsteht (mit Wertgleichheit: die
/// Karte baut nur neu, wenn sich davon etwas ändert).
typedef LiveSkyInputs = ({
  double? sunAzimuth,
  double? sunElevation,
  double? latitude,
  String? condition,
  double? cloudCoverage,
  double? temperature,
  double? snowCm,
});

/// Live-Werte aus dem Snapshot: Sonne aus `sun.sun`, Breite aus
/// `zone.home`, Wetter aus der eingestellten (sonst ersten) Wetter-Entity,
/// Temperatur und Schneehöhe aus den eingestellten Sensoren.
LiveSkyInputs liveSkyInputsOf(HavenSnapshot s) {
  double? n(Object? v) => v is num ? v.toDouble() : double.tryParse('$v');
  final sun = s.entity('sun.sun')?.attributes;
  final cfg = s.weather;
  final weatherId =
      cfg.entity ??
      (s.entities.keys.where((k) => k.startsWith('weather.')).toList()..sort())
          .firstOrNull;
  final w = weatherId == null ? null : s.entity(weatherId);
  final tempSensor = cfg.temperature == null
      ? null
      : s.entity(cfg.temperature!);
  final snow = cfg.snowDepth == null ? null : s.entity(cfg.snowDepth!);
  double? snowCm;
  if (snow != null && snow.isAvailable && snow.number != null) {
    final unit = '${snow.attributes['unit_of_measurement'] ?? 'cm'}';
    snowCm = switch (unit) {
      'm' => snow.number! * 100,
      'mm' => snow.number! / 10,
      _ => snow.number!,
    };
  }
  return (
    sunAzimuth: n(sun?['azimuth']),
    sunElevation: n(sun?['elevation']),
    latitude: n(s.entity('zone.home')?.attributes['latitude']),
    condition: w?.isAvailable == true ? w!.state : null,
    cloudCoverage: n(w?.attributes['cloud_coverage']),
    temperature: tempSensor != null && tempSensor.isAvailable
        ? tempSensor.number
        : n(w?.attributes['temperature']),
    snowCm: snowCm,
  );
}

/// Himmel aus Live-Werten zum Zeitpunkt [now]. Fehlt `sun.sun`, wird die
/// Sonne aus Datum und Uhrzeit gerechnet; der Mond immer (Phase aus dem
/// Datum). Bei Frost wird aus Regen Schnee.
MapWeather liveWeather(LiveSkyInputs i, {double north = 0, DateTime? now}) {
  final t = now ?? DateTime.now();
  final day = (t.difference(DateTime(t.year)).inDays + 1).clamp(1, 366);
  final hour = t.hour + t.minute / 60;
  final lat = i.latitude ?? 50;
  final sun = i.sunAzimuth != null && i.sunElevation != null
      ? (azimuth: i.sunAzimuth!, elevation: i.sunElevation!)
      : h3.sunPosition(dayOfYear: day, hour: hour, latitude: lat);
  final phase = h3.moonPhaseOn(t);
  final moon = h3.moonPosition(
    dayOfYear: day,
    hour: hour,
    phase: phase,
    latitude: lat,
  );
  final night = sun.elevation < -2;
  final w = weatherOf(i.condition, night: night);
  var rain = w.rain, snow = w.snow;
  final temp = i.temperature;
  if (temp != null && temp <= 0.5 && rain > 0) {
    snow = math.max(snow, rain);
    rain = 0;
  }
  final cloud = i.cloudCoverage != null
      ? (i.cloudCoverage! / 100).clamp(0.0, 1.0)
      : w.cloud;
  return MapWeather(
    sky: h3.SceneSky(
      sunAzimuth: sun.azimuth,
      sunElevation: sun.elevation,
      moonAzimuth: moon.azimuth,
      moonElevation: moon.elevation,
      moonIllumination: h3.moonIlluminationOf(phase),
      moonPhase: phase,
      cloud: cloud,
      rain: rain,
      snow: snow,
      storm: w.storm,
      north: north,
    ),
    snowCm: i.snowCm ?? 0,
    label: w.label,
    icon: w.icon,
    live: true,
    temperature: temp,
  );
}

/// Himmel aus eigenen Werten.
MapWeather manualWeather(ManualSky m, {double north = 0}) {
  final sky = h3.SceneSky.at(
    dayOfYear: m.day.round(),
    hour: m.hour,
    moonPhase: m.moon,
    cloud: m.cloud,
    rain: m.rain,
    snow: m.snowfall,
    storm: m.storm,
    north: north,
  );
  final night = sky.sunElevation < -2;
  final IconData icon = m.storm > 0.3
      ? Icons.thunderstorm_rounded
      : m.snowfall > 0.2
      ? Icons.ac_unit_rounded
      : m.rain > 0.2
      ? Icons.water_drop_rounded
      : m.cloud > 0.6
      ? Icons.cloud_rounded
      : night
      ? Icons.nightlight_round
      : Icons.wb_sunny_rounded;
  return MapWeather(
    sky: sky,
    snowCm: m.snowCm,
    label: 'Eigenes Wetter',
    icon: icon,
    live: false,
  );
}

/// Himmel der Karte für einen Plan mit Nordrichtung [north].
final mapWeatherProvider = Provider.family<MapWeather, double>((ref, north) {
  final settings = ref.watch(mapSkySettingsProvider);
  if (settings.mode == MapSkyMode.manual) {
    return manualWeather(settings.manual, north: north);
  }
  final inputs = ref.watch(snapshotProvider.select(liveSkyInputsOf));
  return liveWeather(inputs, north: north);
});

/// Farben des Hintergrunds der Karte unter diesem Himmel: oben der Himmel
/// nach Tageszeit und Wolken, unten weiß (hell) bzw. schwarz (dunkel).
/// Tageslicht des Himmels: 0 Nacht … 1 Tag (Sonne höher als etwa 12°).
double mapSkyDaylight(h3.SceneSky sky) =>
    ((sky.sunElevation + 8) / 20).clamp(0.0, 1.0);

/// Boden unter dem Himmel: dunkel ein tiefes Blauschwarz, hell ein warmes
/// Off-White. Auch die Fläche der Karte ohne Umgebung.
const kMapGroundDark = Color(0xFF12111B);
const kMapGroundLight = Color(0xFFF4EFE8);

/// Nachthimmel oben im Verlauf.
const kMapNightSky = Color(0xFF0A0E1E);

Color mapGround({required bool dark}) =>
    dark ? kMapGroundDark : kMapGroundLight;

/// Farben der Himmelskugel nach Tageszeit und Wetter: hell ein klarer
/// Taghimmel, dunkel derselbe gedämpft; nachts in beiden ein Nachthimmel.
/// Der Boden unter dem Horizont ist die Fläche der Karte.
h3.SkyColors mapSkyColors(h3.SceneSky sky, {required bool dark}) {
  final dayT = mapSkyDaylight(sky);
  Color day(Color clear, Color cloudy) => Color.lerp(clear, cloudy, sky.cover)!;
  if (dark) {
    return h3.SkyColors(
      zenith: Color.lerp(
        const Color(0xFF070A16),
        day(const Color(0xFF1E2C47), const Color(0xFF2A2F38)),
        dayT,
      )!,
      horizon: Color.lerp(
        const Color(0xFF151B30),
        day(const Color(0xFF34435F), const Color(0xFF3A3F48)),
        dayT,
      )!,
      ground: kMapGroundDark,
    );
  }
  return h3.SkyColors(
    zenith: Color.lerp(
      kMapNightSky,
      day(const Color(0xFF7FAEE6), const Color(0xFFAEB8C4)),
      dayT,
    )!,
    horizon: Color.lerp(
      const Color(0xFF1D2540),
      day(const Color(0xFFCFE1F3), const Color(0xFFD7DBE0)),
      dayT,
    )!,
    ground: kMapGroundLight,
  );
}

/// Himmel oben und Boden unten (für die Lesbarkeit des Kopfs).
List<Color> mapSkyGradient(h3.SceneSky sky, {required bool dark}) {
  final c = mapSkyColors(sky, dark: dark);
  return [c.zenith, c.ground];
}
