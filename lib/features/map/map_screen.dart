import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/light/color_math.dart';
import '../../core/light/room_palette.dart';
import '../../core/router/router.dart';
import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/entry_animation.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/haven_card.dart';
import '../../core/widgets/press_scale.dart';
import '../../core/widgets/screen_header.dart';
import '../../data/models/floor_plan.dart';
import 'floor_plan_store.dart';
import 'floor_plan_view.dart';
import 'map_data.dart';
import 'map_markers.dart';
import 'map_painters.dart';
import 'map_routes.dart';

/// Karte: Grundriss mit Räumen, Lampen in Lichtfarbe und Werten.
class MapScreen extends ConsumerWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(floorPlanProvider);
    final p = plan.value;
    final has = p != null && !p.isEmpty;
    return Column(
      children: [
        _MapHeader(plan: has ? p : null),
        Expanded(
          child: !plan.hasValue
              ? const SizedBox.shrink()
              : has
              ? _MapBody(plan: p)
              : const _EmptyMap(),
        ),
      ],
    );
  }
}

class _MapHeader extends ConsumerWidget {
  const _MapHeader({required this.plan});
  final HavenFloorPlan? plan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    String? sub;
    if (plan == null) {
      sub = 'Dein Zuhause im Grundriss';
    } else {
      final l = ref.watch(mapLightsProvider(plan!));
      final n = l.onCount;
      final t = l.avgTemp;
      sub =
          (n == 0
              ? 'Alle Lichter aus'
              : n == 1
              ? 'Ein Licht an'
              : '$n Lichter an') +
          (t == null ? '' : ' · ${num1(t)} °C im Schnitt');
    }
    return ScreenHeader(
      title: 'Karte',
      subtitle: sub,
      large: false,
      actions: [
        if (plan != null)
          RoundIconButton(
            icon: Icons.edit_outlined,
            label: 'Grundriss bearbeiten',
            onTap: () => context.push(mapEditorPath),
          ),
        const SettingsButton(),
      ],
    );
  }
}

class _MapBody extends ConsumerStatefulWidget {
  const _MapBody({required this.plan});
  final HavenFloorPlan plan;

  @override
  ConsumerState<_MapBody> createState() => _MapBodyState();
}

class _MapBodyState extends ConsumerState<_MapBody> {
  bool _showLights = true;
  bool _showValues = true;
  String? _info;
  Timer? _infoTimer;

  @override
  void dispose() {
    _infoTimer?.cancel();
    super.dispose();
  }

  void _say(String text) {
    setState(() => _info = text);
    _infoTimer?.cancel();
    _infoTimer = Timer(const Duration(milliseconds: 2600), () {
      if (mounted) setState(() => _info = null);
    });
  }

  void _tapNode(FloorNode n) {
    final plan = widget.plan;
    final p = plan.placementOf(n.id);
    if (p == null) return;
    final repo = ref.read(repositoryProvider);
    final e = ref.read(entityProvider(n.id));
    final name = e?.name ?? n.id;
    switch (p.resolvedKind) {
      case FloorKind.light:
        Haptics.tick();
        final on = e?.isOn ?? false;
        unawaited(repo.setLights([n.id], on: !on));
      case FloorKind.switchKind:
        Haptics.tick();
        unawaited(repo.callService('switch', 'toggle', entityId: n.id));
        _say('$name ${(e?.isOn ?? false) ? 'aus' : 'an'}');
      case FloorKind.temperature:
        Haptics.tick();
        final v = e?.number;
        _say(v == null ? name : '$name · ${num1(v)} °C');
      case FloorKind.presence:
        Haptics.tick();
        _say('$name · ${(e?.isOn ?? false) ? 'Bewegung' : 'ruhig'}');
      case FloorKind.contact:
        Haptics.tick();
        _say('$name · ${(e?.isOn ?? false) ? 'offen' : 'zu'}');
      case FloorKind.media || FloorKind.remote || FloorKind.device:
        Haptics.tick();
        _say(name);
    }
  }

