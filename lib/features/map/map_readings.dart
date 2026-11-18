import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/providers.dart';
import '../../data/models/entity_state.dart';
import '../../data/models/floor_plan.dart';
import '../../data/models/snapshot.dart';
import '../../data/models/state_history.dart';
import '../../data/models/zigbee.dart';
import '../zigbee/zigbee_providers.dart';
import 'heatmap.dart';

/// Was ein platziertes Gerät misst. Die Werte kommen aus seiner Hauptentity
/// oder einer anderen Entity desselben Geräts.
@immutable
class PlacedReading {
  const PlacedReading({
    required this.entityId,
    required this.cell,
    required this.location,
    this.temp,
    this.hum,
    this.battery,
    this.motionId,
    this.motion = false,
    this.motionSince,
    this.thermostat = false,
    this.setpoint,
    this.heating = false,
  });

  /// Hauptentity der Platzierung (Knoten-ID auf der Karte).
  final String entityId;
  final GridPoint cell;

  /// Raum-ID oder [kOutsideId].
  final String location;
  final double? temp;
  final double? hum;
  final double? battery;

  /// Bewegungs- oder Präsenzmelder des Geräts.
  final String? motionId;
  final bool motion;
  final DateTime? motionSince;

  /// Heizkörperthermostat (Climate-Entity): misst am Heizkörper.
  final bool thermostat;

  /// Zieltemperatur des Thermostats.
  final double? setpoint;

  /// Das Thermostat heizt gerade.
  final bool heating;

  Offset get center => cell.center;

  @override
  bool operator ==(Object other) =>
      other is PlacedReading &&
      other.entityId == entityId &&
      other.cell == cell &&
      other.location == location &&
      other.temp == temp &&
      other.hum == hum &&
      other.battery == battery &&
      other.motionId == motionId &&
      other.motion == motion &&
      other.motionSince == motionSince &&
      other.thermostat == thermostat &&
      other.setpoint == setpoint &&
      other.heating == heating;

  @override
  int get hashCode => Object.hash(
    entityId,
    cell,
    location,
    temp,
    hum,
    battery,
    motionId,
    motion,
    motionSince,
    thermostat,
    setpoint,
    heating,
  );
}

/// Alle Messwerte auf dem Grundriss, mit Wertgleichheit.
@immutable
class MapReadings {
  const MapReadings(this.items);
  final List<PlacedReading> items;

  PlacedReading? of(String entityId) {
    for (final r in items) {
      if (r.entityId == entityId) return r;
    }
    return null;
  }

  /// Werte für die Heatmap. Thermostate messen direkt am Heizkörper und
  /// zählen nur in Räumen ohne eigenen Sensor.
  HeatData heat(HeatKind kind) {
    final by = <String, List<HeatSample>>{};
    final sensed = {
      for (final r in items)
        if (!r.thermostat &&
            (kind == HeatKind.temperature ? r.temp : r.hum) != null)
          r.location,
    };
    for (final r in items) {
      final v = kind == HeatKind.temperature ? r.temp : r.hum;
      if (v == null) continue;
      if (r.thermostat && sensed.contains(r.location)) continue;
      (by[r.location] ??= []).add(HeatSample(r.center, v));
    }
    return HeatData.of(kind, by);
  }

  List<PlacedReading> get motion => [
    for (final r in items)
      if (r.motionId != null) r,
  ];

  List<PlacedReading> get batteries => [
    for (final r in items)
      if (r.battery != null) r,
  ];

  @override
  bool operator ==(Object other) =>
      other is MapReadings && listEquals(other.items, items);

  @override
  int get hashCode => Object.hashAll(items);
}

double? _num(dynamic v) =>
    v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

bool isMotionEntity(EntityState e) =>
    e.domain == 'binary_sensor' &&
    const {'occupancy', 'motion', 'presence'}.contains(e.deviceClass);

/// Entity → alle Entities desselben Geräts (HA-Geräte der Integration und
/// Zigbee-Geräte). Fehlt beides, gelten Entities mit gleichem Namensanfang.
List<String> deviceSiblings(
  String entityId,
  HavenSnapshot s,
  List<ZbDevice> zigbee,
) {
  for (final d in s.devices) {
    if (d.entityIds.contains(entityId)) return d.entityIds;
  }
  for (final d in zigbee) {
    if (d.haEntities.contains(entityId)) return d.haEntities;
  }
  // Zigbee2MQTT-Namen: `<gerät>_<eigenschaft>`.
  final obj = entityId.split('.').last;
  final cut = obj.lastIndexOf('_');
  if (cut <= 0) return [entityId];
  final prefix = '${obj.substring(0, cut)}_';
  const props = {
    'temperature',
    'humidity',
    'battery',
    'occupancy',
    'presence',
    'motion',
    'power',
    'illuminance',
    'contact',
  };
  return [
    entityId,
    for (final id in s.entities.keys)
      if (id != entityId &&
          id.split('.').last.startsWith(prefix) &&
          props.contains(id.split('.').last.substring(prefix.length)))
        id,
  ];
}

