import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/light/color_math.dart';
import '../../core/light/room_palette.dart';
import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/floor_plan.dart';
import '../../data/models/lamp.dart';
import 'map_data.dart';

/// Marker einer Entity auf der Karte (Lampe, Temperatur, Schalter,
/// Anwesenheit). Sichtbar ca. 32 dp, die Trefferfläche (48 dp) setzt die
/// Karte. Antippen behandelt die Karte, nicht der Marker.
class MapMarker extends ConsumerWidget {
  const MapMarker({super.key, required this.entityId, required this.kind});

  final String entityId;
  final FloorKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = ref.watch(entityProvider(entityId));
    final hv = context.hv;
    final available = e?.isAvailable ?? false;
    switch (kind) {
      case FloorKind.light:
        final lamp = e == null ? null : Lamp.fromEntity(e);
        final on = lamp?.on ?? false;
        final fill = on
            ? colorOf(uiColor(lamp!.color, dark: hv.isDark))
            : hv.s2;
        return _Bubble(
          label: e?.name ?? entityId,
          fill: fill,
          glow: on ? fill : null,
          border: on ? null : hv.ln2,
          dim: !available,
          child: Icon(
            on ? Icons.lightbulb_rounded : Icons.lightbulb_outline_rounded,
            size: 18,
            color: on ? onColorFor(rgbOf(fill)).asColor : hv.tx3,
          ),
        );
      case FloorKind.temperature:
        final v = e?.number;
        return _Pill(
          label: e?.name ?? entityId,
          text: v == null ? '–' : '${num1(v)}°',
          dim: !available,
        );
      case FloorKind.switchKind:
        final on = e?.isOn ?? false;
        return _Bubble(
          label: e?.name ?? entityId,
          fill: on ? hv.acc : hv.s2,
          glow: on ? hv.acc : null,
          border: on ? null : hv.ln2,
          dim: !available,
          child: Icon(
            Icons.power_rounded,
            size: 17,
            color: on ? hv.ai : hv.tx3,
          ),
        );
      case FloorKind.presence:
        final on = e?.isOn ?? false;
        return _Bubble(
          label: e?.name ?? entityId,
          fill: on ? hv.ok : hv.s2,
          glow: on ? hv.ok : null,
          border: on ? null : hv.ln2,
          dim: !available,
          child: Icon(
            Icons.sensors_rounded,
            size: 17,
            color: on ? const Color(0xFF0D0C12) : hv.tx3,
          ),
        );
      case FloorKind.contact:
        final open = e?.isOn ?? false;
        return _Bubble(
          label: e?.name ?? entityId,
          fill: open ? hv.warn : hv.s2,
          border: open ? null : hv.ln2,
          dim: !available,
          child: Icon(
            open ? Icons.sensor_door_outlined : Icons.door_front_door_outlined,
            size: 17,
            color: open ? const Color(0xFF0D0C12) : hv.tx3,
          ),
        );
      case FloorKind.media:
        final playing = e?.state == 'playing';
        return _Bubble(
          label: e?.name ?? entityId,
          fill: playing ? hv.acc : hv.s2,
          glow: playing ? hv.acc : null,
          border: playing ? null : hv.ln2,
          dim: !available,
          child: Icon(
            Icons.speaker_outlined,
            size: 17,
            color: playing ? hv.ai : hv.tx3,
          ),
        );
      case FloorKind.remote || FloorKind.device:
        return _Bubble(
          label: e?.name ?? entityId,
          fill: hv.s2,
          border: hv.ln2,
          dim: e != null && !available,
          child: Icon(
            kind == FloorKind.remote
                ? Icons.radio_button_checked_rounded
                : Icons.devices_other_rounded,
            size: 17,
            color: hv.tx3,
          ),
        );
    }
  }
}

extension on Rgb {
  Color get asColor => colorOf(this);
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.label,
    required this.fill,
    required this.child,
    this.glow,
    this.border,
    this.dim = false,
  });

  final String label;
  final Color fill;
  final Color? glow;
  final Color? border;
  final bool dim;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Center(
        child: Opacity(
          opacity: dim ? 0.45 : 1,
          child: AnimatedContainer(
            duration: context.motion(HavenMotion.d2),
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fill,
              border: border == null ? null : Border.all(color: border!),
              boxShadow: [
                if (glow != null)
                  BoxShadow(
                    color: glow!.withValues(alpha: 0.6),
                    blurRadius: 14,
                    spreadRadius: 1,
                  )
                else
                  const BoxShadow(
                    color: Color(0x22000000),
                    blurRadius: 4,
                    offset: Offset(0, 1),
                  ),
              ],
            ),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.text, this.dim = false});
  final String label;
  final String text;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      label: '$label $text',
      child: Center(
        child: Opacity(
          opacity: dim ? 0.45 : 1,
          child: Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hv.s1.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: hv.ln2),
            ),
            child: Text(
              text,
              maxLines: 1,
              style: HavenText.caption.copyWith(
                color: hv.tx,
                fontWeight: FontWeight.w700,
                fontSize: 11.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Symbol einer Darstellungsart (Ziehen-Label, Listen).
IconData floorKindIcon(FloorKind k) => switch (k) {
  FloorKind.light => Icons.lightbulb_rounded,
  FloorKind.temperature => Icons.thermostat_rounded,
  FloorKind.switchKind => Icons.power_rounded,
  FloorKind.presence => Icons.sensors_rounded,
  FloorKind.contact => Icons.door_front_door_outlined,
  FloorKind.media => Icons.speaker_outlined,
  FloorKind.remote => Icons.radio_button_checked_rounded,
  FloorKind.device => Icons.devices_other_rounded,
};
