import 'dart:math' as math;
import 'dart:ui' show Color, Offset;

import 'package:flutter/foundation.dart';

/// Ein Messwert an einem Punkt des Plans (Meter).
@immutable
class HeatPoint {
  const HeatPoint(this.at, this.value);
  final Offset at;
  final double value;
}

/// Farbverläufe wie in der 2D-Karte der App.
abstract final class HeatRamps {
  /// Kalt (blau) bis warm (rot).
  static const temperature = [
    Color(0xFF4A72FF),
    Color(0xFF35C2E6),
    Color(0xFF62D69A),
    Color(0xFFFFCB4F),
    Color(0xFFFF8746),
    Color(0xFFF2455C),
  ];

  /// Trocken (Sand) bis feucht (tiefes Blau).
  static const humidity = [
    Color(0xFFE8B66E),
    Color(0xFFB9D88C),
    Color(0xFF52C6C0),
    Color(0xFF3C8AE8),
    Color(0xFF5B45D6),
  ];
}

/// Heatmap über den Böden: je Raum die eigenen Messpunkte, verteilt mit
/// inverser Distanzgewichtung, eingefärbt über [ramp] zwischen [lo] und
/// [hi]. Räume ohne Messwert bleiben ohne Färbung.
///
/// Die Fläche liegt unbeleuchtet über dem Boden (wie in der 2D-Karte) und
/// streckt sich mit dem Raum, wenn er sich aufrichtet.
@immutable
class SceneHeatmap {
  const SceneHeatmap({
    required this.byRoom,
    required this.ramp,
    required this.lo,
    required this.hi,
    this.opacity = 0.6,
  });

  /// Skala aus allen Werten: gerundet auf [step], mindestens [minSpan] breit
  /// (wie `HeatScale.fit` in der App).
  factory SceneHeatmap.fitted(
    Map<String, List<HeatPoint>> byRoom, {
    required List<Color> ramp,
    double step = 1,
    double minSpan = 4,
    double opacity = 0.6,
  }) {
    final v = [
      for (final l in byRoom.values)
        for (final p in l)
          if (p.value.isFinite) p.value,
    ];
    if (v.isEmpty) {
      return SceneHeatmap(
        byRoom: byRoom,
        ramp: ramp,
        lo: 0,
        hi: 1,
        opacity: opacity,
      );
    }
    final mn = v.reduce(math.min), mx = v.reduce(math.max);
    var lo = (mn / step).floor() * step;
    var hi = (mx / step).ceil() * step;
    if (hi - lo < minSpan) {
      final mid = (mn + mx) / 2;
      lo = ((mid - minSpan / 2) / step).floor() * step;
      hi = lo + (minSpan / step).ceil() * step;
      if (hi < mx) hi = (mx / step).ceil() * step;
    }
    return SceneHeatmap(
      byRoom: byRoom,
      ramp: ramp,
      lo: lo,
      hi: hi,
      opacity: opacity,
    );
  }

  final Map<String, List<HeatPoint>> byRoom;
  final List<Color> ramp;
  final double lo;
  final double hi;
  final double opacity;

  /// Wert bei [p] in Raum [roomId] (NaN ohne Messwerte).
  double valueAt(String roomId, Offset p) {
    final s = byRoom[roomId];
    if (s == null || s.isEmpty) return double.nan;
    if (s.length == 1) return s.first.value;
    var sw = 0.0, sv = 0.0;
    for (final q in s) {
      // Weich in Metern: keine Spitze direkt am Sensor.
      final w = 1 / ((q.at - p).distanceSquared + 0.15);
      sw += w;
      sv += w * q.value;
    }
    return sv / sw;
  }

  /// Farbe zu einem Wert.
  Color colorOf(double v) {
    final t = hi <= lo ? 0.5 : ((v - lo) / (hi - lo)).clamp(0.0, 1.0);
    final n = ramp.length - 1;
    final x = t * n;
    final i = math.min(x.floor(), n - 1);
    return Color.lerp(ramp[i], ramp[i + 1], x - i)!;
  }
}
