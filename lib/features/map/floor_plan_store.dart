import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/state/providers.dart';
import '../../data/models/floor_plan.dart';

/// Ablage des Grundriss-Dokuments (pro Haus eines).
///
/// TODO(haven-integration): Implementierung gegen die Haven-Integration in HA
/// (`.storage`, WebSocket `haven/floorplan/get` und `haven/floorplan/set`)
/// ergänzen und im Provider tauschen. Bis dahin liegt der Grundriss lokal.
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
class FloorPlanNotifier extends AsyncNotifier<HavenFloorPlan?> {
  @override
  Future<HavenFloorPlan?> build() async {
    final saved = await ref.read(floorPlanRepositoryProvider).load();
    if (saved != null) return saved;
    return ref.read(sessionProvider).repo?.sampleFloorPlan;
  }

  /// Setzt den Stand sofort und speichert danach.
  Future<void> save(HavenFloorPlan plan) async {
    state = AsyncData(plan);
    await ref.read(floorPlanRepositoryProvider).save(plan);
  }

  /// Verwirft den gespeicherten Stand: die Entwicklungsdaten kehren zum Beispiel
  /// zurück, sonst gibt es keinen Grundriss.
  Future<void> reset() async {
    await ref.read(floorPlanRepositoryProvider).clear();
    ref.invalidateSelf();
    await future;
  }
}

final floorPlanProvider =
    AsyncNotifierProvider<FloorPlanNotifier, HavenFloorPlan?>(
      FloorPlanNotifier.new,
    );
