import 'dart:async';

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:haven_3d/haven_3d.dart' as h3;
import 'package:material_ui/material_ui.dart';

import '../../../core/adaptive/context_menu.dart';
import '../../../core/adaptive/hover.dart';
import '../../../core/light/color_math.dart';
import '../../../core/light/room_palette.dart';
import '../../../core/router/router.dart';
import '../../../core/state/providers.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/animated_palette.dart';
import '../../../core/widgets/haptics.dart';
import '../../../core/widgets/horizontal_scroller.dart';
import '../../../core/widgets/press_scale.dart';
import '../../../data/models/haven_automation.dart';
import '../../../data/models/room.dart';
import '../../../data/room_view.dart';
import '../../../data/scene_look.dart' show sceneOffColor;
import '../../automations/haven_automations_provider.dart';
import '../../climate/heating_providers.dart';
import '../room_render.dart';
import '../weather_text.dart';

// Räume auf Zuhause, ohne Karte direkt auf dem Hintergrund: der Raum mit
// seinem Licht (Lichtschein der Lampen dahinter), daneben ein runder
// Lichtknopf und das Thermometer. Ausführlich darunter Szenen und das
// Bewegungslicht; eine Szene gedrückt halten zeigt sie im Bild.

/// Räume ausführlich (einer je Zeile, mit Szenen) oder kompakt (zwei je
/// Zeile). Gilt auf dem Handy; am Desktop immer ausführlich.
final homeRoomsDetailedProvider =
    NotifierProvider<HomeRoomsDetailedNotifier, bool>(
      HomeRoomsDetailedNotifier.new,
    );

class HomeRoomsDetailedNotifier extends Notifier<bool> {
  @override
  bool build() => ref.read(settingsStoreProvider).homeRoomsDetailed;

  void set(bool v) {
    state = v;
    unawaited(ref.read(settingsStoreProvider).setHomeRoomsDetailed(v));
  }
}

/// Lampenzustände, wie Szene [s] den Raum [view] ungefähr zeigt (Farben
/// der Szene reihum, wie in den Entwicklungsdaten).
Map<String, h3.LampState> scenePreview(RoomView view, RoomScene s) {
  final out = <String, h3.LampState>{};
  var i = 0;
  for (final l in view.lamps) {
    final only = s.onlyLightIds;
    if (s.brightness <= 0 || (only != null && !only.contains(l.entityId))) {
      out[l.entityId] = h3.LampState.off;
      continue;
    }
    final rgb = s.kelvin != null
        ? kelvinToRgb(s.kelvin!)
        : s.colors[i % s.colors.length];
    i++;
    out[l.entityId] = h3.LampState(
      brightness: (s.brightness / 100).clamp(0.05, 1.0),
      color: colorOf(rgb),
    );
  }
  return out;
}

/// Bewegungslicht des Raums (erste Haven-Automation `room_motion` seines
/// Bereichs), `null` wenn keins.
final roomMotionProvider = Provider.family<HavenAutomation?, String>((
  ref,
  roomId,
) {
  final area = ref.watch(roomAreaProvider(roomId));
  final all = ref.watch(havenAutomationsProvider).value;
  return all?.automations
      .where((a) => a.isMotion && a.roomAreaId == area && a.id != null)
      .firstOrNull;
});

/// Ein Raum auf Zuhause. [detailed]: Bild, Lichtknopf und Thermometer
/// nebeneinander, darunter Szenen; sonst schmal für zwei je Zeile.
class RoomRow extends ConsumerStatefulWidget {
  const RoomRow({
    super.key,
    required this.roomId,
    this.detailed = true,
    this.large = false,
  });

  final String roomId;
  final bool detailed;

  /// Mehr Platz (Desktop): größeres Bild und größerer Knopf.
  final bool large;

  @override
  ConsumerState<RoomRow> createState() => _RoomRowState();
}

class _RoomRowState extends ConsumerState<RoomRow> {
  /// Helligkeit beim Ziehen (Vorschau, Prozent), `null` sonst.
  int? _dim;
  int _dimStart = 100;
  double _dragDx = 0;

  /// Gehaltene Szene (Vorschau im Bild).
  RoomScene? _preview;

  String get roomId => widget.roomId;

