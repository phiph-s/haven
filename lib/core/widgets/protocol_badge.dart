import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../data/models/device.dart';
import '../theme/tokens.dart';

/// Farbe je Funkprotokoll (gedämpft, hell und dunkel lesbar).
Color protocolColor(DeviceProtocol p) => switch (p) {
  DeviceProtocol.zigbee => const Color(0xFFE0573A),
  DeviceProtocol.matter => const Color(0xFF4C6FD8),
  DeviceProtocol.zwave => const Color(0xFF2E9A8B),
};

/// Rundes Zeichen des Protokolls, z. B. als Ecke am Gerätesymbol. Eigene,
/// schlichte Zeichen (keine Markenlogos): Zigbee ein „Z“-Blitz, Matter drei
/// verbundene Knoten, Z-Wave eine Welle.
class ProtocolMark extends StatelessWidget {
  const ProtocolMark(this.protocol, {super.key, this.size = 16, this.ring});

  final DeviceProtocol protocol;
  final double size;

  /// Rand in der Farbe des Hintergrunds (hebt das Zeichen vom Symbol ab).
  final Color? ring;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: protocol.label,
    child: Semantics(
      label: protocol.label,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: protocolColor(protocol),
          shape: BoxShape.circle,
          border: ring == null ? null : Border.all(color: ring!, width: 1.5),
        ),
        child: CustomPaint(painter: _GlyphPainter(protocol)),
      ),
    ),
  );
}

/// Zeichen und Name des Protokolls als Pille (Detailansichten).
class ProtocolPill extends StatelessWidget {
  const ProtocolPill(this.protocol, {super.key});
  final DeviceProtocol protocol;

  @override
  Widget build(BuildContext context) {
    final c = protocolColor(protocol);
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 3, 9, 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: c.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ProtocolMark(protocol, size: 16),
          const SizedBox(width: 5),
          Text(
            protocol.label,
            style: HavenText.caption.copyWith(
              color: Color.lerp(c, context.hv.tx, 0.25),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Gerätesymbol mit dem Zeichen des Protokolls unten rechts.
class WithProtocolMark extends StatelessWidget {
  const WithProtocolMark({
    super.key,
    required this.protocol,
    required this.child,
    this.size = 16,
    this.ring,
  });

  final DeviceProtocol? protocol;
  final Widget child;
  final double size;
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    final p = protocol;
    if (p == null) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          right: -size * 0.3,
          bottom: -size * 0.3,
          child: ProtocolMark(p, size: size, ring: ring ?? context.hv.s1),
        ),
      ],
    );
  }
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.protocol);
  final DeviceProtocol protocol;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final c = size.center(Offset.zero);
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, s * 0.11)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Offset at(double x, double y) => c + Offset(x * s, y * s);
    switch (protocol) {
      case DeviceProtocol.zigbee:
        // „Z“: oben, Diagonale, unten.
        canvas.drawPath(
          Path()
            ..moveTo(at(-0.2, -0.2).dx, at(-0.2, -0.2).dy)
            ..lineTo(at(0.2, -0.2).dx, at(0.2, -0.2).dy)
            ..lineTo(at(-0.2, 0.2).dx, at(-0.2, 0.2).dy)
            ..lineTo(at(0.2, 0.2).dx, at(0.2, 0.2).dy),
          paint,
        );
      case DeviceProtocol.matter:
        // Drei Knoten im Dreieck, verbunden.
        final pts = [
          for (var i = 0; i < 3; i++)
            at(
              0.22 * math.cos(-math.pi / 2 + i * 2 * math.pi / 3),
              0.22 * math.sin(-math.pi / 2 + i * 2 * math.pi / 3) + 0.03,
            ),
        ];
        final thin = Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1, s * 0.08);
        canvas.drawPath(Path()..addPolygon(pts, true), thin);
        final dot = Paint()..color = Colors.white;
        for (final p in pts) {
          canvas.drawCircle(p, math.max(1.2, s * 0.09), dot);
        }
      case DeviceProtocol.zwave:
        // Welle.
        final path = Path();
        for (var i = 0; i <= 24; i++) {
          final t = i / 24;
          final p = at(-0.24 + 0.48 * t, -0.15 * math.sin(t * 2 * math.pi));
          i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.protocol != protocol;
}
