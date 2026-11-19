import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/models/entity_state.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/data/models/snapshot.dart';
import 'package:haven/features/map/plan_cleanup.dart';

void main() {
  HavenFloorPlan plan(List<String> ids) => HavenFloorPlan(
    placements: [
      for (final (i, id) in ids.indexed)
        FloorPlacement(entityId: id, x: i, y: 0),
    ],
  );

  test('Gelöschte Entities: Platzierung verwaist', () {
    final snap = HavenSnapshot(
      status: ConnectionStatus.connected,
      entities: {'light.da': const EntityState('light.da', 'on')},
    );
    expect(orphanPlacements(plan(['light.da', 'light.weg']), snap), {
      'light.weg',
    });
  });

  test('Ohne Verbindung oder ohne Zustände wird nichts entfernt', () {
    final p = plan(['light.weg']);
    expect(orphanPlacements(p, const HavenSnapshot()), isEmpty);
    expect(
      orphanPlacements(
        p,
        const HavenSnapshot(status: ConnectionStatus.connected),
      ),
      isEmpty,
    );
  });
}
