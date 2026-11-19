import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import 'model.dart';

/// Himmel über der Wohnung: Sonne, Mond und Wetter. Daraus entsteht das
/// Licht der Szene (siehe [SkyLight]): tagsüber Sonne, nachts Mond, dazu
/// Umgebungslicht vom Himmel. Mit [north] dreht der Himmel zur Lage der
/// Wohnung.
///
/// Winkel in Grad: Azimut von Norden im Uhrzeigersinn (wie `sun.sun` in Home
/// Assistant), Höhe über dem Horizont.
@immutable
class SceneSky {
  const SceneSky({
    required this.sunAzimuth,
    required this.sunElevation,
    this.moonAzimuth = 0,
    this.moonElevation = -30,
    this.moonIllumination = 0,
    this.moonPhase = 0.5,
    this.cloud = 0,
    this.rain = 0,
    this.snow = 0,
    this.storm = 0,
    this.north = 0,
  });

  /// Himmel aus Datum und Uhrzeit (lokale Sonnenzeit) an der
  /// geographischen Breite [latitude]. [moonPhase] 0 Neumond, 0,5 Vollmond,
  /// 1 wieder Neumond: Der Mond steht entsprechend weit hinter der Sonne.
  factory SceneSky.at({
    required int dayOfYear,
    required double hour,
    double latitude = 49,
    double moonPhase = 0.5,
    double cloud = 0,
    double rain = 0,
    double snow = 0,
    double storm = 0,
    double north = 0,
  }) {
    final sun = sunPosition(
      dayOfYear: dayOfYear,
      hour: hour,
      latitude: latitude,
    );
    final moon = moonPosition(
      dayOfYear: dayOfYear,
      hour: hour,
      latitude: latitude,
      phase: moonPhase,
    );
    return SceneSky(
      sunAzimuth: sun.azimuth,
      sunElevation: sun.elevation,
      moonAzimuth: moon.azimuth,
      moonElevation: moon.elevation,
      moonIllumination: moonIlluminationOf(moonPhase),
      moonPhase: moonPhase,
      cloud: cloud,
      rain: rain,
      snow: snow,
      storm: storm,
      north: north,
    );
  }

  final double sunAzimuth;
  final double sunElevation;
  final double moonAzimuth;
  final double moonElevation;

  /// Beleuchteter Anteil der Mondscheibe (0 Neumond … 1 Vollmond).
  final double moonIllumination;

  /// Mondphase 0 … 1 (unter 0,5 zunehmend, rechte Seite hell).
  final double moonPhase;

  /// Richtung zur Sonne bzw. zum Mond (Weltkoordinaten, Länge 1). Unter dem
  /// Horizont knapp darüber gehalten.
  V3 get sunVector => -_direction(sunAzimuth, sunElevation, north);
  V3 get moonVector => -_direction(moonAzimuth, moonElevation, north);

  /// Bewölkung 0 (klar) … 1 (bedeckt).
  final double cloud;

  /// Regen 0 (keiner) … 1 (stark). Regen bringt auch Wolken mit.
  final double rain;

  /// Schneefall 0 (keiner) … 1 (dicht).
  final double snow;

  /// Gewitter 0 (keins) … 1 (heftig): Blitze, dunkle Wolken, Regen.
  final double storm;

  /// Wirksame Bewölkung: mindestens so viel, wie es regnet, schneit oder
  /// gewittert.
  double get cover => [
    cloud,
    rain * 0.9,
    snow * 0.85,
    storm * 0.95,
  ].reduce(math.max).clamp(0.0, 1.0);

  /// Wirksamer Regen (Gewitter regnet mit).
  double get wetness => math.max(rain, storm * 0.8).clamp(0.0, 1.0);

  /// Wohin Norden auf dem Plan zeigt, Grad im Uhrzeigersinn von oben.
  final double north;

  /// Licht der Szene unter diesem Himmel.
  SkyLight get light => SkyLight.of(this);

  @override
  bool operator ==(Object other) =>
      other is SceneSky &&
      other.sunAzimuth == sunAzimuth &&
      other.sunElevation == sunElevation &&
      other.moonAzimuth == moonAzimuth &&
      other.moonElevation == moonElevation &&
      other.moonIllumination == moonIllumination &&
      other.moonPhase == moonPhase &&
      other.cloud == cloud &&
      other.rain == rain &&
      other.snow == snow &&
      other.storm == storm &&
      other.north == north;

