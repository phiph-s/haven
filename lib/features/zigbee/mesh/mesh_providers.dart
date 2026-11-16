import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/providers.dart';
import '../../../data/haven_repository.dart';
import '../../../data/models/zigbee_network.dart';
import '../../map/floor_plan_store.dart';
import '../zigbee_providers.dart';
import 'mesh_scene.dart';

/// Stand der Netzkarte (`haven/zigbee/networkmap`).
class MeshData {
  const MeshData({
    this.map,
    this.loaded = false,
    this.refreshing = false,
    this.refreshStarted,
    this.error,
    this.legacy = false,
    this.notice,
    this.noticeId = 0,
  });

  final ZbNetworkMap? map;
  final bool loaded;

  /// „Netz neu messen“ läuft (in der Integration oder, bei `legacy`, als
  /// offene Anfrage).
  final bool refreshing;

  /// Beginn der laufenden Messung (für die Uhr).
  final DateTime? refreshStarted;
  final String? error;

  /// Die Integration ist älter als 0.5.1 und kann nicht im Hintergrund
  /// messen: Die App wartet höchstens 120 s auf die offene Anfrage.
  final bool legacy;

  /// Kurze Meldung nach einer fertigen Messung. Neu, wenn [noticeId] steigt.
  final String? notice;
  final int noticeId;

  MeshData copyWith({
    ZbNetworkMap? map,
    bool? loaded,
    bool? refreshing,
    DateTime? refreshStarted,
    String? error,
    bool clearError = false,
    bool? legacy,
    String? notice,
  }) => MeshData(
    map: map ?? this.map,
    loaded: loaded ?? this.loaded,
    refreshing: refreshing ?? this.refreshing,
    refreshStarted: (refreshing ?? this.refreshing)
        ? (refreshStarted ?? this.refreshStarted)
        : null,
    error: clearError ? null : (error ?? this.error),
    legacy: legacy ?? this.legacy,
    notice: notice ?? this.notice,
    noticeId: notice == null ? noticeId : noticeId + 1,
  );
}

/// Hinweis bei einer Integration vor 0.5.1.
const meshLegacyHint = 'Integration aktualisieren für lange Messungen';

/// „1:20“ bzw. „1:02:03“ für die laufende Uhr der Messung.
String meshElapsedLabel(Duration d) {
  final s = d.isNegative ? 0 : d.inSeconds;
  final h = s ~/ 3600, m = s % 3600 ~/ 60, sec = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '$m:${two(sec)}';
}

/// „Stand von heute 14:32“ bzw. „Stand von 15.11. 09:05“ für den alten Cache.
String meshStandLabel(DateTime t, [DateTime? now]) {
  final l = t.toLocal(), n = (now ?? DateTime.now()).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final time = '${two(l.hour)}:${two(l.minute)}';
  final today = l.year == n.year && l.month == n.month && l.day == n.day;
  return today
      ? 'Stand von heute $time'
      : 'Stand von ${two(l.day)}.${two(l.month)}. $time';
}

/// Meldung nach einer fertigen Messung.
String meshDoneText(ZbNetworkMap m) {
  final n = m.nodes.where((n) => !n.isCoordinator).length;
  return 'Netz gemessen, $n ${n == 1 ? 'Gerät' : 'Geräte'}';
}

/// Fehlertext der Integration für die Anzeige.
String meshFailedText(String? error, {bool last = false}) =>
    '${last ? 'Letzte Messung' : 'Messung'} fehlgeschlagen. '
    '${error ?? 'Unbekannter Fehler'}';

/// Verständlicher Text zu einem Fehler beim Laden oder Messen der
/// Netzkarte, nach Ursache getrennt.
String meshErrorText(Object e, {bool refresh = false, bool legacy = false}) {
  final code = e is HavenException ? e.code : null;
  return switch (code) {
    'timeout' when refresh && legacy =>
      'Die Messung hat zu lange gedauert. Zigbee2MQTT misst vielleicht noch, versuch es in einer Minute noch einmal. $meshLegacyHint.',
    'timeout' when refresh =>
      'Die Messung hat zu lange gedauert. Zigbee2MQTT misst vielleicht noch, versuch es in einer Minute noch einmal.',
    'timeout' => 'Home Assistant antwortet gerade nicht.',
    'bridge_offline' =>
      'Zigbee2MQTT ist offline. Prüfe das Add-on in Home Assistant.',
    'mqtt_error' => 'Home Assistant erreicht MQTT gerade nicht.',
    'unauthorized' =>
      'Neu messen geht nur mit einem Administrator-Konto in Home Assistant.',
    'busy' => 'Es läuft schon eine Messung. Warte einen Moment.',
    'disconnected' => 'Keine Verbindung zu Home Assistant.',
    'unknown_command' || 'not_found' => 'Die Haven-Integration in Home Assistant kennt die Netzkarte noch nicht. Aktualisiere sie.',
    'z2m_error' =>
      'Zigbee2MQTT hat die Messung abgelehnt: ${e is HavenException ? e.message : e}',
    _ =>
      refresh
          ? 'Die Messung hat nicht geklappt. $e'
          : 'Die Netzkarte lädt gerade nicht. $e',
  };
}

/// Abstand der Abfragen als Rückfall, falls das Ereignis ausbleibt.
final meshPollIntervalProvider = Provider<Duration>(
  (_) => const Duration(seconds: 15),
);

/// Lädt beim Öffnen die zwischengespeicherte Netzkarte (`refresh: false`,
/// sofort, samt `running` der Integration) und startet auf Wunsch eine
/// Messung im Hintergrund (Integration ab 0.5.1). Das Ende kommt als
/// Ereignis, zusätzlich fragt die App alle 15 s nach. Ältere Integrationen
/// messen blockierend, die App wartet dann bis zu 120 s.
class MeshNotifier extends Notifier<MeshData> {
  int _run = 0;
  int _gen = 0;
  Timer? _poll;
  StreamSubscription<ZbMeasureResult>? _sub;

