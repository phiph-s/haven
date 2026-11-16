import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/light/color_math.dart';
import '../../core/light/room_palette.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/floor_plan.dart';
import 'floor_plan_view.dart';
import 'map_data.dart';

/// Lichtfarbe des Raums und Lichtkegel der Lampen, auf den Raum geclippt.
/// Farben kommen aus dem Farbmotor (`computePalette`, `uiColor`), die
/// Deckkraft eines Kegels ist `.35 + .65 * Helligkeit` (Spec 5).
class MapLightPainter extends FloorOverlayPainter {
  const MapLightPainter({
    required this.plan,
    required this.lights,
    required this.hv,
  });

  final HavenFloorPlan plan;
  final MapLights lights;
  final HavenColors hv;

  @override
  void paint(Canvas canvas, Size size, FloorGeometry geo) {
    final dark = hv.isDark;
    for (final room in plan.rooms) {
      final rect = geo.rooms[room.id];
      if (rect == null) continue;
      final mine = [
        for (final p in plan.placements)
          if (lights.lamps[p.entityId]?.on == true &&
              lights.where[p.entityId] == room.id)
            (p, lights.lamps[p.entityId]!),
      ];
      if (mine.isEmpty) continue;
      final pal = computePalette([
        for (final (_, l) in mine) ?l.asLight,
      ], dark: dark);

      canvas.save();
      canvas.clipPath(geo.roomPath(room.id));
      // Raumton: sanftes Licht über der ganzen Fläche.
      final a = (pal.intensity * hv.ambientGlow * 0.5).clamp(0.0, 1.0);
      canvas.drawRect(
        rect,
        Paint()
          ..shader =
              RadialGradient(
                colors: [
                  pal.mix.withValues(alpha: a),
                  pal.mix.withValues(alpha: 0),
                ],
              ).createShader(
                Rect.fromCircle(
                  center: rect.center,
                  radius: rect.longestSide * 0.75,
                ),
              ),
      );
      final inner = geo.roomCellRect(room.id, room.innerRect);
      final radius =
          0.95 * math.min(rect.width, rect.height) * 0.5 +
          0.12 * math.min(inner.width, inner.height);
      for (final (p, lamp) in mine) {
        final c = colorOf(uiColor(lamp.color, dark: dark));
        final op = 0.35 + 0.65 * lamp.brightness / 100;
        final center = geo.pointToPx(plan.pointOfCell(p.cell));
        canvas.drawCircle(
          center,
          radius,
          Paint()
            ..shader = RadialGradient(
              colors: [
                c.withValues(alpha: 0.95 * op),
                c.withValues(alpha: 0.55 * op),
                c.withValues(alpha: 0.18 * op),
                c.withValues(alpha: 0),
              ],
              stops: const [0, 0.4, 0.74, 1],
            ).createShader(Rect.fromCircle(center: center, radius: radius)),
        );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(MapLightPainter old) =>
      old.plan != plan || old.lights != lights || old.hv != hv;
}
