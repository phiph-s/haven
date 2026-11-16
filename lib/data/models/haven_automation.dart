import 'package:flutter/foundation.dart';

/// Haven-Automationen: Abläufe, die direkt in der Integration laufen
/// (`haven/automations/*`, siehe `integration/README.md`). Bisher gibt es den
/// Typ `room_knob`: Drehregler und Taster steuern das Licht eines Raums.

/// Gesten eines Drehreglers bzw. Tasters.
enum KnobGesture {
  rotate('rotate'),
  single('single'),
  double('double'),
  hold('hold');

  const KnobGesture(this.wire);
  final String wire;

  static KnobGesture? parse(Object? v) {
    for (final g in values) {
      if (g.wire == v) return g;
    }
    return null;
  }
}

/// Was eine Geste tut.
enum GestureAction {
  none('none'),
  brightness('brightness'),
  toggle('toggle'),
  nextScene('next_scene'),
  scene('scene'),
  off('off');

  const GestureAction(this.wire);
  final String wire;

  static GestureAction parse(Object? v) {
    for (final a in values) {
      if (a.wire == v) return a;
    }
    return GestureAction.none;
  }

  /// Erlaubte Aktionen je Geste.
  static List<GestureAction> forGesture(KnobGesture g) =>
      g == KnobGesture.rotate
      ? const [GestureAction.brightness, GestureAction.none]
      : const [
          GestureAction.toggle,
          GestureAction.nextScene,
          GestureAction.scene,
          GestureAction.off,
          GestureAction.none,
        ];
}

@immutable
class GestureBinding {
  const GestureBinding(this.action, {this.scene});
  final GestureAction action;

  /// Szenen-ID der Z2M-Gruppe bei [GestureAction.scene].
  final int? scene;

  factory GestureBinding.fromJson(Object? j) {
    if (j is String) return GestureBinding(GestureAction.parse(j));
    if (j is Map) {
      final s = j['scene'];
      return GestureBinding(
        GestureAction.parse(j['action']),
        scene: s is num ? s.toInt() : null,
      );
    }
    return const GestureBinding(GestureAction.none);
  }

  Map<String, dynamic> toJson() => {
    'action': action.wire,
    if (action == GestureAction.scene) 'scene': scene,
  };

  @override
  bool operator ==(Object other) =>
      other is GestureBinding && other.action == action && other.scene == scene;

  @override
  int get hashCode => Object.hash(action, scene);
}

/// Standardbelegung wie bisher in den HA-Automationen.
const Map<KnobGesture, GestureBinding> kDefaultGestures = {
  KnobGesture.rotate: GestureBinding(GestureAction.brightness),
  KnobGesture.single: GestureBinding(GestureAction.toggle),
  KnobGesture.double: GestureBinding(GestureAction.nextScene),
  KnobGesture.hold: GestureBinding(GestureAction.none),
};

const kDefaultStep = 35;
const kDefaultTransition = 0.2;
const kDefaultMinBrightness = 3;

/// Optionen von `room_knob`.
@immutable
class KnobOptions {
  const KnobOptions({
    this.gestures = kDefaultGestures,
    this.scenes,
    this.onScene,
    this.step = kDefaultStep,
    this.transition = kDefaultTransition,
    this.minBrightness = kDefaultMinBrightness,
    this.offAtMin = false,
    this.extra = const {},
  });

  final Map<KnobGesture, GestureBinding> gestures;

  /// Szenen-IDs in Umlauf-Reihenfolge, `null` = alle der Gruppe.
  final List<int>? scenes;

  /// „Beim Einschalten“: `null` = zuletzt, sonst diese Szene.
  final int? onScene;

  /// Schrittweite von 255.
  final int step;
  final double transition;
  final int minBrightness;
  final bool offAtMin;

  /// Unbekannte Schlüssel (neuere Integration), bleiben beim Speichern erhalten.
  final Map<String, dynamic> extra;

  GestureBinding binding(KnobGesture g) => gestures[g] ?? kDefaultGestures[g]!;

  static const _known = {
    'gestures',
    'scenes',
    'on_action',
    'on_scene',
    'step',
    'transition',
    'min_brightness',
    'off_at_min',
  };

