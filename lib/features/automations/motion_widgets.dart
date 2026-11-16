import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/haven_switch.dart';
import '../../core/widgets/press_scale.dart';
import '../../data/models/haven_automation.dart';
import '../settings/settings_widgets.dart';
import 'haven_automations_provider.dart';
import 'knob_logic.dart';
import 'knob_widgets.dart';
import 'motion_editor_screen.dart';
import 'motion_logic.dart';

/// Karte eines Bewegungslichts im Abläufe-Tab: Raum, Melder, Schalter und
/// der aktuelle Zustand („Licht vom Melder, aus in 1:20“), live über
/// `haven_automation_triggered`. Ein Zeitgeber zählt den Rest sekundengenau.
class MotionAutomationCard extends ConsumerStatefulWidget {
  const MotionAutomationCard({
    super.key,
    required this.automation,
    this.roomName,
  });

  final HavenAutomation automation;
  final String? roomName;

  @override
  ConsumerState<MotionAutomationCard> createState() =>
      _MotionAutomationCardState();
}

class _MotionAutomationCardState extends ConsumerState<MotionAutomationCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      final s = widget.automation.motionStatus;
      if (mounted && s?.offAt != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Color _tone(BuildContext context, MotionPhase p) {
    final hv = context.hv;
    return switch (p) {
      MotionPhase.motion => hv.acc,
      MotionPhase.warn => hv.warn,
      MotionPhase.manual => hv.tx2,
      MotionPhase.inactive => hv.tx3,
      MotionPhase.idle => hv.tx2,
    };
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final a = widget.automation;
    final o = a.motion ?? const MotionOptions();
    final status = a.motionStatus;
    final phase = a.enabled
        ? (status?.phase ?? MotionPhase.idle)
        : MotionPhase.idle;
    final conflicts = a.enabled
        ? ref.watch(haConflictsProvider(a))
        : const <HaConflict>[];
    final n = a.devices.length;
    final cond = conditionLines(o);

    return AnimatedOpacity(
      opacity: a.enabled ? 1 : 0.62,
      duration: context.motion(HavenMotion.d2),
      child: PressScale(
        pressedScale: 0.98,
        onTap: () => context.push(motionEditorPath(a.id)),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 14, 6, 14),
          decoration: BoxDecoration(
            color: hv.s1,
            borderRadius: BorderRadius.circular(HavenRadii.l),
            border: Border.all(color: hv.ln),
            boxShadow: hv.shadowSmall,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  GestureGlyph(
                    icon: Icons.directions_walk_rounded,
                    active: a.enabled && phase != MotionPhase.idle,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.roomName ?? a.roomAreaId,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HavenText.headline.copyWith(color: hv.tx),
                        ),
                        Text(
                          [
                            a.name,
                            n == 1 ? '1 Melder' : '$n Melder',
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HavenText.caption.copyWith(color: hv.tx2),
                        ),
                      ],
                    ),
                  ),
                  HavenSwitch(
                    value: a.enabled,
                    semanticLabel: a.name,
                    onChanged: (v) async {
                      Haptics.tap();
                      try {
                        await ref
                            .read(havenAutomationsProvider.notifier)
                            .setEnabled(a.id!, v);
                      } catch (e) {
                        if (context.mounted) showHavenToast(context, '$e');
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const SizedBox(width: 56),
                  AnimatedContainer(
                    duration: context.motion(HavenMotion.d2),
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(right: 7),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: a.enabled ? _tone(context, phase) : hv.tx3,
                    ),
                  ),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: context.motion(HavenMotion.d2),
                      layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.centerLeft,
                        children: [...previous, ?current],
                      ),
                      child: SizedBox(
                        key: ValueKey(
                          a.enabled
                              ? '${phase.name}${status?.inactive}'
                              : 'off',
                        ),
                        width: double.infinity,
                        child: Text(
                          motionStatusLine(
                            status,
                            DateTime.now(),
                            enabled: a.enabled,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HavenText.label.copyWith(
                            color: a.enabled ? hv.tx : hv.tx2,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (cond.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    const SizedBox(width: 56),
                    Icon(Icons.schedule_rounded, size: 14, color: hv.tx3),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        cond.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HavenText.caption.copyWith(color: hv.tx2),
                      ),
                    ),
                  ],
                ),
              ],
              if (conflicts.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    const SizedBox(width: 56),
                    Icon(Icons.warning_amber_rounded, size: 14, color: hv.warn),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        conflicts.length == 1
                            ? 'Auch eine HA-Automation nutzt diesen Melder'
                            : 'Auch ${conflicts.length} HA-Automationen nutzen diesen Melder',
                        style: HavenText.caption.copyWith(color: hv.warn),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
