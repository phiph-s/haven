import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/entry_animation.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/haven_switch.dart';
import '../../core/widgets/press_scale.dart';
import '../../core/widgets/screen_header.dart';
import '../../core/widgets/section_header.dart';
import '../../core/widgets/skeleton.dart';
import '../../data/models/haven_automation.dart';
import '../settings/settings_widgets.dart';
import 'automation_logic.dart';
import 'automations_provider.dart';
import 'haven_automations_provider.dart';
import 'knob_logic.dart';
import 'knob_widgets.dart';
import 'motion_editor_screen.dart';
import 'motion_widgets.dart';
import '../search/search_sheet.dart';

/// Pfad der Liste der Home-Assistant-Automationen.
const haAutomationsPath = '/automations/home-assistant';

/// Abläufe: oben die Haven-Automationen (laufen in der Integration), darunter
/// der Weg zu den Home-Assistant-Automationen.
class AutomationsScreen extends ConsumerWidget {
  const AutomationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final haven = ref.watch(havenAutomationsProvider);
    final ha = ref.watch(automationsProvider);
    final data = haven.value;
    final items = data?.automations ?? const <HavenAutomation>[];
    final haActive = ha.items.where((a) => a.on).length;
    final active = items.where((a) => a.enabled).length;

    final subtitle = data == null
        ? 'Haven und Home Assistant'
        : items.isEmpty
        ? 'Noch keine Haven-Automation'
        : '$active von ${items.length} Haven-Automationen aktiv';

