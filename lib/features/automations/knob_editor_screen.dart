import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haven_sheet.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/haven_card.dart';
import '../../core/widgets/haven_switch.dart';
import '../../core/widgets/press_scale.dart';
import '../../core/widgets/segmented.dart';
import '../../data/haven_repository.dart';
import '../../data/models/haven_automation.dart';
import '../room/widgets/brightness_slider.dart';
import '../settings/settings_widgets.dart';
import '../zigbee/zigbee_model.dart';
import 'haven_automations_provider.dart';
import 'knob_live_test.dart';
import 'knob_logic.dart';
import 'knob_widgets.dart';

const _steps = [
  'Raum',
  'Regler',
  'Gesten',
  'Szenen',
  'Optionen',
  'Live-Test',
  'Speichern',
];

/// Entwurf auf Raum [areaId] umstellen: Standardname nachziehen, freie Regler
/// des Raums vorschlagen, Szenen zurücksetzen. Gemeinsam für Assistent und
/// Dashboard.
HavenAutomation knobDraftWithRoom(
  HavenAutomation d,
  String areaId,
  HavenAutomations all,
  List<ZbDeviceView> knobs,
) {
  final name = all.rooms[areaId]?.name ?? areaId;
  final oldDefault =
      d.name.isEmpty ||
      d.name == 'Drehregler ${all.rooms[d.roomAreaId]?.name ?? ''}';
  // Freie Regler des Raums gleich vorschlagen, solange nichts gewählt ist.
  var devices = d.devices;
  if (devices.isEmpty) {
    devices = [
      for (final k in knobs)
        if (k.roomId == areaId &&
            all.ownerOf(k.ieee, exceptId: d.id, type: 'room_knob') == null)
          k.ieee,
    ];
  }
  return d.copyWith(
    roomAreaId: areaId,
    name: oldDefault ? 'Drehregler $name' : d.name,
    devices: devices,
    options: d.options.copyWith(clearScenes: true, clearOnScene: true),
  );
}

/// Assistent bzw. Editor „Drehregler für einen Raum“.
///
/// Neu ([id] `null`): Schritt für Schritt von Raum bis Speichern. Vorhanden:
/// dieselben Schritte, alle direkt über die Leiste oben erreichbar.
class KnobEditorScreen extends ConsumerStatefulWidget {
  const KnobEditorScreen({
    super.key,
    this.id,
    this.initialRoom,
    this.initialStep,
    this.demo = false,
  });

  final String? id;
  final String? initialRoom;
  final int? initialStep;

  /// Live-Test mit Beispielgesten füllen (Screenshots).
  final bool demo;

  @override
  ConsumerState<KnobEditorScreen> createState() => _KnobEditorScreenState();
}

class _KnobEditorScreenState extends ConsumerState<KnobEditorScreen> {
  HavenAutomation? _draft;
  late int _step = (widget.initialStep ?? 0).clamp(0, _steps.length - 1);
  int _reached = 0;
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.id == null;

  @override
  void initState() {
    super.initState();
    _reached = _isNew ? _step : _steps.length - 1;
  }

  /// Entwurf aus der Liste (Bearbeiten) bzw. neu, einmalig.
  HavenAutomation? _ensureDraft(HavenAutomations? all) {
    if (_draft != null) return _draft;
    if (all == null) return null;
    if (!_isNew) {
      _draft = all.byId(widget.id!);
      return _draft;
    }
    var d = const HavenAutomation(name: '', roomAreaId: '');
    final room = widget.initialRoom;
    if (room != null && all.rooms.containsKey(room)) {
      d = _withRoom(d, room, all);
    }
    _draft = d;
    return d;
  }

  HavenAutomation _withRoom(
    HavenAutomation d,
    String areaId,
    HavenAutomations all,
  ) => knobDraftWithRoom(d, areaId, all, ref.read(knobDevicesProvider));

  void _update(HavenAutomation d) => setState(() {
    _draft = d;
    _error = null;
  });

  void _go(int step) {
    Haptics.tap();
    setState(() {
      _step = step.clamp(0, _steps.length - 1);
      if (_step > _reached) _reached = _step;
      _error = null;
    });
  }

