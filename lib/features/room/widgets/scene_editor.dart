import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/state/providers.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/haven_button.dart';
import '../../../core/widgets/haven_switch.dart';
import '../../../core/widgets/press_scale.dart';
import '../../../data/haven_repository.dart';
import '../../../data/models/lamp.dart';
import '../../../data/models/room.dart';
import '../../../data/scene_look.dart';
import '../../zigbee/widgets/zb_common.dart';
import '../../zigbee/zigbee_actions.dart' show NameField, confirmSheet;
import 'scene_card.dart';

// ---- Reine Logik (getestet in scene_editor_test.dart) -----------------------

/// Die Szene, die ein Speichern unter [name] ersetzen würde (gleicher Name,
/// Groß- und Kleinschreibung egal), sonst `null`.
RoomScene? sceneNamed(List<RoomScene> scenes, String name) {
  final key = _normalize(name).toLowerCase();
  if (key.isEmpty) return null;
  for (final s in scenes) {
    if (s.name.trim().toLowerCase() == key) return s;
  }
  return null;
}

String _normalize(String name) => name.trim().split(RegExp(r'\s+')).join(' ');

const _suggestions = [
  'Abend',
  'Gemütlich',
  'Lesen',
  'Hell',
  'Kochen',
  'Essen',
  'Film',
  'Nacht',
  'Morgen',
  'Arbeiten',
];

/// Bis zu [count] Namensvorschläge, die es im Raum noch nicht gibt.
List<String> sceneNameSuggestions(List<RoomScene> scenes, {int count = 4}) => [
  for (final n in _suggestions)
    if (sceneNamed(scenes, n) == null) n,
].take(count).toList();

/// Alle Lampen des Raums, auch ausgenommene: Z2M speichert die Szene für
/// jedes Mitglied der Gruppe.
List<Lamp> roomSceneLamps(WidgetRef ref, Room room) {
  final snap = ref.watch(snapshotProvider);
  return [for (final id in room.lightIds) ?snap.lamp(id)];
}

String sceneErrorText(Object e) {
  if (e is HavenException) {
    switch (e.code) {
      case 'unauthorized':
        return 'Szenen ändern braucht Admin-Rechte in Home Assistant';
      case 'bridge_offline':
        return 'Zigbee2MQTT ist gerade nicht erreichbar';
      case 'full':
        return 'In dieser Gruppe ist kein Platz für weitere Szenen';
      case 'no_target':
        return 'Für diese Szene gibt es kein Soll. Erst übernehmen oder neu speichern.';
      case 'timeout':
        return 'Home Assistant hat nicht rechtzeitig geantwortet';
    }
    return e.message;
  }
  return 'Das hat nicht geklappt: $e';
}

// ---- Abläufe -----------------------------------------------------------------

/// Speichert das aktuelle Licht als Szene. Mit [replace] ist die Szene zum
/// Überschreiben schon gewählt.
Future<void> saveSceneFlow(
  BuildContext context,
  WidgetRef ref,
  Room room, {
  RoomScene? replace,
}) async {
  final result = await showZbSheet<_SaveResult>(
    context,
    builder: (ctx) => _SaveSceneForm(roomId: room.id, replace: replace),
  );
  if (result == null || !context.mounted) return;
  final repo = ref.read(repositoryProvider);
  try {
    await repo.storeScene(
      room.id,
      name: result.name,
      number: result.replace?.number,
      devices: result.devices,
    );
    HapticFeedback.lightImpact();
    if (!context.mounted) return;
    zbToast(
      context,
      result.replace == null
          ? 'Szene ${result.name} gespeichert'
          : 'Szene ${result.name} mit dem aktuellen Licht ersetzt',
    );
  } catch (e) {
    if (context.mounted) zbToast(context, sceneErrorText(e), error: true);
  }
}

