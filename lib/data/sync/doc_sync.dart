import 'dart:async';

import 'package:flutter/foundation.dart';

import '../haven_repository.dart';
import '../storage/settings_store.dart';
import 'app_data.dart';

/// Zustand eines Dokuments für die Anzeige in den Einstellungen.
enum SyncState { current, pending, error }

@immutable
class SyncInfo {
  const SyncInfo({
    this.state = SyncState.current,
    this.lastSync,
    this.remoteAt,
    this.remoteSummary,
    this.localSummary,
    this.lastError,
  });
  final SyncState state;

  /// Letzter erfolgreicher Abgleich (nur in dieser Sitzung bekannt).
  final DateTime? lastSync;

  /// `updated_at` des Stands in HA.
  final int? remoteAt;

  /// z. B. „3 Räume, 22 Möbel“ (Stand in HA bzw. hier).
  final String? remoteSummary;
  final String? localSummary;
  final String? lastError;
}

/// Alle laufenden [DocSync] einer Sitzung, für die Einstellungen.
class SyncRegistry extends ChangeNotifier {
  final Map<AppDataKind, DocSync> _docs = {};
  Map<AppDataKind, DocSync> get docs => Map.unmodifiable(_docs);

  void register(DocSync s) {
    _docs[s.kind] = s;
    // Nicht mitten im Aufbau melden (die Einstellungen bauen sich gerade).
    scheduleMicrotask(notifyListeners);
  }

  void unregister(DocSync s) {
    if (_docs[s.kind] == s) _docs.remove(s.kind);
    scheduleMicrotask(notifyListeners);
  }

  @override
  void notifyListeners() {
    if (hasListeners) super.notifyListeners();
  }
}

