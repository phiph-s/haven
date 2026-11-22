import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/light/color_math.dart';
import '../../core/light/room_palette.dart' show colorOf;
import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/haven_card.dart';
import '../../core/widgets/haven_switch.dart';
import '../../core/widgets/segmented.dart';
import '../../data/models/haven_automation.dart';
import '../../data/models/lamp.dart';
import '../../data/models/light_groups.dart';
import '../../data/models/snapshot.dart';
import '../room/widgets/brightness_slider.dart';
import '../room/widgets/color_controls.dart';
import '../settings/settings_widgets.dart';
import 'knob_editor_screen.dart' show FieldLabel, PickRow;

// Eigene Aktion eines Drehreglers: bestimmte Lampen auf einen festen
// Zustand (an/aus, Helligkeit, Weißton oder Farbe). Die Lampen dürfen aus
// jedem Raum kommen.

/// Öffnet den Editor. `null`: abgebrochen.
Future<List<LightTarget>?> showLightTargetsEditor(
  BuildContext context, {
  required String title,
  List<LightTarget> initial = const [],
}) => showHavenSheet<List<LightTarget>>(
  context,
  builder: (_) => LightTargetsEditor(title: title, initial: initial),
);

/// Zustand einer Lampe, wie sie gerade ist (für „Wie jetzt übernehmen“).
LightTarget lightTargetFromLamp(Lamp l) {
  if (!l.on) return LightTarget(l.entityId, on: false);
  final colorMode = l.colorMode;
  final white =
      colorMode == 'color_temp' ||
      (colorMode == null && l.kelvin != null) ||
      !l.supportsColor;
  final c = l.color;
  return LightTarget(
    l.entityId,
    brightness: l.supportsBrightness ? l.brightness.clamp(1, 100) : null,
    kelvin: white && l.supportsKelvin ? l.kelvin : null,
    rgb: !white && l.supportsColor ? (c.$1 << 16) | (c.$2 << 8) | c.$3 : null,
  );
}

class LightTargetsEditor extends ConsumerStatefulWidget {
  const LightTargetsEditor({
    super.key,
    required this.title,
    this.initial = const [],
  });
  final String title;
  final List<LightTarget> initial;

  @override
  ConsumerState<LightTargetsEditor> createState() => _LightTargetsEditorState();
}

class _LightTargetsEditorState extends ConsumerState<LightTargetsEditor> {
  late List<LightTarget> _targets = [...widget.initial];

  void _update(int i, LightTarget t) => setState(() => _targets[i] = t);

  Future<void> _add() async {
    final snap = ref.read(snapshotProvider);
    final picked = await showHavenSheet<Set<String>>(
      context,
      builder: (_) => _LampPicker(
        snapshot: snap,
        selected: {for (final t in _targets) t.entityId},
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _targets = [
        for (final t in _targets)
          if (picked.contains(t.entityId)) t,
      ];
      final have = {for (final t in _targets) t.entityId};
      // Neue Lampen beginnen mit ihrem jetzigen Zustand.
      for (final id in picked) {
        if (have.contains(id)) continue;
        final l = snap.lamp(id);
        _targets.add(l == null ? LightTarget(id) : lightTargetFromLamp(l));
      }
    });
  }