  factory KnobOptions.fromJson(Object? raw) {
    final j = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final g = j['gestures'] is Map ? j['gestures'] as Map : const {};
    final scenes = j['scenes'];
    final onScene = j['on_scene'];
    num? n(String k) => j[k] is num ? j[k] as num : null;
    return KnobOptions(
      gestures: {
        for (final k in KnobGesture.values)
          k: g.containsKey(k.wire)
              ? GestureBinding.fromJson(g[k.wire])
              : kDefaultGestures[k]!,
      },
      scenes: scenes is List
          ? [
              for (final s in scenes)
                if (s is num) s.toInt(),
            ]
          : null,
      onScene: j['on_action'] == 'scene' && onScene is num
          ? onScene.toInt()
          : null,
      step: n('step')?.toInt() ?? kDefaultStep,
      transition: n('transition')?.toDouble() ?? kDefaultTransition,
      minBrightness: n('min_brightness')?.toInt() ?? kDefaultMinBrightness,
      offAtMin: j['off_at_min'] == true,
      extra: {
        for (final e in j.entries)
          if (!_known.contains(e.key)) e.key: e.value,
      },
    );
  }

  Map<String, dynamic> toJson() => {
    ...extra,
    'gestures': {
      for (final k in KnobGesture.values) k.wire: binding(k).toJson(),
    },
    'scenes': scenes,
    'on_action': onScene == null ? 'last' : 'scene',
    'on_scene': onScene,
    'step': step,
    'transition': transition,
    'min_brightness': minBrightness,
    'off_at_min': offAtMin,
  };

  KnobOptions copyWith({
    Map<KnobGesture, GestureBinding>? gestures,
    List<int>? scenes,
    bool clearScenes = false,
    int? onScene,
    bool clearOnScene = false,
    int? step,
    double? transition,
    int? minBrightness,
    bool? offAtMin,
  }) => KnobOptions(
    gestures: gestures ?? this.gestures,
    scenes: clearScenes ? null : (scenes ?? this.scenes),
    onScene: clearOnScene ? null : (onScene ?? this.onScene),
    step: step ?? this.step,
    transition: transition ?? this.transition,
    minBrightness: minBrightness ?? this.minBrightness,
    offAtMin: offAtMin ?? this.offAtMin,
    extra: extra,
  );

  KnobOptions withBinding(KnobGesture g, GestureBinding b) =>
      copyWith(gestures: {...gestures, g: b});

  @override
  bool operator ==(Object other) =>
      other is KnobOptions &&
      mapEquals(other.gestures, gestures) &&
      listEquals(other.scenes, scenes) &&
      other.onScene == onScene &&
      other.step == step &&
      other.transition == transition &&
      other.minBrightness == minBrightness &&
      other.offAtMin == offAtMin &&
      mapEquals(other.extra, extra);

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(
      gestures.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    scenes == null ? null : Object.hashAll(scenes!),
    onScene,
    step,
    transition,
    minBrightness,
    offAtMin,
  );
}

/// Letzte Auslösung einer Automation.
@immutable
class AutomationFired {
  const AutomationFired(this.at, this.action);
  final DateTime at;

  /// `rotate_left`, `rotate_right`, `single`, `double`, `hold`.
  final String action;

  static AutomationFired? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse('${j['at']}');
    if (at == null) return null;
    return AutomationFired(at.toLocal(), '${j['action'] ?? ''}');
  }

  Map<String, dynamic> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'action': action,
  };

  @override
  bool operator ==(Object other) =>
      other is AutomationFired && other.at == at && other.action == action;

  @override
  int get hashCode => Object.hash(at, action);
}

/// Eine Haven-Automation. [id] ist `null`, solange sie nicht gespeichert ist.
@immutable
class HavenAutomation {
  const HavenAutomation({
    this.id,
    this.type = 'room_knob',
    required this.name,
    this.enabled = true,
    required this.roomAreaId,
    this.devices = const [],
    this.options = const KnobOptions(),
    this.lastTriggered,
  });

  final String? id;
  final String type;
  final String name;
  final bool enabled;
  final String roomAreaId;

  /// IEEE-Adressen der Drehregler und Taster.
  final List<String> devices;
  final KnobOptions options;
  final AutomationFired? lastTriggered;