/// Hält ein geteiltes Dokument zwischen lokalem Cache und HA im Gleichstand
/// (Grundriss, Übersicht). Der Besitzer (Notifier) liefert den lokalen Stand
/// und übernimmt den Server-Stand, `DocSync` entscheidet und speichert.
///
/// - [start]: abonniert Änderungen ([HavenRepository.appDataChanges]) und
///   gleicht einmal ab.
/// - [changed]: nach jeder lokalen Änderung. Stempelt die Fassung und lädt
///   nach [debounce] (800 ms) hoch, mehrere Änderungen ergeben ein Speichern.
/// - Abgleich über die Server-Revision bzw. [baseStamp] statt Uhrzeiten
///   (siehe [decideSync]).
/// - Gespeichert wird immer mit der Revision, auf der die lokale Fassung
///   beruht (`base_revision`). Hat inzwischen ein anderes Gerät gespeichert,
///   lehnt HA ab (`conflict`): `DocSync` lädt neu, führt zusammen
///   ([mergeDocs], Grundlage ist der zuletzt abgeglichene Stand) und
///   speichert das Ergebnis. Ohne Revisionen (ältere Integration) prüft
///   `DocSync` vor dem Speichern selbst.
/// - Ein Abgleich, der während eines ausstehenden Speicherns ankommt (z. B.
///   das Ereignis eines anderen Geräts), wird danach nachgeholt.
/// - Fehler ohne Admin-Rechte melden sich über [onError]. Nur offline und
///   Zeitüberschreitung bleiben „dirty“ und werden beim nächsten Verbinden
///   nachgeholt. Jeder andere Fehler wird gemeldet, dann gilt der Server.
class DocSync {
  DocSync({
    required this.kind,
    required this.repo,
    required this.store,
    required this.readLocal,
    required this.applyRemote,
    required this.onError,
    this.describe,
    this.debounce = const Duration(milliseconds: 800),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final AppDataKind kind;
  final HavenRepository repo;
  final SyncStateStore store;

  /// Lokaler Stand als Dokument, `null` wenn es lokal nichts Eigenes gibt.
  final Map<String, dynamic>? Function() readLocal;

  /// Server-Stand übernehmen. `false`, wenn er ungültig ist.
  final Future<bool> Function(Map<String, dynamic> data) applyRemote;
  final void Function(String message) onError;

  /// Kurzbeschreibung eines Dokuments für die Diagnose (Anzahl Räume usw.).
  final String Function(Map<String, dynamic> data)? describe;
  final Duration debounce;
  final DateTime Function() _clock;

  StreamSubscription<AppDataKind>? _sub;
  Timer? _timer;
  Future<void>? _pulling;
  bool _again = false;
  bool _disposed = false;

  /// Ein Speichern läuft. Das Echo (`haven_data_updated`) kann vor der
  /// Antwort eintreffen und darf dann keinen zweiten Upload auslösen.
  bool _pushing = false;

  /// Ein Abgleich kam, während ein Speichern ausstand: danach nachholen.
  bool _pullAfterPush = false;

  /// Zählt lokale Änderungen: Kam während des Speicherns eine neue, bleibt
  /// die Fassung offen.
  int _rev = 0;

  /// Zustand für die Einstellungen.
  final ValueNotifier<SyncInfo> info = ValueNotifier(const SyncInfo());

  String get _key => kind.name;
  int? get stamp => store.syncStamp(_key);
  int? get baseStamp => store.syncBase(_key);
  int? get baseRevision => store.syncRevision(_key);
  bool get dirty => store.syncDirty(_key);
  bool get pending => _timer?.isActive ?? false;

  void start() {
    _setInfo();
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

  /// Hat der Server einen anderen Stand als den, auf dem die lokale Fassung
  /// beruht?
  bool _remoteMoved(RemoteDoc remote) {
    if (remote.isEmpty) return baseStamp != null || baseRevision != null;
    final r = baseRevision;
    if (r != null && remote.revision != null) return remote.revision != r;
    return remote.updatedAt != baseStamp;
  }

  bool get _busy => pending || _pushing;

  Future<void> _pullOnce() async {
    if (_disposed) return;
    if (_busy) {
      // Nicht verwerfen: Nach dem Speichern wird nachgeholt. Das Speichern
      // selbst prüft die Revision, ein veralteter Stand geht nicht durch.
      _pullAfterPush = true;
      return;
    }
    final RemoteDoc remote;
    try {
      remote = await repo.fetchAppData(kind);
    } catch (e) {
      debugPrint('Abgleich ${kind.name}: $e');
      _setInfo(error: 'Abgleich nicht möglich: ${_short(e)}');
      return;
    }
    if (_disposed) return;
    if (_busy) {
      _pullAfterPush = true;
      return;
    }
    final local = readLocal();
    final action = decideSync(
      hasLocal: local != null,
      localDirty: dirty,
      baseStamp: baseStamp,
      baseRevision: baseRevision,
      remote: remote,
    );
    var ok = false;
    switch (action) {
      case SyncAction.none:
        ok = true;
        // Revision und Grundlage nachtragen (erster Abgleich mit Revisionen).
        if (remote.revision != null && baseRevision != remote.revision ||
            store.syncBaseDoc(_key) == null && remote.data != null) {
          await store.setSync(
            _key,
            stamp: stamp,
            dirty: dirty,
            revision: remote.revision,
            baseDoc: remote.data,
          );
        }
      case SyncAction.upload:
        await _push(local!, _nextStamp(), checked: remote);
        _setInfo(remote: remote);
        return;
      case SyncAction.takeRemote:
        ok = await _adopt(remote);
      case SyncAction.conflict:
        ok = await _resolveConflict(remote, local!);
        if (!ok) return;
    }
    _setInfo(remote: remote, synced: ok);
  }

  /// Übernimmt den Server-Stand und merkt ihn als Basis. Die lokale
  /// Änderung ist damit verworfen.
  Future<bool> _adopt(RemoteDoc remote) async {
    if (await applyRemote(remote.data!)) {
      await store.setSync(
        _key,
        stamp: remote.updatedAt,
        dirty: false,
        base: remote.updatedAt,
        revision: remote.revision,
        baseDoc: remote.data,
      );
      return true;
    }
    // Ungültiger Stand: nicht bei jedem Abgleich neu versuchen.
    await store.setSync(_key, stamp: stamp, dirty: false);
    _setInfo(error: 'Der Stand in Home Assistant ist ungültig', remote: remote);
    return false;
  }

  /// Lokal ungespeichert, aber ein anderes Gerät hat inzwischen gespeichert.
  /// Mit bekannter Grundlage: zusammenführen, übernehmen und hochladen.
  /// Ohne (Stand vor dieser Version): Der Server gilt, mit Hinweis.
  Future<bool> _resolveConflict(
    RemoteDoc remote,
    Map<String, dynamic> local, {
    int depth = 0,
  }) async {
    final base = store.syncBaseDoc(_key);
    if (remote.isEmpty) {
      // Auf dem Server gelöscht: lokal gilt, neu anlegen.
      await _push(local, _nextStamp(), checked: remote, depth: depth + 1);
      return true;
    }
    if (base == null) {
      final ok = await _adopt(remote);
      if (ok && !_disposed) onError(syncConflictText(kind));
      return ok;
    }
    final merged = mergeDocs(base, local, remote.data!);
    if (!await applyRemote(merged.doc)) {
      // Zusammengeführt ungültig (z. B. überlappende Räume): Server gilt.
      final ok = await _adopt(remote);
      if (ok && !_disposed) onError(syncConflictText(kind));
      return ok;
    }
    await store.setSync(
      _key,
      stamp: stamp,
      dirty: true,
      base: remote.updatedAt,
      revision: remote.revision,
      baseDoc: remote.data,
    );
    if (merged.overlaps > 0 && !_disposed) onError(syncMergedText(kind));
    if (sameDoc(merged.doc, remote.data)) {
      // Die lokale Änderung steckt schon im Server-Stand.
      await store.setSync(_key, stamp: remote.updatedAt, dirty: false);
      _setInfo(remote: remote, synced: true);
      return true;
    }
    await _push(
      readLocal() ?? merged.doc,
      _nextStamp(),
      checked: remote,
      depth: depth + 1,
    );
    _setInfo(remote: remote);
    return true;
  }

  int _nextStamp() {
    final floor = [stamp ?? 0, baseStamp ?? 0].reduce((a, b) => a > b ? a : b);
    final now = _clock().millisecondsSinceEpoch;
    return now > floor ? now : floor + 1;
  }

  /// Lokale Änderung: stempeln und entprellt hochladen.
  Future<void> changed() async {
    // Streng steigend, auch bei mehreren Änderungen in derselben Millisekunde.
    _rev++;
    await store.setSync(_key, stamp: _nextStamp(), dirty: true);
    _setInfo();
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(flush()));
  }

  /// Sofort hochladen, was aussteht.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    final local = readLocal();
    if (local == null) return;
    await _push(local, stamp ?? _nextStamp());
  }

  /// Lädt [data] hoch, beruhend auf [baseRevision].
  ///
  /// [checked]: Server-Stand, gegen den gerade erst geprüft wurde. Fehlt er
  /// und kann der Server nicht selbst prüfen (ältere Integration, oder noch
  /// keine Revision bekannt), prüft `DocSync` vorher selbst.
  Future<void> _push(
    Map<String, dynamic> data,
    int ts, {
    RemoteDoc? checked,
    int depth = 0,
  }) async {
    _pushing = true;
    final rev = _rev;
    try {
      var baseRev = baseRevision;
      if (checked == null && (!repo.appDataRevisions || baseRev == null)) {
        final remote = await repo.fetchAppData(kind);
        if (_remoteMoved(remote) && depth < 3) {
          _pushing = false;
          await _resolveConflict(remote, data, depth: depth);
          return;
        }
        baseRev = remote.revision ?? baseRev;
      } else if (checked != null) {
        baseRev = checked.revision ?? baseRev;
      }
      final newRev = await repo.storeAppData(
        kind,
        data,
        ts,
        baseRevision: baseRev,
      );
      // Der Server hat jetzt `ts`. Kam inzwischen eine neuere Änderung, bleibt
      // sie offen und beruht auf diesem Stand.
      await store.setSync(
        _key,
        stamp: rev == _rev ? ts : stamp,
        dirty: rev == _rev ? false : dirty,
        base: ts,
        revision: newRev,
        baseDoc: _asStored(data, ts),
      );
      _setInfo(synced: true);
    } catch (e) {
      if (isConflictError(e) && depth < 3) {
        // Ein anderes Gerät war schneller: neu laden, zusammenführen.
        _pushing = false;
        try {
          final remote = await repo.fetchAppData(kind);
          await _resolveConflict(remote, readLocal() ?? data, depth: depth);
        } catch (e2) {
          debugPrint('Abgleich ${kind.name}: $e2');
          _setInfo(error: 'Abgleich nicht möglich: ${_short(e2)}');
        }
        return;
      }
      if (isOfflineError(e)) {
        // Bleibt offen, wird beim nächsten Abgleich hochgeladen.
        debugPrint('Speichern ${kind.name}: $e');
        _setInfo(error: 'Home Assistant nicht erreichbar, Änderung wartet');
        return;
      }
      final code = e is HavenException ? e.code : null;
      final msg = syncErrorText(e, kind);
      // Die Änderung ist erledigt, sonst käme bei jedem Abgleich derselbe
      // Fehler wieder.
      if (rev == _rev) await store.setSync(_key, stamp: ts, dirty: false);
      if (msg != null && !_disposed) onError(msg);
      _setInfo(error: '${code ?? 'Fehler'}: ${_short(e)}');
      // Nur ohne Admin-Rechte und bei abgelehntem Format bleibt die lokale
      // Fassung (gilt nur hier). Jeder andere Fehler: Server gewinnt.
      if (code != 'unauthorized' &&
          code != 'invalid_format' &&
          code != 'unknown_command' &&
          code != 'not_found') {
        _pushing = false;
        await _resolveToServer();
      }
    } finally {
      _pushing = false;
      if (_pullAfterPush && !_disposed && !pending) {
        _pullAfterPush = false;
        unawaited(pull());
      }
    }
  }

  /// So, wie der Server das Dokument zurückgibt (der Grundriss trägt den
  /// Stempel auch im Dokument).
  Map<String, dynamic> _asStored(Map<String, dynamic> data, int ts) =>
      kind == AppDataKind.floorplan && data['plan'] is Map
      ? {
          ...data,
          'plan': {...data['plan'] as Map, 'updatedAt': ts},
        }
      : data;

  Future<void> _resolveToServer() async {
    try {
      final remote = await repo.fetchAppData(kind);
      if (remote.isEmpty || _disposed) return;
      if (await _adopt(remote)) _setInfo(remote: remote);
    } catch (e) {
      debugPrint('Abgleich ${kind.name}: $e');
    }
  }

  /// „Stand aus Home Assistant übernehmen“: verwirft die lokale Fassung.
  /// Gibt einen Hinweistext zurück (Erfolg oder Grund des Scheiterns).
  Future<String> takeRemoteNow() async {
    _timer?.cancel();
    _timer = null;
    // Läuft gerade ein Abgleich, erst abwarten.
    await _pulling;
    final RemoteDoc remote;
    try {
      remote = await repo.fetchAppData(kind);
    } catch (e) {
      _setInfo(error: 'Abgleich nicht möglich: ${_short(e)}');
      return 'Home Assistant ist gerade nicht erreichbar.';
    }
    if (remote.isEmpty) {
      await store.setSync(_key, stamp: stamp, dirty: false);
      _setInfo(remote: remote, synced: true);
      return 'In Home Assistant ist noch nichts gespeichert.';
    }
    if (!await _adopt(remote)) {
      return 'Der Stand in Home Assistant ist ungültig.';
    }
    _setInfo(remote: remote, synced: true);
    return 'Stand aus Home Assistant übernommen.';
  }

  // ---- Diagnose ------------------------------------------------------------

  String _short(Object e) {
    final t = e is HavenException ? e.message : '$e';
    return t.length > 160 ? '${t.substring(0, 160)}…' : t;
  }

  String? _describe(Map<String, dynamic>? d) {
    if (d == null || describe == null) return null;
    try {
      return describe!(d);
    } catch (_) {
      return null;
    }
  }

  DateTime? _lastSync;
  String? _lastError;
  RemoteDoc? _remote;

  /// Aktualisiert [info]. [error] setzt den letzten Fehler, [synced] löscht
  /// ihn und merkt die Zeit.
  void _setInfo({String? error, RemoteDoc? remote, bool synced = false}) {
    if (_disposed) return;
    if (remote != null) _remote = remote;
    if (synced) {
      _lastSync = _clock();
      _lastError = null;
    }
    if (error != null) _lastError = error;
    final r = _remote;
    info.value = SyncInfo(
      state: _lastError != null
          ? SyncState.error
          : (dirty || pending ? SyncState.pending : SyncState.current),
      lastSync: _lastSync,
      remoteAt: r?.updatedAt,
      remoteSummary: r == null
          ? null
          : (r.isEmpty ? 'nichts gespeichert' : _describe(r.data)),
      localSummary: _describe(readLocal()),
      lastError: _lastError,
    );
  }

  /// Eine ausstehende Änderung wird hier nicht mehr hochgeladen: Sie liegt
  /// lokal und „dirty“ und geht beim nächsten Abgleich mit Prüfung der
  /// Revision nach HA (früher ungeprüft, das überschrieb neuere Stände).
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    info.dispose();
    unawaited(_sub?.cancel());
    _timer?.cancel();
    _timer = null;
  }
}
