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
  });

  final ZbNetworkMap? map;
  final bool loaded;

  /// „Netz neu messen“ läuft.
  final bool refreshing;

  /// Beginn der laufenden Messung (für den Fortschritt).
  final DateTime? refreshStarted;
  final String? error;

  MeshData copyWith({
    ZbNetworkMap? map,
    bool? loaded,
    bool? refreshing,
    DateTime? refreshStarted,
    String? error,
    bool clearError = false,
  }) => MeshData(
    map: map ?? this.map,
    loaded: loaded ?? this.loaded,
    refreshing: refreshing ?? this.refreshing,
    refreshStarted: (refreshing ?? this.refreshing)
        ? (refreshStarted ?? this.refreshStarted)
        : null,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Verständlicher Text zu einem Fehler beim Laden oder Messen der
/// Netzkarte, nach Ursache getrennt.
String meshErrorText(Object e, {bool refresh = false}) {
  final code = e is HavenException ? e.code : null;
  return switch (code) {
    'timeout' when refresh => 'Die Messung hat zu lange gedauert. Zigbee2MQTT misst vielleicht noch, versuch es in einer Minute noch einmal.',
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

/// Lädt beim Öffnen die zwischengespeicherte Netzkarte (`refresh: false`,
/// sofort) und misst auf Wunsch neu (`refresh: true`, bis zu 90 s).
class MeshNotifier extends Notifier<MeshData> {
  int _run = 0;

  @override
  MeshData build() {
    Future.microtask(load);
    return const MeshData();
  }

  Future<void> load() async {
    try {
      final m = await ref.read(repositoryProvider).zigbeeNetworkMap();
      state = state.copyWith(map: m, loaded: true, clearError: true);
    } catch (e) {
      state = state.copyWith(loaded: true, error: meshErrorText(e));
    }
  }

  /// Misst neu (`refresh: true`). Gibt die Fehlermeldung zurück, `null` bei
  /// Erfolg oder wenn abgebrochen wurde.
  Future<String?> refresh() async {
    if (state.refreshing) return null;
    final run = ++_run;
    state = state.copyWith(
      refreshing: true,
      refreshStarted: DateTime.now(),
      clearError: true,
    );
    try {
      final m = await ref
          .read(repositoryProvider)
          .zigbeeNetworkMap(refresh: true);
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
      final msg = meshErrorText(e, refresh: true);
      state = state.copyWith(refreshing: false, loaded: true, error: msg);
      return msg;
    }
  }

  /// Nicht mehr warten. Die Messung in Zigbee2MQTT läuft weiter, ein
  /// späteres Ergebnis wird still übernommen.
  void cancel() {
    if (!state.refreshing) return;
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