  void _tapRoom(FloorRoom r) {
    final sr = snapshotRoomFor(ref.read(snapshotProvider), r);
    if (sr != null && sr.lightIds.isNotEmpty) {
      Haptics.tick();
      context.push(Routes.room(sr.id));
    } else {
      _say('${r.name} hat noch keine Lichter');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final plan = widget.plan;
    final lights = ref.watch(mapLightsProvider(plan));

    final nodes = [
      for (final p in plan.placements)
        if (plan.room(p.roomId) != null &&
            (p.resolvedKind == FloorKind.light
                ? _showLights
                : p.resolvedKind != FloorKind.temperature || _showValues))
          FloorNode(id: p.entityId, point: p.point),
    ];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(HavenSpace.page, 12, 12, 8),
          child: Row(
            children: [
              _ToggleChip(
                icon: Icons.lightbulb_outline_rounded,
                label: 'Lichter',
                on: _showLights,
                onTap: () => setState(() => _showLights = !_showLights),
              ),
              const SizedBox(width: 8),
              _ToggleChip(
                icon: Icons.thermostat_rounded,
                label: 'Werte',
                on: _showValues,
                onTap: () => setState(() => _showValues = !_showValues),
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: EntryAnimation(
              index: 1,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: FloorPlanView(
                        plan: plan,
                        nodes: nodes,
                        nodeBuilder: (context, n) => MapMarker(
                          entityId: n.id,
                          kind: plan.placementOf(n.id)!.resolvedKind,
                        ),
                        underlayPainter: _showLights
                            ? MapLightPainter(
                                plan: plan,
                                lights: lights,
                                hv: hv,
                              )
                            : null,
                        roomSubtitle: _showValues
                            ? (r) {
                                final v = lights.rooms[r.id];
                                if (v == null) return null;
                                return [
                                  if (v.temp != null) '${num1(v.temp!)}°',
                                  if (v.hum != null) '${v.hum!.round()} %',
                                ].join(' · ');
                              }
                            : null,
                        onNodeTap: _tapNode,
                        onRoomTap: _tapRoom,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      HavenSpace.page,
                      12,
                      HavenSpace.page,
                      0,
                    ),
                    child: _StatusCard(lights: lights, info: _info),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: HavenSpace.navClearance),
      ],
    );
  }
}

class _ToggleChip extends StatelessWidget {
  const _ToggleChip({
    required this.icon,
    required this.label,
    required this.on,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final fg = on ? hv.ai : hv.tx2;
    return Semantics(
      button: true,
      toggled: on,
      label: label,
      child: PressScale(
        onTap: () {
          Haptics.tick();
          onTap();
        },
        child: SizedBox(
          height: HavenSpace.touch,
          child: Center(
            child: AnimatedContainer(
              duration: context.motion(HavenMotion.d2),
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: on ? hv.acc : hv.s1,
                borderRadius: BorderRadius.circular(HavenRadii.pill),
                border: Border.all(
                  color: on ? const Color(0x00000000) : hv.ln2,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: fg),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: HavenText.label.copyWith(color: fg, fontSize: 13.5),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Unter der Karte: leuchtende Lampen als Punkte und „Alle aus“, oder eine
/// kurze Rückmeldung zum letzten Antippen.
class _StatusCard extends ConsumerWidget {
  const _StatusCard({required this.lights, required this.info});
  final MapLights lights;
  final String? info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final on = [
      for (final l in lights.lamps.values)
        if (l.on) l,
    ];
    return HavenCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      radius: HavenRadii.m,
      child: SizedBox(
        height: 44,
        child: AnimatedSwitcher(
          duration: context.motion(HavenMotion.d2),
          child: info != null
              ? Align(
                  key: ValueKey(info),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    info!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: HavenText.body.copyWith(color: hv.tx),
                  ),
                )
              : Row(
                  key: const ValueKey('lamps'),
                  children: [
                    Expanded(
                      child: on.isEmpty
                          ? Text(
                              'Alle Lichter sind aus',
                              style: HavenText.body.copyWith(color: hv.tx2),
                            )
                          : Align(
                              alignment: Alignment.centerLeft,
                              child: SizedBox(
                                height: 26,
                                width: 26.0 + 20 * (on.length.clamp(1, 8) - 1),
                                child: Stack(
                                  children: [
                                    for (var i = 0; i < on.length && i < 8; i++)
                                      Positioned(
                                        left: 20.0 * i,
                                        child: Container(
                                          width: 26,
                                          height: 26,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: colorOf(
                                              uiColor(
                                                on[i].color,
                                                dark: hv.isDark,
                                              ),
                                            ),
                                            border: Border.all(
                                              color: hv.s1,
                                              width: 2,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                    ),
                    if (on.isNotEmpty)
                      PressScale(
                        onTap: () {
                          Haptics.tick();
                          unawaited(
                            ref.read(repositoryProvider).allLightsOff(),
                          );
                        },
                        child: Container(
                          height: 36,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: hv.s2,
                            borderRadius: BorderRadius.circular(
                              HavenRadii.pill,
                            ),
                            border: Border.all(color: hv.ln2),
                          ),
                          child: Text(
                            'Alle aus',
                            style: HavenText.label.copyWith(
                              color: hv.tx,
                              fontSize: 13.5,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Leerzustand: kein Grundriss vorhanden.
class _EmptyMap extends StatelessWidget {
  const _EmptyMap();

  static const _sample = HavenFloorPlan(
    grid: FloorGrid(cols: 12, rows: 10),
    rooms: [
      FloorRoom(id: 'a', name: 'a', x: 0, y: 0, w: 7, h: 6),
      FloorRoom(id: 'b', name: 'b', x: 7, y: 0, w: 5, h: 4),
      FloorRoom(id: 'c', name: 'c', x: 7, y: 4, w: 5, h: 6),
      FloorRoom(id: 'd', name: 'd', x: 0, y: 6, w: 7, h: 4),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        HavenSpace.page,
        24,
        HavenSpace.page,
        HavenSpace.navClearance,
      ),
      children: [
        EntryAnimation(
          index: 0,
          child: HavenCard(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 190,
                  child: FloorPlanView(
                    plan: _sample,
                    interactive: false,
                    showLabels: false,
                    fill: true,
                    gap: 0.6,
                    padding: 4,
                    roomStyle: (r) => FloorRoomStyle(
                      fill: hv.acc.withValues(alpha: r.id == 'a' ? 0.28 : 0.12),
                      border: hv.acc.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Noch kein Grundriss',
                  textAlign: TextAlign.center,
                  style: HavenText.section.copyWith(color: hv.tx),
                ),
                const SizedBox(height: 8),
                Text(
                  'Zeichne deine Räume grob als Rechtecke. Lampen und Sensoren '
                  'stehen dann an ihrem Platz, Lampen leuchten in ihrer Farbe.',
                  textAlign: TextAlign.center,
                  style: HavenText.body.copyWith(color: hv.tx2),
                ),
                const SizedBox(height: 24),
                HavenButton(
                  label: 'Grundriss zeichnen',
                  icon: Icons.edit_outlined,
                  primary: true,
                  onTap: () => context.push(mapEditorPath),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