  @override
  MeshData build() {
    _sub = ref.read(repositoryProvider).zigbeeMeasureResults.listen(_onResult);
    ref.onDispose(() {
      _poll?.cancel();
      _sub?.cancel();
    });
    Future.microtask(load);
    return const MeshData();
  }

  bool get _watching => state.refreshing && !state.legacy;

  void _startPoll() {
    _poll?.cancel();
    _poll = Timer.periodic(ref.read(meshPollIntervalProvider), (_) {
      if (_watching) {
        load();
      } else {
        _poll?.cancel();
      }
    });
  }

  void _stopPoll() {
    _poll?.cancel();
    _poll = null;
  }

  Future<void> load() async {
    final gen = _gen;
    try {
      final m = await ref.read(repositoryProvider).zigbeeNetworkMap();
      if (gen != _gen) return; // Inzwischen wurde eine Messung gestartet.
      final st = m.status;
      if (st.running) {
        state = state.copyWith(
          map: m,
          loaded: true,
          refreshing: true,
          refreshStarted: st.startedAt ?? DateTime.now(),
          legacy: false,
          clearError: true,
        );
        if (_poll == null) _startPoll();
      } else if (_watching) {
        _finish(m);
      } else {
        state = state.copyWith(
          map: m,
          loaded: true,
          error: st.lastError == null
              ? null
              : meshFailedText(st.lastError, last: true),
          clearError: st.lastError == null,
        );
      }
    } catch (e) {
      if (gen != _gen) return;
      state = state.copyWith(loaded: true, error: meshErrorText(e));
    }
  }

  /// Die beobachtete Messung ist zu Ende (erkannt per Abfrage).
  void _finish(ZbNetworkMap m) {
    _stopPoll();
    final err = m.status.lastError;
    state = state.copyWith(
      map: m,
      loaded: true,
      refreshing: false,
      error: err == null ? null : meshFailedText(err),
      clearError: err == null,
      notice: err == null ? meshDoneText(m) : null,
    );
  }

  Future<void> _onResult(ZbMeasureResult r) async {
    if (!_watching) {
      // Eine Messung eines anderen Geräts: Karte still aktualisieren.
      if (r.ok) await load();
      return;
    }
    if (r.ok) {
      _stopPoll();
      final gen = _gen;
      try {
        final m = await ref.read(repositoryProvider).zigbeeNetworkMap();
        if (gen != _gen || !_watching) return;
        _finish(m);
      } catch (e) {
        if (gen != _gen) return;
        state = state.copyWith(
          refreshing: false,
          error: meshErrorText(e),
        );
      }
    } else {
      _stopPoll();
      state = state.copyWith(
        refreshing: false,
        error: meshFailedText(r.error),
      );
    }
  }

  /// Misst neu. Mit Integration ab 0.5.1 im Hintergrund (Rückgabe sofort),
  /// sonst blockierend bis zu 120 s. Gibt die Fehlermeldung zurück, `null`
  /// bei Erfolg oder wenn abgebrochen wurde.
  Future<String?> refresh() async {
    if (state.refreshing) return null;
    final repo = ref.read(repositoryProvider);
    final run = ++_run;
    _gen++;
    if (repo.zigbeeBackgroundMeasure) {
      state = state.copyWith(
        refreshing: true,
        refreshStarted: DateTime.now(),
        legacy: false,
        clearError: true,
      );
      try {
        final s = await repo.zigbeeStartNetworkMeasure();
        if (s.alreadyRunning && s.startedAt != null) {
          state = state.copyWith(refreshStarted: s.startedAt);
        }
        _startPoll();
        return null;
      } catch (e) {
        final msg = meshErrorText(e, refresh: true);
        state = state.copyWith(refreshing: false, loaded: true, error: msg);
        return msg;
      }
    }
    state = state.copyWith(
      refreshing: true,
      refreshStarted: DateTime.now(),
      legacy: true,
      clearError: true,
    );
    try {
      final m = await repo.zigbeeNetworkMap(refresh: true);
      // Auch nach „Abbrechen“ übernehmen: Die Messung lief ja weiter.
      if (!m.isEmpty || run == _run) {
        state = state.copyWith(
          map: m,
          loaded: true,
          refreshing: run == _run ? false : null,
        );
      }
      return null;
    } catch (e) {
      if (run != _run) return null;
      final msg = meshErrorText(e, refresh: true, legacy: true);
      state = state.copyWith(refreshing: false, loaded: true, error: msg);
      return msg;
    }
  }

  /// Nicht mehr warten (nur bei älterer Integration). Die Messung in
  /// Zigbee2MQTT läuft weiter, ein späteres Ergebnis wird still übernommen.
  void cancel() {
    if (!state.refreshing || !state.legacy) return;
    _run++;
    state = state.copyWith(refreshing: false);
  }
}

final zigbeeMeshProvider = NotifierProvider<MeshNotifier, MeshData>(
  MeshNotifier.new,
);

/// Szene für Graph und Miniatur. `null`, solange Karte oder Grundriss laden
/// oder die Karte leer ist.
final meshSceneProvider = Provider<MeshScene?>((ref) {
  final map = ref.watch(zigbeeMeshProvider.select((d) => d.map));
  final views = ref.watch(zigbeeViewsProvider);
  final plan = ref.watch(floorPlanProvider);
  if (map == null || map.isEmpty || plan.isLoading && !plan.hasValue) {
    return null;
  }
  return buildMeshScene(map: map, views: views, plan: plan.value);
});
