import 'dart:async';
import 'dart:convert';

import 'haven_repository.dart';
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

  // ---- Szenen: ohne Unterstützung (Unterklassen überschreiben) ----------

  @override
  bool canEditScenes(String roomId) => false;

  @override
  Future<int> storeScene(String roomId, {String? name, int? number}) =>
      throw HavenException(
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

  @override
  Future<void> storeAppData(
    AppDataKind kind,
    Map<String, dynamic> data,
    int updatedAt,
  ) async {
    _docs[kind] = RemoteDoc(
      data: Map<String, dynamic>.from(jsonDecode(jsonEncode(data)) as Map),
      updatedAt: updatedAt,
    );
    emitAppData(kind);
  }

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
