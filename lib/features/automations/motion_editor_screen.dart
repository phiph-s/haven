import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
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
import '../zigbee/zigbee_providers.dart';
import 'haven_automations_provider.dart';
import 'knob_editor_screen.dart';
import 'knob_widgets.dart';
import 'motion_live_test.dart';
import 'motion_logic.dart';

/// Pfad des Bewegungslicht-Editors (neu bzw. vorhandene Automation).
String motionEditorPath([String? id]) => '/automations/motion/${id ?? 'new'}';

/// Assistent bzw. Editor „Bewegungslicht“: Raum, Melder, Wann aktiv, Licht,
/// Nachlauf, Live-Test, Speichern. Aufbau wie [KnobEditorScreen].
class MotionEditorScreen extends ConsumerStatefulWidget {
  const MotionEditorScreen({
    super.key,
    this.id,
    this.initialRoom,
    this.initialStep,
    this.demo = false,
  });

  final String? id;
  final String? initialRoom;
  final int? initialStep;

  /// Live-Test mit Beispielen füllen (Screenshots).
  final bool demo;

  @override
  ConsumerState<MotionEditorScreen> createState() => _MotionEditorScreenState();
}

class _MotionEditorScreenState extends ConsumerState<MotionEditorScreen> {
  HavenAutomation? _draft;
  late int _step = (widget.initialStep ?? 0).clamp(0, kMotionSteps.length - 1);
  int _reached = 0;
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.id == null;

  @override
  void initState() {
    super.initState();
    _reached = _isNew ? _step : kMotionSteps.length - 1;
  }

  HavenAutomation? _ensureDraft(HavenAutomations? all) {
    if (_draft != null) return _draft;
    if (all == null) return null;
    if (!_isNew) {
      _draft = all.byId(widget.id!);
      return _draft;
    }
    var d = const HavenAutomation(
      type: kMotionType,
      name: '',
      roomAreaId: '',
      motion: MotionOptions(),
    );
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
  ) {
    final name = all.rooms[areaId]?.name ?? areaId;
    final oldDefault =
        d.name.isEmpty ||
        d.name == 'Bewegungslicht ${all.rooms[d.roomAreaId]?.name ?? ''}';
    var devices = d.devices;
    if (devices.isEmpty) {
      devices = [
        for (final k in ref.read(motionDevicesProvider))
          if (k.roomId == areaId &&
              all.ownerOf(k.ieee, exceptId: d.id, type: kMotionType) == null)
            k.ieee,
      ];
    }
    final o = d.motion ?? const MotionOptions();
    // Szenen eines anderen Raums gelten hier nicht.
    final changed = d.roomAreaId != areaId;
    return d.copyWith(
      roomAreaId: areaId,
      name: oldDefault ? 'Bewegungslicht $name' : d.name,
      devices: devices,
      motion: changed
          ? o.copyWith(
              light: o.light.isScene && o.light.sceneEntity == null
                  ? o.light.asBrightness()
                  : o.light,
              night: o.night?.copyWith(
                light:
                    o.night!.light.isScene && o.night!.light.sceneEntity == null
                    ? o.night!.light.asBrightness()
                    : o.night!.light,
              ),
            )
          : o,
    );
  }

  void _update(HavenAutomation d) => setState(() {
    _draft = d;
    _error = null;
  });

  void _opts(MotionOptions o) => _update(_draft!.copyWith(motion: o));

  void _go(int step) {
    Haptics.tap();
    setState(() {
      _step = step.clamp(0, kMotionSteps.length - 1);
      if (_step > _reached) _reached = _step;
      _error = null;
    });
  }

  void _close() =>
      context.canPop() ? context.pop() : context.go('/automations');