  void _takeCurrent() {
    final snap = ref.read(snapshotProvider);
    Haptics.tap();
    setState(() {
      _targets = [
        for (final t in _targets)
          switch (snap.lamp(t.entityId)) {
            final l? => lightTargetFromLamp(l),
            null => t,
          },
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final snap = ref.watch(snapshotProvider);
    return Column(
      key: const ValueKey('light-targets-editor'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.title, style: HavenText.section.copyWith(color: hv.tx)),
        const SizedBox(height: 4),
        Text(
          'Diese Lampen stellt die Geste genau so ein, egal wie sie gerade '
          'sind. Tipp: Lampen von Hand einstellen und dann „Wie jetzt '
          'übernehmen“.',
          style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14.5),
        ),
        const SizedBox(height: 14),
        if (_targets.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Noch keine Lampen gewählt.',
              textAlign: TextAlign.center,
              style: HavenText.body.copyWith(color: hv.tx3),
            ),
          ),
        for (final (i, t) in _targets.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _TargetCard(
              key: ValueKey('light-target-${t.entityId}'),
              target: t,
              lamp: snap.lamp(t.entityId),
              room: _roomOf(snap, t.entityId),
              onChanged: (n) => _update(i, n),
              onRemove: () => setState(() => _targets.removeAt(i)),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: HavenButton(
                key: const ValueKey('light-targets-add'),
                label: _targets.isEmpty ? 'Lampen wählen' : 'Lampen ändern',
                icon: Icons.lightbulb_outline_rounded,
                onTap: _add,
              ),
            ),
            if (_targets.isNotEmpty) ...[
              const SizedBox(width: 10),
              Expanded(
                child: HavenButton(
                  key: const ValueKey('light-targets-current'),
                  label: 'Wie jetzt übernehmen',
                  icon: Icons.content_copy_rounded,
                  onTap: _takeCurrent,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        HavenButton(
          key: const ValueKey('light-targets-done'),
          label: 'Fertig',
          primary: true,
          onTap: _targets.isEmpty
              ? null
              : () => Navigator.of(context).pop(_targets),
        ),
      ],
    );
  }
}

String? _roomOf(HavenSnapshot s, String id) {
  for (final r in s.rooms) {
    if (r.lightIds.contains(id)) return r.name;
  }
  return null;
}

enum _Color { keep, white, color }

class _TargetCard extends StatelessWidget {
  const _TargetCard({
    super.key,
    required this.target,
    required this.lamp,
    required this.room,
    required this.onChanged,
    required this.onRemove,
  });
  final LightTarget target;
  final Lamp? lamp;
  final String? room;
  final ValueChanged<LightTarget> onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final t = target;
    final l = lamp;
    final name = l?.name ?? t.entityId;
    final canColor = l?.supportsColor ?? true;
    final canWhite = l?.supportsKelvin ?? true;
    final canDim = l?.supportsBrightness ?? true;
    final mode = t.rgb != null
        ? _Color.color
        : t.kelvin != null
        ? _Color.white
        : _Color.keep;
    final Rgb preview = !t.on
        ? (60, 60, 66)
        : t.rgb != null
        ? ((t.rgb! >> 16) & 0xFF, (t.rgb! >> 8) & 0xFF, t.rgb! & 0xFF)
        : kelvinToRgb(t.kelvin ?? 2700);
    final minK = l?.minKelvin ?? 2000;
    final maxK = l?.maxKelvin ?? 6535;
    return HavenCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: colorOf(preview),
                  shape: BoxShape.circle,
                  border: Border.all(color: hv.ln2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HavenText.label.copyWith(color: hv.tx),
                    ),
                    if (room != null)
                      Text(
                        room!,
                        style: HavenText.caption.copyWith(color: hv.tx2),
                      ),
                  ],
                ),
              ),
              HavenSwitch(
                value: t.on,
                semanticLabel: '$name an',
                onChanged: (v) => onChanged(t.copyWith(on: v)),
              ),
              IconButton(
                tooltip: '$name entfernen',
                onPressed: onRemove,
                icon: Icon(Icons.close_rounded, color: hv.tx3),
              ),
            ],
          ),
          if (t.on) ...[
            if (canDim) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 42,
                child: BrightnessSlider(
                  axis: Axis.horizontal,
                  label: '$name Helligkeit',
                  value: t.brightness ?? 100,
                  colors: [
                    colorOf(preview).withValues(alpha: 0.35),
                    colorOf(preview),
                  ],
                  onChanged: (v) =>
                      onChanged(t.copyWith(brightness: v.clamp(1, 100))),
                ),
              ),
            ],
            if (canColor || canWhite) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: HavenSegmented<_Color>(
                  neutral: true,
                  options: [
                    (_Color.keep, 'Farbe wie zuletzt'),
                    if (canWhite) (_Color.white, 'Weiß'),
                    if (canColor) (_Color.color, 'Farbe'),
                  ],
                  selected: mode,
                  onChanged: (m) => onChanged(switch (m) {
                    _Color.keep => t.copyWith(clearColor: true),
                    _Color.white => t.copyWith(
                      kelvin: (l?.kelvin ?? 2700).clamp(minK, maxK),
                    ),
                    _Color.color => t.copyWith(rgb: 0xFF8A1F),
                  }),
                ),
              ),
              if (mode == _Color.white) ...[
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: KelvinSlider(
                    kelvin: t.kelvin!.clamp(minK, maxK),
                    min: minK,
                    max: maxK,
                    onChanged: (k) => onChanged(t.copyWith(kelvin: k)),
                  ),
                ),
              ],
              if (mode == _Color.color) ...[
                const SizedBox(height: 6),
                ColorSwatches(
                  onPick: (c) => onChanged(
                    t.copyWith(rgb: (c.$1 << 16) | (c.$2 << 8) | c.$3),
                  ),
                ),
              ],
            ],
          ],
        ],
      ),
    );
  }
}

/// Lampen nach Raum, mehrere wählbar.
class _LampPicker extends StatefulWidget {
  const _LampPicker({required this.snapshot, required this.selected});
  final HavenSnapshot snapshot;
  final Set<String> selected;

  @override
  State<_LampPicker> createState() => _LampPickerState();
}

class _LampPickerState extends State<_LampPicker> {
  late final Set<String> _sel = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final s = widget.snapshot;
    final seen = <String>{};
    final groups = <(String, List<String>)>[];
    for (final r in s.rooms) {
      final ids = [
        for (final id in r.lightIds)
          if (s.entities[id] case final e?
              when !isLightGroup(e) && seen.add(id))
            id,
      ];
      if (ids.isNotEmpty) groups.add((r.name, ids));
    }
    final rest = [
      for (final e in s.byDomain('light'))
        if (!isLightGroup(e) && seen.add(e.entityId)) e.entityId,
    ];
    if (rest.isNotEmpty) groups.add(('Ohne Raum', rest));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Lampen wählen', style: HavenText.section.copyWith(color: hv.tx)),
        const SizedBox(height: 8),
        for (final (room, ids) in groups) ...[
          FieldLabel(room),
          for (final id in ids)
            PickRow(
              multi: true,
              title: s.entities[id]?.name ?? id,
              selected: _sel.contains(id),
              onTap: () => setState(
                () => _sel.contains(id) ? _sel.remove(id) : _sel.add(id),
              ),
            ),
        ],
        const SizedBox(height: 12),
        HavenButton(
          key: const ValueKey('lamp-picker-done'),
          label: _sel.isEmpty
              ? 'Übernehmen'
              : '${_sel.length} ${_sel.length == 1 ? 'Lampe' : 'Lampen'} übernehmen',
          primary: true,
          onTap: () => Navigator.of(context).pop(_sel),
        ),
      ],
    );
  }
}
