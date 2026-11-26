import '../../data/models/haven_automation.dart';
import 'automation_logic.dart';

/// Reine Logik des Drehregler-Editors: Texte, Validierung, Konflikte.

/// Gerätetypen mit Aktionen (Drehregler, Taster).
const kActionDeviceTypes = {'knob', 'remote'};

/// Gerätetypen von Bewegungs- und Anwesenheitsmeldern.
const kMotionDeviceTypes = {'motion', 'presence'};

/// Wörter, an denen eine HA-Automation zu Reglern bzw. Meldern passt.
final kKnobWords = RegExp(r'knopf|knob|drehregler|regler|taster|schalter');
final kMotionWords = RegExp(
  r'bewegung|melder|motion|prasenz|anwesen|occupied|occupancy|presence|sensor',
);

String gestureLabel(KnobGesture g) => switch (g) {
  KnobGesture.rotate => 'Drehen',
  KnobGesture.single => 'Drücken',
  KnobGesture.double => 'Doppelt drücken',
  KnobGesture.hold => 'Halten',
};

/// Name einer eingehenden Geste (`rotate_left` ...).
String actionLabel(String action) => switch (action) {
  'rotate_left' => 'Nach links gedreht',
  'rotate_right' => 'Nach rechts gedreht',
  'single' => 'Gedrückt',
  'double' => 'Doppelt gedrückt',
  'hold' => 'Gehalten',
  _ => action,
};

/// Text einer Belegung, z. B. „Szene Kinoabend“.
String bindingLabel(
  KnobGesture g,
  GestureBinding b, [
  List<GroupScene> scenes = const [],
]) => switch (b.action) {
  GestureAction.none => 'Nichts',
  GestureAction.brightness => 'Helligkeit',
  GestureAction.toggle => 'Ein/Aus',
  GestureAction.nextScene => 'Nächste Szene',
  GestureAction.sceneStep => 'Szene vor/zurück',
  GestureAction.off => 'Alles aus im Raum',
  GestureAction.lights => switch (b.lights.length) {
    0 => 'Lampen wählen',
    1 => '1 Lampe einstellen',
    final n => '$n Lampen einstellen',
  },
  GestureAction.scene =>
    'Szene ${scenes.where((s) => s.id == b.scene).firstOrNull?.name ?? 'wählen'}',
};

/// Schrittweite (von 255) in Prozent, gerundet.
int stepPercent(int step) => (step / 255 * 100).round();
int stepFromPercent(int pct) => (pct * 2.55).round().clamp(1, 255);

/// Fehler je Schritt des Assistenten (0 Raum, 1 Geräte, 2 Gesten, 3 Szenen).
/// Leer = speicherbar.
Map<int, String> validateKnobDraft(
  HavenAutomation draft,
  HavenAutomations all, {
  Map<String, String> deviceNames = const {},
}) {
  final errors = <int, String>{};
  final room = all.rooms[draft.roomAreaId];
  if (draft.roomAreaId.isEmpty) {
    errors[0] = 'Wähl einen Raum';
  } else if (room != null && !room.hasLights) {
    errors[0] = '${room.name} hat keine Lichter, die Haven steuern kann';
  }
  if (draft.devices.isEmpty) {
    errors[1] = 'Wähl mindestens einen Regler oder Taster';
  } else if (draft.enabled) {
    for (final d in draft.devices) {
      final owner = all.ownerOf(d, exceptId: draft.id, type: 'room_knob');
      if (owner != null) {
        errors[1] = '${deviceNames[d] ?? d} steuert schon ${owner.name}';
        break;
      }
    }
  }
  final scenes = room?.scenes ?? const <GroupScene>[];
  for (final g in KnobGesture.values) {
    final b = draft.options.binding(g);
    if (b.action == GestureAction.scene &&
        !scenes.any((s) => s.id == b.scene)) {
      errors[2] = '${gestureLabel(g)}: Szene wählen';
      break;
    }
    if (b.action == GestureAction.lights && b.lights.isEmpty) {
      errors[2] = '${gestureLabel(g)}: Lampen wählen';
      break;
    }
  }
  final usesScenes = KnobGesture.values.any(
    (g) => const {
      GestureAction.nextScene,
      GestureAction.sceneStep,
    }.contains(draft.options.binding(g).action),
  );
  if (usesScenes && room != null && room.group == null) {
    errors[2] ??= 'Szenen schalten geht nur mit einer Z2M-Gruppe im Raum';
  }
  final chosen = draft.options.scenes;
  if (usesScenes && chosen != null && chosen.isEmpty) {
    errors[3] = 'Wähl mindestens eine Szene';
  }
  final on = draft.options.onScene;
  if (on != null && !scenes.any((s) => s.id == on)) {
    errors[3] ??= 'Beim Einschalten: Szene wählen';
  }
  return errors;
}

/// Szenen in Umlauf-Reihenfolge: gewählte zuerst, dann der Rest (abgewählt).
List<(GroupScene, bool)> orderedScenes(
  List<GroupScene> all,
  List<int>? chosen,
) {
  if (chosen == null) return [for (final s in all) (s, true)];
  final byId = {for (final s in all) s.id: s};
  return [
    for (final id in chosen)
      if (byId[id] != null) (byId[id]!, true),
    for (final s in all)
      if (!chosen.contains(s.id)) (s, false),
  ];
}

/// HA-Automation, die dieselben Regler anspricht.
class HaConflict {
  const HaConflict(this.item, {required this.byDevice});
  final AutomationItem item;

  /// `true`: über Device-Trigger erkannt, sonst nur am Namen.
  final bool byDevice;
}

/// HA-Automationen, die dieselben Geräte steuern: zuerst über die
/// Device-IDs der Integration (`device_automations`), sonst am Namen
/// (Automation über Knopf/Drehregler/Taster mit dem Raum oder dem Gerät im
/// Namen). Ausgeschaltete HA-Automationen zählen nicht.
List<HaConflict> findHaConflicts({
  required List<String> devices,
  required String? roomName,
  required Map<String, String> deviceNames,
  required Map<String, List<String>> deviceAutomations,
  required List<AutomationItem> haAutomations,
  RegExp? words,
}) {
  final byId = {for (final a in haAutomations) a.entityId: a};
  final out = <String, HaConflict>{};
  for (final d in devices) {
    for (final id in deviceAutomations[d] ?? const <String>[]) {
      final a = byId[id];
      if (a != null && a.on) out[id] = HaConflict(a, byDevice: true);
    }
  }
  final room = roomName == null ? null : foldText(roomName);
  final names = [
    for (final d in devices)
      if (deviceNames[d] != null) foldText(deviceNames[d]!),
  ];
  for (final a in haAutomations) {
    if (!a.on || out.containsKey(a.entityId)) continue;
    final n = foldText(a.name);
    if (!(words ?? kKnobWords).hasMatch(n)) continue;
    final hit =
        names.any((x) => x.isNotEmpty && n.contains(x)) ||
        (room != null &&
            (n.split(RegExp(r'[^a-z0-9]+')).contains(room) ||
                foldText(a.room ?? '') == room));
    if (hit) out[a.entityId] = HaConflict(a, byDevice: false);
  }
  return out.values.toList();
}
