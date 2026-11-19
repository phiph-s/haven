import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/providers.dart';
import '../../data/models/floor_plan.dart';
import '../../data/models/snapshot.dart';
import 'floor_plan_store.dart';

/// Platzierte Entities, die es in Home Assistant nicht mehr gibt (z. B. das
/// Gerät wurde in Zigbee2MQTT gelöscht): weder unter den Zuständen noch bei
/// einem Gerät der Integration. Nur mit stehender Verbindung und geladenen
/// Zuständen, sonst leer.
Set<String> orphanPlacements(HavenFloorPlan plan, HavenSnapshot snap) {
  if (snap.status != ConnectionStatus.connected || snap.entities.isEmpty) {
    return const {};
  }
  final known = {
    ...snap.entities.keys,
    for (final d in snap.devices) ...d.entityIds,
  };
  return {
    for (final p in plan.placements)
      if (!known.contains(p.entityId)) p.entityId,
  };
}

/// Wie lange eine Entity fehlen muss, bevor ihre Platzierung entfällt. Beim
/// Start von HA oder Zigbee2MQTT fehlen Entities manchmal kurz.
const Duration kOrphanGrace = Duration(seconds: 30);

/// Räumt den Grundriss auf: Platzierungen gelöschter Geräte entfallen, wenn
/// sie [kOrphanGrace] lang durchgehend fehlen. Einmal beobachten genügt
/// (`ref.watch(planCleanupProvider)`).
final planCleanupProvider = Provider<void>((ref) {
  Timer? timer;
  void check() {
    if (timer?.isActive ?? false) return;
    final plan = ref.read(floorPlanProvider).value;
    if (plan == null) return;
    final first = orphanPlacements(plan, ref.read(snapshotProvider));
    if (first.isEmpty) return;
    timer = Timer(kOrphanGrace, () {
      final now = ref.read(floorPlanProvider).value;
      if (now == null) return;
      final gone = orphanPlacements(
        now,
        ref.read(snapshotProvider),
      ).intersection(first);
      if (gone.isEmpty) return;
      var next = now;
      for (final id in gone) {
        next = next.withoutPlacement(id);
      }
      unawaited(ref.read(floorPlanProvider.notifier).save(next));
    });
  }

  ref.listen(snapshotProvider, (_, _) => check());
  ref.listen(floorPlanProvider, (_, _) => check());
  ref.onDispose(() => timer?.cancel());
  check();
});
