import 'models/entity_state.dart';
import 'models/light_groups.dart';
import 'models/room.dart';

/// Ziele für einen Lichtbefehl: Werden alle Mitglieder der Z2M-Raumgruppe
/// geschaltet, geht der Befehl an die Gruppe, die übrigen Lampen einzeln.
///
/// Die Gruppe wird nur genommen, wenn jedes Mitglied eine gesteuerte Lampe
/// genau dieses Raums ist. Enthält sie eine Lampe aus einem anderen Raum
/// (z. B. eine Raumgruppe, in der die Bettlampe aus dem Schlafzimmer steckt) oder ein
/// ausgenommenes Licht, schaltet Haven einzeln, sonst ginge dort etwas mit an.
List<String> lightCallTargets(
  List<String> ids,
  Iterable<Room> rooms,
  Map<String, EntityState> entities, {
  Set<String> excluded = const {},
}) {
  final rest = [...ids];
  final out = <String>[];
  for (final r in rooms) {
    final g = r.groupEntityId;
    if (g == null || entities[g]?.state == 'unavailable') continue;
    final members = lightGroupMembers(entities[g]).toSet();
    if (members.isEmpty) continue;
    final ok = members.every(
      (m) =>
          rest.contains(m) && r.lightIds.contains(m) && !excluded.contains(m),
    );
    if (!ok) continue;
    out.add(g);
    rest.removeWhere(members.contains);
  }
  return [...out, ...rest];
}
