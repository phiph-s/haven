import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/providers.dart';
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
    this.error,
  });

  final ZbNetworkMap? map;
  final bool loaded;

  /// „Netz neu messen“ läuft.
  final bool refreshing;
  final String? error;

  MeshData copyWith({
    ZbNetworkMap? map,
    bool? loaded,
    bool? refreshing,
    String? error,
    bool clearError = false,
  }) => MeshData(
    map: map ?? this.map,
    loaded: loaded ?? this.loaded,
    refreshing: refreshing ?? this.refreshing,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Lädt die zwischengespeicherte Netzkarte und misst auf Wunsch neu.
class MeshNotifier extends Notifier<MeshData> {
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
      state = state.copyWith(loaded: true, error: '$e');
    }
  }

  /// Misst neu (`refresh: true`). Dauert bis zu einer Minute. Gibt die
  /// Fehlermeldung zurück oder `null`.
  Future<String?> refresh() async {
    if (state.refreshing) return null;
    state = state.copyWith(refreshing: true, clearError: true);
    try {
      final m = await ref
          .read(repositoryProvider)
          .zigbeeNetworkMap(refresh: true);
      state = state.copyWith(map: m, refreshing: false, loaded: true);
      return null;
    } catch (e) {
      state = state.copyWith(refreshing: false, error: '$e');
      return '$e';
    }
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
