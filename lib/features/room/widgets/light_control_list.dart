import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/state/providers.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/haptics.dart';
import '../../../core/widgets/haven_switch.dart';
import '../../../data/models/light_groups.dart';
import '../../../data/models/snapshot.dart';
import '../../settings/settings_widgets.dart';

/// Ein Licht in der Liste „Lichtsteuerung“.
typedef LightEntry = ({String id, String name, bool excluded});

/// Alle Lichter nach Raum (ohne Gruppen), Lichter ohne Raum zuletzt. Mit
/// [roomId] nur dieser Raum.
List<(String, List<LightEntry>)> lightControlEntries(
  HavenSnapshot s, {
  String? roomId,
}) {
  final out = <(String, List<LightEntry>)>[];
  final seen = <String>{};
  for (final r in s.rooms) {
    if (roomId != null && r.id != roomId) continue;
    final l = <LightEntry>[
      for (final id in r.lightIds)
        if (s.entities[id] != null && !isLightGroup(s.entities[id]!))
          (
            id: id,
            name: s.entities[id]!.name,
            excluded: s.excludedLights.contains(id),
          ),
    ];
    seen.addAll(r.lightIds);
    if (l.isNotEmpty) out.add((r.name, l));
  }
  if (roomId == null) {
    final rest = <LightEntry>[
      for (final e in s.byDomain('light'))
        if (!seen.contains(e.entityId) && !isLightGroup(e))
          (
            id: e.entityId,
            name: e.name,
            excluded: s.excludedLights.contains(e.entityId),
          ),
    ];
    if (rest.isNotEmpty) out.add(('Ohne Raum', rest));
  }
  return out;
}

/// Sheet mit Schaltern „In der Lichtsteuerung“ je Licht.
Future<void> showLightControlSheet(BuildContext context, {String? roomId}) =>
    showHavenSheet<void>(
      context,
      builder: (_) => LightControlList(roomId: roomId),
    );

class LightControlList extends ConsumerWidget {
  const LightControlList({super.key, this.roomId});
  final String? roomId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final s = ref.watch(snapshotProvider);
    final repo = ref.read(repositoryProvider);
    final groups = lightControlEntries(s, roomId: roomId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Lichtsteuerung', style: HavenText.section.copyWith(color: hv.tx)),
        const SizedBox(height: 4),
        Text(
          'Ausgeschaltete Lichter zählen nicht für Raum an und aus, Alles aus '
          'und Szenen. Unter Zigbee und in Home Assistant bleiben sie '
          'erreichbar. ${repo.prefsShared ? 'Gilt für alle Geräte mit Haven.' : 'Gilt nur auf diesem Handy, bis die Integration 0.2.0 läuft.'}',
          style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
        ),
        if (groups.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              'Keine Lichter gefunden.',
              style: HavenText.body.copyWith(color: hv.tx2),
            ),
          ),
        for (final (title, lights) in groups) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
            child: Text(
              title,
              style: HavenText.label.copyWith(color: hv.tx2, fontSize: 13),
            ),
          ),
          SettingsGroup(
            children: [
              for (final l in lights)
                SettingsRow(
                  icon: l.excluded
                      ? Icons.lightbulb_outline_rounded
                      : Icons.lightbulb_rounded,
                  iconColor: l.excluded ? hv.tx3 : null,
                  title: l.name,
                  subtitle: l.excluded ? 'Nicht in der Lichtsteuerung' : null,
                  trailing: HavenSwitch(
                    value: !l.excluded,
                    semanticLabel: '${l.name} in der Lichtsteuerung',
                    onChanged: (v) => _set(context, ref, l.id, !v),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

Future<void> _set(
  BuildContext context,
  WidgetRef ref,
  String id,
  bool excluded,
) async {
  Haptics.tick();
  try {
    await ref.read(repositoryProvider).setLightExcluded(id, excluded);
  } catch (e) {
    if (context.mounted) {
      showHavenToast(context, 'Nicht gespeichert: $e');
    }
  }
}

/// Zeile im Lampen-Sheet: ein Licht aus der Lichtsteuerung nehmen.
class ExcludeLightRow extends ConsumerWidget {
  const ExcludeLightRow({super.key, required this.entityId});
  final String entityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final excluded = ref.watch(
      snapshotProvider.select((s) => s.excludedLights.contains(entityId)),
    );
    return Container(
      decoration: BoxDecoration(
        color: hv.s2,
        borderRadius: BorderRadius.circular(HavenRadii.m),
      ),
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Nicht in der Lichtsteuerung',
                  style: HavenText.label.copyWith(color: hv.tx, fontSize: 15),
                ),
                Text(
                  'Zählt nicht für Raum an, Alles aus und Szenen',
                  style: HavenText.caption.copyWith(color: hv.tx2),
                ),
              ],
            ),
          ),
          HavenSwitch(
            value: excluded,
            semanticLabel: 'Nicht in der Lichtsteuerung',
            onChanged: (v) => _set(context, ref, entityId, v),
          ),
        ],
      ),
    );
  }
}
