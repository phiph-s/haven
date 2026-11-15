import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/providers.dart';
import '../../data/models/floor_plan.dart';
import '../../data/models/lamp.dart';
import '../../data/models/room.dart';
import '../../data/models/snapshot.dart';

/// Temperatur und Feuchte eines Plan-Raums.
@immutable
class RoomValues {
  const RoomValues(this.temp, this.hum);
  final double? temp;
  final double? hum;

  @override
  bool operator ==(Object other) =>
      other is RoomValues && other.temp == temp && other.hum == hum;

  @override
  int get hashCode => Object.hash(temp, hum);
}

/// Was die Karte vom Snapshot braucht, mit Wertgleichheit: Die Karte baut nur
/// neu, wenn sich eine platzierte Lampe oder ein Raumwert ändert.
@immutable
class MapLights {
  const MapLights(this.lamps, this.rooms);
  final Map<String, Lamp> lamps;
  final Map<String, RoomValues> rooms;

  @override
  bool operator ==(Object other) =>
      other is MapLights &&
      mapEquals(other.lamps, lamps) &&
      mapEquals(other.rooms, rooms);

  @override
  int get hashCode => Object.hash(lamps.length, rooms.length);

  int get onCount => lamps.values.where((l) => l.on).length;

  /// Mittel der Raumtemperaturen oder `null`.
  double? get avgTemp {
    final t = [
      for (final v in rooms.values)
        if (v.temp != null) v.temp!,
    ];
    return t.isEmpty ? null : t.reduce((a, b) => a + b) / t.length;
  }
}

/// Der Snapshot-Raum (HA-Bereich) zu einem Plan-Raum oder `null`.
Room? snapshotRoomFor(HavenSnapshot s, FloorRoom r) {
  final area = r.areaId;
  for (final sr in s.rooms) {
    if (area != null && (sr.id == area || sr.areaId == area)) return sr;
  }
  for (final sr in s.rooms) {
    if (sr.id == r.id) return sr;
  }
  return null;
}

final mapLightsProvider = Provider.family<MapLights, HavenFloorPlan>((
  ref,
  plan,
) {
  final s = ref.watch(snapshotProvider);
  final lamps = <String, Lamp>{};
  for (final p in plan.placements) {
    if (p.resolvedKind != FloorKind.light) continue;
    final l = s.lamp(p.entityId);
    if (l != null) lamps[p.entityId] = l;
  }
  final rooms = <String, RoomValues>{};
  for (final r in plan.rooms) {
    final sr = snapshotRoomFor(s, r);
    double? t = sr?.temperatureId == null
        ? null
        : s.entity(sr!.temperatureId!)?.number;
    final h = sr?.humidityId == null ? null : s.entity(sr!.humidityId!)?.number;
    if (t == null) {
      for (final p in plan.placements) {
        if (p.roomId == r.id && p.resolvedKind == FloorKind.temperature) {
          t = s.entity(p.entityId)?.number;
          if (t != null) break;
        }
      }
    }
    if (t != null || h != null) rooms[r.id] = RoomValues(t, h);
  }
  return MapLights(lamps, rooms);
});

String num1(double v) => v.toStringAsFixed(1).replaceAll('.', ',');
