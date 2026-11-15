import 'package:material_ui/material_ui.dart';

import '../light/room_palette.dart';
import '../theme/tokens.dart';

class _PaletteTween extends Tween<RoomPalette> {
  _PaletteTween({super.end});
  @override
  RoomPalette lerp(double t) => RoomPalette.lerp(begin!, end!, t);
}

/// Lerpt zwischen Paletten, wenn sich das Licht ändert (800 ms, Spec 2.7).
/// Der Builder läuft pro Frame, deshalb nur leichte Zeichenwidgets hineinlegen.
class AnimatedPalette extends StatelessWidget {
  const AnimatedPalette({
    super.key,
    required this.palette,
    required this.builder,
    this.duration = HavenMotion.d4,
  });

  final RoomPalette palette;
  final Widget Function(BuildContext context, RoomPalette current) builder;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<RoomPalette>(
      tween: _PaletteTween(end: palette),
      duration: context.motion(duration),
      curve: Curves.easeInOut,
      builder: (context, p, _) => builder(context, p),
    );
  }
}

/// Stil des Mesh-Verlaufs.
enum MeshStyle {
  /// Kachel und Raum-Hintergrund: Verlauf füllt die Fläche (Spec 2.3).
  fill,

  /// Weiches Licht oben am Bildschirm: klingt nach unten aus.
  ambient,
}

/// Glow aus drei Radialverläufen. Zeichnet nur, layoutet nie neu und liegt in
/// einer eigenen RepaintBoundary.
class MeshGlow extends StatelessWidget {
  const MeshGlow({
    super.key,
    required this.palette,
    this.style = MeshStyle.fill,
    this.factor,
    this.borderRadius,
  });

  final RoomPalette palette;
  final MeshStyle style;

  /// Modusfaktor der Deckkraft. Standard aus den Tokens je nach Stil.
  final double? factor;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final f =
        factor ?? (style == MeshStyle.fill ? hv.tileGlow : hv.ambientGlow);
    return RepaintBoundary(
      child: AnimatedPalette(
        palette: palette,
        builder: (context, p) {
          Widget w = CustomPaint(
            painter: MeshPainter(p, style, f),
            size: Size.infinite,
          );
          if (borderRadius != null) {
            w = ClipRRect(borderRadius: borderRadius!, child: w);
          }
          return w;
        },
      ),
    );
  }
}

class MeshPainter extends CustomPainter {
  MeshPainter(this.palette, this.style, this.factor);
  final RoomPalette palette;
  final MeshStyle style;
  final double factor;

  @override
  void paint(Canvas canvas, Size size) {
    final a = (palette.intensity * factor).clamp(0.0, 1.0);
    if (a <= 0.003 || size.isEmpty) return;
    final m = palette.mesh;
    // (Mittelpunkt in Anteilen, Radius in Anteilen, Farbe, Alpha)
    final spots = switch (style) {
      MeshStyle.fill => [
        (const Offset(.18, .12), const Offset(.70, .80), m[0], .95),
        (const Offset(.88, .38), const Offset(.70, .80), m[1], .85),
        (const Offset(.40, 1.08), const Offset(.95, .70), m[2], .80),
      ],
      MeshStyle.ambient => [
        (const Offset(.12, .02), const Offset(.75, .62), m[0], .95),
        (const Offset(.92, .16), const Offset(.70, .55), m[1], .85),
        (const Offset(.45, .42), const Offset(.90, .45), m[2], .70),
      ],
    };
    for (final (c, r, color, alpha) in spots) {
      final center = Offset(c.dx * size.width, c.dy * size.height);
      final rx = r.dx * size.width;
      final ry = r.dy * size.height;
      canvas.save();
      canvas.translate(center.dx, center.dy);
      // Ellipse über Skalierung eines Kreisverlaufs.
      canvas.scale(rx, ry);
      final shader = RadialGradient(
        colors: [
          color.withValues(alpha: alpha * a),
          color.withValues(alpha: 0),
        ],
        stops: const [0, 1],
      ).createShader(const Rect.fromLTRB(-1, -1, 1, 1));
      canvas.drawRect(Rect.fromLTRB(-1, -1, 1, 1), Paint()..shader = shader);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(MeshPainter old) =>
      old.palette != palette || old.style != style || old.factor != factor;
}