  void _open() {
    HapticFeedback.mediumImpact();
    context.push(Routes.room(roomId));
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(roomViewProvider(roomId));
    if (view == null) return const SizedBox.shrink();
    final hv = context.hv;
    final palette = view.palette(dark: hv.isDark);
    final repo = ref.read(repositoryProvider);
    final renders = ref.watch(roomRendersAvailableProvider);
    final images = renders
        ? ref.watch(roomLayersProvider((roomId: roomId, dark: hv.isDark))).value
        : null;
    final climate = tileClimateOf(ref, roomId, view.temperature);
    final motion = widget.detailed
        ? ref.watch(roomMotionProvider(roomId))
        : null;

    final dim = _dim;
    final preview = _preview;
    final temp = climate == null && view.temperature != null
        ? '${num1(view.temperature!)}°'
        : null;
    final status = preview != null
        ? 'Vorschau: ${preview.name}'
        : view.lamps.isEmpty
        ? 'Keine Lampen'
        : dim != null
        ? 'Helligkeit $dim %'
        : !view.anyOn
        ? 'Aus'
        : view.lampsOn.length == 1
        ? '${_shortName(view.lampsOn.first.name, view.name)} · ${view.brightness} %'
        : '${view.lampsOn.length} Lichter · ${view.brightness} %';

    // Waagrecht übers Bild ziehen dimmt alle Lampen des Raums (Vorschau im
    // Bild, beim Loslassen an HA).
    void dragStart(DragStartDetails _) {
      if (view.lamps.isEmpty) return;
      _dimStart = view.anyOn ? view.brightness : 0;
      _dragDx = 0;
      setState(() => _dim = _dimStart);
    }

    void dragUpdate(DragUpdateDetails d) {
      if (_dim == null) return;
      _dragDx += d.delta.dx;
      final w = context.size?.width ?? 200;
      final v = (_dimStart + _dragDx / w * 100).round().clamp(1, 100);
      if (v != _dim) setState(() => _dim = v);
    }

    void dragEnd([DragEndDetails? _]) {
      final v = _dim;
      if (v == null) return;
      Haptics.tick();
      repo.setRoomBrightness(roomId, v);
      setState(() => _dim = null);
    }

    void toggle() {
      if (view.lamps.isEmpty) return;
      HapticFeedback.selectionClick();
      repo.toggleRoom(roomId);
    }

    final picture = Semantics(
      button: true,
      label: '${view.name}, $status. Öffnet den Raum.',
      excludeSemantics: true,
      onTap: _open,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _open,
        onLongPress: _open,
        onSecondaryTapUp: (d) =>
            showHavenContextMenu(context, d.globalPosition, [
              HavenMenuItem(
                label: 'Raum öffnen',
                icon: Icons.open_in_new_rounded,
                onSelected: _open,
              ),
              if (view.lamps.isNotEmpty)
                HavenMenuItem(
                  label: view.anyOn ? 'Licht aus' : 'Licht an',
                  icon: view.anyOn
                      ? Icons.lightbulb_outline_rounded
                      : Icons.lightbulb_rounded,
                  onSelected: () => repo.toggleRoom(roomId),
                ),
            ]),
        // Ab dem Aufsetzen zählen: die Helligkeit folgt dem Finger genau.
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart: dragStart,
        onHorizontalDragUpdate: dragUpdate,
        onHorizontalDragEnd: dragEnd,
        onHorizontalDragCancel: dragEnd,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: images != null
              ? RoomRenderView(
                  images: images,
                  dimPercent: dim,
                  preview: preview == null ? null : scenePreview(view, preview),
                  alignY: widget.detailed ? 0 : -0.2,
                  glow: hv.isDark ? 1 : 0.75,
                )
              : _NoPicture(palette: palette),
        ),
      ),
    );

    final title = _Title(
      name: view.name,
      status: status,
      extra: temp == null
          ? null
          : view.humidity == null
          ? temp
          : '$temp · ${view.humidity!.round()} %',
      onOpen: _open,
      large: widget.large,
    );

    if (!widget.detailed) {
      // Kompakt: Bild mit Thermometer am Rand, darunter Name und Knopf.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 124,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  right: climate == null ? 0 : ThermoEdge.width - 6,
                  child: picture,
                ),
                if (climate != null)
                  Positioned(
                    right: -6,
                    top: 0,
                    bottom: 0,
                    width: ThermoEdge.width,
                    child: ThermoEdge(climate: climate, name: view.name),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: title),
              if (view.lamps.isNotEmpty) ...[
                const SizedBox(width: 6),
                LightButton(
                  palette: palette,
                  on: view.anyOn,
                  name: view.name,
                  size: 46,
                  onTap: toggle,
                ),
              ],
            ],
          ),
        ],
      );
    }

    final h = widget.large ? 210.0 : 156.0;
    final chips = <Widget>[
      for (final s in view.room.scenes)
        _SceneChip(
          scene: s,
          active: view.activeSceneId == s.id,
          previewing: identical(preview, s),
          onTap: () {
            HapticFeedback.selectionClick();
            repo.applyScene(roomId, s.id);
          },
          onHold: (on) {
            if (on) Haptics.tick();
            setState(() => _preview = on ? s : null);
          },
        ),
      if (motion != null)
        _MotionChip(
          on: motion.enabled,
          onTap: () async {
            Haptics.tap();
            try {
              await ref
                  .read(havenAutomationsProvider.notifier)
                  .setEnabled(motion.id!, !motion.enabled);
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.maybeOf(
                  context,
                )?.showSnackBar(SnackBar(content: Text('$e')));
              }
            }
          },
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(padding: const EdgeInsets.only(right: 4), child: title),
        const SizedBox(height: 6),
        SizedBox(
          height: h,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: picture),
              if (view.lamps.isNotEmpty) ...[
                const SizedBox(width: 10),
                Center(
                  child: LightButton(
                    palette: palette,
                    on: view.anyOn,
                    name: view.name,
                    size: widget.large ? 84 : 68,
                    brightness: view.anyOn ? view.brightness : null,
                    onTap: toggle,
                  ),
                ),
              ],
              // Platz links vom Regler für den Zielwert. Auch ohne Regler
              // frei: so stehen die Lichtknöpfe aller Räume untereinander.
              SizedBox(
                width: ThermoEdge.width + 58,
                child: climate == null
                    ? null
                    : ThermoEdge(climate: climate, name: view.name),
              ),
            ],
          ),
        ),
        if (chips.isNotEmpty) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 38,
            child: HorizontalScroller(
              builder: (context, controller) => ListView.separated(
                controller: controller,
                scrollDirection: Axis.horizontal,
                itemCount: chips.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) => chips[i],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Lampenname ohne den Raumnamen („Decke“ statt „Salon Decke“).
String _shortName(String lamp, String room) {
  final rest = lamp.replaceAll(room, '').replaceAll(RegExp(r'\s+'), ' ').trim();
  return rest.isEmpty ? lamp : rest;
}

/// Name, Status und (ohne Thermometer) Temperatur; öffnet den Raum.
class _Title extends StatelessWidget {
  const _Title({
    required this.name,
    required this.status,
    required this.onOpen,
    this.extra,
    this.large = false,
  });

  final String name;
  final String status;
  final String? extra;
  final VoidCallback onOpen;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      container: true,
      button: true,
      label: '$name öffnen',
      excludeSemantics: true,
      onTap: onOpen,
      child: DesktopTooltip(
        message: '$name öffnen',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onOpen,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HavenText.headline.copyWith(
                                color: hv.tx,
                                fontSize: large ? 20 : 17,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                            color: hv.tx3,
                          ),
                        ],
                      ),
                      Text(
                        extra == null ? status : '$status · $extra',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HavenText.caption.copyWith(
                          color: hv.tx2,
                          fontSize: 12.5,
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
  }
}

/// Runder Lichtknopf: an in der Lichtfarbe mit Schein, aus dunkel.
class LightButton extends StatelessWidget {
  const LightButton({
    super.key,
    required this.palette,
    required this.on,
    required this.name,
    required this.onTap,
    this.size = 64,
    this.brightness,
  });

  final RoomPalette palette;
  final bool on;
  final String name;
  final VoidCallback onTap;
  final double size;

  /// Helligkeit im Knopf (Prozent), `null`: keine.
  final int? brightness;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      button: true,
      toggled: on,
      label: 'Licht $name',
      excludeSemantics: true,
      onTap: onTap,
      child: PressScale(
        onTap: onTap,
        pressedScale: 0.9,
        hoverScale: 1.04,
        child: AnimatedPalette(
          palette: palette,
          builder: (context, p) {
            final lit = p.intensity > 0;
            return Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: lit
                    ? p.primary
                    : hv.s1.withValues(alpha: hv.isDark ? 0.8 : 0.9),
                border: lit ? null : Border.all(color: hv.ln),
                boxShadow: lit
                    ? [
                        BoxShadow(
                          color: p.primary.withValues(alpha: 0.55),
                          blurRadius: size * 0.5,
                          spreadRadius: size * 0.02,
                        ),
                      ]
                    : hv.shadowSmall,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    lit
                        ? Icons.lightbulb_rounded
                        : Icons.lightbulb_outline_rounded,
                    size: size * 0.4,
                    color: lit ? p.onAccent : hv.tx2,
                  ),
                  if (brightness != null && size >= 60)
                    Text(
                      '$brightness %',
                      style: HavenText.caption.copyWith(
                        fontSize: size * 0.16,
                        fontWeight: FontWeight.w700,
                        color: p.onAccent,
                        height: 1.1,
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Ohne Raumbild: weicher Schein in der Lichtfarbe und ein Raum-Symbol.
class _NoPicture extends StatelessWidget {
  const _NoPicture({required this.palette});
  final RoomPalette palette;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return AnimatedPalette(
      palette: palette,
      builder: (context, p) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            radius: 0.75,
            colors: [
              p.primary.withValues(alpha: 0.5 * p.intensity),
              p.primary.withValues(alpha: 0),
            ],
          ),
        ),
        child: Center(
          child: Icon(
            Icons.meeting_room_outlined,
            size: 34,
            color: hv.tx3.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}

/// Szene als Chip: Tippen ruft sie auf, Halten zeigt sie im Bild.
class _SceneChip extends StatelessWidget {
  const _SceneChip({
    required this.scene,
    required this.active,
    required this.previewing,
    required this.onTap,
    required this.onHold,
  });

  final RoomScene scene;
  final bool active;
  final bool previewing;
  final VoidCallback onTap;
  final ValueChanged<bool> onHold;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final colors = scene.brightness <= 0
        ? [colorOf(sceneOffColor), colorOf(sceneOffColor)]
        : scene.kelvin != null
        ? [
            colorOf(kelvinToRgb(scene.kelvin!)),
            colorOf(kelvinToRgb(scene.kelvin!)),
          ]
        : [for (final c in scene.colors) colorOf(c)];
    final lead = colors.first;
    final strong = active || previewing;
    return Semantics(
      button: true,
      selected: active,
      label: 'Szene ${scene.name}',
      onLongPressHint: 'Vorschau',
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        onLongPressStart: (_) => onHold(true),
        onLongPressEnd: (_) => onHold(false),
        onLongPressCancel: () => onHold(false),
        child: PressScale(
          onTap: onTap,
          pressedScale: 0.94,
          child: AnimatedContainer(
            duration: context.motion(HavenMotion.d2),
            padding: const EdgeInsets.fromLTRB(6, 0, 14, 0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(19),
              color: strong
                  ? lead.withValues(alpha: hv.isDark ? 0.26 : 0.22)
                  : hv.s1.withValues(alpha: hv.isDark ? 0.55 : 0.75),
              border: Border.all(
                color: strong ? lead.withValues(alpha: 0.85) : hv.ln,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: colors.length == 1
                          ? [colors.first, colors.first]
                          : colors,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  scene.name,
                  style: HavenText.label.copyWith(
                    color: hv.tx,
                    fontSize: 13,
                    fontWeight: strong ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bewegungslicht des Raums an/aus.
class _MotionChip extends StatelessWidget {
  const _MotionChip({required this.on, required this.onTap});
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      button: true,
      toggled: on,
      label: 'Bewegungslicht',
      excludeSemantics: true,
      onTap: onTap,
      child: PressScale(
        onTap: onTap,
        pressedScale: 0.94,
        child: AnimatedContainer(
          duration: context.motion(HavenMotion.d2),
          padding: const EdgeInsets.fromLTRB(10, 0, 14, 0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(19),
            color: on
                ? hv.acc.withValues(alpha: hv.isDark ? 0.22 : 0.16)
                : hv.s1.withValues(alpha: hv.isDark ? 0.55 : 0.75),
            border: Border.all(
              color: on ? hv.acc.withValues(alpha: 0.8) : hv.ln,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                on
                    ? Icons.directions_walk_rounded
                    : Icons.do_not_disturb_on_outlined,
                size: 18,
                color: on ? hv.acc : hv.tx3,
              ),
              const SizedBox(width: 6),
              Text(
                on ? 'Bewegung an' : 'Bewegung aus',
                style: HavenText.label.copyWith(
                  color: on ? hv.tx : hv.tx2,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
