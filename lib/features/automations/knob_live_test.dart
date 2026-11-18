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
import 'knob_logic.dart';
import 'knob_widgets.dart';

/// Eine empfangene Geste im Live-Test.
class LiveGesture {
  LiveGesture({
    required this.action,
    this.device,
    required this.at,
    this.executed = false,
    this.test = false,
  });
  final String action;
  final String? device;
  final DateTime at;

  /// Die Haven-Automation hat sie ausgeführt (`haven_automation_triggered`).
  bool executed;
  final bool test;
}

/// Führt Gerätemeldungen (`haven/subscribe_zigbee`, `action`) und Auslösungen
/// (`haven_automation_triggered`) zusammen: Dieselbe Geste am selben Gerät
/// innerhalb von 600 ms ist ein Eintrag.
class LiveGestureLog {
  LiveGestureLog({this.max = 8});
  final int max;
  final List<LiveGesture> items = [];

  static const _window = Duration(milliseconds: 600);

  LiveGesture? _match(String action, String? device, DateTime at) {
    for (final g in items) {
      if (g.action == action &&
          (device == null || g.device == null || g.device == device) &&
          at.difference(g.at).abs() <= _window) {
        return g;
      }
    }
    return null;
  }

  /// Meldung vom Gerät. `false`, wenn sie schon da war.
  bool addDevice(String action, String device, DateTime at) {
    if (_match(action, device, at) != null) return false;
    _add(LiveGesture(action: action, device: device, at: at));
    return true;
  }

  /// Auslösung der Automation. `true` = neuer Eintrag.
  bool addTrigger(AutomationTrigger t) {
    final hit = t.source == 'test' ? null : _match(t.action, t.device, t.at);
    if (hit != null) {
      hit.executed = true;
      return false;
    }
    _add(
      LiveGesture(
        action: t.action,
        device: t.device,
        at: t.at,
        executed: true,
        test: t.source == 'test',
      ),
    );
    return true;
  }

  void _add(LiveGesture g) {
    items.insert(0, g);
    if (items.length > max) items.removeLast();
  }
}

/// Schritt „Live-Test“: zeigt eingehende Gesten in Echtzeit und löst Gesten
/// testweise aus (`haven/automations/test`, nur für gespeicherte).
class KnobLiveTest extends ConsumerStatefulWidget {
  const KnobLiveTest({super.key, required this.automation, this.demo = false});
  final HavenAutomation automation;

  /// Mit Beispielgesten füllen (Screenshots).
  final bool demo;

  @override
  ConsumerState<KnobLiveTest> createState() => _KnobLiveTestState();
}

class _KnobLiveTestState extends ConsumerState<KnobLiveTest> {
  final _log = LiveGestureLog();
  StreamSubscription<ZbEvent>? _zb;
  StreamSubscription<AutomationTrigger>? _trig;
  double _turns = 0;
  int _presses = 0;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    final repo = ref.read(repositoryProvider);
    _zb = repo.zigbeeEvents.listen(_onZigbee);
    _trig = repo.automationTriggers.listen(_onTrigger);
    // „vor 3 s“ aktuell halten
    _tick = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && _log.items.isNotEmpty) setState(() {});
    });
    if (widget.demo) _seed();
  }

  void _seed() {
    final now = DateTime.now();
    final d = widget.automation.devices.firstOrNull;
    for (final (s, a, ex) in const [
      (14, 'single', true),
      (9, 'rotate_left', true),
      (4, 'rotate_right', true),
      (2, 'rotate_right', true),
    ]) {
      _log.addDevice(a, d ?? '', now.subtract(Duration(seconds: s)));
      _log.items.first.executed = ex;
    }
    _turns = 1 / 12;
  }

  @override
  void dispose() {
    _zb?.cancel();
    _trig?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  void _bump(String action) {
    if (action == 'rotate_right') _turns += 1 / 12;
    if (action == 'rotate_left') _turns -= 1 / 12;
    if (gestureOf(action) != KnobGesture.rotate) _presses++;
  }

  void _onZigbee(ZbEvent e) {
    if (e.kind != 'state') return;
    final ieee = e.data['ieee'];
    if (ieee is! String || !widget.automation.devices.contains(ieee)) return;
    final action = normalizeKnobAction(e.data['values']);
    if (action == null || !mounted) return;
    if (_log.addDevice(action, ieee, DateTime.now())) {
      Haptics.tap();
      setState(() => _bump(action));
    }
  }

  void _onTrigger(AutomationTrigger t) {
    final id = widget.automation.id;
    if (id == null || t.id != id || !mounted) return;
    setState(() {
      if (_log.addTrigger(t)) _bump(t.action);
    });
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
    final names = ref.watch(knobDeviceNamesProvider);
    final saved = widget.automation.id != null;
    final now = DateTime.now();
    final latest = _log.items.firstOrNull;

    return ListView(
      // Im Bearbeiten-Sheet des Dashboards zieht das obere Ende das Sheet.
      controller: HavenSheetScope.maybeOf(context)?.scrollController,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      children: [
        Text(
          'Dreh jetzt am Regler',
          style: HavenText.section.copyWith(color: hv.tx),
        ),
        const SizedBox(height: 4),
        Text(
          'Jede Geste erscheint hier sofort.',
          style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14.5),
        ),
        const SizedBox(height: 12),
        Center(
          child: _KnobDial(
            turns: _turns,
            presses: _presses,
            label: latest == null
                ? 'Warte auf Geste'
                : actionLabel(latest.action),
          ),
        ),
        const SizedBox(height: 22),
        Text('Testen', style: HavenText.headline.copyWith(color: hv.tx)),
        const SizedBox(height: 4),
        Text(
          saved
              ? 'Löst die Geste aus, als käme sie vom Regler. Es gilt der gespeicherte Stand.'
              : 'Die Test-Knöpfe gehen, sobald die Automation gespeichert ist. '
                    'Echte Gesten siehst du schon jetzt.',
          style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (a, label) in const [
              ('rotate_left', 'Links'),
              ('rotate_right', 'Rechts'),
              ('single', 'Drücken'),
              ('double', 'Doppelt'),
              ('hold', 'Halten'),
            ])
              _TestButton(
                icon: actionIcon(a),
                mirror: mirroredAction(a),
                label: label,
                onTap: saved ? () => _test(a) : null,
              ),
          ],
        ),
        const SizedBox(height: 22),
        Text('Empfangen', style: HavenText.headline.copyWith(color: hv.tx)),
        const SizedBox(height: 10),
        if (_log.items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              widget.automation.devices.isEmpty
                  ? 'Wähl zuerst Regler oder Taster.'
                  : 'Noch nichts empfangen.',
              textAlign: TextAlign.center,
              style: HavenText.body.copyWith(color: hv.tx3),
            ),
          ),
        for (final g in _log.items)
          _LiveRow(
            key: ObjectKey(g),
            gesture: g,
            device: g.test ? 'Test' : (names[g.device] ?? g.device ?? ''),
            ago: _ago(g.at, now),
          ),
      ],
    );
  }

  static String _ago(DateTime t, DateTime now) {
    final s = now.difference(t).inSeconds;
    if (s < 3) return 'jetzt';
    if (s < 60) return 'vor $s s';
    return 'vor ${s ~/ 60} min';
  }
}

