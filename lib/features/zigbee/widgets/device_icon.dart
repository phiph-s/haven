import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../core/theme/tokens.dart';
import '../../../data/models/zigbee.dart';

/// Gezeichnetes Geräteicon je `device_type`. Reine Vektorgrafik, kein Asset.
/// [active] färbt das Gerät (Licht an, Bewegung, Steckdose an), [glow]
/// (0..1) lässt die Aktivität pulsieren.
class ZbDeviceIcon extends StatelessWidget {
  const ZbDeviceIcon({
    super.key,
    required this.type,
    this.size = 40,
    this.active = false,
    this.glow = 0,
    this.tint,
  });

  final String type;
  final double size;
  final bool active;
  final double glow;

  /// Farbe der Aktivität, sonst Statusgrün bzw. Akzent.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _IconPainter(
          type: type,
          active: active,
          glow: glow,
          tint: tint ?? (type == ZbType.light ? hv.acc : hv.ok),
          dark: hv.isDark,
          ink: hv.tx3,
        ),
      ),
    );
  }
}

class _IconPainter extends CustomPainter {
  _IconPainter({
    required this.type,
    required this.active,
    required this.glow,
    required this.tint,
    required this.dark,
    required this.ink,
  });

  final String type;
  final bool active;
  final double glow;
  final Color tint;
  final bool dark;
  final Color ink;

