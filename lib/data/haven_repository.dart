import '../core/light/color_math.dart';
import 'automations_api.dart';
import 'heating_api.dart';
import 'render_api.dart';
import 'models/floor_plan.dart';
import 'models/lamp_calibration.dart';
import 'models/scene_check.dart';
import 'models/snapshot.dart';
import 'models/state_history.dart';
import 'sync/app_data.dart';
import 'zigbee_api.dart';
import 'models/weather.dart';

/// Einzige Schnittstelle der Oberfläche zu den Daten. Zwei Implementierungen:
/// `HaRepository` (WebSocket zu Home Assistant mit der Integration `haven`)
/// und für die Entwicklung `FakeRepository` (erfundene Wohnung, siehe
/// `lib/dev/`).
///
/// Die Oberfläche liest immer [snapshot] bzw. [snapshots] und ruft die
/// Aktionen auf. Aktionen wirken sofort (optimistisch) und der Snapshot
/// meldet danach den echten Zustand.
abstract class HavenRepository
    implements ZigbeeApi, AutomationsApi, HeatingApi, RenderApi {
  /// `true` für die Entwicklungsdaten (`FakeRepository`). Die Oberfläche
  /// zeigt dann einen Hinweis.
  bool get isFake;

  /// Grundriss, der gilt, solange keiner gespeichert ist. Nur die
  /// Entwicklungsdaten liefern einen, sonst `null`.
  HavenFloorPlan? get sampleFloorPlan;

  /// Aktueller Stand, sofort verfügbar.
  HavenSnapshot get snapshot;

  /// Meldet jede Änderung (gebündelt, höchstens ein Ereignis pro Frame-Takt).
  Stream<HavenSnapshot> get snapshots;

  /// Startet Verbindung bzw. Simulation. Mehrfaches Aufrufen ist harmlos.
  Future<void> start();

  /// Beendet Verbindungen und Timer.
  Future<void> dispose();

  /// Setzt Lampen. Nicht gesetzte Felder bleiben. [brightness] 0..100, 0 und
  /// `on: false` schalten aus. [rgb] und [kelvin] schließen sich aus.
  Future<void> setLights(
    List<String> entityIds, {
    bool? on,
    int? brightness,
    Rgb? rgb,
    int? kelvin,
  });

  /// Raum an oder aus. Beim Einschalten gehen alle Lampen des Raums an.
  Future<void> toggleRoom(String roomId);

  /// Helligkeit für den ganzen Raum. Sind alle Lampen aus, gehen alle an.
  /// 0 schaltet den Raum aus.
  Future<void> setRoomBrightness(String roomId, int brightness);

  /// Szene eines Raums anwenden.
  Future<void> applyScene(String roomId, String sceneId);

  /// Szenen anlegen und ändern geht: Integration mit Feature `scenes` und eine
  /// Z2M-Gruppe im Raum. Schreiben braucht Admin-Rechte in HA.
  bool canEditScenes(String roomId);

  /// Speichert den aktuellen Zustand aller Lampen der Raumgruppe als Szene.
  /// Ohne [number] entsteht eine neue Szene (der Name muss frei sein, sonst
  /// [HavenException] mit `name_taken`), mit [number] wird diese überschrieben
  /// (ohne [name] bleibt der Name). Liefert die Szenen-ID.
  Future<int> storeScene(String roomId, {String? name, int? number});

  /// Benennt eine Szene der Raumgruppe um.
  Future<void> renameScene(String roomId, int number, String name);

  /// Löscht eine Szene aus der Raumgruppe.
  Future<void> removeScene(String roomId, int number);

  /// Szenen-Abgleich (Feature `scene_sync` der Integration): Szenen messen,
  /// das Gemessene als Soll übernehmen oder das Soll auf alle Lampen bringen.
  /// Braucht wie das Ändern Admin-Rechte in HA.
  bool get canSyncScenes;

  /// Drehregler-Automationen können Lampen auf einen festen Zustand setzen
  /// (Integration mit Feature `knob_lights`).
  bool get knobLightActions;

  /// Ruft die Szene [number] der Raumgruppe auf, misst jede Lampe und stellt
  /// das vorherige Licht wieder her. Dauert einige Sekunden.
  Future<SceneCheck> checkScene(String roomId, int number);

  /// Macht die letzte Messung zum Soll und ihren Look zur Kartenfarbe.
  Future<void> adoptScene(String roomId, int number);

  /// Bringt das Soll auf alle Lampen, speichert die Szene neu und misst.
  /// Ohne Soll [HavenException] mit `no_target`.
  Future<SceneCheck> repairScene(String roomId, int number);

  /// Alles aus im ganzen Haus (nur Lampen der Lichtsteuerung).
  Future<void> allLightsOff();

  /// Nimmt ein Licht aus der Lichtsteuerung aus oder wieder auf. In HA
  /// zentral über `haven/prefs/set` (ab Integration 0.2.0, Admin), sonst
  /// und in den Entwicklungsdaten lokal auf dem Gerät.
  Future<void> setLightExcluded(String entityId, bool excluded);

  /// `true`, wenn die Ausnahmen in HA liegen und für alle Geräte gelten.
  bool get prefsShared;

  /// Sperrt Geräte („immer an“) oder gibt sie frei: [ids] sind die IEEE-
  /// Adresse und die schaltbaren Entities eines Geräts. Gesperrte Geräte
  /// schaltet Haven nicht (App, Automationen, Zigbee-Befehle). Wie die
  /// Ausnahmen über `haven/prefs` geteilt.
  Future<void> setLocked(Iterable<String> ids, bool locked);

  /// Woher die Karte das Wetter nimmt (siehe [WeatherConfig]). Wie die
  /// Ausnahmen über `haven/prefs` für alle Geräte geteilt.
  Future<void> setWeatherConfig(WeatherConfig config);

  /// Anzeige-Korrektur je Lampentyp (Einstellungen › Lampen kalibrieren).
  /// Wie die Ausnahmen über `haven/prefs` (Schlüssel `lamp_calibration`)
  /// für alle Geräte geteilt, ohne Integration lokal.
  Future<void> setLampCalibration(LampCalibrations calibration);

  /// Lädt Zustände und Räume neu (Ziehen zum Aktualisieren).
  Future<void> refresh();

  /// Die App ist wieder vorne: Verbindung prüfen bzw. sofort neu aufbauen,
  /// statt die Wartezeit bis zum nächsten Versuch abzusitzen.
  void nudgeConnection();

  /// Beliebiger Dienstaufruf (`call_service`), z. B. `switch.toggle`.
  Future<void> callService(
    String domain,
    String service, {
    String? entityId,
    Map<String, dynamic> data = const {},
  });

  /// Geteilte Dokumente in HA (Grundriss, Widgets mit Layout), siehe
  /// `sync/app_data.dart`. Wirft [HavenException] (offline, `unknown_command`
  /// bei alter Integration). Die Entwicklungsdaten halten sie im Speicher.
  Future<RemoteDoc> fetchAppData(AppDataKind kind);

  /// Speichert ein Dokument mit Zeitstempel [updatedAt] (ms). Wirft
  /// [HavenException], ohne Admin-Rechte mit `unauthorized`.
  ///
  /// [baseRevision]: Revision, auf der [data] beruht. Hat inzwischen ein
  /// anderes Gerät gespeichert, lehnt die Integration mit `conflict` ab
  /// (nur mit [appDataRevisions], sonst wird ohne Prüfung gespeichert).
  /// Gibt die neue Revision zurück, `null` ohne Revisionen.
  Future<int?> storeAppData(
    AppDataKind kind,
    Map<String, dynamic> data,
    int updatedAt, {
    int? baseRevision,
  });

  /// Die Integration vergibt Revisionen und prüft `base_revision` (Feature
  /// `revisions`). Ohne prüft `DocSync` vor dem Speichern selbst.
  bool get appDataRevisions;

  /// Ein Dokument hat sich geändert (Ereignis `haven_data_updated`, auch
  /// das eigene Speichern), außerdem nach jedem Verbinden für alle Arten.
  Stream<AppDataKind> get appDataChanges;

  /// Zustandswechsel der [entityIds] seit [start] (HA-History,
  /// `history/history_during_period`), nach Zeit sortiert. Ohne History
  /// (Recorder aus, Fehler) eine leere Karte.
  Future<Map<String, List<StateChange>>> stateHistory(
    List<String> entityIds,
    DateTime start,
  );

  /// Rohbefehl an die HA-WebSocket-API, z. B. `haven/zigbee/devices`. Die
  /// Das `FakeRepository` beantwortet `haven/info`, `haven/rooms`,
  /// `haven/zigbee/devices` und `haven/zigbee/groups` aus den Konstanten. Wirft bei Fehlern.
  Future<dynamic> command(
    String type, [
    Map<String, dynamic> payload = const {},
  ]);
}

class HavenException implements Exception {
  HavenException(this.message, {this.code});
  final String message;
  final String? code;
  @override
  String toString() => message;
}