  @override
  int get hashCode => Object.hash(
    sunAzimuth,
    sunElevation,
    moonAzimuth,
    moonElevation,
    moonIllumination,
    moonPhase,
    cloud,
    rain,
    snow,
    storm,
    north,
  );
}

/// Was der Himmel an Licht gibt: eine gerichtete Quelle (Sonne oder Mond)
/// und Umgebungslicht. [intensity] und [ambient] sind relativ zu einem klaren
/// Mittag (1).
@immutable
class SkyLight {
  const SkyLight({
    required this.direction,
    required this.color,
    required this.intensity,
    required this.ambient,
    required this.softness,
    required this.night,
  });

  factory SkyLight.of(SceneSky s) {
    final c = s.cover;
    // Regen dunkelt zusätzlich ab.
    final wet = (1 - 0.35 * s.wetness - 0.2 * s.snow - 0.25 * s.storm).clamp(
      0.2,
      1.0,
    );
    // Sonne: Dämmerung zwischen -6° und 10°, dann voll.
    final day = _smooth(-6, 10, s.sunElevation);
    final sunLift = _smooth(-2, 35, s.sunElevation);
    final sunI = sunLift * (1 - 0.85 * c) * wet;
    // Mond: Hälfte ab 2° Höhe, nur ein Bruchteil des Sonnenlichts.
    final moonUp = _smooth(-2, 12, s.moonElevation);
    final moonI = 0.05 * moonUp * s.moonIllumination * (1 - 0.75 * c);
    // Die stärkere Quelle wirft das Licht.
    final useSun = sunI >= moonI;
    final az = useSun ? s.sunAzimuth : s.moonAzimuth;
    final el = useSun ? s.sunElevation : s.moonElevation;
    // Tief stehende Sonne warm, hoch weiß; Mond kühl blau.
    final warm = _smooth(2, 30, s.sunElevation);
    final sunColor = Color.lerp(
      const Color(0xFFFFA45C),
      const Color(0xFFFFF4E4),
      warm,
    )!;
    final color = useSun
        ? Color.lerp(sunColor, const Color(0xFFE6ECF2), c * 0.8)!
        : const Color(0xFFAFC4FF);
    // Himmel: tagsüber hell (bei Wolken etwas weniger, aber weicher), nachts
    // ein Rest vom Mond und vom Himmel.
    // Innen ist es abseits der Fenster deutlich dunkler als draußen.
    final ambient =
        0.06 +
        0.06 * moonUp * s.moonIllumination +
        day * (0.34 - 0.06 * c) * wet;
    return SkyLight(
      direction: _direction(az, el, s.north),
      color: color,
      intensity: useSun ? sunI : moonI,
      ambient: ambient,
      // Wolken machen die Schatten weich.
      softness: 0.05 + 0.6 * c,
      night: !useSun,
    );
  }

  /// Weg des Lichts (von der Quelle zum Boden), Weltkoordinaten.
  final V3 direction;
  final Color color;
  final double intensity;
  final double ambient;
  final double softness;

  /// Mondlicht statt Sonne.
  final bool night;
}

