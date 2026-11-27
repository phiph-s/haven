import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'haven_repository.dart';
import 'render_api.dart';
import 'models/room_heating.dart';
import 'models/scene_check.dart';
import 'models/snapshot.dart';
import 'models/state_history.dart';
import 'sync/app_data.dart';

/// Gemeinsamer Unterbau: hält den Snapshot und den Broadcast-Stream.
abstract class BaseRepository implements HavenRepository {
  HavenSnapshot _snapshot = const HavenSnapshot();
  final StreamController<HavenSnapshot> _controller =
      StreamController<HavenSnapshot>.broadcast();
  bool _disposed = false;

  @override
  HavenSnapshot get snapshot => _snapshot;

  @override
  Stream<HavenSnapshot> get snapshots => _controller.stream;

  bool get disposed => _disposed;

  @override
  void nudgeConnection() {}

  // ---- Gesperrte Geräte („immer an“) -----------------------------------

  /// Wirft, wenn [id] (Entity oder IEEE) gesperrt ist.
  void checkLocked(String? id) {
    if (id != null && _snapshot.locked.contains(id)) {
      throw HavenException(
        'Das Gerät ist gesperrt und bleibt an.',
        code: 'locked',
      );
    }
  }

  /// Zigbee-Werte, die ein Gerät schalten (Zustand, Helligkeit, Farbe).
  /// Einstellungen wie das Verhalten nach Stromausfall bleiben erlaubt.
  static bool controlsDevice(Map<String, dynamic> values) => values.keys.any(
    (k) => const [
      'state',
      'brightness',
      'color',
      'color_temp',
      'effect',
    ].any((c) => k == c || k.startsWith('${c}_')),
  );

  // ---- Szenen: ohne Unterstützung (Unterklassen überschreiben) ----------

  @override
  bool canEditScenes(String roomId) => false;

  @override
  bool get canSceneDevices => false;

  @override
  Future<void> setSceneDevices(
    String roomId,
    int number,
    List<String> devices,
  ) => throw HavenException(
    'Szenen lassen sich hier nicht ändern',
    code: 'not_supported',
  );

  @override
  Future<int> storeScene(
    String roomId, {
    String? name,
    int? number,
    List<String>? devices,
  }) => throw HavenException(
    'Szenen lassen sich hier nicht speichern',
    code: 'not_supported',
  );

  @override
  Future<void> renameScene(String roomId, int number, String name) =>
      throw HavenException(
        'Szenen lassen sich hier nicht ändern',
        code: 'not_supported',
      );

  @override
  Future<void> removeScene(String roomId, int number) => throw HavenException(
    'Szenen lassen sich hier nicht löschen',
    code: 'not_supported',
  );

  @override
  bool get canSyncScenes => false;

  @override
  bool get knobLightActions => false;

  @override
  bool get knobSceneStep => false;

  @override
  bool get knobDimExclude => false;

  @override
  bool get canCreateRoomGroups => false;

  @override
  Future<String> createRoomGroup(String roomId) => throw HavenException(
    'Gruppen lassen sich hier nicht anlegen',
    code: 'not_supported',
  );

  @override
  bool get canCompleteRoomGroups => false;

  @override
  Future<({int added, List<String> failed})> completeRoomGroup(String roomId) =>
      throw HavenException(
        'Gruppen lassen sich hier nicht ändern',
        code: 'not_supported',
      );

  @override
  Future<SceneCheck> checkScene(String roomId, int number) =>
      throw HavenException(
        'Szenen lassen sich hier nicht prüfen',
        code: 'not_supported',
      );

  @override
  Future<void> adoptScene(String roomId, int number) => throw HavenException(
    'Szenen lassen sich hier nicht abgleichen',
    code: 'not_supported',
  );

  @override
  Future<SceneCheck> repairScene(String roomId, int number) =>
      throw HavenException(
        'Szenen lassen sich hier nicht abgleichen',
        code: 'not_supported',
      );