/// Drehregler als Grafik: dreht sich mit jeder Rastung, federt beim Drücken.
class _KnobDial extends StatelessWidget {
  const _KnobDial({
    required this.turns,
    required this.presses,
    required this.label,
  });
  final double turns;
  final int presses;
  final String label;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Column(
      children: [
        TweenAnimationBuilder<double>(
          key: ValueKey(presses),
          tween: Tween(begin: 0.9, end: 1),
          duration: context.motion(HavenMotion.d4),
          curve: HavenMotion.spring,
          builder: (context, s, child) =>
              Transform.scale(scale: s, child: child),
          child: Container(
            width: 150,
            height: 150,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  hv.acc.withValues(alpha: 0.22),
                  hv.acc.withValues(alpha: 0),
                ],
              ),
            ),
            alignment: Alignment.center,
            child: AnimatedRotation(
              turns: turns,
              duration: context.motion(HavenMotion.d3),
              curve: HavenMotion.out,
              child: Container(
                width: 112,
                height: 112,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: hv.s1,
                  border: Border.all(color: hv.ln2, width: 1.5),
                  boxShadow: hv.shadowSmall,
                ),
                alignment: Alignment.topCenter,
                padding: const EdgeInsets.only(top: 12),
                child: Container(
                  width: 8,
                  height: 22,
                  decoration: BoxDecoration(
                    color: hv.acc,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        AnimatedSwitcher(
          duration: context.motion(HavenMotion.d2),
          child: Text(
            label,
            key: ValueKey('$label$presses$turns'),
            style: HavenText.headline.copyWith(color: hv.tx),
          ),
        ),
      ],
    );
  }
}

class _LiveRow extends StatelessWidget {
  const _LiveRow({
    super.key,
    required this.gesture,
    required this.device,
    required this.ago,
  });
  final LiveGesture gesture;
  final String device;
  final String ago;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: context.motion(HavenMotion.d3),
        curve: HavenMotion.out,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * -8),
            child: child,
          ),
        ),
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
          decoration: BoxDecoration(
            color: hv.s1,
            borderRadius: BorderRadius.circular(HavenRadii.m),
            border: Border.all(color: hv.ln),
          ),
          child: Row(
            children: [
              GestureGlyph(
                icon: actionIcon(gesture.action),
                mirror: mirroredAction(gesture.action),
                size: 38,
                active: gesture.executed,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      actionLabel(gesture.action),
                      style: HavenText.label.copyWith(color: hv.tx),
                    ),
                    Text(
                      device,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HavenText.caption.copyWith(color: hv.tx2),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(ago, style: HavenText.caption.copyWith(color: hv.tx3)),
                  if (gesture.executed)
                    Text(
                      'ausgeführt',
                      style: HavenText.caption.copyWith(
                        color: hv.ok,
                        fontWeight: FontWeight.w700,
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

class _TestButton extends StatelessWidget {
  const _TestButton({
    required this.icon,
    required this.label,
    this.onTap,
    this.mirror = false,
  });
  final IconData icon;
  final bool mirror;
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
                Transform.flip(
                  flipX: mirror,
                  child: Icon(icon, size: 20, color: hv.tx),
                ),
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
