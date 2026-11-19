import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/light/room_palette.dart';
import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/accent_scope.dart';
import '../../core/widgets/animated_palette.dart';
import '../../core/widgets/haven_card.dart';
import '../../core/widgets/haven_sheet.dart';
import '../../core/widgets/haven_switch.dart';
import '../../core/widgets/section_header.dart';
import '../home/room_render.dart';
import '../../data/room_view.dart';
import '../climate/thermostat_widgets.dart';
import 'room_hero.dart';
import 'widgets/brightness_slider.dart';
import 'widgets/lamp_row.dart';
import 'widgets/lamp_sheet.dart';
import 'widgets/light_control_list.dart';
import 'widgets/scene_card.dart';
import 'widgets/scene_editor.dart';
import '../../core/widgets/horizontal_scroller.dart';

/// Raum als Sheet von unten (Route in `router.dart`, `HavenSheetPage`):
/// Hintergrund aus der Raumfarbe, Helligkeitsregler, Szenen und Lampen.
/// Ziehen am Griff oder am oberen Ende der Liste schließt. Drehregler und
/// Taster stehen nicht hier, sondern in der Geräteansicht (dort steht,
/// welchen Raum sie steuern).
class RoomScreen extends ConsumerStatefulWidget {
  const RoomScreen({
    super.key,
    required this.roomId,
    this.autoSheet = false,
    this.panel = false,
  });
  final String roomId;

  /// Desktop: Seitenpanel (alle Ecken rund, kein Griff, Schließen mit X).
  final bool panel;

  /// Öffnet das Sheet "Farbe für alle" beim Start (Screenshots).
  final bool autoSheet;

