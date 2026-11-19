import 'package:flutter/foundation.dart';

import '../../core/light/color_math.dart';

/// Szene eines Raums. Farben und Helligkeit beschreiben die Karte und die
/// Simulation der Entwicklungsdaten. In HA ruft [entityId] die echte Szene auf.
@immutable
class RoomScene {
  const RoomScene({
    required this.id,
    required this.name,
    required this.colors,
    required this.brightness,
    this.kelvin,
    this.onlyLightIds,
    this.entityId,
    this.groupId,
    this.number,
    this.stored = false,
    this.sync = SceneSync.unknown,
    this.checkedAt,
  });

  final String id;
  final String name;

  /// Drei Kartenfarben. Lampe i bekommt `colors[i mod 3]`.
  final List<Rgb> colors;
  final int brightness;

  /// Weißszene: Farbtemperatur statt Farben.
  final int? kelvin;

  /// Begrenzt die Szene auf diese Lampen, die übrigen gehen aus.
  final List<String>? onlyLightIds;

  /// HA-Szene (`scene.zg...`). In den Entwicklungsdaten erfunden.
  final String? entityId;

  /// Z2M-Gruppe und Szenen-ID in der Gruppe. Damit ruft die Integration
  /// (Feature `scenes`) die Szene auf und Haven kann sie ändern.
  final int? groupId;
  final int? number;

  /// Farben und Helligkeit stammen vom Speichern über Haven (echt), sonst
  /// aus `scene_styles.dart` (erfunden).
  final bool stored;

  /// Stand des Szenen-Abgleichs (Feature `scene_sync` der Integration):
  /// stimmen die Lampen der Gruppe mit dem gespeicherten Soll überein?
  final SceneSync sync;

  /// Letzte Messung der Szene, `null` = nie gemessen.
  final DateTime? checkedAt;

  bool get editable => groupId != null && number != null;

  /// Die Karte zeigt einen Hinweispunkt: neu prüfen bzw. abgleichen.
  bool get needsSync => sync == SceneSync.stale || sync == SceneSync.differs;
}

/// Stand des Abgleichs einer Szene (`sync` in `haven/zigbee/groups`).
enum SceneSync {
  /// Soll vorhanden, letzte Messung passte (oder noch keine).
  ok,

  /// Soll vorhanden, aber Lampen kamen seit dem Soll in die Gruppe oder
  /// gingen: neu abgleichen.
  stale,

  /// Die letzte Messung wich vom Soll ab.
  differs,

  /// Kein Soll (Szene außerhalb von Haven gespeichert).
  unknown;

  static SceneSync parse(Object? v) => switch (v) {
    'ok' => ok,
    'stale' => stale,
    'differs' => differs,
    _ => unknown,
  };
}

/// Bedienelement im Raum: Drehregler (Knob), Taster, Fernbedienung.
@immutable
class RoomControl {
  const RoomControl({
    required this.name,
    this.kind = 'knob',
    this.batteryEntityId,
  });

  final String name;

  /// `knob`, `remote` oder `button`.
  final String kind;
  final String? batteryEntityId;
}

/// Ein Raum. In HA ist das ein Bereich.
@immutable
class Room {
  const Room({
    required this.id,
    required this.name,
    required this.lightIds,
    this.temperatureId,
    this.humidityId,
    this.scenes = const [],
    this.controls = const [],
    this.areaId,
    this.groupEntityId,
    this.lightGroupIds = const [],
    this.zigbeeGroupId,
  });

  final String id;
  final String name;
  final String? areaId;

  /// Lampen des Raums, ohne Lichtgruppen. Ausgenommene Lampen stehen hier
  /// noch drin, `HavenSnapshot.controlledLightIds` filtert sie.
  final List<String> lightIds;

  /// HA-Entity der Z2M-Raumgruppe (`light.zg...`), falls bekannt. Schaltet
  /// die Raumsteuerung alle Mitglieder auf einmal, geht der Befehl an die
  /// Gruppe (ein Zigbee-Befehl statt vieler, kein Nacheinander-Aufleuchten).
  final String? groupEntityId;

  /// ID der Z2M-Raumgruppe, in der die Szenen liegen.
  final int? zigbeeGroupId;

  /// Lichtgruppen im Bereich (HA-Gruppen, Z2M-Gruppen). Nie Lampen.
  final List<String> lightGroupIds;
  final String? temperatureId;
  final String? humidityId;
  final List<RoomScene> scenes;
  final List<RoomControl> controls;

  List<RoomControl> get knobs =>
      controls.where((c) => c.kind == 'knob').toList(growable: false);
}
