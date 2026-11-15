import 'package:flutter/foundation.dart';

import '../../data/models/entity_state.dart';

/// Faltet Umlaute und Groß-/Kleinschreibung, damit "Küche" und "Kuche"
/// (so heißen HA-Entity-IDs) gleich behandelt werden.
String foldText(String s) => s
    .toLowerCase()
    .replaceAll('ä', 'a')
    .replaceAll('ö', 'o')
    .replaceAll('ü', 'u')
    .replaceAll('ß', 'ss');

/// Bekannte Räume und ihre Schreibweisen (gefaltet), falls die Sitzung
/// keinen passenden Raum kennt.
const Map<String, List<String>> _extraRooms = {
  'Wohnzimmer': ['wohnzimmer', 'wohnraum'],
  'Schlafzimmer': ['schlafzimmer'],
  'Küche': ['kuche'],
  'Bad': ['bad', 'badezimmer'],
  'Flur': ['flur', 'diele'],
  'Toilette': ['toilette', 'gaste-wc', 'wc'],
  'Arbeitszimmer': ['arbeitszimmer', 'buro', 'office'],
  'Kinderzimmer': ['kinderzimmer'],
  'Esszimmer': ['esszimmer'],
  'Balkon': ['balkon', 'terrasse'],
  'Keller': ['keller'],
  'Garten': ['garten'],
  'Garage': ['garage'],
};

/// Raum aus dem Namen eines Ablaufs, sonst `null`. [knownRooms] sind die
/// Räume der Sitzung und haben Vorrang. Verglichen wird wortweise, damit
/// "Bad Lüftung" zum Bad gehört, "Badewanne" aber nicht.
String? detectRoom(String name, [Iterable<String> knownRooms = const []]) {
  final words = foldText(name)
      .split(RegExp(r'[^a-z0-9-]+'))
      .where((w) => w.isNotEmpty)
      .toSet();
  if (words.isEmpty) return null;
  for (final r in knownRooms) {
    if (words.contains(foldText(r))) return r;
  }
  for (final e in _extraRooms.entries) {
    if (e.value.any(words.contains)) return e.key;
  }
  return null;
}

/// Lesbarer Name: `sun_motion1` wird zu "Sun motion1",
/// normale Namen bleiben unverändert.
String prettyName(String raw) {
  var n = raw.trim();
  if (n.isEmpty) return n;
  if (!n.contains(' ') && n.contains('_')) {
    n = n.replaceAll(RegExp(r'_+'), ' ').trim();
  }
  return n[0].toUpperCase() + n.substring(1);
}

/// Relative Zeit auf Deutsch: "gerade eben", "vor 5 Min", "gestern".
String relativeTime(DateTime? t, DateTime now) {
  if (t == null) return 'noch nie ausgelöst';
  final d = now.difference(t);
  if (d.isNegative || d.inSeconds < 60) return 'gerade eben';
  if (d.inMinutes < 60) return 'vor ${d.inMinutes} Min';
  if (d.inHours < 24) return 'vor ${d.inHours} Std';
  if (d.inHours < 48) return 'gestern';
  if (d.inDays < 14) return 'vor ${d.inDays} Tagen';
  if (d.inDays < 60) return 'vor ${d.inDays ~/ 7} Wochen';
  return 'vor ${d.inDays ~/ 30} Monaten';
}

/// Ein Ablauf (Automation) für die Oberfläche.
@immutable
class AutomationItem {
  const AutomationItem({
    required this.entityId,
    required this.name,
    required this.on,
    this.lastTriggered,
    this.configId,
    this.room,
    this.available = true,
  });

  factory AutomationItem.fromEntity(
    EntityState e, {
    Iterable<String> knownRooms = const [],
  }) {
    final raw = e.attributes['last_triggered'];
    return AutomationItem(
      entityId: e.entityId,
      name: prettyName(e.name),
      on: e.isOn,
      available: e.state != 'unavailable',
      lastTriggered: raw is String ? DateTime.tryParse(raw)?.toLocal() : null,
      configId: e.attributes['id']?.toString(),
      room: detectRoom(e.name, knownRooms),
    );
  }

  final String entityId;
  final String name;
  final bool on;
  final bool available;
  final DateTime? lastTriggered;

  /// `id` aus der Automationskonfiguration, Teil der HA-Editor-URL.
  final String? configId;
  final String? room;

  AutomationItem withOn(bool v) => AutomationItem(
    entityId: entityId,
    name: name,
    on: v,
    available: available,
    lastTriggered: lastTriggered,
    configId: configId,
    room: room,
  );

  /// Pfad im HA-Frontend zum Bearbeiten.
  String get editPath => configId == null
      ? '/config/automation/dashboard'
      : '/config/automation/edit/$configId';

  /// Pfad zur Trace-Seite ("Verlauf").
  String get tracePath => configId == null
      ? '/config/automation/dashboard'
      : '/config/automation/trace/$configId';

  @override
  bool operator ==(Object other) =>
      other is AutomationItem &&
      other.entityId == entityId &&
      other.name == name &&
      other.on == on &&
      other.available == available &&
      other.lastTriggered == lastTriggered &&
      other.configId == configId &&
      other.room == room;

  @override
  int get hashCode => Object.hash(entityId, name, on, lastTriggered, room);
}

/// Gruppiert nach Raum. Reihenfolge: Räume nach [roomOrder], dann übrige
/// Räume alphabetisch, "Allgemein" zuletzt. Innerhalb nach Name.
List<(String, List<AutomationItem>)> groupByRoom(
  Iterable<AutomationItem> items, {
  List<String> roomOrder = const [],
}) {
  final map = <String, List<AutomationItem>>{};
  for (final a in items) {
    (map[a.room ?? 'Allgemein'] ??= []).add(a);
  }
  int rank(String r) {
    if (r == 'Allgemein') return 1 << 20;
    final i = roomOrder.indexOf(r);
    return i < 0 ? 1000 : i;
  }

  final keys = map.keys.toList()
    ..sort((a, b) {
      final c = rank(a).compareTo(rank(b));
      return c != 0 ? c : a.compareTo(b);
    });
  return [
    for (final k in keys)
      (
        k,
        map[k]!..sort((a, b) => foldText(a.name).compareTo(foldText(b.name))),
      ),
  ];
}

/// Symbol-Schlüssel aus dem Namen. Die Oberfläche ordnet ein Icon zu.
String automationKind(String name) {
  final n = foldText(name);
  if (n.contains('bewegung')) return 'motion';
  if (n.contains('knopf') || n.contains('knob')) return 'knob';
  if (n.contains('luftung') || n.contains('lüftung')) return 'fan';
  if (n.contains('feucht')) return 'humidity';
  if (n.contains('sun') || n.contains('sonne')) return 'sun';
  if (n.contains('neustart')) return 'restart';
  if (n.contains('display') || n.contains('dashboard')) return 'screen';
  if (n.contains('warn')) return 'warning';
  return 'auto';
}