final mapReadingsProvider = Provider.family<MapReadings, HavenFloorPlan>((
  ref,
  plan,
) {
  final s = ref.watch(snapshotProvider);
  final zb = ref.watch(zigbeeProvider.select((z) => z.devices));
  final out = <PlacedReading>[];
  for (final p in plan.placements) {
    final ids = [
      p.entityId,
      for (final id in deviceSiblings(p.entityId, s, zb))
        if (id != p.entityId) id,
    ];
    double? temp;
    double? hum;
    double? bat;
    EntityState? motion;
    var thermostat = false;
    double? setpoint;
    var heating = false;
    for (final id in ids) {
      final e = s.entity(id);
      if (e != null && e.domain == 'climate' && e.state != 'unavailable') {
        thermostat = true;
        setpoint ??= _num(e.attributes['temperature']);
        heating = heating || e.attributes['hvac_action'] == 'heating';
        temp ??= _num(e.attributes['current_temperature']);
        continue;
      }
      if (e == null || !e.isAvailable) continue;
      final n = e.number;
      switch (e.deviceClass) {
        case 'temperature' when n != null && e.domain == 'sensor':
          temp ??= n;
        case 'humidity' when n != null && e.domain == 'sensor':
          hum ??= n;
        case 'battery' when n != null && e.domain == 'sensor':
          bat ??= n;
        default:
          if (isMotionEntity(e)) motion ??= e;
      }
    }
    out.add(
      PlacedReading(
        entityId: p.entityId,
        cell: p.cell,
        location: plan.locationOf(p),
        temp: temp,
        hum: hum,
        battery: bat,
        motionId: motion?.entityId,
        motion: motion?.isOn ?? false,
        motionSince: motion?.lastChanged,
        thermostat: thermostat,
        setpoint: setpoint,
        heating: heating,
      ),
    );
  }
  return MapReadings(out);
});

// ---- Anwesenheit -------------------------------------------------------------

/// Halbwertszeit des Nachleuchtens nach der letzten Bewegung.
const Duration kPresenceHalfLife = Duration(minutes: 3);

/// Danach leuchtet nichts mehr.
const Duration kPresenceFade = Duration(minutes: 30);

/// Leuchtkraft eines Melders (0..1): an 1, danach klingt sie ab.
double presenceLevel({
  required bool on,
  DateTime? since,
  required DateTime now,
}) {
  if (on) return 1;
  if (since == null) return 0;
  final age = now.difference(since);
  if (age.isNegative) return 1;
  if (age >= kPresenceFade) return 0;
  final h = age.inMilliseconds / kPresenceHalfLife.inMilliseconds;
  return math.pow(0.5, h).toDouble().clamp(0.0, 1.0);
}

/// Zustand eines Raums für die Anwesenheitskarte.
@immutable
class RoomPresence {
  const RoomPresence(this.level, {this.active = false, this.since});
  final double level;
  final bool active;

  /// Ende der letzten Bewegung (wenn nicht aktiv).
  final DateTime? since;

  @override
  bool operator ==(Object other) =>
      other is RoomPresence &&
      other.level == level &&
      other.active == active &&
      other.since == since;

  @override
  int get hashCode => Object.hash(level, active, since);
}

/// Anwesenheit je Ort zum Zeitpunkt [at]. Ohne [history] gilt der aktuelle
/// Zustand der Melder (`motion`, `motionSince`), mit [history] der Zustand
/// aus der HA-History zu diesem Zeitpunkt.
Map<String, RoomPresence> presenceAt(
  List<PlacedReading> motion,
  DateTime at, {
  Map<String, List<StateChange>>? history,
}) {
  final out = <String, RoomPresence>{};
  for (final r in motion) {
    var on = r.motion;
    var since = r.motionSince;
    final h = history?[r.motionId];
    if (h != null) {
      final st = stateAt(h, at);
      on = st?.isOn ?? false;
      since = st?.at;
    }
    final level = presenceLevel(on: on, since: since, now: at);
    final cur = out[r.location];
    if (cur == null ||
        level > cur.level ||
        (level == cur.level && on && !cur.active)) {
      out[r.location] = RoomPresence(
        level,
        active: on,
        since: on ? null : since,
      );
    }
  }
  return out;
}

/// „gerade eben“, „vor 3 min“, „vor 2 h“.
String agoText(DateTime since, DateTime now) {
  final d = now.difference(since);
  if (d.inSeconds < 60) return 'gerade eben';
  if (d.inMinutes < 60) return 'vor ${d.inMinutes} min';
  if (d.inHours < 24) return 'vor ${d.inHours} h';
  return 'vor ${d.inDays} d';
}
