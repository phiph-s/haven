import '../../data/models/entity_state.dart';
import '../../data/models/floor_plan.dart';

/// Ab dieser Leistung (W) ist ein Verbraucher immer der Rede wert.
const double kHighPower = 100;

/// Batterie darunter (%) zeigt die Kombi-Ansicht als Warnung.
const double kLowBattery = 15;

/// Geräte, die die Kombi-Ansicht zeigt: nur die, bei denen gerade etwas los
/// ist, sonst wird die Karte zu voll.
///
/// - Licht an
/// - Heizung heizt (`hvac_action` heating/preheating)
/// - Fenster, Tür, Kontakt offen
/// - Bewegung erkannt
/// - Medien spielen
/// - Steckdose mit hohem Verbrauch: ab [kHighPower] W oder über dem 1,5-
///   Fachen des Medians aller messenden Steckdosen (und über 10 W)
/// - Batterie unter [kLowBattery] %
///
/// [entity] liefert den Zustand einer Entity, [power] die Leistung eines
/// Geräts (W), [battery] seinen Ladestand (%).
Set<String> relevantDevices(
  Iterable<FloorPlacement> placements, {
  required EntityState? Function(String id) entity,
  double? Function(String id)? power,
  double? Function(String id)? battery,
}) {
  final watts = <String, double>{};
  for (final p in placements) {
    final w = power?.call(p.entityId);
    if (w != null && w > 1) watts[p.entityId] = w;
  }
  final sorted = watts.values.toList()..sort();
  final n = sorted.length;
  final median = n == 0
      ? 0.0
      : n.isOdd
      ? sorted[n ~/ 2]
      : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;

  bool relevant(FloorPlacement p) {
    final id = p.entityId;
    final b = battery?.call(id);
    if (b != null && b < kLowBattery) return true;
    final w = watts[id];
    if (w != null && (w >= kHighPower || (w > 10 && w > median * 1.5))) {
      return true;
    }
    final e = entity(id);
    if (e == null || !e.isAvailable) return false;
    return switch (e.domain) {
      'light' => e.isOn,
      'climate' => const {
        'heating',
        'preheating',
      }.contains(e.attributes['hvac_action']),
      'media_player' => e.state == 'playing',
      'binary_sensor' => e.isOn,
      _ => false,
    };
  }

  return {
    for (final p in placements)
      if (relevant(p)) p.entityId,
  };
}
