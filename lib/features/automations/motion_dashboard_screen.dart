import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/haven_automation.dart';
import 'automation_dashboard.dart';
import 'automation_logic.dart';
import 'haven_automations_provider.dart';
import 'knob_widgets.dart';
import 'motion_editor_screen.dart';
import 'motion_live_test.dart';
import 'motion_logic.dart';

/// Dashboard eines bestehenden Bewegungslichts: Zustand live (wem das Licht
/// gehört, Phase, wann es ausgeht), Aktiv, Live-Test, alle Einstellungen als
/// Kacheln, Löschen. Jede Kachel öffnet den passenden Abschnitt des
/// Assistenten als Sheet und speichert nur ihn.
class MotionDashboardScreen extends StatelessWidget {
  const MotionDashboardScreen({
    super.key,
    required this.id,
    this.initialStep,
    this.demo = false,
  });
  final String id;
  final int? initialStep;

  /// Live-Test mit Beispielen füllen (Screenshots).
  final bool demo;

  @override
  Widget build(BuildContext context) {
    return AutomationDashboard(
      id: id,
      kindLabel: 'Bewegungslicht',
      initialStep: initialStep,
      validate: validateMotionDraft,
      activeHint: 'Aus: Der Melder schaltet nichts',
      deleteHint: 'Der Melder schaltet danach kein Licht mehr.',
      wizardPath: '${motionEditorPath(id)}?wizard=1&step=0',
      status: (a) => MotionStatusPanel(automation: a),
      liveTest: (a) => MotionLiveTest(automation: a, demo: demo),
      conflicts: (ref, a) {
        final c = ref.watch(haConflictsProvider(a));
        return c.isEmpty ? null : HaConflictCard(conflicts: c, what: 'Melder');
      },
      sections: motionSections,
    );
  }
}

/// Kacheln des Bewegungslichts, Schritte wie im Assistenten (0 bis 4).
List<DashboardSection> motionSections(
  WidgetRef ref,
  HavenAutomation a,
  HavenAutomations all,
) {
  final room = all.rooms[a.roomAreaId];
  final names = ref.watch(knobDeviceNamesProvider);
  final snapshot = ref.watch(snapshotProvider);
  final o = a.motion ?? const MotionOptions();
  final scenes = room?.scenes ?? const <GroupScene>[];
  String light(MotionLight l) =>
      lightLabel(l, scenes, snapshot.entity(l.sceneEntity ?? '')?.name);
  final cond = conditionLines(o);

  return [
    DashboardSection(
      step: 0,
      title: 'Raum',
      icon: Icons.meeting_room_outlined,
      lines: [
        room?.name ?? a.roomAreaId,
        if (room != null)
          room.group != null
              ? 'Z2M-Gruppe ${room.group}'
              : 'Lichter einzeln über Home Assistant',
      ],
      builder: (d, all, on) => MotionRoomStep(
        draft: d,
        all: all,
        onPick: (areaId) => on(
          motionDraftWithRoom(d, areaId, all, ref.read(motionDevicesProvider)),
        ),
      ),
    ),
    DashboardSection(
      step: 1,
      title: 'Melder',
      icon: Icons.sensors_rounded,
      lines: a.devices.isEmpty
          ? const ['Keiner gewählt']
          : [for (final d in a.devices) names[d] ?? d],
      builder: (d, all, on) =>
          MotionDetectorStep(draft: d, all: all, onChanged: on),
    ),
    DashboardSection(
      step: 2,
      title: 'Wann aktiv',
      icon: Icons.schedule_rounded,
      lines: cond.isEmpty ? const ['Immer'] : cond,
      builder: (d, all, on) => MotionWhenStep(
        draft: d,
        options: d.motion ?? const MotionOptions(),
        onChanged: (v) => on(d.copyWith(motion: v)),
      ),
    ),
    DashboardSection(
      step: 3,
      title: 'Licht',
      icon: Icons.lightbulb_outline_rounded,
      lines: [
        light(o.light),
        if (o.night != null)
          'Nachtlicht ${windowLabel(o.night!.from, o.night!.to)}: '
              '${light(o.night!.light)}',
      ],
      builder: (d, all, on) => MotionLightStep(
        draft: d,
        room: all.rooms[d.roomAreaId],
        options: d.motion ?? const MotionOptions(),
        onChanged: (v) => on(d.copyWith(motion: v)),
      ),
    ),
    DashboardSection(
      step: 4,
      title: 'Name, Nachlauf und Optionen',
      icon: Icons.timer_outlined,
      lines: [
        'Nachlauf ${delayLabel(o.delay)}${o.warn ? ', mit Vorwarnung' : ''}',
        if (o.relight) 'Sofort wieder an',
        o.manualDelay == null
            ? 'Von Hand verstellt: bleibt an'
            : 'Von Hand verstellt: aus nach ${delayLabel(o.manualDelay!)}',
      ],
      builder: (d, all, on) => MotionDelayStep(
        draft: d,
        options: d.motion ?? const MotionOptions(),
        onChanged: on,
      ),
    ),
  ];
}

