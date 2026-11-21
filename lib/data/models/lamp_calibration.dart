import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'device.dart';
import 'zigbee.dart';

/// Lampentyp: Hersteller und Modell. Bei Zigbee-Lampen aus Zigbee2MQTT
/// (`vendor`, `model`), sonst aus dem HA-Geräteregister. Die Kalibrierung
/// gilt je Typ ([key]).
@immutable
class LampModel {
  const LampModel({this.vendor, this.model, this.description});

  final String? vendor;
  final String? model;

  /// Beschreibung, z. B. „Smart LED bulb (RGBCW)“ (nur Anzeige).
  final String? description;

  /// Schlüssel in `lamp_calibration` (`Hersteller|Modell`).
  String get key => '${vendor ?? ''}|${model ?? ''}';

  /// „Hersteller Modell“ für die Anzeige.
  String get label {
    final s = [vendor, model].whereType<String>().where((s) => s.isNotEmpty);
    return s.isEmpty ? 'Unbekanntes Modell' : s.join(' ');
  }

  bool get isKnown =>
      (vendor?.isNotEmpty ?? false) || (model?.isNotEmpty ?? false);

  @override
  bool operator ==(Object other) =>
      other is LampModel &&
      other.vendor == vendor &&
      other.model == model &&
      other.description == description;

  @override
  int get hashCode => Object.hash(vendor, model, description);
}

/// Lampentypen je `light.*`-Entity: HA-Geräte als Grundlage, Zigbee-Geräte
/// (genauer, weil HA oft nur die Beschreibung als Modell kennt) darüber.
Map<String, LampModel> lampModelsOf({
  List<HavenDevice> devices = const [],
  List<ZbDevice> zigbee = const [],
}) {
  final out = <String, LampModel>{};
  for (final d in devices) {
    final m = LampModel(vendor: d.manufacturer, model: d.model);
    if (!m.isKnown) continue;
    for (final id in d.entityIds) {
      if (id.startsWith('light.')) out[id] = m;
    }
  }
  for (final d in zigbee) {
    final m = LampModel(
      vendor: d.vendor,
      model: d.model,
      description: d.description,
    );
    if (!m.isKnown) continue;
    for (final id in d.haEntities) {
      if (id.startsWith('light.')) out[id] = m;
    }
  }
  return out;
}

/// Stützpunkte der Weißkorrektur (gemeldete Kelvin).
const List<int> calibrationAnchors = [2700, 4000, 6500];

/// Weißton, den Haven für Lampen ohne Farbtemperatur annimmt.
const int assumedWhiteKelvin = 2700;

/// Höchste angezeigte Helligkeit (150 %: Lampe wirkt heller als andere).
const double maxShownLevel = 1.5;

/// Korrektur der Anzeige für einen Lampentyp: Wie sieht ein gemeldeter
/// Weißton wirklich aus, und wie hell wirkt eine Helligkeitsstufe?
///
/// - [white]: gemeldete Kelvin → angezeigte Kelvin. Zwischen den
///   Stützpunkten linear in Mired (gleichmäßig für das Auge), außerhalb mit
///   dem Abstand des äußersten Punkts.
/// - Helligkeit: angezeigt = [gain] · gemeldet^[gamma] (beides 0..1).
///   [gamma] > 1 macht die unteren Stufen dunkler, < 1 heller.
@immutable
class LampCalibration {
  const LampCalibration({this.white = const {}, this.gain = 1, this.gamma = 1});

  static const none = LampCalibration();

  static const double minGain = 0.3;
  static const double maxGain = 1.5;
  static const double minGamma = 0.5;
  static const double maxGamma = 2.0;

  final Map<int, int> white;
  final double gain;
  final double gamma;

  bool get correctsWhite => white.entries.any((e) => e.key != e.value);
  bool get correctsBrightness => gain != 1 || gamma != 1;
  bool get isIdentity => !correctsWhite && !correctsBrightness;

  /// Angezeigter Wert am Stützpunkt [reported] (ohne Korrektur derselbe).
  int shownAt(int reported) => white[reported] ?? reported;

