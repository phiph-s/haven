import 'entity_state.dart';

/// Lichtgruppen erkennen. Eine Gruppe ist nie eine Lampe: Sie steht nicht in
/// Lampenlisten, Zählern oder „Raum an“. Die Integration filtert ab 0.2.0
/// selbst (`light_groups`), die App prüft trotzdem, weil 0.1.0 Gruppen in
/// `lights` liefert.
///
/// Merkmale (eins reicht):
/// - Attribut `entity_id` als Liste: HA-Lichtgruppe (Plattform `group`,
///   z. B. `light.alle_lampen`).
/// - Attribut `group_entities` als Liste: MQTT-Gruppe, so meldet Z2M seine
///   Gruppen (`light.zg_kueche`).
/// - `is_hue_group`: Raum oder Zone der Hue-Bridge.
/// - Name gleich einer Z2M-Gruppe ([z2mGroupNames], klein geschrieben).
bool isLightGroup(EntityState e, {Set<String> z2mGroupNames = const {}}) {
  if (e.domain != 'light') return false;
  final a = e.attributes;
  if (a['entity_id'] is List) return true;
  if (a['group_entities'] is List) return true;
  if (a['is_hue_group'] == true) return true;
  if (z2mGroupNames.isEmpty) return false;
  final n = (a['friendly_name'] as String?)?.trim().toLowerCase();
  return n != null && z2mGroupNames.contains(n);
}

/// Mitglieder einer Gruppen-Entity (`group_entities` vor `entity_id`).
List<String> lightGroupMembers(EntityState? e) {
  if (e == null) return const [];
  final a = e.attributes;
  final l = a['group_entities'] ?? a['entity_id'];
  return l is List ? [for (final x in l) '$x'] : const [];
}