double _smooth(double a, double b, double x) {
  final t = ((x - a) / (b - a)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// Lichtrichtung aus Azimut und Höhe (Grad), Plan gedreht um [north].
/// Unter dem Horizont bleibt sie knapp darüber (sonst fiele das Licht von
/// unten durch den Boden).
V3 _direction(double azimuth, double elevation, double north) {
  final n = north * math.pi / 180;
  final a = azimuth * math.pi / 180;
  final e = elevation.clamp(3.0, 89.0) * math.pi / 180;
  final nx = math.sin(n), ny = -math.cos(n);
  final ex = math.cos(n), ey = math.sin(n);
  final hx = math.sin(a) * ex + math.cos(a) * nx;
  final hy = math.sin(a) * ey + math.cos(a) * ny;
  return V3(-hx * math.cos(e), -hy * math.cos(e), -math.sin(e));
}

/// Stand am Himmel: Azimut (von Norden im Uhrzeigersinn) und Höhe, Grad.
typedef SkyPosition = ({double azimuth, double elevation});

/// Sonnenstand (Näherung, auf etwa 1° genau) am Tag [dayOfYear] (1 … 365)
/// zur lokalen Sonnenzeit [hour] auf der Breite [latitude].
SkyPosition sunPosition({
  required int dayOfYear,
  required double hour,
  double latitude = 49,
}) {
  final decl = -23.44 * math.cos(2 * math.pi / 365 * (dayOfYear + 10));
  return _position(decl, 15.0 * (hour - 12), latitude);
}

/// Mondstand (grobe Näherung): Der Mond läuft um [phase] (0 … 1) eines Tages
/// hinter der Sonne her, seine Deklination folgt dem Gegenstück der Sonne
/// (Vollmond im Winter hoch, im Sommer tief).
SkyPosition moonPosition({
  required int dayOfYear,
  required double hour,
  required double phase,
  double latitude = 49,
}) {
  final sunDecl = -23.44 * math.cos(2 * math.pi / 365 * (dayOfYear + 10));
  final decl = sunDecl * math.cos(2 * math.pi * phase);
  return _position(decl, 15.0 * (hour - 12 - 24 * phase), latitude);
}

/// Mondphase (0 Neumond … 0,5 Vollmond … 1) zum Zeitpunkt [t], aus dem
/// mittleren synodischen Monat seit einem bekannten Neumond (auf etwa einen
/// Tag genau).
double moonPhaseOn(DateTime t) {
  final epoch = DateTime.utc(2000, 1, 6, 18, 14);
  const synodic = 29.530588853;
  final days = t.toUtc().difference(epoch).inMinutes / (60 * 24);
  final p = (days / synodic) % 1.0;
  return p < 0 ? p + 1 : p;
}

/// Beleuchteter Anteil der Mondscheibe bei Phase [phase] (0 … 1).
double moonIlluminationOf(double phase) =>
    (1 - math.cos(2 * math.pi * phase)) / 2;

SkyPosition _position(double declDeg, double hourAngleDeg, double latDeg) {
  const r = math.pi / 180;
  final d = declDeg * r, h = hourAngleDeg * r, p = latDeg * r;
  final sinEl =
      math.sin(p) * math.sin(d) + math.cos(p) * math.cos(d) * math.cos(h);
  final el = math.asin(sinEl.clamp(-1.0, 1.0));
  final az = math.atan2(
    math.sin(h),
    math.cos(h) * math.sin(p) - math.tan(d) * math.cos(p),
  );
  return (azimuth: (az / r + 180) % 360, elevation: el / r);
}

/// Färbung eines Geräts in der Szene, z. B. ein Heizkörper rot, solange er
/// heizt ([pulse]: Leuchten atmet), sonst blau.
@immutable
class DeviceTint {
  const DeviceTint(this.color, {this.pulse = false, this.glow = 0.6});
  final Color color;
  final bool pulse;

  /// Stärke des Leuchtens (Emission).
  final double glow;

  @override
  bool operator ==(Object other) =>
      other is DeviceTint &&
      other.color == color &&
      other.pulse == pulse &&
      other.glow == glow;

  @override
  int get hashCode => Object.hash(color, pulse, glow);
}

/// Boden um die Wohnung (Wiese, Hof): eine Fläche knapp unter den Räumen,
/// mit durchsichtiger [color] nur Träger für den Schnee,
/// [margin] Meter über die Wohnung hinaus, zum Rand auf [fade] Meter weich
/// ausgeblendet. Sie bekommt Sonne und Mond samt Schatten des Hauses.
@immutable
class SceneGround {
  const SceneGround({
    required this.color,
    this.margin = 6,
    this.fade = 3,
    this.snow = 0,
  });
  final Color color;
  final double margin;
  final double fade;

  /// Schneehöhe 0 (kein Schnee) … 1 (etwa 25 cm): Schneehauben auf den
  /// Wandkronen so dick wie der Schnee, dazu Schneewehen um das Haus, die
  /// mit der Höhe nach außen wachsen.
  final double snow;

  @override
  bool operator ==(Object other) =>
      other is SceneGround &&
      other.color == color &&
      other.margin == margin &&
      other.fade == fade &&
      other.snow == snow;

  @override
  int get hashCode => Object.hash(color, margin, fade, snow);
}
