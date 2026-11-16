import 'dart:async';

import 'package:flutter/foundation.dart';

import '../haven_repository.dart';
import '../storage/settings_store.dart';
import 'app_data.dart';

/// Hält ein geteiltes Dokument zwischen lokalem Cache und HA im Gleichstand
/// (Grundriss, Übersicht). Der Besitzer (Notifier) liefert den lokalen Stand
/// und übernimmt den Server-Stand, `DocSync` entscheidet und speichert.
///
/// - [start]: abonniert Änderungen ([HavenRepository.appDataChanges]) und
///   gleicht einmal ab.
/// - [changed]: nach jeder lokalen Änderung. Stempelt die Fassung und lädt
///   nach [debounce] (800 ms) hoch, mehrere Änderungen ergeben ein Speichern.
/// - Während ein Speichern aussteht, wird nichts vom Server übernommen.
/// - Fehler ohne Admin-Rechte melden sich über [onError], offline wird
///   beim nächsten Verbinden nachgeholt (die Fassung bleibt „dirty“).
class DocSync {
  DocSync({
    required this.kind,
    required this.repo,
    required this.store,
    required this.readLocal,
    required this.applyRemote,
    required this.onError,
    this.debounce = const Duration(milliseconds: 800),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final AppDataKind kind;
  final HavenRepository repo;
  final SettingsStore store;

  /// Lokaler Stand als Dokument, `null` wenn es lokal nichts Eigenes gibt.
  final Map<String, dynamic>? Function() readLocal;

  /// Server-Stand übernehmen. `false`, wenn er ungültig ist.
  final Future<bool> Function(Map<String, dynamic> data) applyRemote;
  final void Function(String message) onError;
  final Duration debounce;
  final DateTime Function() _clock;

  StreamSubscription<AppDataKind>? _sub;
  Timer? _timer;
  Future<void>? _pulling;
  bool _again = false;
  bool _disposed = false;

  String get _key => kind.name;
  int? get stamp => store.syncStamp(_key);
  bool get dirty => store.syncDirty(_key);
  bool get pending => _timer?.isActive ?? false;

  void start() {
    _sub = repo.appDataChanges
        .where((k) => k == kind)
        .listen((_) => unawaited(pull()));
    // Erst nach dem Aufbau des Besitzers (dessen erster Stand gilt sonst).
    Timer.run(() => unawaited(pull()));
  }

  /// Gleicht mit dem Server ab. Läuft schon einer, folgt genau einer danach.
  Future<void> pull() {
    if (_disposed) return Future.value();
    if (_pulling != null) {
      _again = true;
      return _pulling!;
    }
    final f = () async {
      do {
        _again = false;
        await _pullOnce();
      } while (_again && !_disposed);
    }();
    _pulling = f.whenComplete(() => _pulling = null);
    return _pulling!;
  }

  Future<void> _pullOnce() async {
    if (pending || _disposed) return;
    final RemoteDoc remote;
    try {
      remote = await repo.fetchAppData(kind);
    } catch (e) {
      debugPrint('Abgleich ${kind.name}: $e');
      return;
    }
    if (pending || _disposed) return;
    final local = readLocal();
    final action = decideSync(
      hasLocal: local != null,
      localDirty: dirty,
      localStamp: stamp,
      remote: remote,
    );
    switch (action) {
      case SyncAction.none:
        return;
      case SyncAction.upload:
        await _push(local!, stamp ?? _clock().millisecondsSinceEpoch);
      case SyncAction.takeRemote:
        if (await applyRemote(remote.data!)) {
          await store.setSync(_key, stamp: remote.updatedAt, dirty: false);
        }
    }
  }

  /// Lokale Änderung: stempeln und entprellt hochladen.
  Future<void> changed() async {
    final now = _clock().millisecondsSinceEpoch;
    // Streng steigend, auch bei mehreren Änderungen in derselben Millisekunde.
    final ts = now > (stamp ?? 0) ? now : (stamp ?? 0) + 1;
    await store.setSync(_key, stamp: ts, dirty: true);
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(flush()));
  }

  /// Sofort hochladen, was aussteht.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    final local = readLocal();
    if (local == null) return;
    await _push(local, stamp ?? _clock().millisecondsSinceEpoch);
  }

  Future<void> _push(Map<String, dynamic> data, int ts) async {
    try {
      await repo.storeAppData(kind, data, ts);
      // Kam inzwischen eine neuere Änderung, bleibt sie offen.
      if (stamp == ts) await store.setSync(_key, stamp: ts, dirty: false);
    } on HavenException catch (e) {
      final msg = syncErrorText(e, kind);
      if (e.code == 'unauthorized' || e.code == 'invalid_format') {
        // Nicht bei jedem Verbinden wieder versuchen und melden.
        if (stamp == ts) await store.setSync(_key, stamp: ts, dirty: false);
      }
      if (msg != null && !_disposed) onError(msg);
    } catch (e) {
      debugPrint('Speichern ${kind.name}: $e');
    }
  }

  void dispose() {
    _disposed = true;
    unawaited(_sub?.cancel());
    if (pending) {
      _timer!.cancel();
      _timer = null;
      final local = readLocal();
      final ts = stamp;
      if (local != null && ts != null) {
        unawaited(repo.storeAppData(kind, local, ts).catchError((_) {}));
      }
    }
  }
}
