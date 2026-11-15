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
