import 'package:flutter/foundation.dart';

import '../../data/models/entity_state.dart';
import '../../data/models/room_heating.dart';
import '../../data/models/snapshot.dart';
import 'thermostat_model.dart';

/// Reine Logik der Heizungsregelung für die Oberfläche: Auswahllisten,
/// Texte, Vorschau der Korrektur. Keine Widgets, kein Riverpod.

/// Eine wählbare Entity (Thermometer, Fensterkontakt, Außenquelle).
@immutable
class HeatingSource {
  const HeatingSource({
    required this.entityId,
    required this.name,
    this.value,
    this.inRoom = false,
    this.roomName,
  });
  final String entityId;
  final String name;

  /// Aktueller Wert als Text („21,3 °C“, „offen“), `null` ohne Wert.
  final String? value;
  final bool inRoom;
  final String? roomName;
}

const Set<String> kWindowClasses = {'window', 'door', 'opening', 'garage_door'};

/// Entity → Bereich aus den HA-Geräten des Snapshots, ergänzt um [extra]
/// (z. B. die Zigbee-Geräte mit ihrem Raum).
Map<String, String> entityAreas(
  HavenSnapshot snap, [
  Map<String, String> extra = const {},
]) => {
  ...extra,
  for (final d in snap.devices)
    if (d.areaId != null)
      for (final e in d.entityIds) e: d.areaId!,
};

String _roomName(HavenSnapshot snap, String? area) =>
    snap.rooms.where((r) => (r.areaId ?? r.id) == area).firstOrNull?.name ?? '';

List<HeatingSource> _sorted(List<HeatingSource> l) => l
  ..sort((a, b) {
    if (a.inRoom != b.inRoom) return a.inRoom ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });

/// Raumthermometer: `sensor.*` mit `device_class: temperature`, ohne die
/// Messung der Thermostate selbst ([excluded]). Raum [areaId] zuerst.
List<HeatingSource> temperatureSources(
  HavenSnapshot snap,
  String areaId, {
  Set<String> excluded = const {},
  Map<String, String> areas = const {},
}) {
  areas = entityAreas(snap, areas);
  return _sorted([
    for (final e in snap.entities.values)
      if (e.domain == 'sensor' &&
          e.deviceClass == 'temperature' &&
          !excluded.contains(e.entityId))
        HeatingSource(
          entityId: e.entityId,
          name: e.name,
          value: e.number == null ? null : fmtTemp(e.number!),
          inRoom: areas[e.entityId] == areaId,
          roomName: _roomName(snap, areas[e.entityId]),
        ),
  ]);
}

/// Fenster- und Türkontakte (`binary_sensor.*`), ohne die Fenster-Erkennung
/// der Thermostate ([excluded]).
List<HeatingSource> windowSources(
  HavenSnapshot snap,
  String areaId, {
  Set<String> excluded = const {},
  Map<String, String> areas = const {},
}) {
  areas = entityAreas(snap, areas);
  return _sorted([
    for (final e in snap.entities.values)
      if (e.domain == 'binary_sensor' &&
          kWindowClasses.contains(e.deviceClass) &&
          !excluded.contains(e.entityId))
        HeatingSource(
          entityId: e.entityId,
          name: e.name,
          value: !e.isAvailable ? null : (e.isOn ? 'offen' : 'zu'),
          inRoom: areas[e.entityId] == areaId,
          roomName: _roomName(snap, areas[e.entityId]),
        ),
  ]);
}

/// Außentemperatur: Wetter-Entities zuerst, dann alle Temperatursensoren.
List<HeatingSource> outdoorSources(
  HavenSnapshot snap, {
  Set<String> excluded = const {},
  Map<String, String> areas = const {},
}) {
  areas = entityAreas(snap, areas);
  final weather = <HeatingSource>[];
  final sensors = <HeatingSource>[];
  for (final e in snap.entities.values) {
    if (e.domain == 'weather') {
      final t = e.attributes['temperature'];
      weather.add(
        HeatingSource(
          entityId: e.entityId,
          name: 'Wetter ${e.name}',
          value: t is num ? fmtTemp(t.toDouble()) : null,
          inRoom: true,
        ),
      );
    } else if (e.domain == 'sensor' &&
        e.deviceClass == 'temperature' &&
        !excluded.contains(e.entityId)) {
      sensors.add(
        HeatingSource(
          entityId: e.entityId,
          name: e.name,
          value: e.number == null ? null : fmtTemp(e.number!),
          roomName: _roomName(snap, areas[e.entityId]),
        ),
      );
    }
  }
  int byName(HeatingSource a, HeatingSource b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());
  return [...weather..sort(byName), ...sensors..sort(byName)];
}

