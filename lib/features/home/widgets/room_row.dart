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
import '../../../core/widgets/press_scale.dart';
import '../../../data/models/haven_automation.dart';
import '../../../data/models/lamp_calibration.dart';
import '../../../data/models/room.dart';
import '../../../data/models/widget_config.dart';
import '../../zigbee/widgets/zb_common.dart' show showZbSheet;
import '../../../data/room_view.dart';
import '../../../data/scene_look.dart' show sceneOffColor;
import '../../automations/haven_automations_provider.dart';
import '../../climate/heating_providers.dart';
import '../room_render.dart';
import '../weather_text.dart';

// Räume auf Zuhause, ohne Karte direkt auf dem Hintergrund: der Raum mit
// seinem Licht (Lichtschein der Lampen dahinter), rechts daneben Tabs für
// Licht (Knopf und Szenen), Heizung und Bewegungslicht. Unter dem Raum
// steht nichts. Eine Szene gedrückt halten zeigt sie im Bild.

/// Räume ausführlich (einer je Zeile, mit Tabs) oder kompakt (zwei je
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
    final cal = l.calibration;
    final rgb = s.kelvin != null
        ? kelvinToRgb(cal.mapKelvin(s.kelvin!))
        : s.colors[i % s.colors.length];
    i++;
    out[l.entityId] = h3.LampState(
      brightness: cal.mapLevel(s.brightness / 100).clamp(0.05, maxShownLevel),
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

/// Ein Raum auf Zuhause. [detailed]: Bild und Tabs nebeneinander; sonst
/// schmal (Bild, darunter Name und Lichtknopf) für zwei je Zeile.
class RoomRow extends ConsumerStatefulWidget {
  const RoomRow({
    super.key,
    required this.roomId,
    this.detailed = true,
    this.large = false,
    this.config,
  });

  final String roomId;
  final bool detailed;

  /// Einstellungen des Raum-Widgets (was es zeigt), `null`: alles.
  final HavenWidgetConfig? config;

  /// Mehr Platz (Desktop): größeres Bild, breitere Tabs.
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

  bool _shows(String key) => widget.config?.shows(key) ?? true;

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
    final heatShown = _shows(RoomWidgetOptions.heat) ? climate : null;
    final motion = widget.detailed && _shows(RoomWidgetOptions.motion)
        ? ref.watch(roomMotionProvider(roomId))
        : null;

    final dim = _dim;
    final preview = _preview;
    final current = climate?.current ?? view.temperature;
    // Ausführlich steht die Temperatur am Heizungsknopf, sonst im Status.
    final temp = current == null || (widget.detailed && heatShown != null)
        ? null
        : view.humidity == null || climate != null
        ? '${num1(current)}°'
        : '${num1(current)}° · ${view.humidity!.round()} %';
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
                  alignY: 0,
                  // Kein Lichtschein hinter dem Bild (vorerst aus).
                )
              : _NoPicture(palette: palette),
        ),
      ),
    );

    final title = _Title(
      name: view.name,
      status: temp == null ? status : '$status · $temp',
      onOpen: _open,
      large: widget.large,
    );

    if (!widget.detailed) {
      // Kompakt: Bild, darunter Name und Lichtknopf.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_shows(RoomWidgetOptions.picture)) ...[
            SizedBox(height: 120, child: picture),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(child: title),
              if (view.lamps.isNotEmpty && _shows(RoomWidgetOptions.light)) ...[
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

    final showPicture = _shows(RoomWidgetOptions.picture);
    final light = view.lamps.isNotEmpty && _shows(RoomWidgetOptions.light);
    final scenes = _shows(RoomWidgetOptions.scenes)
        ? view.room.scenes
        : const <RoomScene>[];
    final chips = <Widget>[
      if (heatShown != null)
        _MiniChip(
          icon: heatShown.heating
              ? Icons.local_fire_department_rounded
              : Icons.thermostat_rounded,
          label: heatShown.current == null
              ? (heatShown.off ? 'aus' : '${num1(heatShown.target)}°')
              : '${num1(heatShown.current!)}°',
          color: heatShown.heating ? const Color(0xFFFF8A3D) : null,
          semantics: 'Heizung ${view.name}',
          onTap: () => showRoomHeatSheet(context, roomId, view.name),
        ),
      if (motion != null)
        _MiniChip(
          icon: Icons.directions_walk_rounded,
          label: motion.enabled ? 'an' : 'aus',
          color: motion.enabled ? hv.acc : null,
          semantics: 'Bewegungslicht',
          toggled: motion.enabled,
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
    final hasPanel = light || scenes.isNotEmpty;
    final h = showPicture ? (widget.large ? 172.0 : 144.0) : 96.0;
    final panelW = widget.large ? 250.0 : 152.0;
    final panel = !hasPanel
        ? null
        : _ControlPanel(
            view: view,
            palette: palette,
            preview: preview,
            large: widget.large,
            light: light,
            scenes: scenes,
            onToggle: toggle,
            onScene: (s) {
              HapticFeedback.selectionClick();
              repo.applyScene(roomId, s.id);
            },
            onHold: (s) {
              if (s != null) Haptics.tick();
              setState(() => _preview = s);
            },
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Kleine Knöpfe (Heizung, Bewegungslicht) rechts neben dem Namen:
        // gehören zum Raum, nicht zum Licht.
        if (chips.isEmpty)
          title
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: title),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Wrap(spacing: 6, runSpacing: 6, children: chips),
              ),
            ],
          ),
        const SizedBox(height: 4),
        if (showPicture || panel != null)
          SizedBox(
            height: h,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showPicture) Expanded(child: picture),
                if (panel != null) ...[
                  if (showPicture) const SizedBox(width: 12),
                  if (showPicture)
                    SizedBox(width: panelW, child: panel)
                  else
                    Expanded(child: panel),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// Lampenname ohne den Raumnamen („Decke“ statt „Salon Decke“).
String _shortName(String lamp, String room) {
  final rest = lamp.replaceAll(room, '').replaceAll(RegExp(r'\s+'), ' ').trim();
  return rest.isEmpty ? lamp : rest;
}

/// Name und Status; öffnet den Raum.
class _Title extends StatelessWidget {
  const _Title({
    required this.name,
    required this.status,
    required this.onOpen,
    this.large = false,
  });

  final String name;
  final String status;
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
                    Icon(Icons.chevron_right_rounded, size: 20, color: hv.tx3),
                  ],
                ),
                Text(
                  status,
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
        ),
      ),
    );
  }
}

