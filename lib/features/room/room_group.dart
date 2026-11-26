import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/haven_card.dart';
import '../../data/haven_repository.dart';
import '../../data/models/room.dart';
import '../../data/models/snapshot.dart';
import '../settings/settings_widgets.dart' show showHavenToast;

// Szenen liegen in der Zigbee2MQTT-Gruppe eines Raums. Hat ein Raum keine
// (etwa bei einer neuen Einrichtung), legt Haven sie an: mit allen
// Zigbee-Lampen des Raums. Lampen, die später in den Raum kommen, nimmt
// Haven beim Raumwechsel ohnehin in die Gruppe auf.

/// Lampen eines Raums, die über Zigbee laufen (in eine Z2M-Gruppe passen),
/// und die übrigen (Matter, WLAN, Cloud).
({List<String> zigbee, List<String> other}) roomLampsByRadio(
  HavenSnapshot s,
  Room r,
) {
  final zigbeeEntities = {
    for (final d in s.devices)
      if (d.ieee != null) ...d.entityIds,
  };
  final lamps = s.controlledLightIds(r);
  return (
    zigbee: [
      for (final id in lamps)
        if (zigbeeEntities.contains(id)) id,
    ],
    other: [
      for (final id in lamps)
        if (!zigbeeEntities.contains(id)) id,
    ],
  );
}

/// Kann Haven für [r] eine Gruppe anlegen? (Integration kann es, Raum hat
/// keine Gruppe und mindestens eine Zigbee-Lampe.)
bool canCreateGroupFor(HavenRepository repo, HavenSnapshot s, Room r) =>
    repo.canCreateRoomGroups &&
    r.zigbeeGroupId == null &&
    roomLampsByRadio(s, r).zigbee.isNotEmpty;

/// Legt die Gruppe an und meldet das Ergebnis. `true` bei Erfolg.
Future<bool> createRoomGroupFlow(
  BuildContext context,
  WidgetRef ref,
  Room r,
) async {
  final repo = ref.read(repositoryProvider);
  try {
    final name = await repo.createRoomGroup(r.id);
    Haptics.tap();
    if (context.mounted) {
      showHavenToast(
        context,
        'Gruppe „$name“ angelegt. Jetzt kannst du Szenen speichern.',
      );
    }
    return true;
  } on HavenException catch (e) {
    if (context.mounted) showHavenToast(context, e.message);
    return false;
  }
}

/// Hinweis mit Knopf in der Raumansicht, wo sonst „keine Gruppe“ stünde.
class RoomGroupCard extends ConsumerStatefulWidget {
  const RoomGroupCard({super.key, required this.room});
  final Room room;

  @override
  ConsumerState<RoomGroupCard> createState() => _RoomGroupCardState();
}

