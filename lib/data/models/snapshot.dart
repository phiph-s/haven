import 'device.dart';
import 'entity_state.dart';
import 'lamp.dart';
import 'light_groups.dart';
import 'room.dart';
import 'weather.dart';

enum ConnectionStatus {
  /// Erste Verbindung wird aufgebaut.
  connecting,
  connected,

  /// Verbindung verloren, Wiederverbindung läuft.
  reconnecting,

  /// Token abgelehnt: keine automatische Wiederholung.
  authFailed,

  /// Gestoppt.
  offline,
}

/// Unveränderlicher Gesamtzustand, den ein Repository liefert.
class HavenSnapshot {
  const HavenSnapshot({
    this.status = ConnectionStatus.connecting,
    this.entities = const {},
    this.rooms = const [],
    this.integrationMissing = false,
    this.activeScenes = const {},
    this.excludedLights = const {},
    this.locked = const {},
    this.weather = const WeatherConfig(),
    this.devices = const [],
    this.revision = 0,
  });

  final ConnectionStatus status;

  /// Alle bekannten Entities nach ID.
  final Map<String, EntityState> entities;
  final List<Room> rooms;

  /// HA antwortet, aber die Haven-Integration ist nicht geladen.
  final bool integrationMissing;

  /// Zuletzt angewendete Szene je Raum (Raum-ID nach Szenen-ID). Wird
  /// gelöscht, sobald jemand die Lampen des Raums von Hand ändert.
  final Map<String, String> activeScenes;

  /// Lichter, die nicht zur Lichtsteuerung gehören (3D-Drucker-LED, Status-LED).
  /// Sie fehlen in Lampenlisten, Zählern, Raum an/aus, „Alles aus“ und
  /// Szenen. Über die Geräteansicht bleiben sie erreichbar.
  final Set<String> excludedLights;

  /// Gesperrte Geräte („immer an“, z. B. die Steckdose von HA selbst oder der
  /// Kühlschrank): Entity-IDs und IEEE-Adressen. Haven schaltet sie nicht,
  /// weder aus der App noch per Automation.
  final Set<String> locked;

  bool isLocked(String? id) => id != null && locked.contains(id);

  /// Woher die Karte das Wetter nimmt (für alle Geräte gleich).
  final WeatherConfig weather;

  /// HA-Geräte mit ihren Haupt-Entities (leer bei Integration 0.1.0).
  final List<HavenDevice> devices;

  /// Zählt hoch bei jeder Änderung.
  final int revision;

  EntityState? entity(String id) => entities[id];

  Lamp? lamp(String id) {
    final e = entities[id];
    return e == null ? null : Lamp.fromEntity(e);
  }

  Room? room(String id) {
    for (final r in rooms) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// Lampen eines Raums, die zur Lichtsteuerung gehören: ohne Gruppen und
  /// ohne ausgenommene Lichter.
  List<String> controlledLightIds(Room r) => [
    for (final id in r.lightIds)
      if (!excludedLights.contains(id) &&
          entities[id] != null &&
          !isLightGroup(entities[id]!))
        id,
  ];

  List<Lamp> lampsOf(Room r) => [
    for (final id in controlledLightIds(r)) Lamp.fromEntity(entities[id]!),
  ];

  /// Ausgenommene Lampen eines Raums.
  List<Lamp> excludedLampsOf(Room r) => [
    for (final id in r.lightIds)
      if (excludedLights.contains(id) && entities[id] != null)
        Lamp.fromEntity(entities[id]!),
  ];

  /// Alle Entities einer Domain, sortiert nach Name.
  List<EntityState> byDomain(String domain) =>
      entities.values.where((e) => e.domain == domain).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  HavenSnapshot copyWith({
    ConnectionStatus? status,
    Map<String, EntityState>? entities,
    List<Room>? rooms,
    bool? integrationMissing,
    Map<String, String>? activeScenes,
    Set<String>? excludedLights,
    Set<String>? locked,
    WeatherConfig? weather,
    List<HavenDevice>? devices,
  }) => HavenSnapshot(
    status: status ?? this.status,
    entities: entities ?? this.entities,
    rooms: rooms ?? this.rooms,
    integrationMissing: integrationMissing ?? this.integrationMissing,
    activeScenes: activeScenes ?? this.activeScenes,
    excludedLights: excludedLights ?? this.excludedLights,
    locked: locked ?? this.locked,
    weather: weather ?? this.weather,
    devices: devices ?? this.devices,
    revision: revision + 1,
  );
}