    return ListView(
      padding: const EdgeInsets.only(bottom: HavenSpace.navClearance),
      children: [
        ScreenHeader(
          title: 'Abläufe',
          subtitle: subtitle,
          actions: const [SearchButton(), SettingsButton()],
        ),
        const SizedBox(height: 18),
        const SectionHeader(
          'Haven-Automationen',
          padding: EdgeInsets.symmetric(horizontal: HavenSpace.page),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HavenSpace.page),
          child: Text(
            'Laufen direkt in Haven, schnell und ohne HA-Automation.',
            style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
          ),
        ),
        const SizedBox(height: 12),
        if (haven.isLoading && data == null)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: HavenSpace.page),
            child: SkeletonScope(
              label: 'Automationen laden',
              child: Skeleton(
                width: double.infinity,
                height: 92,
                radius: HavenRadii.l,
              ),
            ),
          )
        else if (data != null && !data.supported)
          const _Notice(
            icon: Icons.system_update_alt_rounded,
            text:
                'Deine Haven-Integration in Home Assistant kann noch keine '
                'Automationen. Aktualisiere sie auf die neueste Version.',
          )
        else if (haven.hasError && data == null)
          _Notice(
            icon: Icons.cloud_off_rounded,
            text: 'Automationen nicht erreichbar: ${haven.error}',
          )
        else if (items.isEmpty)
          const _EmptyHaven()
        else
          for (final (i, a) in items.indexed)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HavenSpace.page,
                0,
                HavenSpace.page,
                10,
              ),
              child: EntryAnimation(
                index: i,
                child: a.isMotion
                    ? MotionAutomationCard(
                        key: ValueKey(a.id),
                        automation: a,
                        roomName: data?.rooms[a.roomAreaId]?.name,
                      )
                    : HavenAutomationCard(
                        key: ValueKey(a.id),
                        automation: a,
                        roomName: data?.rooms[a.roomAreaId]?.name,
                      ),
              ),
            ),
        if (data == null || data.supported)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HavenSpace.page,
              6,
              HavenSpace.page,
              0,
            ),
            child: HavenButton(
              label: 'Neue Automation',
              icon: Icons.add_rounded,
              primary: true,
              onTap: () => _chooseType(context),
            ),
          ),
        const SizedBox(height: 30),
        const SectionHeader(
          'Home Assistant',
          padding: EdgeInsets.symmetric(horizontal: HavenSpace.page),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HavenSpace.page),
          child: SettingsGroup(
            children: [
              SettingsRow(
                icon: Icons.home_work_outlined,
                title: 'Home-Assistant-Automationen (${ha.items.length})',
                subtitle: ha.items.isEmpty
                    ? 'Keine vorhanden'
                    : '$haActive aktiv · suchen, schalten, in HA bearbeiten',
                onTap: () => context.push(haAutomationsPath),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Welche Art Automation? Drehregler oder Bewegungslicht.
Future<void> _chooseType(BuildContext context) async {
  final kind = await showHavenSheet<String>(
    context,
    builder: (ctx) {
      final hv = ctx.hv;
      Widget option(String id, IconData icon, String title, String text) =>
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: PressScale(
              pressedScale: 0.98,
              onTap: () => Navigator.of(ctx).pop(id),
              child: Semantics(
                button: true,
                label: title,
                excludeSemantics: true,
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: hv.s1,
                    borderRadius: BorderRadius.circular(HavenRadii.l),
                    border: Border.all(color: hv.ln),
                  ),
                  child: Row(
                    children: [
                      GestureGlyph(icon: icon, size: 48),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: HavenText.label.copyWith(
                                color: hv.tx,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              text,
                              style: HavenText.body.copyWith(
                                color: hv.tx2,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Was soll Haven übernehmen?',
            style: HavenText.section.copyWith(color: hv.tx),
          ),
          const SizedBox(height: 14),
          option(
            'knob',
            kRotateIcon,
            'Drehregler für einen Raum',
            'Drehen dimmt, Drücken schaltet, Doppelt wechselt die Szene.',
          ),
          option(
            'motion',
            Icons.directions_walk_rounded,
            'Bewegungslicht',
            'Ein Melder schaltet das Licht, nur wenn es passt.',
          ),
        ],
      );
    },
  );
  if (!context.mounted || kind == null) return;
  context.push(kind == 'motion' ? motionEditorPath() : knobEditorPath());
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HavenSpace.page,
        0,
        HavenSpace.page,
        4,
      ),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: hv.s1,
          borderRadius: BorderRadius.circular(HavenRadii.l),
          border: Border.all(color: hv.ln),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: hv.tx2, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyHaven extends StatelessWidget {
  const _EmptyHaven();

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    Widget tile(IconData icon, String title, String text) => Row(
      children: [
        GestureGlyph(icon: icon, size: 52),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: HavenText.label.copyWith(color: hv.tx, fontSize: 15),
              ),
              const SizedBox(height: 3),
              Text(
                text,
                style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
              ),
            ],
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HavenSpace.page,
        0,
        HavenSpace.page,
        4,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
        decoration: BoxDecoration(
          color: hv.s1,
          borderRadius: BorderRadius.circular(HavenRadii.l),
          border: Border.all(color: hv.ln),
        ),
        child: Column(
          children: [
            tile(
              kRotateIcon,
              'Drehregler für einen Raum',
              'Drehen dimmt, Drücken schaltet, Doppelt wechselt die Szene.',
            ),
            const SizedBox(height: 16),
            tile(
              Icons.directions_walk_rounded,
              'Bewegungslicht',
              'Ein Melder schaltet das Licht, nur wenn es passt.',
            ),
          ],
        ),
      ),
    );
  }
}

/// Karte einer Haven-Automation: Raum, Anzahl der Regler, Schalter,
/// zuletzt ausgelöst, Hinweis auf doppelte HA-Automationen.
class HavenAutomationCard extends ConsumerWidget {
  const HavenAutomationCard({
    super.key,
    required this.automation,
    this.roomName,
  });

  final HavenAutomation automation;
  final String? roomName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final a = automation;
    final knobs = ref.watch(knobDevicesProvider);
    final types = {for (final k in knobs) k.ieee: k.device.deviceType};
    final nKnobs = a.devices.where((d) => types[d] != 'remote').length;
    final nButtons = a.devices.length - nKnobs;
    final parts = [
      if (nKnobs > 0) nKnobs == 1 ? '1 Drehregler' : '$nKnobs Drehregler',
      if (nButtons > 0) nButtons == 1 ? '1 Taster' : '$nButtons Taster',
    ];
    final conflicts = a.enabled
        ? ref.watch(haConflictsProvider(a))
        : const <HaConflict>[];
    final fired = a.lastTriggered;
    final last = fired == null
        ? 'noch nie ausgelöst'
        : 'zuletzt ${relativeTime(fired.at, DateTime.now())} · '
              '${actionLabel(fired.action)}';

    return AnimatedOpacity(
      opacity: a.enabled ? 1 : 0.62,
      duration: context.motion(HavenMotion.d2),
      child: PressScale(
        pressedScale: 0.98,
        onTap: () => context.push(knobEditorPath(a.id)),
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
                    icon: nKnobs == 0
                        ? Icons.radio_button_checked_rounded
                        : kRotateIcon,
                    active: a.enabled,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          roomName ?? a.roomAreaId,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HavenText.headline.copyWith(color: hv.tx),
                        ),
                        Text(
                          [a.name, ...parts].join(' · '),
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
                  Icon(Icons.schedule_rounded, size: 14, color: hv.tx3),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      a.enabled ? last : 'ausgeschaltet',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HavenText.caption.copyWith(color: hv.tx2),
                    ),
                  ),
                ],
              ),
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
                            ? 'Auch eine HA-Automation steuert diese Regler'
                            : 'Auch ${conflicts.length} HA-Automationen steuern diese Regler',
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