/// Wem das Licht gerade gehört.
String motionOwnerLabel(MotionPhase p) => switch (p) {
  MotionPhase.motion || MotionPhase.warn => 'Melder',
  MotionPhase.manual => 'von Hand',
  MotionPhase.idle || MotionPhase.inactive => 'niemand',
};

/// Zustand live: Phase, Besitzer, Ausschaltzeit (sekundengenau), Lux,
/// Nachtlicht, zuletzt ausgelöst.
class MotionStatusPanel extends StatefulWidget {
  const MotionStatusPanel({super.key, required this.automation});
  final HavenAutomation automation;

  @override
  State<MotionStatusPanel> createState() => _MotionStatusPanelState();
}

class _MotionStatusPanelState extends State<MotionStatusPanel> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.automation.motionStatus?.offAt != null) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final a = widget.automation;
    final s = a.motionStatus;
    final now = DateTime.now();
    final phase = a.enabled ? (s?.phase ?? MotionPhase.idle) : MotionPhase.idle;
    final active = phase == MotionPhase.motion || phase == MotionPhase.warn;
    final tone = switch (phase) {
      MotionPhase.motion => hv.acc,
      MotionPhase.warn => hv.warn,
      MotionPhase.manual => hv.tx,
      MotionPhase.inactive => hv.tx2,
      MotionPhase.idle => hv.tx,
    };
    final off = s?.offAt;
    final fired = a.lastTriggered;
    return StatusCard(
      icon: switch (phase) {
        MotionPhase.manual => Icons.pan_tool_alt_rounded,
        MotionPhase.inactive => Icons.nights_stay_outlined,
        _ => Icons.directions_walk_rounded,
      },
      headline: motionStatusLine(s, now, enabled: a.enabled),
      tone: tone,
      active: active,
      facts: [
        if (a.enabled)
          StatusFact(
            icon: Icons.person_outline_rounded,
            text: 'Licht gehört: ${motionOwnerLabel(phase)}',
          ),
        if (a.enabled && off != null)
          StatusFact(
            icon: Icons.timer_outlined,
            text:
                'Aus um ${off.hour.toString().padLeft(2, '0')}:'
                '${off.minute.toString().padLeft(2, '0')}',
          ),
        if (a.enabled && s?.occupied == true)
          const StatusFact(icon: Icons.sensors_rounded, text: 'Jemand da'),
        if (a.enabled && s?.night == true)
          const StatusFact(icon: Icons.bedtime_outlined, text: 'Nachtlicht'),
        if (s?.lux != null)
          StatusFact(
            icon: Icons.wb_sunny_outlined,
            text: 'Jetzt ${s!.lux!.round()} lx',
          ),
        StatusFact(
          icon: Icons.history_rounded,
          text: fired == null
              ? 'Noch nie ausgelöst'
              : 'Zuletzt ${relativeTime(fired.at, now)}: '
                    '${motionEventLabel(fired.action)}',
        ),
      ],
    );
  }
}
