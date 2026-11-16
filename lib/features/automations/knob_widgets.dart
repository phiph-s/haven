import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/press_scale.dart';
import '../../data/models/haven_automation.dart';
import '../settings/settings_widgets.dart';
import 'automations_provider.dart';
import 'haven_automations_provider.dart';
import 'knob_logic.dart';

/// Pfad des Editors (neu bzw. vorhandene Automation).
String knobEditorPath([String? id]) => '/automations/knob/${id ?? 'new'}';

/// ↻ für Drehen, nach links gespiegelt (siehe [mirroredAction]).
const IconData kRotateIcon = Icons.refresh_rounded;

/// Linksdrehung zeigt das Drehsymbol gespiegelt.
bool mirroredAction(String action) => action == 'rotate_left';

IconData gestureIcon(KnobGesture g) => switch (g) {
  KnobGesture.rotate => kRotateIcon,
  KnobGesture.single => Icons.touch_app_rounded,
  KnobGesture.double => Icons.ads_click_rounded,
  KnobGesture.hold => Icons.front_hand_rounded,
};

IconData actionIcon(String action) => switch (action) {
  'rotate_left' || 'rotate_right' => kRotateIcon,
  'single' => Icons.touch_app_rounded,
  'double' => Icons.ads_click_rounded,
  'hold' => Icons.front_hand_rounded,
  _ => Icons.radio_button_checked_rounded,
};

/// Runde Kachel mit Symbol, z. B. für Gesten.
class GestureGlyph extends StatelessWidget {
  const GestureGlyph({
    super.key,
    required this.icon,
    this.size = 44,
    this.active = false,
    this.mirror = false,
  });
  final IconData icon;
  final double size;
  final bool active;

  /// Waagrecht gespiegelt (Linksdrehung).
  final bool mirror;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return AnimatedContainer(
      duration: context.motion(HavenMotion.d2),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? hv.acc.withValues(alpha: 0.16) : hv.s2,
        border: Border.all(color: active ? hv.acc : hv.ln),
      ),
      child: Transform.flip(
        flipX: mirror,
        child: Icon(icon, size: size * 0.5, color: active ? hv.acc : hv.tx),
      ),
    );
  }
}

/// Hinweis, wenn HA-Automationen dieselben Regler steuern, mit Knopf zum
/// Deaktivieren nach Bestätigung.
class HaConflictCard extends ConsumerWidget {
  const HaConflictCard({
    super.key,
    required this.conflicts,
    this.what = 'Regler',
  });
  final List<HaConflict> conflicts;

  /// Was die HA-Automationen ansprechen („Regler“, „Melder“).
  final String what;

  Future<void> _disable(BuildContext context, WidgetRef ref) async {
    final ok = await showHavenSheet<bool>(
      context,
      builder: (ctx) {
        final hv = ctx.hv;
        final n = conflicts.length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              n == 1
                  ? 'HA-Automation ausschalten?'
                  : '$n HA-Automationen ausschalten?',
              style: HavenText.section.copyWith(color: hv.tx),
            ),
            const SizedBox(height: 6),
            Text(
              'Sie bleiben in Home Assistant erhalten und lassen sich dort '
              'jederzeit wieder einschalten.',
              style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
            ),
            const SizedBox(height: 12),
            for (final c in conflicts)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '· ${c.item.name}',
                  style: HavenText.body.copyWith(color: hv.tx),
                ),
              ),
            const SizedBox(height: 14),
            HavenButton(
              label: 'Ausschalten',
              icon: Icons.power_settings_new_rounded,
              primary: true,
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
    if (ok != true) return;
    final actions = ref.read(automationActionsProvider);
    for (final c in conflicts) {
      unawaited(actions.setEnabled(c.item.entityId, false));
    }
    Haptics.tap();
    if (context.mounted) {
      showHavenToast(
        context,
        conflicts.length == 1
            ? 'HA-Automation ausgeschaltet'
            : '${conflicts.length} HA-Automationen ausgeschaltet',
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    if (conflicts.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: hv.warn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(HavenRadii.l),
        border: Border.all(color: hv.warn.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: hv.warn, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Doppelt gesteuert',
                  style: HavenText.label.copyWith(color: hv.tx, fontSize: 15),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Diese HA-Automationen ${what == 'Regler' ? 'steuern' : 'nutzen'} dieselben $what. Deaktiviere sie, '
            'sonst passiert alles doppelt.',
            style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
          ),
          const SizedBox(height: 10),
          for (final c in conflicts)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Icon(Icons.home_work_outlined, size: 16, color: hv.tx3),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      c.item.name,
                      style: HavenText.label.copyWith(color: hv.tx),
                    ),
                  ),
                  if (!c.byDevice)
                    Text(
                      'am Namen erkannt',
                      style: HavenText.caption.copyWith(color: hv.tx3),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          HavenButton(
            label: conflicts.length == 1
                ? 'In Home Assistant ausschalten'
                : 'Alle ${conflicts.length} ausschalten',
            icon: Icons.power_settings_new_rounded,
            onTap: () => _disable(context, ref),
          ),
        ],
      ),
    );
  }
}

/// Zeile im Gerät-Detail eines Drehreglers oder Tasters:
/// „Steuert: Salon (Haven-Automation)“, führt in den Editor.
class KnobAutomationLink extends ConsumerWidget {
  const KnobAutomationLink({super.key, required this.ieee});
  final String ieee;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(automationForDeviceProvider(ieee));
    if (a == null) return const SizedBox.shrink();
    final hv = context.hv;
    final rooms = ref.watch(havenAutomationsProvider).value?.rooms ?? const {};
    final room = rooms[a.roomAreaId]?.name ?? a.roomAreaId;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Semantics(
        button: true,
        label: 'Steuert $room, Haven-Automation öffnen',
        excludeSemantics: true,
        child: PressScale(
          pressedScale: 0.985,
          onTap: () => context.push(knobEditorPath(a.id)),
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            decoration: BoxDecoration(
              color: hv.s1,
              borderRadius: BorderRadius.circular(HavenRadii.m),
              border: Border.all(color: hv.ln),
            ),
            child: Row(
              children: [
                Icon(Icons.auto_awesome_rounded, size: 20, color: hv.acc),
                const SizedBox(width: 12),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: 'Steuert: ',
                          style: HavenText.body.copyWith(color: hv.tx2),
                        ),
                        TextSpan(
                          text: room,
                          style: HavenText.label.copyWith(color: hv.tx),
                        ),
                        TextSpan(
                          text: a.enabled
                              ? ' (Haven-Automation)'
                              : ' (Haven-Automation, aus)',
                          style: HavenText.body.copyWith(color: hv.tx2),
                        ),
                      ],
                    ),
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: hv.tx3),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