  /// Angezeigte Farbtemperatur für gemeldete [kelvin].
  int mapKelvin(int kelvin) {
    if (!correctsWhite || kelvin <= 0) return kelvin;
    // In Mired: Absteigend nach Kelvin heißt aufsteigend nach Mired.
    final pts = [
      for (final e in white.entries)
        if (e.key > 0 && e.value > 0) (1e6 / e.key, 1e6 / e.value),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    if (pts.isEmpty) return kelvin;
    final m = 1e6 / kelvin;
    double shown;
    if (m <= pts.first.$1) {
      shown = m + (pts.first.$2 - pts.first.$1);
    } else if (m >= pts.last.$1) {
      shown = m + (pts.last.$2 - pts.last.$1);
    } else {
      shown = m;
      for (var i = 0; i < pts.length - 1; i++) {
        final (a, b) = (pts[i], pts[i + 1]);
        if (m >= a.$1 && m <= b.$1) {
          final t = (m - a.$1) / (b.$1 - a.$1);
          shown = a.$2 + (b.$2 - a.$2) * t;
          break;
        }
      }
    }
    // 1000 K … 12000 K: weiter rechnet kelvinToRgb nicht sinnvoll.
    return (1e6 / shown.clamp(1e6 / 12000, 1e6 / 1000)).round();
  }

  /// Angezeigte Helligkeit (0..[maxShownLevel]) für gemeldete [level]
  /// (0..1).
  double mapLevel(double level) {
    if (level <= 0) return 0;
    final l = level > 1 ? 1.0 : level;
    if (!correctsBrightness) return l;
    return (gain * math.pow(l, gamma)).clamp(0.0, maxShownLevel).toDouble();
  }

  LampCalibration copyWith({
    Map<int, int>? white,
    double? gain,
    double? gamma,
  }) => LampCalibration(
    white: white ?? this.white,
    gain: gain ?? this.gain,
    gamma: gamma ?? this.gamma,
  );

  /// Mit einem Stützpunkt: [reported] sieht aus wie [shown]. Die übrigen
  /// [anchors] werden mit ihrem jetzigen Wert festgehalten, damit sich nur
  /// ändert, was man sieht.
  LampCalibration withWhite(
    int reported,
    int shown, {
    Iterable<int> anchors = const [],
  }) => copyWith(
    white: {for (final a in anchors) a: shownAt(a), ...white, reported: shown},
  );

  /// Unveränderte Stützpunkte bleiben drin, solange einer korrigiert: Sie
  /// halten die Nachbarn fest (sonst würde außen weitergeschoben).
  Map<String, dynamic> toJson() => {
    if (correctsWhite)
      'white': [
        for (final e
            in (white.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
          [e.key, e.value],
      ],
    if (gain != 1) 'gain': _round(gain),
    if (gamma != 1) 'gamma': _round(gamma),
  };

  /// Unbekanntes und Unsinn wird übergangen, Werte geklemmt.
  static LampCalibration fromJson(Object? json) {
    if (json is! Map) return none;
    final white = <int, int>{};
    final raw = json['white'];
    if (raw is List) {
      for (final p in raw) {
        if (p is List && p.length >= 2 && p[0] is num && p[1] is num) {
          final k = (p[0] as num).round();
          final v = (p[1] as num).round();
          if (k >= 1000 && k <= 12000 && v >= 1000 && v <= 12000) {
            white[k] = v;
          }
        }
      }
    }
    double num_(Object? v, double lo, double hi) =>
        v is num && v.isFinite ? v.toDouble().clamp(lo, hi) : 1.0;
    return LampCalibration(
      white: white,
      gain: num_(json['gain'], minGain, maxGain),
      gamma: num_(json['gamma'], minGamma, maxGamma),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LampCalibration &&
      mapEquals(other.white, white) &&
      other.gain == gain &&
      other.gamma == gamma;

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered([
      for (final e in white.entries) Object.hash(e.key, e.value),
    ]),
    gain,
    gamma,
  );
}

double _round(double v) => (v * 1000).round() / 1000;

/// Alle Kalibrierungen je Lampentyp ([LampModel.key]). In HA unter
/// `lamp_calibration` im Dokument `haven/prefs`, damit sie für alle Geräte
/// gilt.
@immutable
class LampCalibrations {
  const LampCalibrations([this.byModel = const {}]);

  static const empty = LampCalibrations();

  final Map<String, LampCalibration> byModel;

  bool get isEmpty => byModel.values.every((c) => c.isIdentity);

  LampCalibration of(LampModel? m) =>
      m == null ? LampCalibration.none : byModel[m.key] ?? LampCalibration.none;

  /// Neue Fassung mit [c] für [key]. Ohne Korrektur fällt der Typ heraus.
  LampCalibrations withModel(String key, LampCalibration c) => LampCalibrations(
    Map.unmodifiable({
      for (final e in byModel.entries)
        if (e.key != key) e.key: e.value,
      if (!c.isIdentity) key: c,
    }),
  );

  Map<String, dynamic> toJson() => {
    for (final e in byModel.entries)
      if (!e.value.isIdentity) e.key: e.value.toJson(),
  };

  static LampCalibrations fromJson(Object? json) {
    if (json is! Map) return empty;
    return LampCalibrations(
      Map.unmodifiable(
        {
          for (final e in json.entries)
            if (e.key is String)
              e.key as String: LampCalibration.fromJson(e.value),
        }..removeWhere((_, c) => c.isIdentity),
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LampCalibrations && mapEquals(other.byModel, byModel);

  @override
  int get hashCode => Object.hashAllUnordered([
    for (final e in byModel.entries) Object.hash(e.key, e.value),
  ]);
}