/// Mittel der gültigen Werte der Thermometer, `null` ohne Wert.
double? averageOf(Map<String, EntityState> entities, List<String> ids) {
  final v = [
    for (final id in ids)
      if (entities[id] case final e? when e.isAvailable && e.number != null)
        e.number!,
  ];
  if (v.isEmpty) return null;
  return v.reduce((a, b) => a + b) / v.length;
}

/// Vorschau beim Einrichten: Raum (Thermometer) minus Thermostat-Messung.
/// Negativ: Das Thermostat misst am Heizkörper zu warm.
double? correctionPreview(double? room, double? trvLocal) =>
    room == null || trvLocal == null
    ? null
    : ((room - trvLocal) * 10).round() / 10;

/// „+0,5“ bzw. „−2,1“.
String fmtSigned(double v) {
  final r = (v * 10).round() / 10;
  if (r == 0) return '±0';
  final s = fmtNum1(r.abs());
  return r > 0 ? '+$s' : '−$s';
}

/// Satz zum Zustand des Raums, z. B. „Heizt auf 21 °C“.
String heatingStatusText(HeatingStatus s, {DateTime? now}) {
  final t = s.effectiveTarget;
  switch (s.pause) {
    case HeatingPause.off:
      return 'Heizung aus';
    case HeatingPause.window:
      return 'Fenster offen, Heizung pausiert';
    case HeatingPause.summer:
      final o = s.outdoorValue;
      return o == null ? 'Sommerpause' : 'Sommerpause, draußen ${fmtTemp(o)}';
    case null:
      break;
  }
  if (s.windowOpen && s.pauseAt != null) {
    return 'Fenster offen, pausiert gleich';
  }
  if (t == null) return 'Bereit';
  if (s.heating == true) return 'Heizt auf ${fmtTemp(t)}';
  final r = s.roomTemperature;
  if (r != null && r >= t - 0.2) return 'Hält ${fmtTemp(t)}';
  return 'Ziel ${fmtTemp(t)}';
}

/// Woher die Raumtemperatur kommt (Zeile unter dem Wert).
String heatingSourceText(HeatingStatus s, int sensorCount) {
  if (s.roomSource == 'sensors') {
    final valid = s.sensorValues.values.whereType<double>().length;
    if (sensorCount <= 1) return 'Raumthermometer';
    return valid == sensorCount
        ? 'Mittel aus $sensorCount Thermometern'
        : 'Mittel aus $valid von $sensorCount Thermometern';
  }
  if (s.roomSource == 'trv') {
    return sensorCount == 0
        ? 'Am Thermostat gemessen'
        : 'Thermometer ohne Wert, am Thermostat gemessen';
  }
  return 'Noch keine Messung';
}

/// Was Haven an einem Thermostat ausgleicht, z. B. „gleicht −2,1 °C aus“.
String? trvCorrectionText(HeatingTrvStatus t, double? target) {
  if (!t.available) return 'nicht erreichbar';
  switch (t.method) {
    case HeatingCalibration.offset:
      final c = t.desiredCalibration ?? t.calibration;
      if (c == null) return null;
      return 'gleicht ${fmtSigned(c)} °C aus';
    case HeatingCalibration.target:
      final sp = t.desiredSetpoint ?? t.setpoint;
      if (sp == null || target == null) return null;
      return 'stellt ${fmtNum1(sp)}° ein für ${fmtNum1(target)}° im Raum';
    case HeatingCalibration.none:
      return null;
  }
}

/// Auswahl für die Verzögerungen (Sekunden, Beschriftung).
const List<(int, String)> kWindowOpenDelays = [
  (0, 'Sofort'),
  (30, '30 s'),
  (60, '1 min'),
  (180, '3 min'),
];
const List<(int, String)> kWindowCloseDelays = [
  (0, 'Sofort'),
  (60, '1 min'),
  (120, '2 min'),
  (300, '5 min'),
];

/// Nächster Wert aus [options] zu [v] (für gespeicherte Zwischenwerte).
int nearestDelay(List<(int, String)> options, int v) {
  var best = options.first.$1;
  for (final (s, _) in options) {
    if ((s - v).abs() < (best - v).abs()) best = s;
  }
  return best;
}
