import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven_3d/haven_3d.dart' as h3;
import 'package:material_ui/material_ui.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/haven_switch.dart';
import '../map/map_3d.dart';
import '../zigbee/widgets/zb_common.dart' show showZbSheet;
import 'settings_widgets.dart';

/// Zeile „Erweiterte Render-Einstellungen“: öffnet ein Blatt mit Wänden und
/// Umgebung der 3D-Karte (gilt auf diesem Gerät).
class AdvancedRenderSettingsRow extends ConsumerWidget {
  const AdvancedRenderSettingsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(map3dSettingsProvider);
    final parts = [
      s.transparentWalls ? 'Durchsichtige Wände' : 'Deckende Wände',
      s.environment ? 'mit Umgebung' : 'ohne Umgebung',
      _reachShort(s.lightReach),
    ];
    return SettingsGroup(
      children: [
        SettingsRow(
          key: const ValueKey('advanced-render'),
          icon: Icons.tune_rounded,
          title: 'Erweiterte Render-Einstellungen',
          subtitle: parts.join(', '),
          onTap: () {
            Haptics.tick();
            showZbSheet<void>(
              context,
              builder: (_) => const AdvancedRenderSettingsSheet(),
            );
          },
        ),
      ],
    );
  }
}

/// Inhalt des Blatts: Schalter, die sofort gelten.
class AdvancedRenderSettingsSheet extends ConsumerWidget {
  const AdvancedRenderSettingsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final s = ref.watch(map3dSettingsProvider);
    final n = ref.read(map3dSettingsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Erweiterte Render-Einstellungen',
          style: HavenText.section.copyWith(color: hv.tx, fontSize: 22),
        ),
        const SizedBox(height: 4),
        Text(
          'Wie die 3D-Karte auf diesem Gerät aussieht.',
          style: HavenText.caption.copyWith(color: hv.tx2),
        ),
        const SizedBox(height: 14),
        SettingsGroup(
          children: [
            SettingsRow(
              icon: Icons.layers_outlined,
              title: 'Durchsichtige Wände',
              subtitle: s.transparentWalls
                  ? 'Nachbarräume scheinen durch die Wände'
                  : 'Wände decken, was dahinter liegt; die zur Kamera hin '
                        'bleiben weggeschnitten',
              trailing: HavenSwitch(
                key: const ValueKey('render-transparent-walls'),
                value: s.transparentWalls,
                onChanged: n.setTransparentWalls,
                semanticLabel: 'Durchsichtige Wände',
              ),
              onTap: () => n.setTransparentWalls(!s.transparentWalls),
            ),
            SettingsRow(
              icon: Icons.wb_twilight_rounded,
              title: 'Umgebung',
              subtitle: s.environment
                  ? 'Sonne, Mond, Tageszeit und Wetter rund um die Wohnung'
                  : 'Aus: ruhiger Hintergrund, festes Kartenlicht',
              trailing: HavenSwitch(
                key: const ValueKey('render-environment'),
                value: s.environment,
                onChanged: n.setEnvironment,
                semanticLabel: 'Umgebung',
              ),
              onTap: () => n.setEnvironment(!s.environment),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          'Licht der Lampen',
          style: HavenText.label.copyWith(color: hv.tx2),
        ),
        const SizedBox(height: 4),
        Text(
          'Wie weit Licht in andere Räume fällt. Weniger lädt die Karte und '
          'die Bilder für Widgets deutlich schneller.',
          style: HavenText.caption.copyWith(color: hv.tx3),
        ),
        const SizedBox(height: 10),
        SettingsGroup(
          children: [
            for (final r in h3.LightReach.values)
              SettingsRow(
                key: ValueKey('light-reach-${r.name}'),
                icon: switch (r) {
                  h3.LightReach.doors => Icons.door_front_door_outlined,
                  h3.LightReach.open => Icons.view_quilt_outlined,
                  h3.LightReach.room => Icons.crop_square_rounded,
                },
                title: switch (r) {
                  h3.LightReach.doors => 'Volle Beleuchtung',
                  h3.LightReach.open => 'Nur offene Räume',
                  h3.LightReach.room => 'Nur im Raum',
                },
                subtitle: switch (r) {
                  h3.LightReach.doors =>
                    'Licht fällt durch Türen und offene Wände',
                  h3.LightReach.open =>
                    'Licht fällt nur in offen verbundene Räume',
                  h3.LightReach.room => 'Jede Lampe leuchtet nur ihren Raum',
                },
                trailing: Icon(
                  s.lightReach == r
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: s.lightReach == r ? hv.acc : hv.tx3,
                  semanticLabel: s.lightReach == r ? 'gewählt' : null,
                ),
                onTap: () {
                  Haptics.tick();
                  n.setLightReach(r);
                },
              ),
          ],
        ),
      ],
    );
  }
}

String _reachShort(h3.LightReach r) => switch (r) {
  h3.LightReach.doors => 'volles Licht',
  h3.LightReach.open => 'Licht nur offen',
  h3.LightReach.room => 'Licht je Raum',
};
