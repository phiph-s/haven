import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/state/providers.dart';
import '../../data/haven_repository.dart';
import '../../data/models/floor_plan.dart';
import '../../data/sync/app_data.dart';
import '../../data/sync/doc_sync.dart';

/// Lokaler Cache des Grundriss-Dokuments (pro Haus eines). Die Quelle der
/// Wahrheit liegt in HA (`haven/floorplan/get|set`), [FloorPlanNotifier]
/// gleicht über `DocSync` ab.
abstract class FloorPlanRepository {
  /// `null`, wenn noch nie gespeichert wurde.
  Future<HavenFloorPlan?> load();
  Future<void> save(HavenFloorPlan plan);
  Future<void> clear();
}

/// Lokal in den SharedPreferences.
class LocalFloorPlanRepository implements FloorPlanRepository {
  static const key = 'floor_plan_v1';

  @override
  Future<HavenFloorPlan?> load() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(key);
    if (s == null) return null;
    try {
      final plan = HavenFloorPlan.decode(s);
      return plan.isValid ? plan : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(HavenFloorPlan plan) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(key, plan.encode());
  }

  @override
  Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(key);
  }
}

final floorPlanRepositoryProvider = Provider<FloorPlanRepository>(
  (ref) => LocalFloorPlanRepository(),
);

/// Lädt und speichert den Grundriss. `null` heißt: kein Grundriss. In den
/// Entwicklungsdaten gilt ohne gespeicherten Stand [HavenRepository.sampleFloorPlan].
///
/// Start mit dem lokalen Cache (sofort, auch offline), danach Abgleich mit HA:
/// Server leer und lokal etwas da: hochladen (Migration). Sonst gilt die
/// neuere Fassung (`updatedAt`). Jede Änderung geht 800 ms nach der letzten
/// an HA. Andere Geräte laden nach dem Ereignis `haven_data_updated` neu.
class FloorPlanNotifier extends AsyncNotifier<HavenFloorPlan?> {
  HavenFloorPlan? _local;
  DocSync? _sync;

  @override
  Future<HavenFloorPlan?> build() async {
    final repo = ref.watch(sessionProvider.select((s) => s.repo));
    final cache = ref.read(floorPlanRepositoryProvider);
    _local = await cache.load();
    if (repo != null) {
      final sync = DocSync(
        kind: AppDataKind.floorplan,
        repo: repo,
        store: ref.read(settingsStoreProvider),
        debounce: repo.isFake
            ? Duration.zero
            : const Duration(milliseconds: 800),
        readLocal: () => _local == null ? null : {'plan': _local!.toJson()},
        applyRemote: (data) async {
          final HavenFloorPlan plan;
          try {
            plan = HavenFloorPlan.fromJson(
              Map<String, dynamic>.from(data['plan'] as Map),
            );
          } catch (_) {
            return false;
          }
          if (!plan.isValid) return false;
          _local = plan;
          await cache.save(plan);
          state = AsyncData(plan);
          return true;
        },
        onError: (m) => ref.read(syncNoticeProvider.notifier).show(m),
      );
      _sync = sync;
      ref.onDispose(sync.dispose);
      sync.start();
    }
    return _local ?? repo?.sampleFloorPlan;
  }

  /// Setzt den Stand sofort, legt ihn lokal ab und speichert entprellt in HA.
  Future<void> save(HavenFloorPlan plan) async {
    state = AsyncData(plan);
    _local = plan;
    await ref.read(floorPlanRepositoryProvider).save(plan);
    await _sync?.changed();
  }

  /// Verwirft den lokalen Stand: die Entwicklungsdaten kehren zum Beispiel
  /// zurück, sonst gilt beim nächsten Abgleich wieder der Stand aus HA.
  Future<void> reset() async {
    await ref.read(floorPlanRepositoryProvider).clear();
    await ref
        .read(settingsStoreProvider)
        .setSync(AppDataKind.floorplan.name, dirty: false);
    ref.invalidateSelf();
    await future;
  }
}

final floorPlanProvider =
    AsyncNotifierProvider<FloorPlanNotifier, HavenFloorPlan?>(
      FloorPlanNotifier.new,
    );
