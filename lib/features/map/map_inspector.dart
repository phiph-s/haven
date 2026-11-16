import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/adaptive/hover.dart';
import '../../core/light/color_math.dart';
import '../../core/light/room_palette.dart';
import '../../core/router/router.dart';
import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/haven_card.dart';
import '../../core/widgets/haven_switch.dart';
import '../../data/models/floor_plan.dart';
import 'map_data.dart';
import 'map_panels.dart';
import 'map_routes.dart';

/// Inspektor rechts neben der Desktop-Karte: oben die Ansicht (Legende,
/// Status der Kartenart, Hinweise), darunter der gewählte Raum mit Lampen
/// oder die Liste der Räume.
class MapInspector extends ConsumerWidget {
  const MapInspector({
    super.key,
    required this.plan,
    required this.selected,
    required this.onSelect,
    required this.layerCard,
    this.info,
    this.panel,
    this.onClosePanel,
  });

  final HavenFloorPlan plan;

  /// Plan-Raum-ID oder `null`.
  final String? selected;
  final ValueChanged<String?> onSelect;

  /// Karte der aktiven Kartenart (Status, Legende, Zeitstrahl).
  final Widget layerCard;

  /// Kurzer Hinweis nach einer Aktion (ersetzt die Karte kurz).
  final String? info;