  static const _bodyA = Color(0xFFFFFFFF);
  static const _bodyB = Color(0xFFD9D4E3);
  static const _edge = Color(0xFFC4BED2);
  static const _screen = Color(0xFF1B1824);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 100, size.height / 100);
    // Schatten auf dem Boden.
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(50, 90), width: 56, height: 8),
      Paint()..color = const Color(0x33000000),
    );
    if (active && glow > 0) {
      canvas.drawCircle(
        const Offset(50, 50),
        32 + 16 * glow,
        Paint()
          ..color = tint.withValues(alpha: 0.35 * (1 - glow))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }
    switch (type) {
      case ZbType.light:
        _bulb(canvas);
      case ZbType.plug:
        _plug(canvas);
      case ZbType.relay:
      case ZbType.switch_:
        _relay(canvas);
      case ZbType.climate:
        _climate(canvas);
      case ZbType.motion:
        _motion(canvas);
      case ZbType.presence:
        _presence(canvas);
      case ZbType.contact:
        _contact(canvas);
      case ZbType.remote:
        _remote(canvas);
      case ZbType.knob:
        _knob(canvas);
      case ZbType.thermostat:
        _thermostat(canvas);
      default:
        _generic(canvas);
    }
  }

  Paint _body(Rect r) => Paint()
    ..shader = const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [_bodyA, _bodyB],
    ).createShader(r);

  Paint get _line => Paint()
    ..color = _edge
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.2;

  void _rrect(Canvas c, Rect r, double rad, {Paint? fill}) {
    final rr = RRect.fromRectAndRadius(r, Radius.circular(rad));
    c.drawRRect(rr, fill ?? _body(r));
    c.drawRRect(rr, _line);
  }

  void _led(Canvas c, Offset o, {bool on = true}) => c.drawCircle(
    o,
    2.6,
    Paint()..color = (on && active) ? tint : const Color(0xFFB3ADC2),
  );

  void _bulb(Canvas c) {
    final lit = active;
    const warm = Color(0xFFFFC46B);
    if (lit) {
      c.drawCircle(
        const Offset(50, 40),
        40,
        Paint()
          ..shader =
              RadialGradient(
                colors: [
                  warm.withValues(alpha: 0.55),
                  warm.withValues(alpha: 0),
                ],
              ).createShader(
                Rect.fromCircle(center: const Offset(50, 40), radius: 40),
              ),
      );
    }
    // Sockel.
    _rrect(
      c,
      const Rect.fromLTWH(38, 68, 24, 16),
      5,
      fill: Paint()..color = const Color(0xFFB9B3C6),
    );
    c.drawLine(
      const Offset(41, 74),
      const Offset(59, 74),
      Paint()
        ..color = const Color(0xFF8B859A)
        ..strokeWidth = 1.4,
    );
    c.drawLine(
      const Offset(41, 79),
      const Offset(59, 79),
      Paint()
        ..color = const Color(0xFF8B859A)
        ..strokeWidth = 1.4,
    );
    final glass = Path()
      ..moveTo(39, 68)
      ..cubicTo(28, 60, 24, 52, 24, 41)
      ..arcToPoint(const Offset(76, 41), radius: const Radius.circular(26))
      ..cubicTo(76, 52, 72, 60, 61, 68)
      ..close();
    c.drawPath(
      glass,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.2, -0.4),
          colors: lit
              ? [const Color(0xFFFFF4D6), warm]
              : [_bodyA, const Color(0xFFDAD5E5)],
        ).createShader(const Rect.fromLTWH(24, 15, 52, 54)),
    );
    c.drawPath(glass, _line);
    c.drawPath(
      Path()
        ..moveTo(43, 62)
        ..lineTo(45, 44)
        ..lineTo(50, 52)
        ..lineTo(55, 44)
        ..lineTo(57, 62),
      Paint()
        ..color = lit ? const Color(0xFFE59A2E) : const Color(0xFFB3ADC2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  void _plug(Canvas c) {
    _rrect(c, const Rect.fromLTWH(20, 16, 60, 66), 22);
    c.drawCircle(
      const Offset(50, 49),
      22,
      Paint()..color = const Color(0xFFEDEAF3),
    );
    c.drawCircle(const Offset(50, 49), 22, _line);
    for (final dx in [-8.0, 8.0]) {
      c.drawCircle(Offset(50 + dx, 49), 3.2, Paint()..color = _screen);
    }
    c.drawRect(
      const Rect.fromLTWH(46, 33, 8, 2.6),
      Paint()..color = const Color(0xFFB3ADC2),
    );
    c.drawRect(
      const Rect.fromLTWH(46, 62.5, 8, 2.6),
      Paint()..color = const Color(0xFFB3ADC2),
    );
    _led(c, const Offset(50, 74));
  }

  void _relay(Canvas c) {
    _rrect(c, const Rect.fromLTWH(22, 26, 56, 48), 14);
    final p = Paint()
      ..color = active ? tint : const Color(0xFF8B859A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.4
      ..strokeCap = StrokeCap.round;
    c.drawArc(
      Rect.fromCircle(center: const Offset(50, 50), radius: 11),
      -math.pi / 2 + 0.6,
      math.pi * 2 - 1.2,
      false,
      p,
    );
    c.drawLine(const Offset(50, 36), const Offset(50, 48), p);
    _led(c, const Offset(50, 67));
  }

  void _climate(Canvas c) {
    _rrect(c, const Rect.fromLTWH(24, 20, 52, 58), 16);
    _rrect(
      c,
      const Rect.fromLTWH(31, 27, 38, 26),
      8,
      fill: Paint()..color = _screen,
    );
    final t = TextPainter(
      text: const TextSpan(
        text: '21°',
        style: TextStyle(
          color: Color(0xFF7FD6FF),
          fontSize: 15,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    t.paint(c, Offset(50 - t.width / 2, 40 - t.height / 2));
    c.drawCircle(
      const Offset(41, 66),
      3,
      Paint()..color = const Color(0xFFB3ADC2),
    );
    c.drawCircle(
      const Offset(59, 66),
      3,
      Paint()..color = const Color(0xFFB3ADC2),
    );
    _led(c, const Offset(50, 69));
  }

  void _motion(Canvas c) {
    _rrect(c, const Rect.fromLTWH(22, 18, 56, 62), 24);
    final lens = Rect.fromCircle(center: const Offset(50, 45), radius: 20);
    c.drawCircle(
      lens.center,
      20,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.3, -0.4),
          colors: [Color(0xFFFDFCFF), Color(0xFFE2DEEC), Color(0xFFC9C3D8)],
        ).createShader(lens),
    );
    c.drawCircle(lens.center, 20, _line);
    final seg = Paint()
      ..color = const Color(0xFFB3ACCB)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    c.drawCircle(lens.center, 13, seg);
    c.drawCircle(lens.center, 6, seg);
    c.drawLine(const Offset(50, 25), const Offset(50, 65), seg);
    c.drawLine(const Offset(30, 45), const Offset(70, 45), seg);
    _led(c, const Offset(50, 72));
  }

  void _presence(Canvas c) {
    _rrect(c, const Rect.fromLTWH(20, 18, 60, 60), 18);
    _rrect(
      c,
      const Rect.fromLTWH(28, 26, 44, 36),
      12,
      fill: Paint()..color = _screen,
    );
    final arc = Paint()
      ..color = const Color(0xFF7FD6FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    c.drawArc(
      Rect.fromCircle(center: const Offset(50, 53), radius: 9),
      -math.pi * 0.8,
      math.pi * 0.6,
      false,
      arc,
    );
    c.drawArc(
      Rect.fromCircle(center: const Offset(50, 53), radius: 17),
      -math.pi * 0.8,
      math.pi * 0.6,
      false,
      arc,
    );
    c.drawCircle(
      const Offset(50, 53),
      2.6,
      Paint()..color = const Color(0xFF7FD6FF),
    );
    _led(c, const Offset(50, 70));
  }

  void _contact(Canvas c) {
    _rrect(c, const Rect.fromLTWH(14, 32, 44, 22), 7);
    _rrect(c, const Rect.fromLTWH(64, 32, 22, 22), 7);
    _led(c, const Offset(24, 43));
    c.drawLine(
      const Offset(40, 66),
      const Offset(74, 66),
      Paint()
        ..color = ink.withValues(alpha: 0.5)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  void _remote(Canvas c) {
    _rrect(c, const Rect.fromLTWH(30, 14, 40, 72), 18);
    c.drawCircle(
      const Offset(50, 40),
      11,
      Paint()..color = const Color(0xFFEDEAF3),
    );
    c.drawCircle(const Offset(50, 40), 11, _line);
    c.drawCircle(
      const Offset(50, 40),
      4,
      Paint()..color = active ? tint : const Color(0xFFB3ADC2),
    );
    c.drawCircle(
      const Offset(50, 66),
      5,
      Paint()..color = const Color(0xFFEDEAF3),
    );
    c.drawCircle(const Offset(50, 66), 5, _line);
  }

  void _knob(Canvas c) {
    _rrect(c, const Rect.fromLTWH(20, 20, 60, 60), 30);
    c.drawCircle(
      const Offset(50, 50),
      21,
      Paint()..color = const Color(0xFFEDEAF3),
    );
    c.drawCircle(const Offset(50, 50), 21, _line);
    c.drawLine(
      const Offset(50, 50),
      const Offset(50, 34),
      Paint()
        ..color = active ? tint : const Color(0xFF8B859A)
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round,
    );
    final tick = Paint()
      ..color = const Color(0xFFB3ADC2)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 9; i++) {
      final a = -math.pi * 1.25 + i * math.pi * 1.5 / 8;
      c.drawLine(
        Offset(50 + 25 * math.cos(a), 50 + 25 * math.sin(a)),
        Offset(50 + 28 * math.cos(a), 50 + 28 * math.sin(a)),
        tick,
      );
    }
  }

  void _thermostat(Canvas c) {
    _rrect(c, const Rect.fromLTWH(20, 20, 60, 60), 30);
    _rrect(
      c,
      const Rect.fromLTWH(34, 38, 32, 24),
      8,
      fill: Paint()..color = _screen,
    );
    _led(c, const Offset(50, 72));
  }

  void _generic(Canvas c) {
    _rrect(c, const Rect.fromLTWH(24, 24, 52, 52), 16);
    final p = Paint()..color = const Color(0xFFB3ADC2);
    for (final dx in [-10.0, 0.0, 10.0]) {
      c.drawCircle(Offset(50 + dx, 50), 2.8, p);
    }
  }

  @override
  bool shouldRepaint(_IconPainter old) =>
      old.type != type ||
      old.active != active ||
      old.glow != glow ||
      old.tint != tint ||
      old.dark != dark;
}

/// Die gleiche Figur mit pulsierendem Ring, solange [active].
class ZbPulsingIcon extends StatefulWidget {
  const ZbPulsingIcon({
    super.key,
    required this.type,
    required this.size,
    required this.active,
    this.tint,
  });
  final String type;
  final double size;
  final bool active;
  final Color? tint;

  @override
  State<ZbPulsingIcon> createState() => _ZbPulsingIconState();
}

class _ZbPulsingIconState extends State<ZbPulsingIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  void _sync() {
    if (widget.active && !context.reduceMotion) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(ZbPulsingIcon old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, _) => ZbDeviceIcon(
      type: widget.type,
      size: widget.size,
      active: widget.active,
      glow: _c.value,
      tint: widget.tint,
    ),
  );
}