  @override
  ConsumerState<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends ConsumerState<RoomScreen> {
  String get roomId => widget.roomId;

  @override
  void initState() {
    super.initState();
    if (widget.autoSheet) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final view = ref.read(roomViewProvider(roomId));
        if (!mounted || view == null) return;
        final targets = view.anyOn ? view.lampsOn : view.lamps;
        showLampSheet(
          context,
          LampTarget(
            title: '${view.name} · alle Lampen',
            subtitle: '${targets.length} Lampen',
            lampIds: [for (final l in targets) l.entityId],
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(roomViewProvider(roomId));
    final hv = context.hv;
    if (view == null) {
      return Center(
        child: Text(
          'Raum nicht gefunden',
          style: HavenText.body.copyWith(color: hv.tx2),
        ),
      );
    }
    final palette = view.palette(dark: hv.isDark);
    final radius = widget.panel
        ? BorderRadius.circular(HavenRadii.l)
        : const BorderRadius.vertical(top: Radius.circular(HavenRadii.xl));
    return AccentScope(
      palette: palette,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF000000).withValues(alpha: 0.18),
              blurRadius: 24,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Stack(
            fit: StackFit.expand,
            children: [
              RoomPageBackdrop(palette: palette),
              // Haarlinie oben, damit das Sheet im Dunkeln eine Kante hat.
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: widget.panel
                        ? Border.all(color: hv.ln2)
                        : Border(top: BorderSide(color: hv.ln2)),
                  ),
                ),
              ),
              Column(
                children: [
                  if (widget.panel)
                    const SizedBox(height: 14)
                  else
                    const SheetGrabber(),
                  Expanded(
                    child: _RoomBody(
                      view: view,
                      palette: palette,
                      panel: widget.panel,
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

class _RoomBody extends ConsumerWidget {
  const _RoomBody({
    required this.view,
    required this.palette,
    this.panel = false,
  });
  final RoomView view;
  final RoomPalette palette;
  final bool panel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final repo = ref.read(repositoryProvider);
    final room = view.room;
    final bottom = MediaQuery.of(context).padding.bottom;
    final hasLights = view.lamps.isNotEmpty;
    // Liest den Snapshot mit, damit die Karte nach dem Verbinden erscheint.
    ref.watch(snapshotProvider.select((s) => s.rooms));
    final canEditScenes = repo.canEditScenes(room.id);
    final excludedCount = ref.watch(
      snapshotProvider.select((s) => s.excludedLampsOf(room).length),
    );

    void openLamp(String id, String name) => showLampSheet(
      context,
      LampTarget(title: name, subtitle: id, lampIds: [id]),
    );

    void openGroupSheet() {
      final targets = view.anyOn ? view.lampsOn : view.lamps;
      showLampSheet(
        context,
        LampTarget(
          title: '${room.name} · alle Lampen',
          subtitle:
              '${targets.length} ${targets.length == 1 ? 'Lampe' : 'Lampen'}',
          lampIds: [for (final l in targets) l.entityId],
        ),
      );
    }

    final sheet = HavenSheetScope.maybeOf(context);
    return ListView(
      controller: sheet?.scrollController,
      physics: const AlwaysScrollableScrollPhysics(
        parent: ClampingScrollPhysics(),
      ),
      padding: EdgeInsets.only(bottom: 40 + bottom),
      children: [
        // Kopfzeile
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 12, 0),
          child: Row(
            children: [
              RoundIconButton(
                icon: panel
                    ? Icons.close_rounded
                    : Icons.keyboard_arrow_down_rounded,
                label: 'Schließen',
                onTap: () => sheet != null ? sheet.close() : context.pop(),
              ),
              Expanded(
                child: Text(
                  room.name,
                  textAlign: TextAlign.center,
                  style: HavenText.headline.copyWith(
                    color: hv.tx,
                    fontSize: 22,
                  ),
                ),
              ),
              if (hasLights)
                HavenSwitch(
                  value: view.anyOn,
                  semanticLabel: 'Raum ${room.name}',
                  onChanged: (_) => repo.toggleRoom(room.id),
                )
              else
                const SizedBox(width: 62),
            ],
          ),
        ),
        // Der Raum mit seinem Licht (aus der Kachel hierher geflogen).
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: RoomRenderHeader(roomId: room.id),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 20, 14),
          child: _ClimateLine(view: view),
        ),
        if (!hasLights) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: HavenCard(
              child: Text(
                excludedCount > 0
                    ? 'Die Lichter in diesem Raum gehören nicht zur Lichtsteuerung.'
                    : 'In diesem Raum gibt es noch keine Lampen. Ordne sie unter Zigbee einem Raum zu oder in Home Assistant einem Bereich.',
                style: HavenText.body.copyWith(color: hv.tx2),
              ),
            ),
          ),
          if (excludedCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: _ExcludedHint(
                count: excludedCount,
                onTap: () => showLightControlSheet(context, roomId: room.id),
              ),
            ),
        ] else ...[
          // Regler und Seitenspalte
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SizedBox(
              height: 300,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 140,
                    child: AnimatedPalette(
                      palette: palette,
                      builder: (context, p) => BrightnessSlider(
                        value: view.brightness,
                        colors: [p.mix, p.primary, p.secondary],
                        label: 'Helligkeit ${room.name}',
                        onChanged: (v) => repo.setRoomBrightness(room.id, v),
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: _SideColumn(
                      view: view,
                      palette: palette,
                      onAll: openGroupSheet,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Szenen
          const SizedBox(height: 22),
          SectionHeader(
            'Szenen',
            padding: const EdgeInsets.symmetric(horizontal: 20),
            trailing: canEditScenes
                ? SceneSaveChip(onTap: () => saveSceneFlow(context, ref, room))
                : null,
          ),
          const SizedBox(height: 10),
          if (room.scenes.isEmpty && !canEditScenes)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: HavenCard(
                child: Text(
                  room.zigbeeGroupId == null
                      ? 'Dieser Raum hat noch keine Szenen. Szenen liegen in einer Zigbee-Gruppe, dieser Raum hat keine.'
                      : 'Dieser Raum hat noch keine Szenen. Zum Anlegen braucht Haven eine neuere Integration in Home Assistant.',
                  style: HavenText.body.copyWith(color: hv.tx2, fontSize: 13.5),
                ),
              ),
            )
          else
            SizedBox(
              height: 108,
              child: HorizontalScroller(
                builder: (context, controller) => ListView.separated(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  itemCount: room.scenes.length + (canEditScenes ? 1 : 0),
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (context, i) {
                    if (i == room.scenes.length) {
                      return SceneAddCard(
                        onTap: () => saveSceneFlow(context, ref, room),
                      );
                    }
                    final s = room.scenes[i];
                    return SceneCard(
                      scene: s,
                      active: view.activeSceneId == s.id,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        repo.applyScene(room.id, s.id);
                      },
                      onEdit: canEditScenes && s.editable
                          ? () {
                              HapticFeedback.mediumImpact();
                              editSceneFlow(context, ref, room, s);
                            }
                          : null,
                    );
                  },
                ),
              ),
            ),
          // Lampen
          const SizedBox(height: 14),
          SectionHeader(
            'Lampen',
            padding: const EdgeInsets.symmetric(horizontal: 20),
            trailing: Text(
              '${view.lamps.length}',
              style: HavenText.label.copyWith(color: hv.tx2),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              children: [
                for (final l in view.lamps)
                  LampRow(
                    key: ValueKey(l.entityId),
                    lamp: l,
                    onToggle: (v) => repo.setLights([l.entityId], on: v),
                    onOpen: () => openLamp(l.entityId, l.name),
                    onLongPress: () {
                      HapticFeedback.mediumImpact();
                      openLamp(l.entityId, l.name);
                    },
                  ),
              ],
            ),
          ),
          if (excludedCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
              child: _ExcludedHint(
                count: excludedCount,
                onTap: () => showLightControlSheet(context, roomId: room.id),
              ),
            ),
        ],
        RoomHeatingSection(roomId: room.id),
      ],
    );
  }
}

class _ClimateLine extends StatelessWidget {
  const _ClimateLine({required this.view});
  final RoomView view;

  static String _n(double v) => v.toStringAsFixed(1).replaceAll('.', ',');

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final style = HavenText.label.copyWith(color: hv.tx2);
    if (view.temperature == null) {
      return Text('Kein Klimasensor', style: style);
    }
    return Row(
      children: [
        Icon(Icons.thermostat_rounded, size: 16, color: hv.tx2),
        const SizedBox(width: 4),
        Text('${_n(view.temperature!)} °C', style: style),
        if (view.humidity != null) ...[
          const SizedBox(width: 14),
          Icon(Icons.water_drop_outlined, size: 16, color: hv.tx2),
          const SizedBox(width: 4),
          Text('${_n(view.humidity!)} %', style: style),
        ],
      ],
    );
  }
}

class _SideColumn extends ConsumerWidget {
  const _SideColumn({
    required this.view,
    required this.palette,
    required this.onAll,
  });
  final RoomView view;
  final RoomPalette palette;
  final VoidCallback onAll;

  static const _whites = [
    ('Kerze', 2200),
    ('Warm', 2700),
    ('Neutral', 4000),
    ('Kalt', 6000),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final repo = ref.read(repositoryProvider);
    final targets = view.anyOn ? view.lampsOn : view.lamps;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              label: 'Helligkeit ${view.brightness} Prozent',
              excludeSemantics: true,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${view.brightness}',
                      style: HavenText.percent.copyWith(color: hv.tx),
                    ),
                    TextSpan(
                      text: '%',
                      style: HavenText.percent.copyWith(
                        color: hv.tx2,
                        fontSize: 26,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              view.activeSceneId != null
                  ? 'Szene ${view.room.scenes.where((s) => s.id == view.activeSceneId).firstOrNull?.name ?? ''}'
                  : view.anyOn
                  ? '${view.lampsOn.length} ${view.lampsOn.length == 1 ? 'Lampe' : 'Lampen'} an'
                  : 'Alles aus',
              style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14.5),
            ),
            const SizedBox(height: 8),
            AnimatedPalette(
              palette: palette,
              builder: (context, p) => Row(
                children: [
                  for (final c in p.mesh)
                    Container(
                      width: 18,
                      height: 18,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: p.isOn ? c : hv.s3,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var row = 0; row < 2; row++)
              Row(
                children: [
                  for (var col = 0; col < 2; col++) ...[
                    if (col == 1) const SizedBox(width: 6),
                    Expanded(
                      child: _WhiteChip(
                        label: _whites[row * 2 + col].$1,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          repo.setLights([
                            for (final l in targets) l.entityId,
                          ], kelvin: _whites[row * 2 + col].$2);
                        },
                      ),
                    ),
                  ],
                ],
              ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onAll,
              child: Container(
                height: HavenSpace.touch,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: hv.s2,
                  borderRadius: BorderRadius.circular(HavenRadii.m),
                  border: Border.all(color: hv.ln),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.palette_outlined, size: 18, color: hv.tx),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Farbe für alle',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HavenText.label.copyWith(color: hv.tx),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ExcludedHint extends StatelessWidget {
  const _ExcludedHint({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final text = count == 1
        ? '1 Licht nicht in der Lichtsteuerung'
        : '$count Lichter nicht in der Lichtsteuerung';
    return Semantics(
      button: true,
      label: text,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: HavenSpace.touch,
          child: Row(
            children: [
              Icon(Icons.visibility_off_outlined, size: 18, color: hv.tx3),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: HavenText.caption.copyWith(
                    color: hv.tx2,
                    fontSize: 13,
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 20, color: hv.tx3),
            ],
          ),
        ),
      ),
    );
  }
}

class _WhiteChip extends StatelessWidget {
  const _WhiteChip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      button: true,
      label: 'Weißton $label',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: HavenSpace.touch,
          child: Container(
            alignment: Alignment.center,
            margin: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: hv.s2,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: hv.ln),
            ),
            child: Text(
              label,
              style: HavenText.label.copyWith(color: hv.tx, fontSize: 12.5),
            ),
          ),
        ),
      ),
    );
  }
}