  factory HavenAutomation.fromJson(Map<String, dynamic> j) => HavenAutomation(
    id: j['id'] as String?,
    type: (j['type'] as String?) ?? 'room_knob',
    name: (j['name'] as String?) ?? '',
    enabled: j['enabled'] != false,
    roomAreaId: (j['room_area_id'] as String?) ?? '',
    devices: [for (final d in (j['devices'] as List? ?? const [])) '$d'],
    options: KnobOptions.fromJson(j['options']),
    lastTriggered: AutomationFired.fromJson(j['last_triggered']),
  );

  /// Für `haven/automations/set` (ohne `last_triggered`).
  Map<String, dynamic> toJson() => {
    'id': ?id,
    'type': type,
    'name': name,
    'enabled': enabled,
    'room_area_id': roomAreaId,
    'devices': devices,
    'options': options.toJson(),
  };

  HavenAutomation copyWith({
    String? id,
    String? name,
    bool? enabled,
    String? roomAreaId,
    List<String>? devices,
    KnobOptions? options,
    AutomationFired? lastTriggered,
  }) => HavenAutomation(
    id: id ?? this.id,
    type: type,
    name: name ?? this.name,
    enabled: enabled ?? this.enabled,
    roomAreaId: roomAreaId ?? this.roomAreaId,
    devices: devices ?? this.devices,
    options: options ?? this.options,
    lastTriggered: lastTriggered ?? this.lastTriggered,
  );

  @override
  bool operator ==(Object other) =>
      other is HavenAutomation &&
      other.id == id &&
      other.type == type &&
      other.name == name &&
      other.enabled == enabled &&
      other.roomAreaId == roomAreaId &&
      listEquals(other.devices, devices) &&
      other.options == options &&
      other.lastTriggered == lastTriggered;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    enabled,
    roomAreaId,
    Object.hashAll(devices),
    options,
    lastTriggered,
  );
}

/// Szene einer Z2M-Raumgruppe.
@immutable
class GroupScene {
  const GroupScene(this.id, this.name);
  final int id;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is GroupScene && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// Was die Integration über einen Raum weiß (`rooms` in der Liste).
@immutable
class AutomationRoom {
  const AutomationRoom({
    required this.areaId,
    required this.name,
    this.group,
    this.scenes = const [],
    this.lights = const [],
    this.declaredHasLights,
  });

  final String areaId;
  final String name;

  /// Friendly-Name der Z2M-Raumgruppe, `null` = Lichter einzeln über HA.
  final String? group;
  final List<GroupScene> scenes;
  final List<String> lights;

  /// `has_lights` der Integration, sonst aus Gruppe und Lichtern.
  final bool? declaredHasLights;

  bool get hasLights =>
      declaredHasLights ?? (group != null || lights.isNotEmpty);

  factory AutomationRoom.fromJson(String areaId, Map<String, dynamic> j) =>
      AutomationRoom(
        areaId: areaId,
        name: (j['name'] as String?) ?? areaId,
        group: j['group'] as String?,
        scenes: [
          for (final s in (j['scenes'] as List? ?? const []))
            if (s is Map && s['id'] is num)
              GroupScene((s['id'] as num).toInt(), '${s['name'] ?? s['id']}'),
        ],
        lights: [for (final l in (j['lights'] as List? ?? const [])) '$l'],
        declaredHasLights: j['has_lights'] as bool?,
      );

  @override
  bool operator ==(Object other) =>
      other is AutomationRoom &&
      other.areaId == areaId &&
      other.name == name &&
      other.group == group &&
      listEquals(other.scenes, scenes) &&
      listEquals(other.lights, lights) &&
      other.hasLights == hasLights;

  @override
  int get hashCode => Object.hash(areaId, name, group, scenes.length);
}

/// Antwort von `haven/automations/list`.
@immutable
class HavenAutomations {
  const HavenAutomations({
    this.automations = const [],
    this.rooms = const {},
    this.deviceAutomations = const {},
    this.running = true,
    this.supported = true,
  });

  static const empty = HavenAutomations();

  /// Integration ohne Automationen (vor dieser Version).
  static const unsupported = HavenAutomations(supported: false);

  final List<HavenAutomation> automations;
  final Map<String, AutomationRoom> rooms;

  /// IEEE → HA-Automationen, die das Gerät verwenden (Device-Trigger).
  final Map<String, List<String>> deviceAutomations;

  /// Die Integration ist geladen und hört auf die Geräte.
  final bool running;
  final bool supported;