class _RoomGroupCardState extends ConsumerState<RoomGroupCard> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final snap = ref.watch(snapshotProvider);
    final lamps = roomLampsByRadio(snap, widget.room);
    final n = lamps.zigbee.length;
    final other = lamps.other.length;
    return HavenCard(
      key: const ValueKey('room-group-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            ref.watch(repositoryProvider).canSceneDevices
                ? 'Mit einer Zigbee-Gruppe schalten die Zigbee-Lampen bei '
                      'Szenen und beim Dimmen gleichzeitig. Haven kann sie '
                      'anlegen, mit '
                      '${n == 1 ? 'der Zigbee-Lampe' : 'den $n Zigbee-Lampen'} '
                      'des Raums.'
                : 'Szenen speichert Haven in einer Zigbee-Gruppe. Dieser Raum '
                      'hat noch keine. Haven kann sie anlegen, mit '
                      '${n == 1 ? 'der Zigbee-Lampe' : 'den $n Zigbee-Lampen'} '
                      'des Raums.',
            style: HavenText.body.copyWith(color: hv.tx2, fontSize: 13.5),
          ),
          if (widget.room.scenes.any((s) => s.own)) ...[
            const SizedBox(height: 6),
            Text(
              'Die Szenen, die Haven bisher für den Raum führt, gelten danach '
              'nicht mehr. Speichere sie mit der Gruppe neu.',
              style: HavenText.caption.copyWith(color: hv.warn),
            ),
          ],
          if (other > 0) ...[
            const SizedBox(height: 6),
            Text(
              other == 1
                  ? '1 Lampe läuft nicht über Zigbee und schaltet bei Szenen '
                        'nicht mit.'
                  : '$other Lampen laufen nicht über Zigbee und schalten bei '
                        'Szenen nicht mit.',
              style: HavenText.caption.copyWith(color: hv.tx3),
            ),
          ],
          const SizedBox(height: 12),
          HavenButton(
            key: const ValueKey('room-group-create'),
            label: 'Zigbee-Gruppe anlegen',
            icon: Icons.group_work_outlined,
            primary: true,
            busy: _busy,
            onTap: _busy
                ? null
                : () async {
                    setState(() => _busy = true);
                    await createRoomGroupFlow(context, ref, widget.room);
                    if (mounted) setState(() => _busy = false);
                  },
          ),
        ],
      ),
    );
  }
}

/// Alle Räume ohne Gruppe auf einmal (Einstellungen › Räume verwalten).
/// Nichts zu tun: leer.
class MissingRoomGroupsCard extends ConsumerStatefulWidget {
  const MissingRoomGroupsCard({super.key});

  @override
  ConsumerState<MissingRoomGroupsCard> createState() =>
      _MissingRoomGroupsCardState();
}

class _MissingRoomGroupsCardState extends ConsumerState<MissingRoomGroupsCard> {
  bool _busy = false;

  Future<void> _createAll(List<Room> rooms) async {
    setState(() => _busy = true);
    final repo = ref.read(repositoryProvider);
    final done = <String>[];
    final failed = <String>[];
    for (final r in rooms) {
      try {
        await repo.createRoomGroup(r.id);
        done.add(r.name);
      } on HavenException catch (e) {
        failed.add('${r.name}: ${e.message}');
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    Haptics.tap();
    showHavenToast(
      context,
      [
        if (done.isNotEmpty)
          done.length == 1
              ? 'Gruppe für ${done.single} angelegt.'
              : '${done.length} Gruppen angelegt.',
        ...failed,
      ].join(' '),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final repo = ref.watch(repositoryProvider);
    final snap = ref.watch(snapshotProvider);
    final missing = [
      for (final r in snap.rooms)
        if (canCreateGroupFor(repo, snap, r)) r,
    ];
    if (missing.isEmpty) return const SizedBox.shrink();
    final names = [for (final r in missing) r.name].join(', ');
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: HavenCard(
        key: const ValueKey('missing-room-groups'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              missing.length == 1
                  ? '$names hat keine Zigbee-Gruppe'
                  : '${missing.length} Räume ohne Zigbee-Gruppe',
              style: HavenText.label.copyWith(color: hv.tx),
            ),
            const SizedBox(height: 4),
            Text(
              '${missing.length == 1 ? '' : '$names. '}Ohne Gruppe gibt es '
              'dort keine Szenen. Haven legt die Gruppen in Zigbee2MQTT an, '
              'jeweils mit den Zigbee-Lampen des Raums.',
              style: HavenText.body.copyWith(color: hv.tx2, fontSize: 13.5),
            ),
            const SizedBox(height: 12),
            HavenButton(
              key: const ValueKey('missing-room-groups-create'),
              label: missing.length == 1
                  ? 'Gruppe anlegen'
                  : '${missing.length} Gruppen anlegen',
              icon: Icons.group_work_outlined,
              primary: true,
              busy: _busy,
              onTap: _busy ? null : () => _createAll(missing),
            ),
          ],
        ),
      ),
    );
  }
}
