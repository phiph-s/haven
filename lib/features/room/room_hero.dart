import 'package:material_ui/material_ui.dart';

import '../../core/light/room_palette.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/animated_palette.dart';

/// Kachel-Look: Fläche s1, Haarlinie, Glow über die ganze Fläche.
class TileSurface extends StatelessWidget {
  const TileSurface({
    super.key,
    required this.palette,
    this.radius = HavenRadii.l,
    this.shadow = true,
  });

  final RoomPalette palette;
  final double radius;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final r = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: hv.s1,
        borderRadius: r,
        border: Border.all(color: hv.ln),
        boxShadow: shadow ? hv.shadowSmall : null,
      ),
      child: MeshGlow(palette: palette, borderRadius: r),
    );
  }
}

/// Seiten-Look: Hintergrund mit weichem Licht oben.
class RoomPageBackdrop extends StatelessWidget {
  const RoomPageBackdrop({super.key, required this.palette});
  final RoomPalette palette;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return ColoredBox(
      color: hv.bg,
      child: Align(
        alignment: Alignment.topCenter,
        child: FractionallySizedBox(
          heightFactor: 0.6,
          widthFactor: 1,
          child: MeshGlow(palette: palette, style: MeshStyle.ambient),
        ),
      ),
    );
  }
}

/// Bildschirmrechteck der Kachel, von der aus der Raum aufgeht. Geht als
/// JSON-taugliche Map in `extra` an die Route (go_router legt `extra` im
/// Browserverlauf ab).
Map<String, double>? originExtra(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return null;
  final o = box.localToGlobal(Offset.zero);
  return {'l': o.dx, 't': o.dy, 'w': box.size.width, 'h': box.size.height};
}

Rect? originFromExtra(Object? extra) {
  if (extra is! Map) return null;
  final l = extra['l'], t = extra['t'], w = extra['w'], h = extra['h'];
  if (l is! num || t is! num || w is! num || h is! num) return null;
  return Rect.fromLTWH(l.toDouble(), t.toDouble(), w.toDouble(), h.toDouble());
}

/// Übergang Kachel zu Raum als Container-Transform: Die Raumseite wächst aus
/// dem Rechteck der Kachel auf den ganzen Bildschirm, die Ecken laufen von 26
/// auf 0. Darüber liegt am Anfang der Kachel-Look und blendet in den ersten
/// 35 % aus.
///
/// Vorher war das ein Hero. Dessen Flug liegt im Overlay über der Seite,
/// deshalb war der Rauminhalt erst nach der Landung zu sehen.
///
/// Pro Frame ändert sich nur der Clip (`reclip`) und zwei FadeTransitions.
/// Es baut nichts neu und layoutet nichts, die Seite ist ab dem ersten Frame
/// fertig gebaut.
class RoomReveal extends StatelessWidget {
  const RoomReveal({
    super.key,
    required this.animation,
    required this.origin,
    required this.palette,
    required this.child,
  });

  final Animation<double> animation;

  /// Kachel in globalen Koordinaten. `null` (Deep Link, Karte): nur
  /// Einblenden und leichtes Wachsen aus der Mitte.
  final Rect? origin;
  final RoomPalette palette;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final move = CurvedAnimation(
      parent: animation,
      curve: HavenMotion.out,
      reverseCurve: Curves.easeInCubic,
    );
    final tile = ReverseAnimation(
      CurvedAnimation(
        parent: animation,
        curve: const Interval(0, 0.35, curve: Curves.easeOut),
        reverseCurve: const Interval(0.0, 0.45, curve: Curves.easeIn),
      ),
    );
    final content = CurvedAnimation(
      parent: animation,
      curve: const Interval(0.08, 0.6, curve: Curves.easeOut),
      reverseCurve: const Interval(0.35, 1, curve: Curves.easeIn),
    );
    return ClipRRect(
      clipper: _RevealClipper(move, origin),
      child: Stack(
        fit: StackFit.expand,
        children: [
          FadeTransition(opacity: content, child: child),
          IgnorePointer(
            child: FadeTransition(
              opacity: tile,
              child: _TileCover(origin: origin, palette: palette),
            ),
          ),
        ],
      ),
    );
  }
}

/// Kachel-Look während des Übergangs. Nicht sichtbar (Deckkraft 0) baut
/// FadeTransition nichts neu und malt nichts.
class _TileCover extends StatelessWidget {
  const _TileCover({required this.origin, required this.palette});
  final Rect? origin;
  final RoomPalette palette;

  @override
  Widget build(BuildContext context) {
    if (origin == null) return const SizedBox.shrink();
    return RepaintBoundary(
      child: TileSurface(palette: palette, radius: 0, shadow: false),
    );
  }
}

class _RevealClipper extends CustomClipper<RRect> {
  _RevealClipper(this.t, this.origin) : super(reclip: t);
  final Animation<double> t;
  final Rect? origin;

  @override
  RRect getClip(Size size) {
    final full = Offset.zero & size;
    final v = t.value.clamp(0.0, 1.0);
    final from =
        origin ??
        Rect.fromCenter(
          center: full.center,
          width: size.width * 0.92,
          height: size.height * 0.92,
        );
    final r = Rect.lerp(from, full, v)!;
    return RRect.fromRectAndRadius(r, Radius.circular(HavenRadii.l * (1 - v)));
  }

  @override
  bool shouldReclip(_RevealClipper old) => old.origin != origin || old.t != t;
}
