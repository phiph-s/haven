import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/haven_automation.dart';
import 'automation_dashboard.dart';
import 'automation_logic.dart';
import 'haven_automations_provider.dart';
import 'knob_editor_screen.dart';
import 'knob_live_test.dart';
import 'knob_logic.dart';
import 'knob_widgets.dart';

/// Dashboard eines bestehenden Drehreglers: zuletzt ausgelöst (live), Geräte
/// mit Batterie, Aktiv, Live-Test, alle Einstellungen als Kacheln, Löschen.
/// Jede Kachel öffnet den passenden Abschnitt des Assistenten als Sheet.
class KnobDashboardScreen extends StatelessWidget {
  const KnobDashboardScreen({
    super.key,
    required this.id,
    this.initialStep,
    this.demo = false,
  });
  final String id;
  final int? initialStep;

  /// Live-Test mit Beispielgesten füllen (Screenshots).
  final bool demo;

  @override
  Widget build(BuildContext context) {
    return AutomationDashboard(
      id: id,
      kindLabel: 'Drehregler',
      initialStep: initialStep,
      validate: validateKnobDraft,
      activeHint: 'Aus: Die Regler tun nichts',
      deleteHint: 'Die Regler tun danach nichts mehr, bis du sie neu belegst.',
      wizardPath: '${knobEditorPath(id)}?wizard=1&step=0',
      status: (a) => KnobStatusPanel(automation: a),
      liveTest: (a) => KnobLiveTest(automation: a, demo: demo),
      conflicts: (ref, a) {
        final c = ref.watch(haConflictsProvider(a));
        return c.isEmpty ? null : HaConflictCard(conflicts: c);
      },
      sections: knobSections,
    );
  }
}

/// Kacheln des Drehreglers, Schritte wie im Assistenten (0 bis 4).
List<DashboardSection> knobSections(
  WidgetRef ref,
  HavenAutomation a,
  HavenAutomations all,
) {
  final room = all.rooms[a.roomAreaId];
  final names = ref.watch(knobDeviceNamesProvider);
  final scenes = room?.scenes ?? const <GroupScene>[];
  final o = a.options;
  final cycle = [
    for (final (s, on) in orderedScenes(scenes, o.scenes))
      if (on) s.name,
  ];
  final onScene = o.onScene == null
      ? 'wie zuletzt'
      : 'Szene ${scenes.where((s) => s.id == o.onScene).firstOrNull?.name ?? o.onScene}';

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
      builder: (d, all, on) => KnobRoomStep(
        draft: d,
        all: all,
        onPick: (areaId) => on(
          knobDraftWithRoom(d, areaId, all, ref.read(knobDevicesProvider)),
        ),
      ),
    ),
    DashboardSection(
      step: 1,
      title: 'Regler und Taster',
      icon: kRotateIcon,
      lines: a.devices.isEmpty
          ? const ['Keine gewählt']
          : [for (final d in a.devices) names[d] ?? d],
      builder: (d, all, on) =>
          KnobDeviceStep(draft: d, all: all, onChanged: on),
    ),
    DashboardSection(
      step: 2,
      title: 'Gesten',
      icon: Icons.touch_app_outlined,
      lines: [
        for (final g in KnobGesture.values)
          if (o.binding(g).action != GestureAction.none)
            '${gestureLabel(g)}: ${bindingLabel(g, o.binding(g), scenes)}',
      ],
      builder: (d, all, on) => KnobGestureStep(
        draft: d,
        room: all.rooms[d.roomAreaId],
        onChanged: on,
      ),
    ),
    DashboardSection(
      step: 3,
      title: 'Szenen',
      icon: Icons.palette_outlined,
      lines: room?.canScenes != true
          ? const ['Noch keine Szenen im Raum']
          : [
              cycle.isEmpty ? 'Keine im Umlauf' : cycle.join(' → '),
              'Beim Einschalten: $onScene',
            ],
      builder: (d, all, on) =>
          KnobSceneStep(draft: d, room: all.rooms[d.roomAreaId], onChanged: on),
    ),
    DashboardSection(
      step: 4,
      title: 'Name und Feinschliff',
      icon: Icons.tune_rounded,
      lines: [
        '${stepPercent(o.step)} % je Rastung',
        'Mindestens ${stepPercent(o.minBrightness)} %'
            '${o.offAtMin ? ', dann aus' : ''}',
        'Übergang ${o.transition.toStringAsFixed(1).replaceAll('.', ',')} s',
      ],
      builder: (d, all, on) => KnobOptionsStep(draft: d, onChanged: on),
    ),
  ];
}

/// Zustand: letzte Geste (live über `haven_automation_triggered`) und die
/// Geräte mit Batterie.
class KnobStatusPanel extends ConsumerStatefulWidget {
  const KnobStatusPanel({super.key, required this.automation});
  final HavenAutomation automation;

  @override
  ConsumerState<KnobStatusPanel> createState() => _KnobStatusPanelState();
}

class _KnobStatusPanelState extends ConsumerState<KnobStatusPanel> {
  StreamSubscription<AutomationTrigger>? _sub;
  Timer? _tick;
  AutomationFired? _live;

  @override
  void initState() {
    super.initState();
    _sub = ref.read(repositoryProvider).automationTriggers.listen((t) {
      if (t.id != widget.automation.id || !mounted) return;
      setState(() => _live = AutomationFired(t.at, t.action));
    });
    _tick = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final a = widget.automation;
    final now = DateTime.now();
    final stored = a.lastTriggered;
    final fired =
        _live != null && (stored == null || _live!.at.isAfter(stored.at))
        ? _live
        : stored;
    final fresh = fired != null && now.difference(fired.at).inSeconds < 10;
    final devices = {for (final k in ref.watch(knobDevicesProvider)) k.ieee: k};
    return StatusCard(
      icon: fired == null ? kRotateIcon : actionIcon(fired.action),
      headline: !a.enabled
          ? 'Ausgeschaltet'
          : (fired == null
                ? 'Bereit, noch nie ausgelöst'
                : '${actionLabel(fired.action)}, ${relativeTime(fired.at, now)}'),
      tone: a.enabled ? (fresh ? hv.acc : hv.tx) : hv.tx2,
      active: a.enabled && fresh,
      facts: [
        for (final id in a.devices)
          StatusFact(
            icon: devices[id]?.device.deviceType == 'remote'
                ? Icons.radio_button_checked_rounded
                : kRotateIcon,
            text: [
              devices[id]?.name ?? id,
              if (devices[id]?.battery != null)
                'Batterie ${devices[id]!.battery} %',
            ].join(' · '),
          ),
      ],
    );
  }
}
