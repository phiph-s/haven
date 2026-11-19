import 'dart:math' as math;

import 'package:haven_3d/haven_3d.dart' as h3;
import 'package:material_ui/material_ui.dart';

import '../../core/theme/tokens.dart';
import 'climate_links.dart';

/// Rot: die Leitung lässt gerade heizen.
const Color kHeatingLinkColor = Color(0xFFE5483B);

/// Blau: alles andere (ruhend, offenes Fenster).
const Color kWindowLinkColor = Color(0xFF5AB0FF);

/// Leitungen der Klima-Karte als Linien im Boden der 3D-Szene. Wirkt eine
/// Leitung gerade (Thermometer lässt heizen, offenes Fenster hält an),
/// laufen Pulse von der Quelle zum Thermostat; nur dann läuft auch die
/// Animation.
class ClimateLinkOverlay extends StatefulWidget {
  const ClimateLinkOverlay({
    super.key,
    required this.links,
    required this.projection,
    required this.cellMeters,
  });

  final List<ClimateLink> links;
  final h3.SceneProjection projection;
  final double cellMeters;

  @override
  State<ClimateLinkOverlay> createState() => _ClimateLinkOverlayState();
}

class _ClimateLinkOverlayState extends State<ClimateLinkOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  bool get _active =>
      widget.links.any((l) => l.state == ClimateLinkState.active);

  void _sync() {
    final run = _active && !context.reduceMotion;
    if (run && !_flow.isAnimating) {
      _flow.repeat();
    } else if (!run && _flow.isAnimating) {
      _flow.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(ClimateLinkOverlay old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _flow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.links.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: ClimateLinkPainter(
            links: widget.links,
            projection: widget.projection,
            cellMeters: widget.cellMeters,
            phase: _flow,
            hv: context.hv,
          ),
        ),
      ),
    );
  }
}

/// Zeichnet die Leitungen: Boden-Weg rechtwinklig, an den Enden hoch zum
/// Gerät (Wandthermometer, Fenster auf Brüstungshöhe).
class ClimateLinkPainter extends CustomPainter {
  ClimateLinkPainter({
    required this.links,
    required this.projection,
    required this.cellMeters,
    required this.phase,
    required this.hv,
  }) : super(repaint: phase);

  final List<ClimateLink> links;
  final h3.SceneProjection projection;
  final double cellMeters;
  final Animation<double> phase;
  final HavenColors hv;

  /// Bildschirmpunkte einer Leitung: von der Quelle zum Thermostat.
  List<Offset> pointsOf(ClimateLink l) {
    final p = projection;
    final m = cellMeters;
    final pts = <Offset>[];
    if (l.fromWindow case final w?) {
      pts.add(p.project(h3.V3(w.dx * m, w.dy * m, 0.9)));
    } else if (p.markers[l.from] case final s?) {
      pts.add(s);
    }
    for (final c in l.path) {
      pts.add(p.floor(c * m));
    }
    if (p.markers[l.to] case final t?) pts.add(t);
    return pts;
  }

  /// Rot nur, solange die Leitung heizen lässt, sonst blau (ein offenes
  /// Fenster pulsiert blau).
  Color _color(ClimateLink l) => switch (l.state) {
    ClimateLinkState.released => hv.tx3,
    ClimateLinkState.idle => kWindowLinkColor.withValues(alpha: 0.6),
    ClimateLinkState.active =>
      l.kind == ClimateLinkKind.window ? kWindowLinkColor : kHeatingLinkColor,
  };

  @override
  void paint(Canvas canvas, Size size) {
    // Breite folgt dem Zoom (etwa 4 cm im Boden), mit Grenzen.
    final w = (0.04 * projection.scale).clamp(1.4, 4.5);
    final t = phase.value;
    // Ruhende zuerst, wirkende obenauf.
    final ordered = [...links]
      ..sort((a, b) => a.state.index.compareTo(b.state.index));
    for (final l in ordered) {
      final pts = pointsOf(l);
      if (pts.length < 2) continue;
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final q in pts.skip(1)) {
        path.lineTo(q.dx, q.dy);
      }
      final color = _color(l);
      final active = l.state == ClimateLinkState.active;
      final base = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      if (active) {
        // Glühen unter der Leitung.
        canvas.drawPath(
          path,
          base
            ..color = color.withValues(alpha: 0.28)
            ..strokeWidth = w * 3.2
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
        );
        base.maskFilter = null;
      }
      if (l.state == ClimateLinkState.released) {
        _dashed(
          canvas,
          path,
          base
            ..color = color
            ..strokeWidth = w * 0.8,
          dash: w * 2.2,
          gap: w * 2.4,
        );
      } else {
        canvas.drawPath(
          path,
          base
            ..color = color
            ..strokeWidth = active ? w : w * 0.8,
        );
      }
      if (active) _pulses(canvas, path, color, w, t);
      // Anschluss an beiden Enden.
      final dot = Paint()..color = color;
      canvas.drawCircle(pts.first, w * 0.9, dot);
      canvas.drawCircle(pts.last, w * 0.9, dot);
    }
  }

  /// Helle Pulse, die von der Quelle zum Thermostat laufen.
  void _pulses(Canvas canvas, Path path, Color color, double w, double t) {
    final spacing = math.max(18.0, w * 9);
    final len = w * 3;
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = w * 1.5
      ..shader = null
      ..color = Color.lerp(color, Colors.white, 0.55)!;
    for (final metric in path.computeMetrics()) {
      for (var d = t * spacing - spacing; d < metric.length; d += spacing) {
        final a = d.clamp(0.0, metric.length);
        final b = (d + len).clamp(0.0, metric.length);
        if (b - a < 0.5) continue;
        canvas.drawPath(metric.extractPath(a, b), glow);
      }
    }
  }

  void _dashed(
    Canvas canvas,
    Path path,
    Paint paint, {
    required double dash,
    required double gap,
  }) {
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += dash + gap) {
        canvas.drawPath(
          metric.extractPath(d, math.min(d + dash, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(ClimateLinkPainter old) =>
      !identical(old.links, links) ||
      old.projection != projection ||
      old.hv != hv;
}
