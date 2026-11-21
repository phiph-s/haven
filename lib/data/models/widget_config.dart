import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Typen der Zuhause-Widgets. Neue Typen kommen hier und in
/// features/home/widgets/widget_registry.dart dazu.
enum HavenWidgetType {
  /// Stromverbrauch, entityIds leer = alle Leistungssensoren.
  power,

  /// Beliebiger Schalter, z. B. ein Ventilator. entityIds[0] ist die Entity.
  entityToggle,

  /// Batterien niedrig, entityIds leer = alle Batteriesensoren.
  lowBattery,

  /// Wetter, entityIds[0] ist eine `weather.*`-Entity.
  weather,

  /// Kopf der Seite: Gruß, „Zuhause“, Lichter und Wetter, Knöpfe.
  header,

  /// Hinweise: Verbindung, Entwicklungsdaten, verfügbare Updates.
  notices,

  /// Schnellaktionen: Alles aus und Szenen-Vorschläge.
  scenes,

  /// Ein Raum, `options.room` ist die Raum-ID (siehe [RoomWidgetOptions]).
  room,
}

/// Was ein Raum-Widget zeigt (`options` eines [HavenWidgetType.room]).
abstract final class RoomWidgetOptions {
  static const picture = 'picture';
  static const light = 'light';
  static const scenes = 'scenes';
  static const heat = 'heat';
  static const motion = 'motion';

  /// `compact` (schmal, zwei je Zeile am Handy) oder `detailed`.
  static const size = 'size';

  static const all = [picture, light, scenes, heat, motion];

  static String label(String key) => switch (key) {
    picture => 'Raumbild',
    light => 'Lichtknopf',
    scenes => 'Szenen',
    heat => 'Heizung',
    motion => 'Bewegungslicht',
    _ => key,
  };
}

/// Generisches Widget-Modell: Typ, Entity-IDs und Optionen, lokal gespeichert.
@immutable
class HavenWidgetConfig {
  const HavenWidgetConfig({
    required this.id,
    required this.type,
    this.entityIds = const [],
    this.options = const {},
  });

  factory HavenWidgetConfig.fromJson(Map<String, dynamic> j) =>
      HavenWidgetConfig(
        id: j['id'] as String,
        type: HavenWidgetType.values.firstWhere(
          (t) => t.name == j['type'],
          orElse: () => HavenWidgetType.entityToggle,
        ),
        entityIds: [for (final e in (j['entities'] as List? ?? const [])) '$e'],
        options: Map<String, dynamic>.from(j['options'] as Map? ?? const {}),
      );

  final String id;
  final HavenWidgetType type;
  final List<String> entityIds;
  final Map<String, dynamic> options;

  /// Kann mehr als eine Spalte brauchen: Strom und Wetter sind breit.
  bool get isWide =>
      type == HavenWidgetType.power || type == HavenWidgetType.weather;

  /// Gehört zur Hauptspalte (am Desktop links): Kopf, Hinweise, Szenen,
  /// Räume. Die übrigen sind kleine Karten (Desktop: rechte Spalte).
  bool get isMain => const {
    HavenWidgetType.header,
    HavenWidgetType.notices,
    HavenWidgetType.scenes,
    HavenWidgetType.room,
  }.contains(type);

  /// Raum eines Raum-Widgets.
  String? get roomId =>
      type == HavenWidgetType.room ? options['room'] as String? : null;

  /// Zeigt das Raum-Widget [key] (siehe [RoomWidgetOptions])? Standard: ja.
  bool shows(String key) => options[key] != false;

  /// Raum-Widget schmal (zwei je Zeile am Handy)?
  bool get compact => options[RoomWidgetOptions.size] == 'compact';

  HavenWidgetConfig withOptions(Map<String, dynamic> o) => HavenWidgetConfig(
    id: id,
    type: type,
    entityIds: entityIds,
    options: {...options, ...o},
  );

  static HavenWidgetConfig forRoom(String roomId, {bool compact = false}) =>
      HavenWidgetConfig(
        id: 'room-$roomId',
        type: HavenWidgetType.room,
        options: {
          'room': roomId,
          if (compact) RoomWidgetOptions.size: 'compact',
        },
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'entities': entityIds,
    'options': options,
  };

  static String encodeList(List<HavenWidgetConfig> l) =>
      jsonEncode([for (final w in l) w.toJson()]);

  static List<HavenWidgetConfig> decodeList(String s) => [
    for (final j in jsonDecode(s) as List)
      HavenWidgetConfig.fromJson(Map<String, dynamic>.from(j as Map)),
  ];

  /// Voreinstellung für neue Installationen.
  static const List<HavenWidgetConfig> defaults = [
    HavenWidgetConfig(id: 'power', type: HavenWidgetType.power),
    HavenWidgetConfig(
      id: 'battery',
      type: HavenWidgetType.lowBattery,
      options: {'threshold': 50},
    ),
    // Ohne Entity nimmt das Wetter-Widget die erste `weather.*`-Entity.
    HavenWidgetConfig(id: 'weather', type: HavenWidgetType.weather),
  ];
}