  factory HavenAutomations.fromJson(Map<String, dynamic> j) {
    final rooms = j['rooms'] is Map ? j['rooms'] as Map : const {};
    final da = j['device_automations'] is Map
        ? j['device_automations'] as Map
        : const {};
    return HavenAutomations(
      automations: [
        for (final a in (j['automations'] as List? ?? const []))
          if (a is Map) HavenAutomation.fromJson(Map<String, dynamic>.from(a)),
      ],
      rooms: {
        for (final e in rooms.entries)
          if (e.value is Map)
            '${e.key}': AutomationRoom.fromJson(
              '${e.key}',
              Map<String, dynamic>.from(e.value as Map),
            ),
      },
      deviceAutomations: {
        for (final e in da.entries)
          if (e.value is List)
            '${e.key}': [for (final x in e.value as List) '$x'],
      },
      running: j['running'] != false,
    );
  }

  HavenAutomation? byId(String id) =>
      automations.where((a) => a.id == id).firstOrNull;

  /// Aktive Automation, die das Gerät steuert (ohne [exceptId]).
  HavenAutomation? ownerOf(String ieee, {String? exceptId}) => automations
      .where((a) => a.enabled && a.id != exceptId && a.devices.contains(ieee))
      .firstOrNull;

  HavenAutomations copyWith({List<HavenAutomation>? automations}) =>
      HavenAutomations(
        automations: automations ?? this.automations,
        rooms: rooms,
        deviceAutomations: deviceAutomations,
        running: running,
        supported: supported,
      );

  @override
  bool operator ==(Object other) =>
      other is HavenAutomations &&
      listEquals(other.automations, automations) &&
      mapEquals(other.rooms, rooms) &&
      mapEquals(
        other.deviceAutomations.map((k, v) => MapEntry(k, v.join(','))),
        deviceAutomations.map((k, v) => MapEntry(k, v.join(','))),
      ) &&
      other.running == running &&
      other.supported == supported;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(automations), rooms.length, running);
}

/// Ereignis `haven_automation_triggered`.
@immutable
class AutomationTrigger {
  const AutomationTrigger({
    required this.id,
    required this.action,
    this.room,
    this.device,
    this.source = 'device',
    required this.at,
  });

  final String id;

  /// `rotate_left`, `rotate_right`, `single`, `double`, `hold`.
  final String action;
  final String? room;
  final String? device;

  /// `device` oder `test`.
  final String source;
  final DateTime at;

  static AutomationTrigger? fromEvent(Object? event) {
    final data = event is Map ? event['data'] : null;
    if (data is! Map || data['id'] is! String || data['action'] is! String) {
      return null;
    }
    return AutomationTrigger(
      id: data['id'] as String,
      action: data['action'] as String,
      room: data['room'] as String?,
      device: data['device'] as String?,
      source: (data['source'] as String?) ?? 'device',
      at: DateTime.tryParse('${data['at']}')?.toLocal() ?? DateTime.now(),
    );
  }
}

// ---- Normalisierung (wie `automations.normalize_action` der Integration) ----

const _actionMap = <String, String>{
  'rotate_right': 'rotate_right',
  'rotate_left': 'rotate_left',
  'single': 'single',
  'double': 'double',
  'hold': 'hold',
  'brightness_step_up': 'rotate_right',
  'brightness_step_down': 'rotate_left',
  'toggle': 'single',
  'on': 'single',
  'off': 'single',
  'single_click': 'single',
  'click': 'single',
  'press': 'single',
  'double_click': 'double',
  'long': 'hold',
  'long_press': 'hold',
};

/// Z2M-Meldung (`{"action": ...}`) zur Geste (`rotate_left`, `single` ...),
/// leer oder unbekannt: `null`. Event- und Command-Modus.
String? normalizeKnobAction(Object? values) {
  if (values is! Map) return null;
  final a = values['action'];
  if (a is! String) return null;
  return _actionMap[a.trim().toLowerCase()];
}

/// Geste aus dem Namen (`rotate_left` → [KnobGesture.rotate]).
KnobGesture? gestureOf(String action) => switch (action) {
  'rotate_left' || 'rotate_right' => KnobGesture.rotate,
  'single' => KnobGesture.single,
  'double' => KnobGesture.double,
  'hold' => KnobGesture.hold,
  _ => null,
};
