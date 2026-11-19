import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/adaptive/context_menu.dart';
import '../../../core/adaptive/hover.dart';
import '../../../core/state/providers.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/animated_palette.dart';
import '../../../core/widgets/haptics.dart';
import '../../../core/widgets/press_scale.dart';
import '../../../data/room_view.dart';
import '../../../core/router/router.dart';
import '../../room/room_hero.dart';
import '../../../core/light/room_palette.dart';
import '../room_render.dart';
import '../weather_text.dart';

/// Raumkachel: Lichtfarbe als Glow, Temperatur und Feuchte. Tippen schaltet,
/// Halten oder der Pfeil öffnet den Raum (Sheet von unten), waagrecht ziehen
/// dimmt. Mit Bildern aus Home Assistant zeigt sie den Raum mit seinem
/// Licht (live zusammengesetzt), mit Heizungsregelung oder genau einem
/// Thermostat ein Thermometer am Rand.
class RoomTile extends ConsumerStatefulWidget {
  const RoomTile({super.key, required this.roomId, this.wide = false});

  final String roomId;
  final bool wide;

  @override
  ConsumerState<RoomTile> createState() => _RoomTileState();
}

class _RoomTileState extends ConsumerState<RoomTile> {
  /// Helligkeit beim Ziehen (Vorschau, Prozent), `null` sonst.
  int? _dim;
  int _dimStart = 100;
  double _dragDx = 0;

  String get roomId => widget.roomId;

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
    final edge = climate == null ? 0.0 : ThermoEdge.width;

    void open() {
      HapticFeedback.mediumImpact();
      context.push(Routes.room(roomId));
    }

    final dim = _dim;
    final status = view.lamps.isEmpty
        ? 'Keine Lampen'
        : dim != null
        ? 'Helligkeit $dim %'
        : !view.anyOn
        ? 'Aus'
        : view.lampsOn.length == 1
        ? '${_shortName(view.lampsOn.first.name, view.name)} · ${view.brightness} %'
        : '${view.lampsOn.length} Lichter · ${view.brightness} %';

    // Waagrecht ziehen dimmt alle Lampen des Raums (Vorschau im Bild, beim
    // Loslassen an HA).
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

    final height = renders
        ? (widget.wide ? 176.0 : 168.0)
        : (widget.wide ? 150.0 : 132.0);

    return Semantics(
      button: true,
      label: view.lamps.isEmpty
          ? '${view.name}, $status. Lang drücken öffnet.'
          : '${view.name}, $status. Tippen schaltet, lang drücken öffnet.',
      onLongPress: open,
      // Desktop: Rechtsklick öffnet ein Menü (Raum öffnen, Licht).
      child: GestureDetector(
        onSecondaryTapUp: (d) =>
            showHavenContextMenu(context, d.globalPosition, [
              HavenMenuItem(
                label: 'Raum öffnen',
                icon: Icons.open_in_new_rounded,
                onSelected: open,
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
        child: PressScale(
          hoverScale: 1.015,
          onTap: () {
            if (view.lamps.isEmpty) return;
            HapticFeedback.selectionClick();
            repo.toggleRoom(roomId);
          },
          onLongPress: open,
          child: SizedBox(
            height: height,
            child: Stack(
              children: [
                Positioned.fill(child: TileSurface(palette: palette)),
                // Der Raum mit seinem Licht, ganz sichtbar links vom
                // Thermometer, oben in der Kachel (unten stehen Name und
                // Status).
                if (images != null)
                  Positioned(
                    left: 8,
                    top: 6,
                    right: edge + 4,
                    bottom: 40,
                    child: IgnorePointer(
                      child: RoomRenderView(images: images, dimPercent: dim),
                    ),
                  ),
                Padding(
                  padding: EdgeInsets.fromLTRB(14, 14, 14 + edge, 14),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _IconDot(palette: palette, small: images != null),
                          // Mit Thermometer steht die Temperatur dort.
                          if (climate == null)
                            Flexible(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerRight,
                                child: _Climate(view: view),
                              ),
                            ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.only(right: 34),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              view.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HavenText.headline.copyWith(
                                color: hv.tx,
                                fontSize: 17,
                              ),
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
                    ],
                  ),
                ),
                if (climate != null)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    width: ThermoEdge.width,
                    child: ThermoEdge(climate: climate, name: view.name),
                  ),
                Positioned(
                  right: edge,
                  bottom: 0,
                  child: Semantics(
                    container: true,
                    button: true,
                    label: '${view.name} öffnen',
                    child: DesktopTooltip(
                      message: '${view.name} öffnen',
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: open,
                          child: SizedBox(
                            width: HavenSpace.touch,
                            height: HavenSpace.touch,
                            child: Center(
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: hv.s2,
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.chevron_right_rounded,
                                  size: 20,
                                  color: hv.tx2,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
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

/// Lampenname ohne den Raumnamen („Decke“ statt „Salon Decke“).
String _shortName(String lamp, String room) {
  final rest = lamp.replaceAll(room, '').replaceAll(RegExp(r'\s+'), ' ').trim();
  return rest.isEmpty ? lamp : rest;
}

class _IconDot extends StatelessWidget {
  const _IconDot({required this.palette, this.small = false});
  final RoomPalette palette;

  /// Kleiner über dem Raumbild.
  final bool small;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final d = small ? 30.0 : 38.0;
    return AnimatedPalette(
      palette: palette,
      builder: (context, p) => Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Color.lerp(hv.s2, p.primary, p.intensity > 0 ? 1 : 0),
        ),
        child: Icon(
          Icons.lightbulb_rounded,
          size: small ? 16 : 20,
          color: p.isOn ? p.onAccent : hv.tx3,
        ),
      ),
    );
  }
}

class _Climate extends StatelessWidget {
  const _Climate({required this.view});
  final RoomView view;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    if (view.temperature == null) {
      return Text(
        'kein Sensor',
        style: HavenText.caption.copyWith(color: hv.tx3),
      );
    }
    final style = HavenText.label.copyWith(color: hv.tx2, fontSize: 14);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.thermostat_rounded, size: 15, color: hv.tx2),
        Text('${num1(view.temperature!)}°', style: style),
        if (view.humidity != null) ...[
          const SizedBox(width: 6),
          Icon(Icons.water_drop_outlined, size: 14, color: hv.tx2),
          Text('${view.humidity!.round()} %', style: style),
        ],
      ],
    );
  }
}
