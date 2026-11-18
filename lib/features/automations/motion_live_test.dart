import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haven_sheet.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/press_scale.dart';
import '../../data/models/haven_automation.dart';
import '../../data/models/zigbee.dart';
import '../settings/settings_widgets.dart';
import 'haven_automations_provider.dart';
import 'knob_widgets.dart';
import 'motion_logic.dart';

/// Eine Zeile im Protokoll des Live-Tests.
class MotionLogEntry {
  MotionLogEntry(this.kind, this.at, {this.test = false});

  /// `detected`, `cleared` (vom Melder) oder `motion_on`, `motion_extend`,
  /// `motion_off`, `takeover`, `warn` (von der Automation).
  final String kind;
  final DateTime at;
  final bool test;
}

String motionEventLabel(String kind) => switch (kind) {
  'detected' => 'Bewegung erkannt',
  'cleared' => 'Keine Bewegung mehr',
  'motion_on' => 'Licht eingeschaltet',
  'motion_extend' => 'Nachlauf verlängert',
  'motion_off' => 'Licht ausgeschaltet',
  'takeover' => 'Von Hand übernommen',
  'warn' => 'Vorwarnung, dimmt',
  _ => kind,
};

IconData motionEventIcon(String kind) => switch (kind) {
  'detected' => Icons.directions_walk_rounded,
  'cleared' => Icons.hourglass_empty_rounded,
  'motion_on' => Icons.lightbulb_rounded,
  'motion_extend' => Icons.update_rounded,
  'motion_off' => Icons.lightbulb_outline_rounded,
  'takeover' => Icons.pan_tool_alt_rounded,
  'warn' => Icons.brightness_low_rounded,
  _ => Icons.circle_outlined,
};

/// Schritt „Live-Test“ des Bewegungslichts: zeigt den Zustand der
/// Automation live, protokolliert Meldungen des Melders und Auslösungen und
/// löst Bewegung testweise aus (`haven/automations/test`, nur gespeichert).
class MotionLiveTest extends ConsumerStatefulWidget {
  const MotionLiveTest({
    super.key,
    required this.automation,
    this.demo = false,
  });
  final HavenAutomation automation;
  final bool demo;

  @override
  ConsumerState<MotionLiveTest> createState() => _MotionLiveTestState();
}

class _MotionLiveTestState extends ConsumerState<MotionLiveTest> {
  final List<MotionLogEntry> _log = [];
  StreamSubscription<ZbEvent>? _zb;
  StreamSubscription<AutomationTrigger>? _trig;
  Timer? _tick;
  bool? _detected;

  @override
  void initState() {
    super.initState();
    final repo = ref.read(repositoryProvider);
    _zb = repo.zigbeeEvents.listen(_onZigbee);
    _trig = repo.automationTriggers.listen(_onTrigger);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    if (widget.demo) _seed();
  }

  void _seed() {
    final now = DateTime.now();
    for (final (s, k) in const [
      (48, 'detected'),
      (47, 'motion_on'),
      (30, 'cleared'),
      (12, 'detected'),
      (11, 'motion_extend'),
    ]) {
      _log.insert(0, MotionLogEntry(k, now.subtract(Duration(seconds: s))));
    }
    _detected = true;
  }

  @override
  void dispose() {
    _zb?.cancel();
    _trig?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  void _add(MotionLogEntry e) {
    _log.insert(0, e);
    if (_log.length > 8) _log.removeLast();
  }

  void _onZigbee(ZbEvent e) {
    if (e.kind != 'state') return;
    final ieee = e.data['ieee'];
    if (ieee is! String || !widget.automation.devices.contains(ieee)) return;
    final v = e.data['values'];
    if (v is! Map) return;
    final active = v['presence'] ?? v['occupancy'];
    if (active is! bool || !mounted) return;
    if (active == _detected) return;
    Haptics.tap();
    setState(() {
      _detected = active;
      _add(MotionLogEntry(active ? 'detected' : 'cleared', DateTime.now()));
    });
  }

  void _onTrigger(AutomationTrigger t) {
    if (t.id != widget.automation.id || !mounted) return;
    setState(
      () => _add(MotionLogEntry(t.action, t.at, test: t.source == 'test')),
    );
  }

  Future<void> _test(String action) async {
    final id = widget.automation.id;
    if (id == null) return;
    Haptics.tap();
    try {
      await ref.read(havenAutomationsProvider.notifier).test(id, action);
    } catch (e) {
      if (mounted) showHavenToast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final id = widget.automation.id;
    final saved = id != null;
    final live = saved
        ? ref.watch(havenAutomationsProvider).value?.byId(id)
        : null;
    final status = (live ?? widget.automation).motionStatus;
    final now = DateTime.now();
    final names = ref.watch(knobDeviceNamesProvider);
    final phase = status?.phase ?? MotionPhase.idle;
    final active = phase == MotionPhase.motion || phase == MotionPhase.warn;

    return ListView(
      // Im Bearbeiten-Sheet des Dashboards zieht das obere Ende das Sheet.
      controller: HavenSheetScope.maybeOf(context)?.scrollController,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      children: [
        Text(
          'Lauf einmal durch den Raum',
          style: HavenText.section.copyWith(color: hv.tx),
        ),
        const SizedBox(height: 4),
        Text(
          widget.automation.devices.isEmpty
              ? 'Wähl zuerst einen Melder.'
              : '${[for (final d in widget.automation.devices) names[d] ?? d].join(', ')} meldet sich hier sofort.',
          style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14.5),
        ),
        const SizedBox(height: 14),
        _StateCard(
          detected: _detected,
          phase: phase,
          active: active,
          line: saved
              ? motionStatusLine(
                  status,
                  now,
                  enabled: widget.automation.enabled,
                )
              : 'Erst nach dem Speichern',
        ),
        const SizedBox(height: 22),
        Text('Testen', style: HavenText.headline.copyWith(color: hv.tx)),
        const SizedBox(height: 4),
        Text(
          saved
              ? 'Löst den Melder aus, als käme es vom Gerät, und schaltet das '
                    'Licht wirklich. Es gilt der gespeicherte Stand.'
              : 'Die Test-Knöpfe gehen, sobald die Automation gespeichert ist. '
                    'Echte Bewegung siehst du schon jetzt.',
          style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _TestButton(
              icon: Icons.directions_walk_rounded,
              label: 'Bewegung',
              onTap: saved ? () => _test('motion') : null,
            ),
            _TestButton(
              icon: Icons.hourglass_empty_rounded,
              label: 'Keine Bewegung',
              onTap: saved ? () => _test('clear') : null,
            ),
            _TestButton(
              icon: Icons.pan_tool_alt_rounded,
              label: 'Von Hand übernehmen',
              onTap: saved ? () => _test('takeover') : null,
            ),
          ],
        ),
        const SizedBox(height: 22),
        Text('Verlauf', style: HavenText.headline.copyWith(color: hv.tx)),
        const SizedBox(height: 10),
        if (_log.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Noch nichts empfangen.',
              textAlign: TextAlign.center,
              style: HavenText.body.copyWith(color: hv.tx3),
            ),
          ),
        for (final e in _log) _LogRow(entry: e, now: now),
      ],
    );
  }
}