  void _close() =>
      context.canPop() ? context.pop() : context.go('/automations');

  Future<void> _next(HavenAutomations all) async {
    final errors = validateKnobDraft(
      _draft!,
      all,
      deviceNames: ref.read(knobDeviceNamesProvider),
    );
    if (_step < _steps.length - 1) {
      final e = errors[_step];
      if (e != null) {
        Haptics.tap();
        setState(() => _error = e);
        return;
      }
      _go(_step + 1);
      return;
    }
    if (errors.isNotEmpty) {
      final first = errors.keys.reduce((a, b) => a < b ? a : b);
      setState(() {
        _step = first;
        _error = errors[first];
      });
      return;
    }
    await _save();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final saved = await ref
          .read(havenAutomationsProvider.notifier)
          .save(_draft!);
      if (!mounted) return;
      Haptics.tap();
      showHavenToast(context, '${saved.name} gespeichert');
      _close();
    } on HavenException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showHavenSheet<bool>(
      context,
      builder: (ctx) {
        final hv = ctx.hv;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${_draft!.name} löschen?',
              style: HavenText.section.copyWith(color: hv.tx),
            ),
            const SizedBox(height: 6),
            Text(
              'Die Regler tun danach nichts mehr, bis du sie neu belegst.',
              style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
            ),
            const SizedBox(height: 16),
            HavenButton(
              label: 'Löschen',
              icon: Icons.delete_outline_rounded,
              destructive: true,
              onTap: () => Navigator.of(ctx).pop(true),
            ),
            const SizedBox(height: 10),
            HavenButton(
              label: 'Abbrechen',
              onTap: () => Navigator.of(ctx).pop(false),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(havenAutomationsProvider.notifier).delete(_draft!.id!);
      if (!mounted) return;
      showHavenToast(context, 'Gelöscht');
      _close();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final async = ref.watch(havenAutomationsProvider);
    final all = async.value;
    final draft = _ensureDraft(all);

    Widget body;
    if (all == null) {
      body = Center(
        child: async.hasError
            ? Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Automationen nicht erreichbar: ${async.error}',
                  textAlign: TextAlign.center,
                  style: HavenText.body.copyWith(color: hv.tx2),
                ),
              )
            : const CircularProgressIndicator.adaptive(),
      );
    } else if (draft == null) {
      body = Center(
        child: Text(
          'Diese Automation gibt es nicht mehr.',
          style: HavenText.body.copyWith(color: hv.tx2),
        ),
      );
    } else {
      body = AnimatedSwitcher(
        duration: context.motion(HavenMotion.d3),
        switchInCurve: HavenMotion.out,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0.04, 0),
              end: Offset.zero,
            ).animate(anim),
            child: child,
          ),
        ),
        child: KeyedSubtree(key: ValueKey(_step), child: _stepBody(draft, all)),
      );
    }

    final last = _step == _steps.length - 1;
    return Scaffold(
      backgroundColor: hv.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
              child: Row(
                children: [
                  RoundIconButton(
                    icon: _isNew
                        ? Icons.close_rounded
                        : Icons.arrow_back_rounded,
                    label: _isNew ? 'Abbrechen' : 'Zurück',
                    onTap: _close,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Schritt ${_step + 1} von ${_steps.length} · ${_steps[_step]}',
                          style: HavenText.caption.copyWith(color: hv.tx2),
                        ),
                        Text(
                          _isNew
                              ? 'Drehregler für einen Raum'
                              : (draft?.name ?? 'Drehregler'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HavenText.headline.copyWith(color: hv.tx),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
              child: StepBar(
                step: _step,
                reached: _reached,
                onTap: draft == null ? null : _go,
              ),
            ),
            Expanded(child: body),
            if (draft != null && all != null)
              Container(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
                decoration: BoxDecoration(
                  color: hv.bg,
                  border: Border(top: BorderSide(color: hv.ln)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AnimatedSize(
                      duration: context.motion(HavenMotion.d2),
                      child: _error == null
                          ? const SizedBox(width: double.infinity)
                          : Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.error_outline_rounded,
                                    size: 18,
                                    color: hv.bad,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _error!,
                                      style: HavenText.body.copyWith(
                                        color: hv.bad,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                    Row(
                      children: [
                        if (_step > 0) ...[
                          Expanded(
                            child: HavenButton(
                              label: 'Zurück',
                              onTap: () => _go(_step - 1),
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          flex: 2,
                          child: HavenButton(
                            label: last ? 'Speichern' : 'Weiter',
                            icon: last
                                ? Icons.check_rounded
                                : Icons.arrow_forward_rounded,
                            primary: true,
                            busy: _saving,
                            onTap: _saving ? null : () => _next(all),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _stepBody(HavenAutomation d, HavenAutomations all) {
    final room = all.rooms[d.roomAreaId];
    return switch (_step) {
      0 => KnobRoomStep(
        draft: d,
        all: all,
        onPick: (id) => _update(_withRoom(d, id, all)),
      ),
      1 => KnobDeviceStep(draft: d, all: all, onChanged: _update),
      2 => KnobGestureStep(draft: d, room: room, onChanged: _update),
      3 => KnobSceneStep(draft: d, room: room, onChanged: _update),
      4 => KnobOptionsStep(draft: d, onChanged: _update),
      5 => KnobLiveTest(automation: d, demo: widget.demo),
      _ => _SummaryStep(
        draft: d,
        all: all,
        onChanged: _update,
        onDelete: _isNew ? null : _delete,
      ),
    };
  }
}

// ---- Leiste der Schritte ---------------------------------------------------

class StepBar extends StatelessWidget {
  const StepBar({
    super.key,
    required this.step,
    required this.reached,
    this.onTap,
    this.labels = _steps,
  });
  final List<String> labels;
  final int step;
  final int reached;
  final ValueChanged<int>? onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Row(
      children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(
            child: Semantics(
              button: i <= reached,
              label: 'Schritt ${i + 1}: ${labels[i]}',
              excludeSemantics: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap == null || i > reached ? null : () => onTap!(i),
                child: SizedBox(
                  height: 24,
                  child: Center(
                    child: AnimatedContainer(
                      duration: context.motion(HavenMotion.d3),
                      curve: HavenMotion.out,
                      height: i == step ? 6 : 4,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        color: i <= step
                            ? hv.acc
                            : (i <= reached
                                  ? hv.acc.withValues(alpha: 0.35)
                                  : hv.s3),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ---- Gemeinsame Bausteine -------------------------------------------------

class StepScroll extends StatelessWidget {
  const StepScroll({
    super.key,
    required this.title,
    this.lead,
    required this.children,
  });
  final String title;
  final String? lead;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return ListView(
      // Im Bearbeiten-Sheet des Dashboards zieht das obere Ende das Sheet.
      controller: HavenSheetScope.maybeOf(context)?.scrollController,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      children: [
        Text(title, style: HavenText.section.copyWith(color: hv.tx)),
        if (lead != null) ...[
          const SizedBox(height: 4),
          Text(
            lead!,
            style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14.5),
          ),
        ],
        const SizedBox(height: 16),
        ...children,
      ],
    );
  }
}

/// Auswahlzeile mit Haken bzw. Kreis.
class PickRow extends StatelessWidget {
  const PickRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    required this.selected,
    this.onTap,
    this.multi = false,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final bool selected;
  final VoidCallback? onTap;
  final bool multi;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final enabled = onTap != null;
    final row = AnimatedContainer(
      duration: context.motion(HavenMotion.d2),
      constraints: const BoxConstraints(minHeight: 60),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: selected ? hv.acc.withValues(alpha: 0.10) : hv.s1,
        borderRadius: BorderRadius.circular(HavenRadii.m),
        border: Border.all(color: selected ? hv.acc : hv.ln),
      ),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: HavenText.label.copyWith(color: hv.tx, fontSize: 15),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: HavenText.caption.copyWith(color: hv.tx2),
                  ),
              ],
            ),
          ),
          AnimatedContainer(
            duration: context.motion(HavenMotion.d2),
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              shape: multi ? BoxShape.rectangle : BoxShape.circle,
              borderRadius: multi ? BorderRadius.circular(7) : null,
              color: selected ? hv.acc : null,
              border: Border.all(color: selected ? hv.acc : hv.ln2, width: 2),
            ),
            child: selected
                ? Icon(Icons.check_rounded, size: 16, color: hv.ai)
                : null,
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Semantics(
          button: enabled,
          selected: selected,
          label: subtitle == null ? title : '$title, $subtitle',
          excludeSemantics: true,
          child: PressScale(
            pressedScale: 0.985,
            onTap: onTap == null
                ? null
                : () {
                    Haptics.tap();
                    onTap!();
                  },
            child: row,
          ),
        ),
      ),
    );
  }
}

// ---- 1. Raum --------------------------------------------------------------

class KnobRoomStep extends ConsumerWidget {
  const KnobRoomStep({
    super.key,
    required this.draft,
    required this.all,
    required this.onPick,
  });
  final HavenAutomation draft;
  final HavenAutomations all;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final order = [for (final r in ref.watch(snapshotProvider).rooms) r.id];
    final rooms = all.rooms.values.toList()
      ..sort((a, b) {
        final ia = order.indexOf(a.areaId), ib = order.indexOf(b.areaId);
        return (ia < 0 ? 999 : ia).compareTo(ib < 0 ? 999 : ib);
      });
    return StepScroll(
      title: 'Welcher Raum?',
      lead: 'Die Regler steuern das Licht dieses Raums.',
      children: [
        if (rooms.isEmpty)
          Text(
            'Keine Räume gefunden. Leg in Home Assistant Bereiche an.',
            style: HavenText.body.copyWith(color: context.hv.tx2),
          ),
        for (final r in rooms)
          PickRow(
            title: r.name,
            subtitle: _roomSubtitle(r, all),
            leading: Icon(Icons.meeting_room_outlined, color: context.hv.tx2),
            selected: draft.roomAreaId == r.areaId,
            onTap: r.hasLights ? () => onPick(r.areaId) : null,
          ),
      ],
    );
  }

  static String _roomSubtitle(AutomationRoom r, HavenAutomations all) {
    if (!r.hasLights) return 'Keine Lichter';
    final existing = all.automations
        .where((a) => a.roomAreaId == r.areaId)
        .length;
    final base = r.group != null
        ? '${r.group} · ${r.scenes.length == 1 ? '1 Szene' : '${r.scenes.length} Szenen'}'
        : '${r.lights.length} Lichter einzeln, ohne Z2M-Gruppe';
    return existing == 0
        ? base
        : '$base · schon $existing ${existing == 1 ? 'Automation' : 'Automationen'}';
  }
}

// ---- 2. Regler ----------------------------------------------------------------

class KnobDeviceStep extends ConsumerWidget {
  const KnobDeviceStep({
    super.key,
    required this.draft,
    required this.all,
    required this.onChanged,
  });
  final HavenAutomation draft;
  final HavenAutomations all;
  final ValueChanged<HavenAutomation> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final knobs = ref.watch(knobDevicesProvider);
    final room = all.rooms[draft.roomAreaId];
    final inRoom = [
      for (final k in knobs)
        if (k.roomId == draft.roomAreaId) k,
    ];
    final others = [
      for (final k in knobs)
        if (k.roomId != draft.roomAreaId) k,
    ];
    final conflicts = ref.watch(haConflictsProvider(draft));

    Widget row(ZbDeviceView k) {
      final owner = all.ownerOf(k.ieee, exceptId: draft.id, type: 'room_knob');
      final selected = draft.devices.contains(k.ieee);
      final kind = k.device.deviceType == 'remote' ? 'Taster' : 'Drehregler';
      return PickRow(
        multi: true,
        title: k.name,
        subtitle: owner != null && draft.enabled
            ? 'steuert schon ${all.rooms[owner.roomAreaId]?.name ?? owner.name}'
            : [
                kind,
                if (k.roomName != null && k.roomId != draft.roomAreaId)
                  k.roomName!,
                if (k.battery != null) 'Batterie ${k.battery} %',
              ].join(' · '),
        leading: GestureGlyph(
          icon: k.device.deviceType == 'remote'
              ? Icons.radio_button_checked_rounded
              : kRotateIcon,
          size: 40,
          active: selected,
        ),
        selected: selected,
        onTap: owner != null && draft.enabled && !selected
            ? null
            : () => onChanged(
                draft.copyWith(
                  devices: selected
                      ? [
                          for (final d in draft.devices)
                            if (d != k.ieee) d,
                        ]
                      : [...draft.devices, k.ieee],
                ),
              ),
      );
    }

    return StepScroll(
      title: 'Welche Regler und Taster?',
      lead: 'Alle gewählten Geräte machen dasselbe.',
      children: [
        if (knobs.isEmpty)
          Text(
            'Keine Drehregler oder Taster gefunden. Lern sie unter Zigbee an.',
            style: HavenText.body.copyWith(color: hv.tx2),
          ),
        if (inRoom.isNotEmpty) ...[
          FieldLabel('Im Raum ${room?.name ?? ''}'.trim()),
          for (final k in inRoom) row(k),
        ],
        if (others.isNotEmpty) ...[
          FieldLabel(inRoom.isEmpty ? 'Alle Geräte' : 'Weitere'),
          for (final k in others) row(k),
        ],
        if (conflicts.isNotEmpty) ...[
          const SizedBox(height: 8),
          HaConflictCard(conflicts: conflicts),
        ],
      ],
    );
  }
}

class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
    child: Text(
      text.toUpperCase(),
      style: HavenText.caption.copyWith(
        color: context.hv.tx3,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
      ),
    ),
  );
}

// ---- 3. Gesten ----------------------------------------------------------------

class KnobGestureStep extends StatelessWidget {
  const KnobGestureStep({
    super.key,
    required this.draft,
    required this.room,
    required this.onChanged,
  });
  final HavenAutomation draft;
  final AutomationRoom? room;
  final ValueChanged<HavenAutomation> onChanged;

  Future<void> _pick(BuildContext context, KnobGesture g) async {
    final scenes = room?.scenes ?? const <GroupScene>[];
    final current = draft.options.binding(g);
    final options = <GestureBinding>[
      for (final a in GestureAction.forGesture(g))
        if (a == GestureAction.scene)
          for (final s in scenes) GestureBinding(a, scene: s.id)
        else if (a != GestureAction.nextScene || room?.group != null)
          GestureBinding(a),
    ];
    final picked = await showHavenSheet<GestureBinding>(
      context,
      builder: (ctx) {
        final hv = ctx.hv;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                GestureGlyph(icon: gestureIcon(g), size: 40, active: true),
                const SizedBox(width: 12),
                Text(
                  gestureLabel(g),
                  style: HavenText.section.copyWith(color: hv.tx),
                ),
              ],
            ),
            const SizedBox(height: 14),
            for (final b in options)
              PickRow(
                title: bindingLabel(g, b, scenes),
                subtitle: _hint(b),
                selected: b == current,
                onTap: () => Navigator.of(ctx).pop(b),
              ),
          ],
        );
      },
    );
    if (picked != null) {
      onChanged(draft.copyWith(options: draft.options.withBinding(g, picked)));
    }
  }

  static String? _hint(GestureBinding b) => switch (b.action) {
    GestureAction.brightness => 'Rechts heller, links dunkler',
    GestureAction.toggle => 'An, wenn alles aus ist, sonst aus',
    GestureAction.nextScene => 'Szenen der Reihe nach',
    GestureAction.off => 'Alle Lichter im Raum aus',
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final scenes = room?.scenes ?? const <GroupScene>[];
    return StepScroll(
      title: 'Was soll passieren?',
      lead: 'Tipp auf eine Geste, um sie zu belegen.',
      children: [
        for (final g in KnobGesture.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Semantics(
              button: true,
              label:
                  '${gestureLabel(g)}: ${bindingLabel(g, draft.options.binding(g), scenes)}',
              excludeSemantics: true,
              child: PressScale(
                pressedScale: 0.985,
                onTap: () => _pick(context, g),
                child: HavenCard(
                  padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
                  child: Row(
                    children: [
                      GestureGlyph(
                        icon: gestureIcon(g),
                        size: 48,
                        active:
                            draft.options.binding(g).action !=
                            GestureAction.none,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              gestureLabel(g),
                              style: HavenText.caption.copyWith(color: hv.tx2),
                            ),
                            Text(
                              bindingLabel(g, draft.options.binding(g), scenes),
                              style: HavenText.headline.copyWith(
                                color:
                                    draft.options.binding(g).action ==
                                        GestureAction.none
                                    ? hv.tx3
                                    : hv.tx,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, color: hv.tx3),
                    ],
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 4),
        Text(
          'Geht mit Reglern im Modus „event“ und „command“.',
          style: HavenText.caption.copyWith(color: hv.tx3),
        ),
      ],
    );
  }
}

// ---- 4. Szenen ------------------------------------------------------------------

class KnobSceneStep extends StatelessWidget {
  const KnobSceneStep({
    super.key,
    required this.draft,
    required this.room,
    required this.onChanged,
  });
  final HavenAutomation draft;
  final AutomationRoom? room;
  final ValueChanged<HavenAutomation> onChanged;

  void _setScenes(List<int>? scenes) => onChanged(
    draft.copyWith(
      options: scenes == null
          ? draft.options.copyWith(clearScenes: true)
          : draft.options.copyWith(scenes: scenes),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final all = room?.scenes ?? const <GroupScene>[];
    if (room?.group == null || all.isEmpty) {
      return StepScroll(
        title: 'Szenen',
        lead: room?.group == null
            ? 'Dieser Raum hat keine Z2M-Gruppe. Szenen gibt es nur mit Gruppe, '
                  'Helligkeit und Ein/Aus gehen trotzdem.'
            : 'Die Gruppe ${room!.group} hat noch keine Szenen.',
        children: const [],
      );
    }
    final ordered = orderedScenes(all, draft.options.scenes);
    final chosen = [
      for (final (s, on) in ordered)
        if (on) s.id,
    ];
    final onScene = draft.options.onScene;
    return ListView(
      // Im Bearbeiten-Sheet des Dashboards zieht das obere Ende das Sheet.
      controller: HavenSheetScope.maybeOf(context)?.scrollController,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      children: [
        Text('Szenen', style: HavenText.section.copyWith(color: hv.tx)),
        const SizedBox(height: 4),
        Text(
          'Doppelt drücken schaltet in dieser Reihenfolge weiter. Zum Sortieren '
          'am Griff ziehen.',
          style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14.5),
        ),
        const SizedBox(height: 12),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          proxyDecorator: (child, _, _) =>
              Material(color: Colors.transparent, child: child),
          onReorderItem: (from, to) {
            final ids = [for (final (s, _) in ordered) s.id];
            final id = ids.removeAt(from);
            ids.insert(to, id);
            final on = {...chosen};
            Haptics.tap();
            _setScenes([
              for (final x in ids)
                if (on.contains(x)) x,
            ]);
          },
          children: [
            for (final (i, (s, on)) in ordered.indexed)
              PickRow(
                key: ValueKey(s.id),
                multi: true,
                title: s.name,
                subtitle: on
                    ? '${chosen.indexOf(s.id) + 1}. im Umlauf'
                    : 'nicht im Umlauf',
                leading: ReorderableDragStartListener(
                  index: i,
                  child: SizedBox(
                    width: 32,
                    height: 40,
                    child: Icon(Icons.drag_indicator_rounded, color: hv.tx3),
                  ),
                ),
                selected: on,
                onTap: () => _setScenes(
                  on
                      ? [
                          for (final x in chosen)
                            if (x != s.id) x,
                        ]
                      : [...chosen, s.id],
                ),
              ),
          ],
        ),
        if (draft.options.scenes != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => _setScenes(null),
              child: Text(
                'Alle in Z2M-Reihenfolge',
                style: HavenText.label.copyWith(color: hv.acc),
              ),
            ),
          ),
        const SizedBox(height: 18),
        Text(
          'Beim Einschalten',
          style: HavenText.headline.copyWith(color: hv.tx),
        ),
        const SizedBox(height: 10),
        HavenSegmented<bool>(
          options: const [(false, 'Zuletzt'), (true, 'Bestimmte Szene')],
          selected: onScene != null,
          onChanged: (v) => onChanged(
            draft.copyWith(
              options: v
                  ? draft.options.copyWith(
                      onScene: chosen.firstOrNull ?? all.first.id,
                    )
                  : draft.options.copyWith(clearOnScene: true),
            ),
          ),
        ),
        if (onScene != null) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in all)
                OptionChip(
                  label: s.name,
                  selected: s.id == onScene,
                  onTap: () => onChanged(
                    draft.copyWith(
                      options: draft.options.copyWith(onScene: s.id),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class OptionChip extends StatelessWidget {
  const OptionChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: PressScale(
        onTap: () {
          Haptics.tap();
          onTap();
        },
        child: AnimatedContainer(
          duration: context.motion(HavenMotion.d2),
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? hv.acc : hv.s1,
            borderRadius: BorderRadius.circular(HavenRadii.pill),
            border: Border.all(color: selected ? hv.acc : hv.ln),
          ),
          child: Text(
            label,
            style: HavenText.label.copyWith(color: selected ? hv.ai : hv.tx),
          ),
        ),
      ),
    );
  }
}

// ---- 5. Optionen -------------------------------------------------------------

class KnobOptionsStep extends StatefulWidget {
  const KnobOptionsStep({
    super.key,
    required this.draft,
    required this.onChanged,
  });
  final HavenAutomation draft;
  final ValueChanged<HavenAutomation> onChanged;

  @override
  State<KnobOptionsStep> createState() => _KnobOptionsStepState();
}

class _KnobOptionsStepState extends State<KnobOptionsStep> {
  late final _name = TextEditingController(text: widget.draft.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  HavenAutomation get d => widget.draft;
  void _opts(KnobOptions o) => widget.onChanged(d.copyWith(options: o));

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final o = d.options;
    final rotates =
        o.binding(KnobGesture.rotate).action == GestureAction.brightness;
    return StepScroll(
      title: 'Feinschliff',
      children: [
        FieldLabel('Name'),
        Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: hv.s1,
            borderRadius: BorderRadius.circular(HavenRadii.m),
            border: Border.all(color: hv.ln),
          ),
          alignment: Alignment.centerLeft,
          child: TextField(
            controller: _name,
            onChanged: (v) => widget.onChanged(d.copyWith(name: v)),
            style: HavenText.body.copyWith(color: hv.tx),
            cursorColor: hv.acc,
            decoration: InputDecoration.collapsed(
              hintText: 'z. B. Drehregler Salon',
              hintStyle: HavenText.body.copyWith(color: hv.tx3),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Opacity(
          opacity: rotates ? 1 : 0.45,
          child: IgnorePointer(
            ignoring: !rotates,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ValueHeader(
                  'Schrittweite',
                  '${stepPercent(o.step)} % je Rastung',
                ),
                SizedBox(
                  height: 44,
                  child: BrightnessSlider(
                    axis: Axis.horizontal,
                    label: 'Schrittweite',
                    value: stepPercent(o.step).clamp(1, 100),
                    colors: [hv.acc2.withValues(alpha: 0.7), hv.acc],
                    onChanged: (p) => _opts(
                      o.copyWith(step: stepFromPercent(p.clamp(2, 60))),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                ValueHeader(
                  'Mindesthelligkeit',
                  '${stepPercent(o.minBrightness)} %',
                ),
                SizedBox(
                  height: 44,
                  child: BrightnessSlider(
                    axis: Axis.horizontal,
                    label: 'Mindesthelligkeit',
                    value: stepPercent(o.minBrightness).clamp(1, 100),
                    colors: [hv.acc2.withValues(alpha: 0.7), hv.acc],
                    onChanged: (p) => _opts(
                      o.copyWith(
                        minBrightness: stepFromPercent(p.clamp(1, 50)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                ValueHeader(
                  'Übergang',
                  '${o.transition.toStringAsFixed(1).replaceAll('.', ',')} s',
                ),
                const SizedBox(height: 6),
                HavenSegmented<double>(
                  options: const [
                    (0.0, 'Sofort'),
                    (0.2, '0,2 s'),
                    (0.5, '0,5 s'),
                    (1.0, '1 s'),
                  ],
                  selected: o.transition,
                  neutral: true,
                  onChanged: (v) => _opts(o.copyWith(transition: v)),
                ),
                const SizedBox(height: 14),
                SwitchRow(
                  title: 'Am Minimum ausschalten',
                  subtitle: 'Weiter nach links drehen schaltet aus',
                  value: o.offAtMin,
                  onChanged: (v) => _opts(o.copyWith(offAtMin: v)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class ValueHeader extends StatelessWidget {
  const ValueHeader(this.title, this.value, {super.key});
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: HavenText.label.copyWith(color: hv.tx)),
          ),
          Text(value, style: HavenText.label.copyWith(color: hv.tx2)),
        ],
      ),
    );
  }
}

class SwitchRow extends StatelessWidget {
  const SwitchRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      decoration: BoxDecoration(
        color: hv.s1,
        borderRadius: BorderRadius.circular(HavenRadii.m),
        border: Border.all(color: hv.ln),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: HavenText.label.copyWith(color: hv.tx)),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: HavenText.caption.copyWith(color: hv.tx2),
                  ),
              ],
            ),
          ),
          HavenSwitch(value: value, semanticLabel: title, onChanged: onChanged),
        ],
      ),
    );
  }
}

// ---- 7. Zusammenfassung -------------------------------------------------------

class _SummaryStep extends ConsumerWidget {
  const _SummaryStep({
    required this.draft,
    required this.all,
    required this.onChanged,
    this.onDelete,
  });
  final HavenAutomation draft;
  final HavenAutomations all;
  final ValueChanged<HavenAutomation> onChanged;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final room = all.rooms[draft.roomAreaId];
    final names = ref.watch(knobDeviceNamesProvider);
    final scenes = room?.scenes ?? const <GroupScene>[];
    final o = draft.options;
    final cycle = [
      for (final (s, on) in orderedScenes(scenes, o.scenes))
        if (on) s.name,
    ];
    final conflicts = ref.watch(haConflictsProvider(draft));

    Widget line(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(k, style: HavenText.body.copyWith(color: hv.tx2)),
          ),
          Expanded(
            child: Text(v, style: HavenText.label.copyWith(color: hv.tx)),
          ),
        ],
      ),
    );

    return StepScroll(
      title: 'Alles klar?',
      children: [
        HavenCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              line('Raum', room?.name ?? draft.roomAreaId),
              line(
                'Geräte',
                [for (final d in draft.devices) names[d] ?? d].join(', '),
              ),
              for (final g in KnobGesture.values)
                line(gestureLabel(g), bindingLabel(g, o.binding(g), scenes)),
              if (room?.group != null && cycle.isNotEmpty)
                line('Szenen', cycle.join(' → ')),
              line(
                'Einschalten',
                o.onScene == null
                    ? 'wie zuletzt'
                    : 'Szene ${scenes.where((s) => s.id == o.onScene).firstOrNull?.name ?? o.onScene}',
              ),
              line(
                'Drehen',
                '${stepPercent(o.step)} % je Rastung, mindestens '
                    '${stepPercent(o.minBrightness)} %'
                    '${o.offAtMin ? ', dann aus' : ''}',
              ),
              if (room != null && room.group == null)
                line('Steuerung', 'Lichter einzeln über Home Assistant'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SwitchRow(
          title: 'Aktiv',
          subtitle: 'Aus: Die Regler tun nichts',
          value: draft.enabled,
          onChanged: (v) => onChanged(draft.copyWith(enabled: v)),
        ),
        if (conflicts.isNotEmpty) ...[
          const SizedBox(height: 12),
          HaConflictCard(conflicts: conflicts),
        ],
        if (onDelete != null) ...[
          const SizedBox(height: 20),
          HavenButton(
            label: 'Automation löschen',
            icon: Icons.delete_outline_rounded,
            destructive: true,
            onTap: onDelete,
          ),
        ],
      ],
    );
  }
}