  // ---- Bilder der Wohnung: ohne Unterstützung -----------------------------

  @override
  Future<RenderStatus?> renderStatus() async => null;

  @override
  Future<void> uploadRenders(
    String key,
    List<RenderFile> files, {
    void Function(int sent, int total)? onProgress,
    bool Function()? cancelled,
  }) => throw HavenException(
    'Bilder für Widgets gibt es hier nicht',
    code: 'not_supported',
  );

  @override
  Future<Uint8List> renderFile(String set, String name) => throw HavenException(
    'Bilder für Widgets gibt es hier nicht',
    code: 'not_supported',
  );

  @override
  Stream<void> get renderChanges => const Stream.empty();

  // ---- Heizungsregelung: ohne Unterstützung (Unterklassen überschreiben) --

  @override
  Future<HeatingRooms> heatingRooms() async => HeatingRooms.unsupported;

  @override
  Future<RoomHeating> saveHeating(HeatingConfig config) => throw HavenException(
    'Die Heizungsregelung gibt es hier nicht',
    code: 'not_supported',
  );

  @override
  Future<void> deleteHeating(String areaId) => throw HavenException(
    'Die Heizungsregelung gibt es hier nicht',
    code: 'not_supported',
  );

  @override
  Future<Set<String>> setHeatingDisplay(String ieee, bool display) =>
      throw HavenException(
        'Die Heizungsregelung gibt es hier nicht',
        code: 'not_supported',
      );

  @override
  Future<HeatingStatus> controlHeating(
    String areaId, {
    double? target,
    HeatingMode? mode,
    bool resume = false,
  }) => throw HavenException(
    'Die Heizungsregelung gibt es hier nicht',
    code: 'not_supported',
  );

  @override
  Stream<HeatingUpdate> get heatingUpdates => const Stream.empty();

  @override
  Stream<void> get heatingChanged => const Stream.empty();

  // ---- Geteilte Dokumente, im Speicher (Entwicklungsdaten, Tests) --------

  final Map<AppDataKind, RemoteDoc> _docs = {};
  final StreamController<AppDataKind> _appData =
      StreamController<AppDataKind>.broadcast();

  @override
  Stream<AppDataKind> get appDataChanges => _appData.stream;

  /// Meldet eine Änderung an die Hörer von [appDataChanges].
  void emitAppData(AppDataKind kind) {
    if (!_appData.isClosed) _appData.add(kind);
  }

  @override
  Future<Map<String, List<StateChange>>> stateHistory(
    List<String> entityIds,
    DateTime start,
  ) async => const {};

  @override
  Future<RemoteDoc> fetchAppData(AppDataKind kind) async =>
      _docs[kind] ?? RemoteDoc.empty;

  /// Wie die Integration mit Feature `revisions`: Jedes Speichern erhöht die
  /// Revision, ein veralteter [baseRevision] wird mit `conflict` abgelehnt.
  @override
  Future<int?> storeAppData(
    AppDataKind kind,
    Map<String, dynamic> data,
    int updatedAt, {
    int? baseRevision,
  }) async {
    final current = _docs[kind]?.revision ?? 0;
    if (baseRevision != null && baseRevision != current) {
      throw HavenException(
        'Inzwischen auf einem anderen Gerät geändert.',
        code: 'conflict',
      );
    }
    _docs[kind] = RemoteDoc(
      data: Map<String, dynamic>.from(jsonDecode(jsonEncode(data)) as Map),
      updatedAt: updatedAt,
      revision: current + 1,
    );
    emitAppData(kind);
    return current + 1;
  }

  @override
  bool get appDataRevisions => true;

  /// Ersetzt den Snapshot und benachrichtigt die Hörer.
  void publish(HavenSnapshot s) {
    if (_disposed) return;
    _snapshot = s;
    _controller.add(s);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _controller.close();
    await _appData.close();
  }
}