class _StateCard extends StatelessWidget {
  const _StateCard({
    required this.detected,
    required this.phase,
    required this.active,
    required this.line,
  });
  final bool? detected;
  final MotionPhase phase;
  final bool active;
  final String line;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final tone = switch (phase) {
      MotionPhase.motion => hv.acc,
      MotionPhase.warn => hv.warn,
      MotionPhase.manual => hv.tx2,
      MotionPhase.inactive => hv.tx3,
      MotionPhase.idle => hv.tx2,
    };
    return AnimatedContainer(
      duration: context.motion(HavenMotion.d3),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: active ? hv.acc.withValues(alpha: 0.10) : hv.s1,
        borderRadius: BorderRadius.circular(HavenRadii.l),
        border: Border.all(color: active ? hv.acc : hv.ln),
      ),
      child: Row(
        children: [
          AnimatedContainer(
            duration: context.motion(HavenMotion.d3),
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: detected == true ? hv.acc.withValues(alpha: 0.18) : hv.s2,
              border: Border.all(color: detected == true ? hv.acc : hv.ln),
            ),
            child: Icon(
              detected == true
                  ? Icons.directions_walk_rounded
                  : Icons.sensors_off_rounded,
              color: detected == true ? hv.acc : hv.tx3,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  detected == null
                      ? 'Warte auf den Melder'
                      : (detected! ? 'Bewegung erkannt' : 'Ruhig'),
                  style: HavenText.headline.copyWith(color: hv.tx),
                ),
                const SizedBox(height: 2),
                Text(
                  line,
                  style: HavenText.body.copyWith(color: tone, fontSize: 14),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry, required this.now});
  final MotionLogEntry entry;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final auto = !{'detected', 'cleared'}.contains(entry.kind);
    final s = now.difference(entry.at).inSeconds;
    final ago = s < 3 ? 'jetzt' : (s < 60 ? 'vor $s s' : 'vor ${s ~/ 60} min');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
        decoration: BoxDecoration(
          color: hv.s1,
          borderRadius: BorderRadius.circular(HavenRadii.m),
          border: Border.all(color: hv.ln),
        ),
        child: Row(
          children: [
            GestureGlyph(
              icon: motionEventIcon(entry.kind),
              size: 36,
              active: auto,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    motionEventLabel(entry.kind),
                    style: HavenText.label.copyWith(color: hv.tx),
                  ),
                  Text(
                    auto ? (entry.test ? 'Test' : 'Haven') : 'Melder',
                    style: HavenText.caption.copyWith(color: hv.tx2),
                  ),
                ],
              ),
            ),
            Text(ago, style: HavenText.caption.copyWith(color: hv.tx3)),
          ],
        ),
      ),
    );
  }
}

class _TestButton extends StatelessWidget {
  const _TestButton({required this.icon, required this.label, this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Opacity(
      opacity: onTap == null ? 0.45 : 1,
      child: Semantics(
        button: true,
        label: 'Test: $label',
        excludeSemantics: true,
        child: PressScale(
          onTap: onTap,
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: hv.s2,
              borderRadius: BorderRadius.circular(HavenRadii.pill),
              border: Border.all(color: hv.ln),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: hv.tx),
                const SizedBox(width: 8),
                Text(label, style: HavenText.label.copyWith(color: hv.tx)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
