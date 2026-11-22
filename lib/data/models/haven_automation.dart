import 'package:flutter/foundation.dart';

/// Haven-Automationen: Abläufe, die direkt in der Integration laufen
/// (`haven/automations/*`, siehe `integration/README.md`). Typen: `room_knob`
/// (Drehregler und Taster steuern das Licht eines Raums) und `room_motion`
/// (Bewegungslicht, siehe [MotionOptions]).

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
  off('off'),

  /// Eigene Aktion: bestimmte Lampen auf einen festen Zustand
  /// (Integration mit Feature `knob_lights`).
  lights('lights');

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
          GestureAction.lights,
          GestureAction.none,
        ];
}

/// Eine Lampe in der Aktion [GestureAction.lights]: an oder aus, an mit
/// Helligkeit (1 bis 100 %) und Weißton ([kelvin]) oder Farbe ([rgb]).
/// Ohne Angaben behält die Lampe Helligkeit bzw. Farbe.
@immutable
class LightTarget {
  const LightTarget(
    this.entityId, {
    this.on = true,
    this.brightness,
    this.kelvin,
    this.rgb,
  });

  final String entityId;
  final bool on;
  final int? brightness;
  final int? kelvin;

  /// Farbe als `0xRRGGBB`.
  final int? rgb;

  static LightTarget? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['entity_id'];
    if (id is! String || !id.startsWith('light.')) return null;
    int? n(Object? v) => v is num ? v.toInt() : null;
    final c = j['rgb'];
    return LightTarget(
      id,
      on: j['on'] != false,
      brightness: n(j['brightness']),
      kelvin: n(j['kelvin']),
      rgb: c is List && c.length == 3 && c.every((x) => x is num)
          ? ((c[0] as num).toInt().clamp(0, 255) << 16) |
                ((c[1] as num).toInt().clamp(0, 255) << 8) |
                (c[2] as num).toInt().clamp(0, 255)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'entity_id': entityId,
    'on': on,
    if (on && brightness != null) 'brightness': brightness!.clamp(1, 100),
    if (on && rgb == null && kelvin != null)
      'kelvin': kelvin!.clamp(1000, 10000),
    if (on && rgb != null)
      'rgb': [(rgb! >> 16) & 0xFF, (rgb! >> 8) & 0xFF, rgb! & 0xFF],
  };

  /// Weißton und Farbe schließen sich aus: [kelvin] löscht die Farbe,
  /// [rgb] den Weißton.
  LightTarget copyWith({
    bool? on,
    int? brightness,
    bool clearBrightness = false,
    int? kelvin,
    int? rgb,
    bool clearColor = false,
  }) => LightTarget(
    entityId,
    on: on ?? this.on,
    brightness: clearBrightness ? null : (brightness ?? this.brightness),
    kelvin: clearColor || rgb != null ? null : (kelvin ?? this.kelvin),
    rgb: clearColor || kelvin != null ? null : (rgb ?? this.rgb),
  );

  @override
  bool operator ==(Object other) =>
      other is LightTarget &&
      other.entityId == entityId &&
      other.on == on &&
      other.brightness == brightness &&
      other.kelvin == kelvin &&
      other.rgb == rgb;

  @override
  int get hashCode => Object.hash(entityId, on, brightness, kelvin, rgb);
}

@immutable
class GestureBinding {
  const GestureBinding(this.action, {this.scene, this.lights = const []});
  final GestureAction action;

  /// Szenen-ID der Z2M-Gruppe bei [GestureAction.scene].
  final int? scene;

  /// Lampen bei [GestureAction.lights].
  final List<LightTarget> lights;

  factory GestureBinding.fromJson(Object? j) {
    if (j is String) return GestureBinding(GestureAction.parse(j));
    if (j is Map) {
      final s = j['scene'];
      final l = j['lights'];
      return GestureBinding(
        GestureAction.parse(j['action']),
        scene: s is num ? s.toInt() : null,
        lights: l is List
            ? [for (final x in l) ?LightTarget.fromJson(x)]
            : const [],
      );
    }
    return const GestureBinding(GestureAction.none);
  }

