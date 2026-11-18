import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/models/floor_plan.dart';

/// Ein Messwert an einem Punkt (Zellen).
@immutable
class HeatSample {
  const HeatSample(this.at, this.value);
  final Offset at;
  final double value;

  @override
  bool operator ==(Object other) =>
      other is HeatSample && other.at == at && other.value == value;

  @override
  int get hashCode => Object.hash(at, value);
}

/// Inverse Distanzgewichtung: Mittel der Werte mit Gewicht
/// `1 / (d² + soften)^(power / 2)` (d in Zellen). [soften] verhindert die
/// Spitze direkt am Sensor. Ein einzelner Wert färbt gleichmäßig.
double idw(
  List<HeatSample> samples,
  Offset p, {
  double power = 2,
  double soften = 0.6,
}) {
  if (samples.isEmpty) return double.nan;
  if (samples.length == 1) return samples.first.value;
  var sw = 0.0;
  var sv = 0.0;
  for (final s in samples) {
    final d2 = (s.at - p).distanceSquared + soften;
    final w = power == 2 ? 1 / d2 : 1 / math.pow(d2, power / 2);
    sw += w;
    sv += w * s.value;
  }
  return sv / sw;
}

/// Farbskala über alle Räume: gerundete Grenzen mit Mindestspanne, damit
/// kleine Unterschiede nicht zu grellen Gegensätzen werden.
@immutable
class HeatScale {
  const HeatScale(this.lo, this.hi);

  /// Grenzen aus [values], auf [step] gerundet, mindestens [minSpan] breit
  /// (um die Mitte der Werte). Ohne Werte `null`.
  static HeatScale? fit(
    Iterable<double> values, {
    double step = 1,
    double minSpan = 4,
  }) {
    final v = values.where((x) => x.isFinite).toList();
    if (v.isEmpty) return null;
    final mn = v.reduce(math.min);
    final mx = v.reduce(math.max);
    var lo = (mn / step).floor() * step;
    var hi = (mx / step).ceil() * step;
    if (hi - lo < minSpan) {
      final mid = (mn + mx) / 2;
      lo = ((mid - minSpan / 2) / step).floor() * step;
      hi = lo + (minSpan / step).ceil() * step;
      if (hi < mx) hi = (mx / step).ceil() * step;
    }
    return HeatScale(lo, hi);
  }

  final double lo;
  final double hi;

  /// 0..1 auf der Skala (geklemmt).
  double t(double v) => hi <= lo ? 0.5 : ((v - lo) / (hi - lo)).clamp(0.0, 1.0);

  @override
  bool operator ==(Object other) =>
      other is HeatScale && other.lo == lo && other.hi == hi;

  @override
  int get hashCode => Object.hash(lo, hi);

  @override
  String toString() => 'HeatScale($lo, $hi)';
}

/// Farbverlauf (gleichmäßig verteilte Stützfarben).
@immutable
class HeatRamp {
  const HeatRamp(this.colors);
  final List<Color> colors;

  Color at(double t) {
    final n = colors.length - 1;
    final x = t.clamp(0.0, 1.0) * n;
    final i = math.min(x.floor(), n - 1);
    return Color.lerp(colors[i], colors[i + 1], x - i)!;
  }

  /// Kalt (blau) bis warm (rot).
  static const temperature = HeatRamp([
    Color(0xFF4A72FF),
    Color(0xFF35C2E6),
    Color(0xFF62D69A),
    Color(0xFFFFCB4F),
    Color(0xFFFF8746),
    Color(0xFFF2455C),
  ]);

  /// Trocken (Sand) bis feucht (tiefes Blau).
  static const humidity = HeatRamp([
    Color(0xFFE8B66E),
    Color(0xFFB9D88C),
    Color(0xFF52C6C0),
    Color(0xFF3C8AE8),
    Color(0xFF5B45D6),
  ]);
}

/// Welche Werte die Heatmap zeigt.
enum HeatKind {
  temperature('°', HeatRamp.temperature, 1, 4),
  humidity(' %', HeatRamp.humidity, 5, 20);

  const HeatKind(this.unit, this.ramp, this.step, this.minSpan);
  final String unit;
  final HeatRamp ramp;
  final double step;
  final double minSpan;
}

/// Werte je Raum (nur die eigenen Sensoren) und die gemeinsame Skala.
@immutable
class HeatData {
  const HeatData({
    required this.kind,
    required this.rooms,
    required this.scale,
    this.outside = const [],
  });

  /// Baut aus den Messwerten je Ort ([kOutsideId] für draußen) die Daten. Die
  /// Skala kommt nur aus den Räumen, draußen zählt nicht mit.
  factory HeatData.of(HeatKind kind, Map<String, List<HeatSample>> byLocation) {
    final rooms = <String, List<HeatSample>>{
      for (final e in byLocation.entries)
        if (e.key != kOutsideId && e.value.isNotEmpty) e.key: e.value,
    };
    return HeatData(
      kind: kind,
      rooms: rooms,
      outside: byLocation[kOutsideId] ?? const [],
      scale: HeatScale.fit(
        [
          for (final l in rooms.values)
            for (final s in l) s.value,
        ],
        step: kind.step,
        minSpan: kind.minSpan,
      ),
    );
  }

  final HeatKind kind;
  final Map<String, List<HeatSample>> rooms;
  final List<HeatSample> outside;
  final HeatScale? scale;

  /// Mittel der Werte draußen oder `null`.
  double? get outsideValue => outside.isEmpty
      ? null
      : outside.map((s) => s.value).reduce((a, b) => a + b) / outside.length;

  /// Spanne der Werte eines Raums (min, max) oder `null`.
  (double, double)? roomRange(String id) {
    final l = rooms[id];
    if (l == null || l.isEmpty) return null;
    final v = l.map((s) => s.value);
    return (v.reduce(math.min), v.reduce(math.max));
  }

  @override
  bool operator ==(Object other) =>
      other is HeatData &&
      other.kind == kind &&
      other.scale == scale &&
      listEquals(other.outside, outside) &&
      mapEquals(
        other.rooms.map((k, v) => MapEntry(k, Object.hashAll(v))),
        rooms.map((k, v) => MapEntry(k, Object.hashAll(v))),
      );

  @override
  int get hashCode => Object.hash(kind, scale, rooms.length);
}

/// Werte auf einem Gitter über dem Raum (Schritt [step] Zellen), nur aus den
/// Sensoren des Raums (für Tests).
List<(Offset, double)> roomHeatGrid(
  FloorRoom room,
  List<HeatSample> samples, {
  double step = 0.5,
}) {
  final b = room.bounds;
  final out = <(Offset, double)>[];
  for (var y = b.top; y <= b.bottom + 1e-9; y += step) {
    for (var x = b.left; x <= b.right + 1e-9; x += step) {
      final p = Offset(x, y);
      out.add((p, idw(samples, p)));
    }
  }
  return out;
}

String heatValue(double v, HeatKind k) => k == HeatKind.temperature
    ? v.toStringAsFixed(1).replaceAll('.', ',')
    : '${v.round()}';