/// Langes Drücken auf eine Szene: überschreiben, umbenennen, löschen.
Future<void> editSceneFlow(
  BuildContext context,
  WidgetRef ref,
  Room room,
  RoomScene scene,
) async {
  final action = await showZbSheet<_EditAction>(
    context,
    builder: (ctx) => _SceneActions(scene: scene),
  );
  if (action == null || !context.mounted) return;
  final repo = ref.read(repositoryProvider);
  switch (action) {
    case _EditAction.overwrite:
      await saveSceneFlow(context, ref, room, replace: scene);
    case _EditAction.rename:
      final name = await showZbSheet<String>(
        context,
        builder: (ctx) => _RenameSceneForm(scene: scene, others: room.scenes),
      );
      if (name == null || !context.mounted) return;
      try {
        await repo.renameScene(room.id, scene.number!, name);
        if (context.mounted) zbToast(context, 'Umbenannt in $name');
      } catch (e) {
        if (context.mounted) zbToast(context, sceneErrorText(e), error: true);
      }
    case _EditAction.devices:
      final keep = await showZbSheet<List<String>>(
        context,
        builder: (ctx) => _SceneDevicesForm(scene: scene, own: scene.own),
      );
      if (keep == null || !context.mounted) return;
      try {
        await repo.setSceneDevices(room.id, scene.number!, keep);
        if (context.mounted) zbToast(context, '${scene.name} geändert');
      } catch (e) {
        if (context.mounted) zbToast(context, sceneErrorText(e), error: true);
      }
    case _EditAction.remove:
      final ok = await confirmSheet(
        context,
        title: '${scene.name} löschen?',
        text:
            'Die Szene verschwindet von allen Lampen der Gruppe. Abläufe, die '
            'sie aufrufen, überspringen sie dann.',
        action: 'Löschen',
        destructive: true,
      );
      if (!ok || !context.mounted) return;
      try {
        await repo.removeScene(room.id, scene.number!);
        if (context.mounted) zbToast(context, '${scene.name} gelöscht');
      } catch (e) {
        if (context.mounted) zbToast(context, sceneErrorText(e), error: true);
      }
  }
}

// ---- Karte „Speichern“ in der Szenenreihe -------------------------------------