  Map<String, dynamic> toJson() => {
    'action': action.wire,
    if (action == GestureAction.scene) 'scene': scene,
    if (action == GestureAction.lights)
      'lights': [for (final l in lights) l.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is GestureBinding &&
      other.action == action &&
      other.scene == scene &&
      listEquals(other.lights, lights);

  @override
  int get hashCode => Object.hash(action, scene, Object.hashAll(lights));
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
    this.motion,
    this.motionStatus,
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

  /// Optionen von `room_motion` (sonst `null`).
  final MotionOptions? motion;

  /// Aktueller Zustand eines Bewegungslichts (Liste und Ereignisse).
  final MotionStatus? motionStatus;
  final AutomationFired? lastTriggered;

  bool get isMotion => type == kMotionType;

  factory HavenAutomation.fromJson(Map<String, dynamic> j) => HavenAutomation(
    id: j['id'] as String?,
    type: (j['type'] as String?) ?? 'room_knob',
    name: (j['name'] as String?) ?? '',
    enabled: j['enabled'] != false,
    roomAreaId: (j['room_area_id'] as String?) ?? '',
    devices: [for (final d in (j['devices'] as List? ?? const [])) '$d'],
    options: j['type'] == kMotionType
        ? const KnobOptions()
        : KnobOptions.fromJson(j['options']),
    motion: j['type'] == kMotionType
        ? MotionOptions.fromJson(j['options'])
        : null,
    motionStatus: MotionStatus.fromJson(j['motion']),
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
    'options': isMotion
        ? (motion ?? const MotionOptions()).toJson()
        : options.toJson(),
  };

  HavenAutomation copyWith({
    String? id,
    String? name,
    bool? enabled,
    String? roomAreaId,
    List<String>? devices,
    KnobOptions? options,
    MotionOptions? motion,
    MotionStatus? motionStatus,
    AutomationFired? lastTriggered,
  }) => HavenAutomation(
    id: id ?? this.id,
    type: type,
    name: name ?? this.name,
    enabled: enabled ?? this.enabled,
    roomAreaId: roomAreaId ?? this.roomAreaId,
    devices: devices ?? this.devices,
    options: options ?? this.options,
    motion: motion ?? this.motion,
    motionStatus: motionStatus ?? this.motionStatus,
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
      other.motion == motion &&
      other.motionStatus == motionStatus &&
      other.lastTriggered == lastTriggered;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    enabled,
    roomAreaId,
    Object.hashAll(devices),
    options,
    motion,
    motionStatus,
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
  HavenAutomation? ownerOf(String ieee, {String? exceptId, String? type}) =>
      automations
          .where(
            (a) =>
                a.enabled &&
                a.id != exceptId &&
                (type == null || a.type == type) &&
                a.devices.contains(ieee),
          )
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
    this.motion,
  });

  final String id;

  /// `rotate_left`, `rotate_right`, `single`, `double`, `hold`.
  final String action;
  final String? room;
  final String? device;

  /// `device` oder `test`.
  final String source;
  final DateTime at;

  /// Zustand des Bewegungslichts nach dem Ereignis (`state`), sonst `null`.
  final MotionStatus? motion;

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
      motion: MotionStatus.fromJson(data['state']),
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

// ---- Bewegungslicht (`room_motion`) --------------------------------------------

const kMotionType = 'room_motion';

const kDefaultMotionDelay = 120;
const kDefaultWarnSeconds = 20;

/// `HH:MM` von bis (auch über Mitternacht).
@immutable
class TimeWindow {
  const TimeWindow(this.from, this.to);
  final String from;
  final String to;

  static TimeWindow? fromJson(Object? j) =>
      j is Map && j['from'] is String && j['to'] is String
      ? TimeWindow(j['from'] as String, j['to'] as String)
      : null;

  Map<String, dynamic> toJson() => {'from': from, 'to': to};

  @override
  bool operator ==(Object other) =>
      other is TimeWindow && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

/// Sonnenereignis mit Versatz in Minuten.
@immutable
class SunEdge {
  const SunEdge(this.event, [this.offset = 0]);

  /// `sunrise` oder `sunset`.
  final String event;
  final int offset;

  static SunEdge? fromJson(Object? j) =>
      j is Map && (j['event'] == 'sunrise' || j['event'] == 'sunset')
      ? SunEdge(
          j['event'] as String,
          j['offset'] is num ? (j['offset'] as num).toInt() : 0,
        )
      : null;

  Map<String, dynamic> toJson() => {'event': event, 'offset': offset};

  @override
  bool operator ==(Object other) =>
      other is SunEdge && other.event == event && other.offset == offset;

  @override
  int get hashCode => Object.hash(event, offset);
}

/// Aktiv zwischen zwei Sonnenereignissen, z. B. ab Sonnenuntergang bis
/// Sonnenaufgang + 60 min.
@immutable
class SunWindow {
  const SunWindow({this.from, this.until});
  final SunEdge? from;
  final SunEdge? until;

  static SunWindow? fromJson(Object? j) {
    if (j is! Map) return null;
    final w = SunWindow(
      from: SunEdge.fromJson(j['from']),
      until: SunEdge.fromJson(j['until']),
    );
    return w.from == null && w.until == null ? null : w;
  }

  Map<String, dynamic> toJson() => {
    'from': from?.toJson(),
    'until': until?.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is SunWindow && other.from == from && other.until == until;

  @override
  int get hashCode => Object.hash(from, until);
}

/// Was das Bewegungslicht einschaltet: eine Szene oder Helligkeit mit Farbtemperatur.
@immutable
class MotionLight {
  const MotionLight({
    this.scene,
    this.sceneEntity,
    this.brightness = 204,
    this.colorTemp,
    this.transition = 1.0,
    bool? useScene,
  }) : _scene = useScene;

  /// Z2M-Szene der Raumgruppe.
  final int? scene;

  /// HA-Szene (`scene.*`).
  final String? sceneEntity;

  /// 1 bis 254.
  final int brightness;

  /// Kelvin, `null` = nicht ändern.
  final int? colorTemp;
  final double transition;
  final bool? _scene;

  /// Szene statt Helligkeit.
  bool get isScene => _scene ?? (scene != null || sceneEntity != null);

  int get percent => (brightness / 2.54).round().clamp(1, 100);

  factory MotionLight.fromJson(Object? raw) {
    final j = raw is Map ? raw : const {};
    num? n(String k) => j[k] is num ? j[k] as num : null;
    return MotionLight(
      useScene: j['mode'] == 'scene',
      scene: j['mode'] == 'scene' ? n('scene')?.toInt() : null,
      sceneEntity: j['mode'] == 'scene' ? j['scene_entity'] as String? : null,
      brightness: n('brightness')?.toInt() ?? 204,
      colorTemp: n('color_temp')?.toInt(),
      transition: n('transition')?.toDouble() ?? 1.0,
    );
  }

  Map<String, dynamic> toJson() => isScene
      ? {
          'mode': 'scene',
          if (sceneEntity != null)
            'scene_entity': sceneEntity
          else
            'scene': scene,
          'transition': transition,
        }
      : {
          'mode': 'brightness',
          'brightness': brightness,
          'color_temp': colorTemp,
          'transition': transition,
        };

  MotionLight asScene() => MotionLight(
    useScene: true,
    scene: scene,
    sceneEntity: sceneEntity,
    brightness: brightness,
    colorTemp: colorTemp,
    transition: transition,
  );

  MotionLight asBrightness() => MotionLight(
    useScene: false,
    brightness: brightness,
    colorTemp: colorTemp,
    transition: transition,
  );

  MotionLight withScene({int? scene, String? entity}) => MotionLight(
    useScene: true,
    scene: scene,
    sceneEntity: entity,
    brightness: brightness,
    colorTemp: colorTemp,
    transition: transition,
  );

  MotionLight copyWith({
    int? brightness,
    int? colorTemp,
    bool clearColorTemp = false,
    double? transition,
  }) => MotionLight(
    useScene: isScene,
    scene: scene,
    sceneEntity: sceneEntity,
    brightness: brightness ?? this.brightness,
    colorTemp: clearColorTemp ? null : (colorTemp ?? this.colorTemp),
    transition: transition ?? this.transition,
  );

  @override
  bool operator ==(Object other) =>
      other is MotionLight &&
      other.isScene == isScene &&
      other.scene == scene &&
      other.sceneEntity == sceneEntity &&
      other.brightness == brightness &&
      other.colorTemp == colorTemp &&
      other.transition == transition;

  @override
  int get hashCode => Object.hash(
    isScene,
    scene,
    sceneEntity,
    brightness,
    colorTemp,
    transition,
  );
}

/// Zweites Zeitfenster mit eigenem Licht („Nachtlicht“).
@immutable
class NightLight {
  const NightLight({
    this.from = '23:00',
    this.to = '06:00',
    this.light = const MotionLight(brightness: 25, colorTemp: 2200),
  });
  final String from;
  final String to;
  final MotionLight light;

  static NightLight? fromJson(Object? j) => j is Map
      ? NightLight(
          from: j['from'] as String? ?? '23:00',
          to: j['to'] as String? ?? '06:00',
          light: MotionLight.fromJson(j['light']),
        )
      : null;

  Map<String, dynamic> toJson() => {
    'from': from,
    'to': to,
    'light': light.toJson(),
  };

  NightLight copyWith({String? from, String? to, MotionLight? light}) =>
      NightLight(
        from: from ?? this.from,
        to: to ?? this.to,
        light: light ?? this.light,
      );

  @override
  bool operator ==(Object other) =>
      other is NightLight &&
      other.from == from &&
      other.to == to &&
      other.light == light;

  @override
  int get hashCode => Object.hash(from, to, light);
}

/// Optionen von `room_motion`.
@immutable
class MotionOptions {
  const MotionOptions({
    this.windows = const [],
    this.sun,
    this.luxBelow,
    this.luxEntity,
    this.light = const MotionLight(),
    this.night,
    this.delay = kDefaultMotionDelay,
    this.warn = false,
    this.warnSeconds = kDefaultWarnSeconds,
    this.relight = true,
    this.manualDelay,
    this.extra = const {},
  });

  final List<TimeWindow> windows;
  final SunWindow? sun;

  /// Nur aktiv unter diesem Wert in lx, `null` = egal.
  final double? luxBelow;

  /// `sensor.*`, `null` = Helligkeit des Melders.
  final String? luxEntity;
  final MotionLight light;
  final NightLight? night;

  /// Sekunden ohne Bewegung bis Aus.
  final int delay;
  final bool warn;
  final int warnSeconds;
  final bool relight;

  /// Sekunden, nach denen auch manuell übernommenes Licht ausgeht, `null` = nie.
  final int? manualDelay;
  final Map<String, dynamic> extra;

  static const _known = {
    'windows',
    'sun',
    'lux',
    'light',
    'night',
    'delay',
    'warn',
    'warn_seconds',
    'relight',
    'manual_delay',
  };

  factory MotionOptions.fromJson(Object? raw) {
    final j = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    num? n(String k) => j[k] is num ? j[k] as num : null;
    final lux = j['lux'] is Map ? j['lux'] as Map : null;
    return MotionOptions(
      windows: [
        for (final w in (j['windows'] as List? ?? const []))
          if (TimeWindow.fromJson(w) case final TimeWindow tw) tw,
      ],
      sun: SunWindow.fromJson(j['sun']),
      luxBelow: lux?['below'] is num ? (lux!['below'] as num).toDouble() : null,
      luxEntity: lux?['entity'] as String?,
      light: MotionLight.fromJson(j['light']),
      night: NightLight.fromJson(j['night']),
      delay: n('delay')?.toInt() ?? kDefaultMotionDelay,
      warn: j['warn'] == true,
      warnSeconds: n('warn_seconds')?.toInt() ?? kDefaultWarnSeconds,
      relight: j['relight'] != false,
      manualDelay: n('manual_delay')?.toInt(),
      extra: {
        for (final e in j.entries)
          if (!_known.contains(e.key)) e.key: e.value,
      },
    );
  }

  Map<String, dynamic> toJson() => {
    ...extra,
    'windows': [for (final w in windows) w.toJson()],
    'sun': sun?.toJson(),
    'lux': luxBelow == null ? null : {'below': luxBelow, 'entity': luxEntity},
    'light': light.toJson(),
    'night': night?.toJson(),
    'delay': delay,
    'warn': warn,
    'warn_seconds': warnSeconds,
    'relight': relight,
    'manual_delay': manualDelay,
  };

  MotionOptions copyWith({
    List<TimeWindow>? windows,
    SunWindow? sun,
    bool clearSun = false,
    double? luxBelow,
    bool clearLux = false,
    String? luxEntity,
    bool clearLuxEntity = false,
    MotionLight? light,
    NightLight? night,
    bool clearNight = false,
    int? delay,
    bool? warn,
    int? warnSeconds,
    bool? relight,
    int? manualDelay,
    bool clearManualDelay = false,
  }) => MotionOptions(
    windows: windows ?? this.windows,
    sun: clearSun ? null : (sun ?? this.sun),
    luxBelow: clearLux ? null : (luxBelow ?? this.luxBelow),
    luxEntity: clearLux || clearLuxEntity
        ? null
        : (luxEntity ?? this.luxEntity),
    light: light ?? this.light,
    night: clearNight ? null : (night ?? this.night),
    delay: delay ?? this.delay,
    warn: warn ?? this.warn,
    warnSeconds: warnSeconds ?? this.warnSeconds,
    relight: relight ?? this.relight,
    manualDelay: clearManualDelay ? null : (manualDelay ?? this.manualDelay),
    extra: extra,
  );

  @override
  bool operator ==(Object other) =>
      other is MotionOptions &&
      listEquals(other.windows, windows) &&
      other.sun == sun &&
      other.luxBelow == luxBelow &&
      other.luxEntity == luxEntity &&
      other.light == light &&
      other.night == night &&
      other.delay == delay &&
      other.warn == warn &&
      other.warnSeconds == warnSeconds &&
      other.relight == relight &&
      other.manualDelay == manualDelay &&
      mapEquals(other.extra, extra);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(windows),
    sun,
    luxBelow,
    luxEntity,
    light,
    night,
    delay,
    warn,
    warnSeconds,
    relight,
    manualDelay,
  );
}

/// Wem das Licht gehört: `none`, `motion`, `manual`.
enum MotionPhase {
  /// Bereit, Licht aus oder von Hand an.
  idle,

  /// Licht vom Melder.
  motion,

  /// Dimmt vor dem Ausschalten.
  warn,

  /// Von Hand übernommen.
  manual,

  /// Bedingungen nicht erfüllt.
  inactive;

  static MotionPhase parse(Object? v) {
    for (final p in values) {
      if (p.name == v) return p;
    }
    return idle;
  }
}

/// Zustand eines Bewegungslichts (`motion` in der Liste, `state` im Ereignis).
@immutable
class MotionStatus {
  const MotionStatus({
    this.phase = MotionPhase.idle,
    this.occupied = false,
    this.offAt,
    this.inactive,
    this.night,
    this.lux,
    this.detectors = const [],
    this.luxEntity,
  });

  final MotionPhase phase;
  final bool occupied;

  /// Wann das Licht ausgeht, `null` = nicht geplant (Melder aktiv oder manuell).
  final DateTime? offAt;

  /// Grund bei [MotionPhase.inactive]: `time`, `sun`, `lux`.
  final String? inactive;
  final bool? night;
  final double? lux;
  final List<String> detectors;
  final String? luxEntity;

  static MotionStatus? fromJson(Object? j) {
    if (j is! Map) return null;
    return MotionStatus(
      phase: MotionPhase.parse(j['phase']),
      occupied: j['occupied'] == true,
      offAt: DateTime.tryParse('${j['off_at'] ?? ''}')?.toLocal(),
      inactive: j['inactive'] as String?,
      night: j['night'] as bool?,
      lux: j['lux'] is num ? (j['lux'] as num).toDouble() : null,
      detectors: [for (final d in (j['detectors'] as List? ?? const [])) '$d'],
      luxEntity: j['lux_entity'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MotionStatus &&
      other.phase == phase &&
      other.occupied == occupied &&
      other.offAt == offAt &&
      other.inactive == inactive &&
      other.night == night &&
      other.lux == lux &&
      listEquals(other.detectors, detectors) &&
      other.luxEntity == luxEntity;

  @override
  int get hashCode =>
      Object.hash(phase, occupied, offAt, inactive, night, lux, luxEntity);
}
