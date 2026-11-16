import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/adaptive/context_menu.dart';
import '../../../core/adaptive/hover.dart';
import '../../../core/state/providers.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/animated_palette.dart';
import '../../../core/widgets/press_scale.dart';
import '../../../data/room_view.dart';
import '../../../core/router/router.dart';
import '../../room/room_hero.dart';
import '../../../core/light/room_palette.dart';
import '../weather_text.dart';

/// Raumkachel: Lichtfarbe als Glow, Temperatur und Feuchte. Tippen schaltet,
/// Halten oder der Pfeil öffnet den Raum (Sheet von unten).
class RoomTile extends ConsumerWidget {
  const RoomTile({super.key, required this.roomId, this.wide = false});

  final String roomId;
  final bool wide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(roomViewProvider(roomId));
    if (view == null) return const SizedBox.shrink();
    final hv = context.hv;
    final palette = view.palette(dark: hv.isDark);
    final repo = ref.read(repositoryProvider);

    void open() {
      HapticFeedback.mediumImpact();
      context.push(Routes.room(roomId));
    }

    final status = view.lamps.isEmpty
        ? 'Keine Lampen'
        : !view.anyOn
        ? 'Aus'
        : view.lampsOn.length == 1
        ? '${_short(view.lampsOn.first.name, view.name)} · ${view.brightness} %'
        : '${view.lampsOn.length} Lichter · ${view.brightness} %';

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
        child: PressScale(
          hoverScale: 1.015,
          onTap: () {
            if (view.lamps.isEmpty) return;
            HapticFeedback.selectionClick();
            repo.toggleRoom(roomId);
          },
          onLongPress: open,
          child: SizedBox(
            height: wide ? 150 : 132,
            child: Stack(
              children: [
                Positioned.fill(child: TileSurface(palette: palette)),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _IconDot(palette: palette),
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
                Positioned(
                  right: 0,
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

  static String _short(String lamp, String room) =>
      lamp.replaceAll(room, '').replaceAll(RegExp(r'\s+'), ' ').trim().isEmpty
      ? lamp
      : lamp.replaceAll(room, '').replaceAll(RegExp(r'\s+'), ' ').trim();
}

class _IconDot extends StatelessWidget {
  const _IconDot({required this.palette});
  final RoomPalette palette;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return AnimatedPalette(
      palette: palette,
      builder: (context, p) => Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Color.lerp(hv.s2, p.primary, p.intensity > 0 ? 1 : 0),
        ),
        child: Icon(
          Icons.lightbulb_rounded,
          size: 20,
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
