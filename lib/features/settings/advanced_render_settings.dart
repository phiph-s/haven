import 'package:flutter_riverpod/flutter_riverpod.dart';
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
      ],
    );
  }
}