  Future<void> _next(HavenAutomations all) async {
    final errors = validateMotionDraft(
      _draft!,
      all,
      deviceNames: ref.read(knobDeviceNamesProvider),
    );
    if (_step < kMotionSteps.length - 1) {
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
              'Der Melder schaltet danach kein Licht mehr.',
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

    final last = _step == kMotionSteps.length - 1;
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
                          'Schritt ${_step + 1} von ${kMotionSteps.length} · ${kMotionSteps[_step]}',
                          style: HavenText.caption.copyWith(color: hv.tx2),
                        ),
                        Text(
                          _isNew
                              ? 'Bewegungslicht'
                              : (draft?.name ?? 'Bewegungslicht'),
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
                labels: kMotionSteps,
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
    final o = d.motion ?? const MotionOptions();
    return switch (_step) {
      0 => _RoomStep(
        draft: d,
        all: all,
        onPick: (id) => _update(_withRoom(d, id, all)),
      ),
      1 => _DetectorStep(draft: d, all: all, onChanged: _update),
      2 => _WhenStep(draft: d, options: o, onChanged: _opts),
      3 => _LightStep(draft: d, room: room, options: o, onChanged: _opts),
      4 => _DelayStep(draft: d, options: o, onChanged: _update),
      5 => MotionLiveTest(automation: d, demo: widget.demo),
      _ => _SummaryStep(
        draft: d,
        all: all,
        onChanged: _update,
        onDelete: _isNew ? null : _delete,
      ),
    };
  }
}

// ---- 1. Raum --------------------------------------------------------------

class _RoomStep extends ConsumerWidget {
  const _RoomStep({
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
      lead: 'Der Melder schaltet das Licht dieses Raums.',
      children: [
        if (rooms.isEmpty)
          Text(
            'Keine Räume gefunden. Leg in Home Assistant Bereiche an.',
            style: HavenText.body.copyWith(color: context.hv.tx2),
          ),
        for (final r in rooms)
          PickRow(
            title: r.name,
            subtitle: r.hasLights
                ? (r.group != null
                      ? '${r.group} · ${r.scenes.length == 1 ? '1 Szene' : '${r.scenes.length} Szenen'}'
                      : '${r.lights.length} Lichter einzeln, ohne Z2M-Gruppe')
                : 'Keine Lichter',
            leading: Icon(Icons.meeting_room_outlined, color: context.hv.tx2),
            selected: draft.roomAreaId == r.areaId,
            onTap: r.hasLights ? () => onPick(r.areaId) : null,
          ),
      ],
    );
  }
}

// ---- 2. Melder -----------------------------------------------------------

/// Helligkeit des Melders in lx (Entity `sensor.*` mit `illuminance`), sonst `null`.
({String id, double? value})? illuminanceOf(ZbDeviceView v) {
  for (final e in v.entities) {
    if (e.domain == 'sensor' &&
        (e.attributes['device_class'] == 'illuminance' ||
            e.entityId.endsWith('_illuminance'))) {
      return (id: e.entityId, value: e.number);
    }
  }
  return null;
}

class _DetectorStep extends ConsumerWidget {
  const _DetectorStep({
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
    final devices = ref.watch(motionDevicesProvider);
    final room = all.rooms[draft.roomAreaId];
    final inRoom = [
      for (final k in devices)
        if (k.roomId == draft.roomAreaId) k,
    ];
    final others = [
      for (final k in devices)
        if (k.roomId != draft.roomAreaId) k,
    ];
    final conflicts = ref.watch(haConflictsProvider(draft));

    Widget row(ZbDeviceView k) {
      final owner = all.ownerOf(k.ieee, exceptId: draft.id, type: kMotionType);
      final selected = draft.devices.contains(k.ieee);
      final lux = illuminanceOf(k)?.value;
      return PickRow(
        multi: true,
        title: k.name,
        subtitle: owner != null && draft.enabled
            ? 'meldet schon für ${all.rooms[owner.roomAreaId]?.name ?? owner.name}'
            : [
                k.device.deviceType == 'presence' ? 'Anwesenheit' : 'Bewegung',
                if (lux != null) '${lux.round()} lx',
                if (k.roomName != null && k.roomId != draft.roomAreaId)
                  k.roomName!,
                if (k.battery != null) 'Batterie ${k.battery} %',
              ].join(' · '),
        leading: GestureGlyph(
          icon: k.device.deviceType == 'presence'
              ? Icons.sensors_rounded
              : Icons.directions_walk_rounded,
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
      title: 'Welcher Melder?',
      lead: 'Bewegung oder Anwesenheit. Mehrere Melder gelten zusammen.',
      children: [
        if (devices.isEmpty)
          Text(
            'Keine Bewegungs- oder Präsenzmelder gefunden. Lern sie unter Zigbee an.',
            style: HavenText.body.copyWith(color: hv.tx2),
          ),
        if (inRoom.isNotEmpty) ...[
          FieldLabel('Im Raum ${room?.name ?? ''}'.trim()),
          for (final k in inRoom) row(k),
        ],
        if (others.isNotEmpty) ...[
          FieldLabel(inRoom.isEmpty ? 'Alle Melder' : 'Weitere'),
          for (final k in others) row(k),
        ],
        if (conflicts.isNotEmpty) ...[
          const SizedBox(height: 8),
          HaConflictCard(conflicts: conflicts, what: 'Melder'),
        ],
      ],
    );
  }
}

// ---- 3. Wann aktiv -------------------------------------------------------

class _WhenStep extends ConsumerWidget {
  const _WhenStep({
    required this.draft,
    required this.options,
    required this.onChanged,
  });
  final HavenAutomation draft;
  final MotionOptions options;
  final ValueChanged<MotionOptions> onChanged;

  MotionOptions get o => options;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final views = ref.watch(zigbeeViewsProvider);
    final mine = [
      for (final v in views)
        if (draft.devices.contains(v.ieee)) v,
    ];
    final own = mine.map(illuminanceOf).nonNulls.firstOrNull;
    final snapshot = ref.watch(snapshotProvider);
    final luxEntity = o.luxEntity ?? own?.id;
    final liveLux = luxEntity == null
        ? null
        : snapshot.entity(luxEntity)?.number;
    final others = [
      for (final e in snapshot.entities.values)
        if (e.domain == 'sensor' &&
            e.attributes['device_class'] == 'illuminance' &&
            e.entityId != own?.id)
          e,
    ];

    final windows = o.windows;
    final sun = o.sun;

    return StepScroll(
      title: 'Wann soll es gelten?',
      lead:
          'Alle Bedingungen zusammen müssen erfüllt sein. Ohne Bedingung '
          'schaltet der Melder immer.',
      children: [
        _Block(
          title: 'Zeitfenster',
          subtitle: windows.isEmpty
              ? 'Zu jeder Uhrzeit'
              : windows.map((w) => windowLabel(w.from, w.to)).join(' und '),
          on: windows.isNotEmpty,
          onToggle: (v) => onChanged(
            o.copyWith(
              windows: v ? const [TimeWindow('18:00', '07:00')] : const [],
            ),
          ),
          children: [
            for (final (i, w) in windows.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: _TimeBox(
                        label: 'Von',
                        value: w.from,
                        onTap: () async {
                          final v = await _pickTime(context, w.from);
                          if (v == null) return;
                          onChanged(
                            o.copyWith(
                              windows: [...windows]..[i] = TimeWindow(v, w.to),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _TimeBox(
                        label: 'Bis',
                        value: w.to,
                        hint: windowCrossesMidnight(w.from, w.to)
                            ? 'nächster Tag'
                            : null,
                        onTap: () async {
                          final v = await _pickTime(context, w.to);
                          if (v == null) return;
                          onChanged(
                            o.copyWith(
                              windows: [...windows]
                                ..[i] = TimeWindow(w.from, v),
                            ),
                          );
                        },
                      ),
                    ),
                    RoundIconButton(
                      icon: Icons.close_rounded,
                      label: 'Zeitfenster entfernen',
                      onTap: () => onChanged(
                        o.copyWith(
                          windows: [
                            for (final (j, x) in windows.indexed)
                              if (j != i) x,
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (windows.length < 6)
              Align(
                alignment: Alignment.centerLeft,
                child: OptionChip(
                  label: 'Weiteres Zeitfenster',
                  selected: false,
                  onTap: () => onChanged(
                    o.copyWith(
                      windows: [...windows, const TimeWindow('06:00', '09:00')],
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        _Block(
          title: 'Sonnenstand',
          subtitle: sun == null ? 'Egal' : sunWindowLabel(sun),
          on: sun != null,
          onToggle: (v) => onChanged(
            v
                ? o.copyWith(
                    sun: const SunWindow(
                      from: SunEdge('sunset'),
                      until: SunEdge('sunrise'),
                    ),
                  )
                : o.copyWith(clearSun: true),
          ),
          children: [
            if (sun != null) ...[
              HavenSegmented<int>(
                neutral: true,
                options: const [
                  (0, 'Nachts'),
                  (1, 'Abends'),
                  (2, 'Morgens'),
                ],
                selected: sun.from != null && sun.until != null
                    ? 0
                    : (sun.from != null ? 1 : 2),
                onChanged: (v) => onChanged(
                  o.copyWith(
                    sun: switch (v) {
                      0 => const SunWindow(
                        from: SunEdge('sunset'),
                        until: SunEdge('sunrise'),
                      ),
                      1 => const SunWindow(from: SunEdge('sunset')),
                      _ => const SunWindow(until: SunEdge('sunrise')),
                    },
                  ),
                ),
              ),
              if (sun.from != null) ...[
                const SizedBox(height: 10),
                _OffsetRow(
                  label: sunEventLabel(sun.from!.event),
                  offset: sun.from!.offset,
                  onChanged: (v) => onChanged(
                    o.copyWith(
                      sun: SunWindow(
                        from: SunEdge(sun.from!.event, v),
                        until: sun.until,
                      ),
                    ),
                  ),
                ),
              ],
              if (sun.until != null) ...[
                const SizedBox(height: 10),
                _OffsetRow(
                  label: sunEventLabel(sun.until!.event),
                  offset: sun.until!.offset,
                  onChanged: (v) => onChanged(
                    o.copyWith(
                      sun: SunWindow(
                        from: sun.from,
                        until: SunEdge(sun.until!.event, v),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
        const SizedBox(height: 12),
        _Block(
          title: 'Helligkeit',
          subtitle: o.luxBelow == null
              ? 'Egal'
              : 'Nur unter ${luxLabel(o.luxBelow!)}'
                    '${liveLux == null ? '' : ' · jetzt ${liveLux.round()} lx'}',
          on: o.luxBelow != null,
          onToggle: (v) => onChanged(
            v ? o.copyWith(luxBelow: 30) : o.copyWith(clearLux: true),
          ),
          children: [
            if (o.luxBelow != null) ...[
              ValueHeader('Schwelle', 'unter ${luxLabel(o.luxBelow!)}'),
              SizedBox(
                height: 44,
                child: BrightnessSlider(
                  axis: Axis.horizontal,
                  label: 'Helligkeitsschwelle',
                  value: luxToPercent(o.luxBelow!),
                  colors: [hv.acc2.withValues(alpha: 0.7), hv.acc],
                  onChanged: (p) =>
                      onChanged(o.copyWith(luxBelow: percentToLux(p))),
                ),
              ),
              const SizedBox(height: 12),
              ValueHeader(
                'Sensor',
                liveLux == null ? 'kein Wert' : 'jetzt ${liveLux.round()} lx',
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OptionChip(
                    label: own == null ? 'Sensor des Melders' : 'Melder',
                    selected: o.luxEntity == null,
                    onTap: () => onChanged(o.copyWith(clearLuxEntity: true)),
                  ),
                  for (final e in others.take(6))
                    OptionChip(
                      label: e.name,
                      selected: o.luxEntity == e.entityId,
                      onTap: () => onChanged(o.copyWith(luxEntity: e.entityId)),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Die Helligkeit zählt nur, solange das Licht aus ist. Sonst '
                'misst der Sensor das eigene Licht.',
                style: HavenText.caption.copyWith(color: hv.tx2),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// Block mit Schalter und aufklappbarem Inhalt.
class _Block extends StatelessWidget {
  const _Block({
    required this.title,
    required this.subtitle,
    required this.on,
    required this.onToggle,
    required this.children,
  });
  final String title;
  final String subtitle;
  final bool on;
  final ValueChanged<bool> onToggle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return AnimatedSize(
      duration: context.motion(HavenMotion.d2),
      curve: HavenMotion.out,
      alignment: Alignment.topCenter,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 0),
        decoration: BoxDecoration(
          color: hv.s1,
          borderRadius: BorderRadius.circular(HavenRadii.m),
          border: Border.all(color: on ? hv.acc.withValues(alpha: 0.5) : hv.ln),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: HavenText.label.copyWith(color: hv.tx),
                        ),
                        Text(
                          subtitle,
                          style: HavenText.caption.copyWith(color: hv.tx2),
                        ),
                      ],
                    ),
                  ),
                ),
                HavenSwitch(
                  value: on,
                  semanticLabel: title,
                  onChanged: onToggle,
                ),
              ],
            ),
            if (on && children.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 4, 8, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TimeBox extends StatelessWidget {
  const _TimeBox({
    required this.label,
    required this.value,
    required this.onTap,
    this.hint,
  });
  final String label;
  final String value;
  final String? hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      button: true,
      label: '$label $value',
      excludeSemantics: true,
      child: PressScale(
        onTap: () {
          Haptics.tap();
          onTap();
        },
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: hv.s2,
            borderRadius: BorderRadius.circular(HavenRadii.s),
            border: Border.all(color: hv.ln),
          ),
          child: Row(
            children: [
              Text(label, style: HavenText.caption.copyWith(color: hv.tx2)),
              const Spacer(),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(value, style: HavenText.headline.copyWith(color: hv.tx)),
                  if (hint != null)
                    Text(
                      hint!,
                      style: HavenText.caption.copyWith(
                        color: hv.tx3,
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Versatz zu einem Sonnenereignis in 15-Minuten-Schritten.
class _OffsetRow extends StatelessWidget {
  const _OffsetRow({
    required this.label,
    required this.offset,
    required this.onChanged,
  });
  final String label;
  final int offset;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final text = offset == 0
        ? 'genau'
        : '${offset.abs()} min ${offset > 0 ? 'danach' : 'davor'}';
    return Row(
      children: [
        Expanded(
          child: Text(label, style: HavenText.body.copyWith(color: hv.tx)),
        ),
        RoundIconButton(
          icon: Icons.remove_rounded,
          label: 'Versatz $label früher',
          onTap: () => onChanged((offset - 15).clamp(-360, 360)),
        ),
        SizedBox(
          width: 92,
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: HavenText.label.copyWith(color: hv.tx),
          ),
        ),
        RoundIconButton(
          icon: Icons.add_rounded,
          label: 'Versatz $label später',
          onTap: () => onChanged((offset + 15).clamp(-360, 360)),
        ),
      ],
    );
  }
}

// ---- 4. Licht -------------------------------------------------------------

class _LightStep extends StatelessWidget {
  const _LightStep({
    required this.draft,
    required this.room,
    required this.options,
    required this.onChanged,
  });
  final HavenAutomation draft;
  final AutomationRoom? room;
  final MotionOptions options;
  final ValueChanged<MotionOptions> onChanged;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final o = options;
    final night = o.night;
    return StepScroll(
      title: 'Was soll angehen?',
      lead: 'Eine Szene oder einfach Helligkeit und Farbtemperatur.',
      children: [
        MotionLightEditor(
          light: o.light,
          room: room,
          onChanged: (l) => onChanged(o.copyWith(light: l)),
        ),
        const SizedBox(height: 18),
        SwitchRow(
          title: 'Nachtlicht',
          subtitle: night == null
              ? 'Zu einer anderen Zeit ein anderes Licht'
              : '${windowLabel(night.from, night.to)} · ${lightLabel(night.light, room?.scenes ?? const [])}',
          value: night != null,
          onChanged: (v) => onChanged(
            v
                ? o.copyWith(night: const NightLight())
                : o.copyWith(clearNight: true),
          ),
        ),
        if (night != null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _TimeBox(
                  label: 'Von',
                  value: night.from,
                  onTap: () async {
                    final v = await _pickTime(context, night.from);
                    if (v != null) {
                      onChanged(o.copyWith(night: night.copyWith(from: v)));
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _TimeBox(
                  label: 'Bis',
                  value: night.to,
                  hint: windowCrossesMidnight(night.from, night.to)
                      ? 'nächster Tag'
                      : null,
                  onTap: () async {
                    final v = await _pickTime(context, night.to);
                    if (v != null) {
                      onChanged(o.copyWith(night: night.copyWith(to: v)));
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          MotionLightEditor(
            light: night.light,
            room: room,
            onChanged: (l) =>
                onChanged(o.copyWith(night: night.copyWith(light: l))),
          ),
          const SizedBox(height: 8),
          Text(
            'Im Nachtfenster gilt dieses Licht statt des oberen. Die '
            'Bedingungen aus „Wann aktiv“ gelten weiter.',
            style: HavenText.caption.copyWith(color: hv.tx2),
          ),
        ],
      ],
    );
  }
}

Future<String?> _pickTime(BuildContext context, String current) async {
  final m = parseHhmm(current) ?? 0;
  final t = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60),
    builder: (ctx, child) => MediaQuery(
      data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
      child: child!,
    ),
  );
  return t == null ? null : formatHhmm(t.hour * 60 + t.minute);
}

/// Licht wählen: Szene (Z2M-Gruppe oder HA) oder Helligkeit mit Farbtemperatur.
class MotionLightEditor extends ConsumerWidget {
  const MotionLightEditor({
    super.key,
    required this.light,
    required this.room,
    required this.onChanged,
  });
  final MotionLight light;
  final AutomationRoom? room;
  final ValueChanged<MotionLight> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final scenes = room?.scenes ?? const <GroupScene>[];
    final haScenes = [
      for (final e in ref.watch(snapshotProvider).entities.values)
        if (e.domain == 'scene') e,
    ]..sort((a, b) => a.name.compareTo(b.name));
    final hasGroup = room?.group != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HavenSegmented<bool>(
          neutral: true,
          options: const [(false, 'Helligkeit'), (true, 'Szene')],
          selected: light.isScene,
          onChanged: (v) {
            Haptics.tap();
            onChanged(v ? light.asScene() : light.asBrightness());
          },
        ),
        const SizedBox(height: 12),
        if (light.isScene) ...[
          if (hasGroup && scenes.isNotEmpty) ...[
            const FieldLabel('Szenen der Gruppe'),
            for (final s in scenes)
              PickRow(
                title: s.name,
                selected: light.sceneEntity == null && light.scene == s.id,
                onTap: () => onChanged(light.withScene(scene: s.id)),
              ),
          ],
          if (haScenes.isNotEmpty) ...[
            const FieldLabel('Home-Assistant-Szenen'),
            for (final e in haScenes.take(12))
              PickRow(
                title: e.name,
                selected: light.sceneEntity == e.entityId,
                onTap: () => onChanged(light.withScene(entity: e.entityId)),
              ),
          ],
          if (!(hasGroup && scenes.isNotEmpty) && haScenes.isEmpty)
            Text(
              'Keine Szenen gefunden. Nimm Helligkeit.',
              style: HavenText.body.copyWith(color: hv.tx2),
            ),
        ] else ...[
          ValueHeader('Helligkeit', '${light.percent} %'),
          SizedBox(
            height: 44,
            child: BrightnessSlider(
              axis: Axis.horizontal,
              label: 'Helligkeit',
              value: light.percent,
              colors: [hv.acc2.withValues(alpha: 0.7), hv.acc],
              onChanged: (p) => onChanged(
                light.copyWith(brightness: (p * 2.54).round().clamp(1, 254)),
              ),
            ),
          ),
          const SizedBox(height: 14),
          const ValueHeader('Farbtemperatur', ''),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OptionChip(
                label: 'Unverändert',
                selected: light.colorTemp == null,
                onTap: () => onChanged(light.copyWith(clearColorTemp: true)),
              ),
              for (final (n, k) in const [
                ('Kerzenlicht', 2200),
                ('Warm', 2700),
                ('Neutral', 4000),
                ('Tageslicht', 6000),
              ])
                OptionChip(
                  label: '$n · $k K',
                  selected: light.colorTemp == k,
                  onTap: () => onChanged(light.copyWith(colorTemp: k)),
                ),
            ],
          ),
        ],
        const SizedBox(height: 14),
        ValueHeader(
          'Übergang',
          '${light.transition.toStringAsFixed(light.transition % 1 == 0 ? 0 : 1).replaceAll('.', ',')} s',
        ),
        HavenSegmented<double>(
          neutral: true,
          options: const [
            (0.0, 'Sofort'),
            (1.0, '1 s'),
            (3.0, '3 s'),
            (5.0, '5 s'),
          ],
          selected: const [0.0, 1.0, 3.0, 5.0].contains(light.transition)
              ? light.transition
              : 1.0,
          onChanged: (v) => onChanged(light.copyWith(transition: v)),
        ),
      ],
    );
  }
}

// ---- 5. Nachlauf ----------------------------------------------------------

class _DelayStep extends StatefulWidget {
  const _DelayStep({
    required this.draft,
    required this.options,
    required this.onChanged,
  });
  final HavenAutomation draft;
  final MotionOptions options;
  final ValueChanged<HavenAutomation> onChanged;

  @override
  State<_DelayStep> createState() => _DelayStepState();
}

class _DelayStepState extends State<_DelayStep> {
  late final _name = TextEditingController(text: widget.draft.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  MotionOptions get o => widget.options;
  void _opts(MotionOptions v) =>
      widget.onChanged(widget.draft.copyWith(motion: v));

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    const delays = [30, 60, 120, 300, 600];
    const manual = [600, 1800, 3600, 7200];
    return StepScroll(
      title: 'Nachlauf und Optionen',
      children: [
        const FieldLabel('Name'),
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
            onChanged: (v) => widget.onChanged(widget.draft.copyWith(name: v)),
            style: HavenText.body.copyWith(color: hv.tx),
            cursorColor: hv.acc,
            decoration: InputDecoration.collapsed(
              hintText: 'z. B. Bewegungslicht Bad',
              hintStyle: HavenText.body.copyWith(color: hv.tx3),
            ),
          ),
        ),
        const SizedBox(height: 18),
        ValueHeader('Nachlauf', delayLabel(o.delay)),
        Text(
          'So lange bleibt das Licht an, nachdem der Melder nichts mehr sieht. '
          'Anwesenheitsmelder halten es an, solange jemand da ist.',
          style: HavenText.caption.copyWith(color: hv.tx2),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final d in delays)
              OptionChip(
                label: delayLabel(d),
                selected: o.delay == d,
                onTap: () => _opts(o.copyWith(delay: d)),
              ),
          ],
        ),
        const SizedBox(height: 18),
        SwitchRow(
          title: 'Vorwarnung',
          subtitle:
              '${o.warnSeconds} s vorher auf die Hälfte dimmen. Bewegung '
              'stellt das Licht wieder her.',
          value: o.warn,
          onChanged: (v) => _opts(o.copyWith(warn: v)),
        ),
        const SizedBox(height: 10),
        SwitchRow(
          title: 'Sofort wieder an',
          subtitle:
              'Bewegung bis 30 s nach dem Ausschalten schaltet gleich wieder ein, '
              'auch wenn es zu hell wäre.',
          value: o.relight,
          onChanged: (v) => _opts(o.copyWith(relight: v)),
        ),
        const SizedBox(height: 10),
        SwitchRow(
          title: 'Auch von Hand verstelltes Licht ausschalten',
          subtitle: o.manualDelay == null
              ? 'Aus: Wer das Licht verstellt, behält es an, bis er es selbst ausschaltet.'
              : 'Nach ${delayLabel(o.manualDelay!)} ohne Bewegung.',
          value: o.manualDelay != null,
          onChanged: (v) => _opts(
            v
                ? o.copyWith(manualDelay: 1800)
                : o.copyWith(clearManualDelay: true),
          ),
        ),
        if (o.manualDelay != null) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final d in manual)
                OptionChip(
                  label: delayLabel(d),
                  selected: o.manualDelay == d,
                  onTap: () => _opts(o.copyWith(manualDelay: d)),
                ),
            ],
          ),
        ],
        const SizedBox(height: 18),
        HavenCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded, size: 20, color: hv.tx2),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Dreht jemand das Licht heller, ändert die Farbe oder wählt '
                  'eine Szene, gehört es ihm. Der Melder setzt dann nichts mehr '
                  'zurück. Ist das Licht aus, ist er wieder zuständig.',
                  style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---- 7. Zusammenfassung ---------------------------------------------------

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
    final o = draft.motion ?? const MotionOptions();
    final conflicts = ref.watch(haConflictsProvider(draft));
    final cond = conditionLines(o);
    final snapshot = ref.watch(snapshotProvider);
    String light(MotionLight l) =>
        lightLabel(l, scenes, snapshot.entity(l.sceneEntity ?? '')?.name);

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
                'Melder',
                [for (final d in draft.devices) names[d] ?? d].join(', '),
              ),
              line('Aktiv', cond.isEmpty ? 'immer' : cond.join(', ')),
              line('Licht', light(o.light)),
              if (o.night != null)
                line(
                  'Nachtlicht',
                  '${windowLabel(o.night!.from, o.night!.to)}: ${light(o.night!.light)}',
                ),
              line(
                'Nachlauf',
                '${delayLabel(o.delay)}${o.warn ? ', mit Vorwarnung' : ''}',
              ),
              line(
                'Von Hand',
                o.manualDelay == null
                    ? 'bleibt an'
                    : 'aus nach ${delayLabel(o.manualDelay!)}',
              ),
              if (room != null && room.group == null)
                line('Steuerung', 'Lichter einzeln über Home Assistant'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SwitchRow(
          title: 'Aktiv',
          subtitle: 'Aus: Der Melder schaltet nichts',
          value: draft.enabled,
          onChanged: (v) => onChanged(draft.copyWith(enabled: v)),
        ),
        if (conflicts.isNotEmpty) ...[
          const SizedBox(height: 12),
          HaConflictCard(conflicts: conflicts, what: 'Melder'),
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
