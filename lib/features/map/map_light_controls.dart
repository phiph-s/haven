import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/floor_plan.dart';
import '../../data/models/haven_automation.dart';
import '../../data/models/zigbee.dart';
import '../automations/haven_automations_provider.dart';
import '../zigbee/zigbee_providers.dart';

/// Typen, die als Lichtschalter gelten (Drehregler und Taster).
const _kControlTypes = {ZbType.knob, ZbType.remote};

/// Welche platzierten Geräte auf der Kartenart „Licht“ als Schalter erscheinen.
///
/// Ein Gerät zählt, wenn es ein Drehregler oder Taster ist und entweder in
/// einer aktiven Haven-Knob-Automation (`room_knob`) steckt oder Mitglied einer
/// Z2M-Gruppe ist. Der Wert ist der Raumname für den Hinweis.
///
/// Rein, damit sich die Regeln ohne Widgets testen lassen. [roomOf] liefert
/// den Namen des Plan-Raums einer Platzierung (Rückfall, wenn weder
/// Automation noch Gruppe einen Raum nennen).
Map<String, String> lightControlRooms({
  required HavenFloorPlan plan,
  required List<ZbDevice> devices,
  required List<ZbGroup> groups,
  required HavenAutomations? automations,
  String? Function(FloorPlacement p)? roomOf,
}) {
  final byEntity = <String, ZbDevice>{};
  for (final d in devices) {
    if (!_kControlTypes.contains(d.deviceType)) continue;
    for (final e in d.haEntities) {
      byEntity[e] = d;
    }
  }
  final out = <String, String>{};
  for (final p in plan.placements) {
    if (p.resolvedKind == FloorKind.light) continue;
    final d = byEntity[p.entityId];
    if (d == null) continue;
    final auto = automations?.automations
        .where(
          (a) =>
              a.type == 'room_knob' && a.enabled && a.devices.contains(d.ieee),
        )
        .firstOrNull;
    String? room;
    if (auto != null) {
      room = automations!.rooms[auto.roomAreaId]?.name ?? roomOf?.call(p);
    } else {
      final g = groups.where((g) => g.memberIeees.contains(d.ieee)).firstOrNull;
      if (g == null) continue;
      final byGroup = automations?.rooms.values
          .where((r) => r.group == g.friendlyName)
          .firstOrNull;
      room = byGroup?.name ?? roomOf?.call(p) ?? g.friendlyName;
    }
    out[p.entityId] = room ?? d.friendlyName;
  }
  return out;
}

/// Eintrag je platziertem Lichtschalter: Raumname, mit Wertgleichheit.
@immutable
class MapLightControls {
  const MapLightControls(this.rooms);
  final Map<String, String> rooms;

  @override
  bool operator ==(Object other) =>
      other is MapLightControls && mapEquals(other.rooms, rooms);

  @override
  int get hashCode => Object.hashAll(rooms.entries.map((e) => e.key));
}

final mapLightControlsProvider =
    Provider.family<MapLightControls, HavenFloorPlan>((ref, plan) {
      final z = ref.watch(zigbeeProvider.select((z) => (z.devices, z.groups)));
      final auto = ref.watch(havenAutomationsProvider).value;
      return MapLightControls(
        lightControlRooms(
          plan: plan,
          devices: z.$1,
          groups: z.$2,
          automations: auto,
          roomOf: (p) {
            final id = plan.locationOf(p);
            return id == kOutsideId ? null : plan.room(id)?.name;
          },
        ),
      );
    });