  /// Info-Panel zu einem angetippten Gerät oder Raum (ersetzt die
  /// Raumansicht, bis es geschlossen wird).
  final MapPanelSpec? panel;
  final VoidCallback? onClosePanel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final room = selected == null ? null : plan.room(selected!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HavenCard(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          radius: HavenRadii.m,
          child: AnimatedSize(
            duration: context.motion(HavenMotion.d3),
            curve: HavenMotion.out,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: context.motion(HavenMotion.d2),
              child: info != null
                  ? SizedBox(
                      key: ValueKey(info),
                      width: double.infinity,
                      child: Text(
                        info!,
                        style: HavenText.body.copyWith(color: hv.tx),
                      ),
                    )
                  : KeyedSubtree(key: const ValueKey('card'), child: layerCard),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: HavenCard(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
            radius: HavenRadii.m,
            child: AnimatedSwitcher(
              duration: context.motion(HavenMotion.d2),
              child: panel != null
                  ? MapPanelScope(
                      key: ValueKey('panel-${panel!.key}'),
                      sheet: false,
                      onClose: onClosePanel,
                      child: Builder(
                        builder: (context) =>
                            ListView(children: [panel!.builder(context)]),
                      ),
                    )
                  : room == null
                  ? _RoomList(
                      key: const ValueKey('list'),
                      plan: plan,
                      onSelect: onSelect,
                    )
                  : _RoomDetail(
                      key: ValueKey('room-${room.id}'),
                      plan: plan,
                      room: room,
                      onClose: () => onSelect(null),
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

String _m2(FloorRoom r, double cellMeters) {
  final v = r.area * cellMeters * cellMeters;
  return '${(v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1)).replaceAll('.', ',')} m²';
}

String _values(RoomValues? v) => [
  if (v?.temp != null) '${num1(v!.temp!)} °C',
  if (v?.hum != null) '${v!.hum!.round()} %',
].join(' · ');

class _RoomList extends ConsumerWidget {
  const _RoomList({super.key, required this.plan, required this.onSelect});
  final HavenFloorPlan plan;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final lights = ref.watch(mapLightsProvider(plan));
    final snap = ref.watch(snapshotProvider);
    return ListView(
      children: [
        Text('Räume', style: HavenText.headline.copyWith(color: hv.tx)),
        const SizedBox(height: 2),
        Text(
          'Klick auf einen Raum zeigt ihn hier. Mausrad zoomt, Ziehen '
          'verschiebt die Karte.',
          style: HavenText.caption.copyWith(color: hv.tx3),
        ),
        const SizedBox(height: 10),
        for (final r in plan.rooms)
          Builder(
            builder: (context) {
              final sr = snapshotRoomFor(snap, r);
              final on = sr == null
                  ? 0
                  : sr.lightIds
                        .where((id) => snap.entity(id)?.isOn ?? false)
                        .length;
              final sub = [
                if (sr == null || sr.lightIds.isEmpty)
                  'Keine Lampen'
                else if (on == 0)
                  'Aus'
                else
                  on == 1 ? 'Ein Licht an' : '$on Lichter an',
                if (_values(lights.rooms[r.id]).isNotEmpty)
                  _values(lights.rooms[r.id]),
              ].join(' · ');
              return _Row(
                title: r.name,
                subtitle: sub,
                lit: on > 0,
                onTap: () => onSelect(r.id),
              );
            },
          ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.lit = false,
  });
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool lit;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return HoverBuilder(
      builder: (context, hover) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: context.motion(HavenMotion.d1),
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: hoverOverlay(hv, hover),
            borderRadius: BorderRadius.circular(HavenRadii.s),
          ),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: lit ? hv.acc : hv.s3,
                  boxShadow: lit
                      ? [
                          BoxShadow(
                            color: hv.acc.withValues(alpha: 0.6),
                            blurRadius: 8,
                          ),
                        ]
                      : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: HavenText.label.copyWith(
                        color: hv.tx,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HavenText.caption.copyWith(color: hv.tx2),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: hv.tx3, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoomDetail extends ConsumerWidget {
  const _RoomDetail({
    super.key,
    required this.plan,
    required this.room,
    required this.onClose,
  });
  final HavenFloorPlan plan;
  final FloorRoom room;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final snap = ref.watch(snapshotProvider);
    final lights = ref.watch(mapLightsProvider(plan));
    final sr = snapshotRoomFor(snap, room);
    final view = sr == null ? null : ref.watch(roomViewProvider(sr.id));
    final repo = ref.read(repositoryProvider);
    final furniture = plan.furniture
        .where((f) => plan.locationOfFurniture(f) == room.id)
        .length;
    final facts = [
      _m2(room, plan.grid.cellMeters),
      if (_values(lights.rooms[room.id]).isNotEmpty)
        _values(lights.rooms[room.id]),
      if (furniture > 0) furniture == 1 ? '1 Möbelstück' : '$furniture Möbel',
    ].join(' · ');
    final lamps = view?.lamps ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                room.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HavenText.section.copyWith(color: hv.tx, fontSize: 22),
              ),
            ),
            if (view != null && lamps.isNotEmpty)
              HavenSwitch(
                value: view.anyOn,
                semanticLabel: 'Raum ${room.name}',
                onChanged: (_) => repo.toggleRoom(view.id),
              ),
            RoundIconButton(
              icon: Icons.close_rounded,
              label: 'Auswahl aufheben',
              onTap: onClose,
            ),
          ],
        ),
        Text(facts, style: HavenText.caption.copyWith(color: hv.tx2)),
        const SizedBox(height: 14),
        Expanded(
          child: lamps.isEmpty
              ? Text(
                  'In diesem Raum gibt es keine Lampen.',
                  style: HavenText.body.copyWith(color: hv.tx3, fontSize: 14),
                )
              : ListView(
                  children: [
                    for (final l in lamps)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          children: [
                            Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: l.on
                                    ? colorOf(uiColor(l.color, dark: hv.isDark))
                                    : hv.s2,
                                border: l.on ? null : Border.all(color: hv.ln2),
                              ),
                              child: Icon(
                                l.on
                                    ? Icons.lightbulb_rounded
                                    : Icons.lightbulb_outline_rounded,
                                size: 15,
                                color: l.on
                                    ? colorOf(
                                        onColorFor(
                                          uiColor(l.color, dark: hv.isDark),
                                        ),
                                      )
                                    : hv.tx3,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: HavenText.label.copyWith(
                                      color: hv.tx,
                                      fontSize: 13.5,
                                    ),
                                  ),
                                  Text(
                                    l.on ? '${l.brightness} %' : 'Aus',
                                    style: HavenText.caption.copyWith(
                                      color: hv.tx3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            HavenSwitch(
                              value: l.on,
                              semanticLabel: l.name,
                              onChanged: (v) =>
                                  repo.setLights([l.entityId], on: v),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            if (sr != null && sr.lightIds.isNotEmpty) ...[
              Expanded(
                child: HavenButton(
                  label: 'Raum öffnen',
                  icon: Icons.open_in_new_rounded,
                  primary: true,
                  onTap: () => context.push(Routes.room(sr.id)),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: HavenButton(
                label: 'Einrichten',
                icon: Icons.chair_outlined,
                onTap: () => context.push(
                  '$mapEditorPath?mode=furniture&sel=${room.id}',
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