class SceneAddCard extends StatelessWidget {
  const SceneAddCard({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      button: true,
      label: 'Aktuelles Licht als Szene speichern',
      child: PressScale(
        onTap: onTap,
        pressedScale: 0.9,
        child: Container(
          width: 112,
          height: 92,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: hv.s1.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(HavenRadii.m),
            border: Border.all(color: hv.ln2, width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: hv.acc.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.add_rounded, size: 20, color: hv.acc),
              ),
              const Spacer(),
              Text(
                'Licht speichern',
                maxLines: 2,
                style: HavenText.label.copyWith(color: hv.tx, fontSize: 13.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Knopf im Abschnittskopf „Szenen“, immer sichtbar.
class SceneSaveChip extends StatelessWidget {
  const SceneSaveChip({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      button: true,
      label: 'Aktuelles Licht als Szene speichern',
      child: PressScale(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 14, 6),
          decoration: BoxDecoration(
            color: hv.s2.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(HavenRadii.pill),
            border: Border.all(color: hv.ln),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_rounded, size: 18, color: hv.acc),
              const SizedBox(width: 4),
              Text(
                'Speichern',
                style: HavenText.label.copyWith(color: hv.tx, fontSize: 13.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---- Sheets --------------------------------------------------------------------

class _SaveResult {
  const _SaveResult(this.name, this.replace, [this.devices]);
  final String name;
  final RoomScene? replace;

  /// Zusatzgeräte, `null` = die Integration kann keine.
  final List<String>? devices;
}

/// Geräte, die eine Szene zusätzlich speichern kann: Lampen außerhalb der
/// Zigbee-Gruppe, dann Steckdosen und Schalter.
List<String> sceneDeviceCandidates(Room room) => [
  ...room.sceneLightIds,
  ...room.switchIds,
];

/// Vorauswahl der Zusatzgeräte: beim Ersetzen die der Szene, sonst die
/// Lampen außerhalb der Gruppe (ohne ausgenommene). Steckdosen und Schalter
/// nie von selbst.
Set<String> defaultSceneDevices(
  Room room,
  RoomScene? replace,
  Set<String> excluded,
) {
  final candidates = sceneDeviceCandidates(room).toSet();
  if (replace != null && replace.devices.isNotEmpty) {
    return replace.devices.where(candidates.contains).toSet();
  }
  return {
    for (final l in room.sceneLightIds)
      if (!excluded.contains(l)) l,
  };
}

class _SaveSceneForm extends ConsumerStatefulWidget {
  const _SaveSceneForm({required this.roomId, this.replace});
  final String roomId;
  final RoomScene? replace;

  @override
  ConsumerState<_SaveSceneForm> createState() => _SaveSceneFormState();
}

class _SaveSceneFormState extends ConsumerState<_SaveSceneForm> {
  late final TextEditingController _c = TextEditingController(
    text: widget.replace?.name ?? '',
  );

  /// Gewählte Zusatzgeräte, `null` bis zur ersten Auswahl (dann Vorauswahl
  /// der Szene, die ersetzt würde).
  Set<String>? _devices;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Set<String> _chosen(Room room, RoomScene? target) =>
      _devices ??
      defaultSceneDevices(
        room,
        target,
        ref.read(snapshotProvider).excludedLights,
      );

  void _pick(String name) {
    _c.text = name;
    _c.selection = TextSelection.collapsed(offset: name.length);
    setState(() {});
  }

  void _done() {
    final name = _normalize(_c.text);
    if (name.isEmpty) return;
    final room = ref.read(snapshotProvider).room(widget.roomId);
    if (room == null) return;
    final target = sceneNamed(room.scenes, name);
    final devices = ref.read(repositoryProvider).canSceneDevices
        ? [
            for (final d in sceneDeviceCandidates(room))
              if (_chosen(room, target).contains(d)) d,
          ]
        : null;
    Navigator.of(context).pop(_SaveResult(name, target, devices));
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final room = ref.watch(
      snapshotProvider.select((s) => s.room(widget.roomId)),
    );
    if (room == null) return const SizedBox.shrink();
    final lamps = roomSceneLamps(ref, room);
    final look = sceneLookOf(lamps);
    final name = _normalize(_c.text);
    final target = sceneNamed(room.scenes, name);
    final onCount = lamps.where((l) => l.on).length;
    final withDevices = ref.watch(
      repositoryProvider.select((r) => r.canSceneDevices),
    );
    final candidates = withDevices
        ? sceneDeviceCandidates(room)
        : const <String>[];
    final chosen = _chosen(room, target);
    final noGroup = room.zigbeeGroupId == null;
    // Ohne Gruppe besteht die Szene nur aus Zusatzgeräten
    final canSave = name.isNotEmpty && (!noGroup || chosen.isNotEmpty);
    final preview = RoomScene(
      id: '_preview',
      name: name.isEmpty ? 'Neue Szene' : name,
      colors: look.cardColors,
      brightness: look.brightness,
      kelvin: look.kelvin,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          target == null ? 'Licht als Szene speichern' : 'Szene ersetzen',
          style: HavenText.headline.copyWith(color: hv.tx),
        ),
        const SizedBox(height: 4),
        Text(
          look.allOff
              ? 'Alle Lampen in ${room.name} sind aus. Die Szene schaltet den Raum aus.'
              : 'Haven merkt sich, wie die $onCount von ${lamps.length} Lampen in '
                    '${room.name} gerade leuchten.',
          style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IgnorePointer(
              child: SceneCard(scene: preview, active: false, onTap: () {}),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  NameField(
                    controller: _c,
                    autofocus: widget.replace == null,
                    hint: 'Name',
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _done(),
                  ),
                  const SizedBox(height: 8),
                  AnimatedSwitcher(
                    duration: context.motion(HavenMotion.d2),
                    child: Text(
                      key: ValueKey(target?.number),
                      target == null
                          ? 'Wird eine neue Szene.'
                          : 'Ersetzt „${target.name}“. Abläufe mit dieser Szene nutzen dann das neue Licht.',
                      style: HavenText.caption.copyWith(
                        color: target == null ? hv.tx3 : hv.warn,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (candidates.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(
            noGroup ? 'Geräte in der Szene' : 'Weitere Geräte',
            style: HavenText.label.copyWith(color: hv.tx2),
          ),
          const SizedBox(height: 2),
          Text(
            noGroup
                ? 'Haven merkt sich ihren Zustand und stellt ihn wieder her.'
                : 'Nicht in der Zigbee-Gruppe. Haven merkt sich ihren '
                      'Zustand und schaltet sie mit.',
            style: HavenText.caption.copyWith(color: hv.tx3),
          ),
          const SizedBox(height: 6),
          for (final id in candidates)
            _DeviceToggle(
              key: ValueKey('scene-device-$id'),
              entityId: id,
              value: chosen.contains(id),
              onChanged: (v) => setState(() {
                final next = {...chosen};
                v ? next.add(id) : next.remove(id);
                _devices = next;
              }),
            ),
        ],
        if (room.scenes.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(
            'Bestehende ersetzen',
            style: HavenText.label.copyWith(color: hv.tx2),
          ),
          const SizedBox(height: 8),
          _ChipWrap(
            names: [for (final s in room.scenes) s.name],
            selected: target?.name,
            onTap: _pick,
          ),
        ],
        if (widget.replace == null) ...[
          const SizedBox(height: 14),
          Text('Vorschläge', style: HavenText.label.copyWith(color: hv.tx2)),
          const SizedBox(height: 8),
          _ChipWrap(
            names: sceneNameSuggestions(room.scenes),
            selected: null,
            onTap: _pick,
          ),
        ],
        const SizedBox(height: 20),
        HavenButton(
          label: target == null ? 'Speichern' : '„${target.name}“ ersetzen',
          primary: true,
          onTap: canSave ? _done : null,
        ),
      ],
    );
  }
}

/// Ein Zusatzgerät mit Schalter: Name, Zustand jetzt, drin oder nicht.
class _DeviceToggle extends ConsumerWidget {
  const _DeviceToggle({
    super.key,
    required this.entityId,
    required this.value,
    required this.onChanged,
  });
  final String entityId;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final e = ref.watch(snapshotProvider.select((s) => s.entities[entityId]));
    final name = e?.name ?? entityId;
    final light = entityId.startsWith('light.');
    final state = switch (e?.state) {
      'on' => 'an',
      'off' => 'aus',
      _ => 'nicht erreichbar',
    };
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(
            light ? Icons.lightbulb_outline_rounded : Icons.power_outlined,
            size: 20,
            color: hv.tx2,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: HavenText.label.copyWith(color: hv.tx)),
                Text(
                  light ? 'Jetzt $state' : 'Steckdose/Schalter, jetzt $state',
                  style: HavenText.caption.copyWith(color: hv.tx3),
                ),
              ],
            ),
          ),
          HavenSwitch(value: value, semanticLabel: name, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _ChipWrap extends StatelessWidget {
  const _ChipWrap({
    required this.names,
    required this.selected,
    required this.onTap,
  });
  final List<String> names;
  final String? selected;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final n in names)
          PressScale(
            onTap: () => onTap(n),
            child: AnimatedContainer(
              duration: context.motion(HavenMotion.d2),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: n == selected ? hv.acc : hv.s2,
                borderRadius: BorderRadius.circular(HavenRadii.pill),
                border: Border.all(color: n == selected ? hv.acc : hv.ln),
              ),
              child: Text(
                n,
                style: HavenText.label.copyWith(
                  color: n == selected ? hv.ai : hv.tx,
                  fontSize: 13.5,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

enum _EditAction { overwrite, rename, devices, remove }

class _SceneActions extends StatelessWidget {
  const _SceneActions({required this.scene});
  final RoomScene scene;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    void pop(_EditAction a) => Navigator.of(context).pop(a);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IgnorePointer(
              child: Transform.scale(
                scale: 0.75,
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 132,
                  child: SceneCard(scene: scene, active: false, onTap: () {}),
                ),
              ),
            ),
            Expanded(
              child: Text(
                scene.stored
                    ? 'Gespeichert mit Haven.'
                    : 'Die Farben der Karte sind geschätzt. Nach dem Ersetzen zeigt Haven die echten.',
                style: HavenText.caption.copyWith(color: hv.tx2),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        HavenButton(
          label: 'Mit aktuellem Licht ersetzen',
          icon: Icons.refresh_rounded,
          primary: true,
          onTap: () => pop(_EditAction.overwrite),
        ),
        const SizedBox(height: 10),
        HavenButton(
          label: 'Umbenennen',
          icon: Icons.edit_rounded,
          onTap: () => pop(_EditAction.rename),
        ),
        if (scene.devices.isNotEmpty) ...[
          const SizedBox(height: 10),
          HavenButton(
            key: const ValueKey('scene-edit-devices'),
            label: scene.devices.length == 1
                ? '1 Zusatzgerät'
                : '${scene.devices.length} Zusatzgeräte',
            icon: Icons.devices_other_rounded,
            onTap: () => pop(_EditAction.devices),
          ),
        ],
        const SizedBox(height: 10),
        HavenButton(
          label: 'Löschen',
          icon: Icons.delete_outline_rounded,
          destructive: true,
          onTap: () => pop(_EditAction.remove),
        ),
      ],
    );
  }
}

class _RenameSceneForm extends StatefulWidget {
  const _RenameSceneForm({required this.scene, required this.others});
  final RoomScene scene;
  final List<RoomScene> others;

  @override
  State<_RenameSceneForm> createState() => _RenameSceneFormState();
}

class _RenameSceneFormState extends State<_RenameSceneForm> {
  late final TextEditingController _c = TextEditingController(
    text: widget.scene.name,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final name = _normalize(_c.text);
    final clash = sceneNamed(widget.others, name);
    final taken = clash != null && clash.number != widget.scene.number;
    final ok = name.isNotEmpty && !taken && name != widget.scene.name;
    void done() {
      if (ok) Navigator.of(context).pop(name);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Umbenennen', style: HavenText.headline.copyWith(color: hv.tx)),
        const SizedBox(height: 14),
        NameField(
          controller: _c,
          autofocus: true,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => done(),
        ),
        if (taken) ...[
          const SizedBox(height: 8),
          Text(
            '„${clash.name}“ gibt es in diesem Raum schon.',
            style: HavenText.caption.copyWith(color: hv.warn),
          ),
        ],
        const SizedBox(height: 14),
        HavenButton(label: 'Speichern', primary: true, onTap: ok ? done : null),
      ],
    );
  }
}

/// Zusatzgeräte einer Szene herausnehmen. Neue kommen beim Ersetzen dazu.
class _SceneDevicesForm extends StatefulWidget {
  const _SceneDevicesForm({required this.scene, required this.own});
  final RoomScene scene;
  final bool own;

  @override
  State<_SceneDevicesForm> createState() => _SceneDevicesFormState();
}

class _SceneDevicesFormState extends State<_SceneDevicesForm> {
  late final Set<String> _keep = widget.scene.devices.toSet();

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final ok = !widget.own || _keep.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Geräte in ${widget.scene.name}',
          style: HavenText.headline.copyWith(color: hv.tx),
        ),
        const SizedBox(height: 4),
        Text(
          'Ausgeschaltete fliegen aus der Szene. Neue Geräte kommen beim '
          'Ersetzen mit aktuellem Licht dazu.',
          style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
        ),
        const SizedBox(height: 8),
        for (final id in widget.scene.devices)
          _DeviceToggle(
            key: ValueKey('scene-keep-$id'),
            entityId: id,
            value: _keep.contains(id),
            onChanged: (v) =>
                setState(() => v ? _keep.add(id) : _keep.remove(id)),
          ),
        const SizedBox(height: 20),
        HavenButton(
          key: const ValueKey('scene-devices-save'),
          label: ok ? 'Übernehmen' : 'Mindestens ein Gerät',
          primary: true,
          onTap: ok
              ? () => Navigator.of(context).pop([
                  for (final d in widget.scene.devices)
                    if (_keep.contains(d)) d,
                ])
              : null,
        ),
      ],
    );
  }
}