/// Heizung des Raums als Blatt: Raumtemperatur und Ziel mit Plus/Minus,
/// live aus HA.
Future<void> showRoomHeatSheet(
  BuildContext context,
  String roomId,
  String name,
) => showZbSheet<void>(
  context,
  builder: (context) => Consumer(
    builder: (context, ref, _) {
      final hv = context.hv;
      final view = ref.watch(roomViewProvider(roomId));
      final c = tileClimateOf(ref, roomId, view?.temperature);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Heizung $name',
            style: HavenText.section.copyWith(color: hv.tx, fontSize: 22),
          ),
          if (c != null) ...[
            const SizedBox(height: 4),
            Text(c.label, style: HavenText.caption.copyWith(color: hv.tx2)),
            const SizedBox(height: 18),
            Center(
              child: SizedBox(
                width: 220,
                height: 150,
                child: TempStepper(climate: c, name: name),
              ),
            ),
          ],
        ],
      );
    },
  ),
);

/// Rechts vom Raumbild: runder Lichtknopf, daneben die Szenen als
/// Farbpunkte (Tippen ruft sie auf, Halten zeigt sie im Bild).
class _ControlPanel extends StatelessWidget {
  const _ControlPanel({
    required this.view,
    required this.palette,
    required this.preview,
    required this.large,
    required this.light,
    required this.scenes,
    required this.onToggle,
    required this.onScene,
    required this.onHold,
  });

  final RoomView view;
  final RoomPalette palette;
  final RoomScene? preview;
  final bool large;
  final bool light;
  final List<RoomScene> scenes;
  final VoidCallback onToggle;
  final ValueChanged<RoomScene> onScene;
  final ValueChanged<RoomScene?> onHold;

  @override
  Widget build(BuildContext context) {
    final button = LightButton(
      palette: palette,
      on: view.anyOn,
      name: view.name,
      size: large ? 84 : 64,
      brightness: view.anyOn ? view.brightness : null,
      onTap: onToggle,
    );
    final dots = scenes.isEmpty
        ? null
        : LayoutBuilder(
            builder: (context, c) {
              const dot = 30.0, gap = 8.0;
              final cols = ((c.maxWidth + gap) / (dot + gap)).floor().clamp(
                1,
                8,
              );
              return Align(
                alignment: Alignment.centerLeft,
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final s in scenes)
                        SizedBox(
                          width: dot,
                          height: dot,
                          child: _SceneDot(
                            scene: s,
                            active: view.activeSceneId == s.id,
                            previewing: identical(preview, s),
                            onTap: () => onScene(s),
                            onHold: (on) => onHold(on ? s : null),
                          ),
                        ),
                    ],
                  ).withMaxWidth(cols * (dot + gap) - gap),
                ),
              );
            },
          );
    // Lichtknopf und daneben die Szenen, mittig zum Bild.
    final Widget body = !light
        ? (dots ?? const SizedBox.shrink())
        : dots == null
        ? Center(child: button)
        : Row(
            children: [
              button,
              const SizedBox(width: 10),
              Expanded(child: dots),
            ],
          );
    return Align(alignment: Alignment.centerLeft, child: body);
  }
}

/// Kleiner Knopf über den Szenen (Heizung, Bewegungslicht).
class _MiniChip extends StatelessWidget {
  const _MiniChip({
    required this.icon,
    required this.label,
    required this.semantics,
    required this.onTap,
    this.color,
    this.toggled,
  });

  final IconData icon;
  final String label;
  final String semantics;
  final VoidCallback onTap;
  final Color? color;
  final bool? toggled;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final c = color;
    return Semantics(
      button: true,
      toggled: toggled,
      label: semantics,
      value: label,
      excludeSemantics: true,
      onTap: onTap,
      child: PressScale(
        onTap: onTap,
        pressedScale: 0.92,
        child: AnimatedContainer(
          duration: context.motion(HavenMotion.d2),
          height: 30,
          padding: const EdgeInsets.fromLTRB(8, 0, 10, 0),
          decoration: BoxDecoration(
            color: c != null
                ? c.withValues(alpha: hv.isDark ? 0.2 : 0.16)
                : hv.s1.withValues(alpha: hv.isDark ? 0.7 : 0.85),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: c?.withValues(alpha: 0.6) ?? hv.ln),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: c ?? hv.tx2),
              const SizedBox(width: 4),
              Text(
                label,
                style: HavenText.label.copyWith(
                  color: hv.tx,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

extension on Widget {
  Widget withMaxWidth(double w) => ConstrainedBox(
    constraints: BoxConstraints(maxWidth: w),
    child: this,
  );
}

/// Szene als Farbpunkt. Aktiv: Ring; gehalten: größer.
class _SceneDot extends StatelessWidget {
  const _SceneDot({
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
    return Semantics(
      button: true,
      selected: active,
      label: 'Szene ${scene.name}',
      onLongPressHint: 'Vorschau',
      excludeSemantics: true,
      onTap: onTap,
      child: DesktopTooltip(
        message: scene.name,
        child: GestureDetector(
          onLongPressStart: (_) => onHold(true),
          onLongPressEnd: (_) => onHold(false),
          onLongPressCancel: () => onHold(false),
          child: PressScale(
            onTap: onTap,
            pressedScale: 0.88,
            child: AnimatedScale(
              scale: previewing ? 1.18 : 1,
              duration: context.motion(HavenMotion.d2),
              child: AnimatedContainer(
                duration: context.motion(HavenMotion.d2),
                padding: EdgeInsets.all(active ? 3 : 0),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: active
                      ? Border.all(color: hv.tx, width: 2)
                      : Border.all(color: hv.ln),
                ),
                child: DecoratedBox(
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
              ),
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

/// Leise Fläche hinter einem Raum der Startseite: fast durchsichtig mit
/// Haarlinie, bei Licht oben links ein Schein in der Lichtfarbe. Gibt der
/// Seite Halt, ohne schwere Karte.
class RoomPlate extends ConsumerWidget {
  const RoomPlate({super.key, required this.roomId, required this.child});
  final String roomId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final view = ref.watch(roomViewProvider(roomId));
    final palette = view?.palette(dark: hv.isDark);
    final radius = BorderRadius.circular(HavenRadii.l + 2);
    Widget plate(Color glow, double k) => DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        color: hv.s1.withValues(alpha: hv.isDark ? 0.42 : 0.6),
        border: Border.all(color: hv.ln),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: RadialGradient(
            center: const Alignment(-0.85, -1),
            radius: 1.25,
            colors: [
              glow.withValues(alpha: (hv.isDark ? 0.2 : 0.16) * k),
              glow.withValues(alpha: 0),
            ],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: child,
        ),
      ),
    );
    if (palette == null) return plate(hv.acc, 0);
    return AnimatedPalette(
      palette: palette,
      builder: (context, p) => plate(p.primary, p.intensity),
    );
  }
}
