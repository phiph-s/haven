import 'package:material_ui/material_ui.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/haptics.dart';
import '../../../core/widgets/spring_value.dart';

/// Regler für Helligkeit. Der Finger wird ohne Verzögerung verfolgt, beim
/// Loslassen und bei Änderungen von außen federt die Füllung ins Ziel.
/// Haptik bei jeder 10. Prozentstufe.
class BrightnessSlider extends StatefulWidget {
  const BrightnessSlider({
    super.key,
    required this.value,
    required this.onChanged,
    required this.colors,
    this.axis = Axis.vertical,
    this.label = 'Helligkeit',
    this.onChangeEnd,
  });

  /// 0..100.
  final int value;
  final ValueChanged<int> onChanged;
  final VoidCallback? onChangeEnd;

  /// Verlauf der Füllung, vom Anfang (unten bzw. links) zum Ende.
  final List<Color> colors;
  final Axis axis;
  final String label;

  @override
  State<BrightnessSlider> createState() => _BrightnessSliderState();
}

class _BrightnessSliderState extends State<BrightnessSlider>
    with SingleTickerProviderStateMixin {
  late final SpringValue _spring = SpringValue(this, widget.value / 100);
  bool _dragging = false;
  late int _last = widget.value;

  @override
  void didUpdateWidget(BrightnessSlider old) {
    super.didUpdateWidget(old);
    if (!_dragging && widget.value != old.value) {
      _last = widget.value;
      _spring.springTo(widget.value / 100, instant: context.reduceMotion);
    }
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  void _update(Offset p, Size size) {
    final f = widget.axis == Axis.vertical
        ? 1 - p.dy / size.height
        : p.dx / size.width;
    final v = (f.clamp(0.0, 1.0) * 100).round();
    _spring.jumpTo(v / 100);
    if (v != _last) {
      if (v % 10 == 0 || (v ~/ 10) != (_last ~/ 10)) Haptics.tick();
      _last = v;
      widget.onChanged(v);
    }
  }

  void _end(double pixelVelocity, Size size) {
    _dragging = false;
    final extent = widget.axis == Axis.vertical ? size.height : size.width;
    final sign = widget.axis == Axis.vertical ? -1 : 1;
    // Etwas Schwung mitgeben: Die Füllung läuft physikalisch aus
    // (SpringSimulation), kaum Überschwingen.
    final v = (sign * pixelVelocity / extent * 0.2).clamp(-1.5, 1.5);
    _spring.springTo(_last / 100, velocity: v, instant: context.reduceMotion);
    widget.onChangeEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final vertical = widget.axis == Axis.vertical;
    return LayoutBuilder(
      builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        return Semantics(
          slider: true,
          label: widget.label,
          value: '${widget.value} %',
          increasedValue: '${(widget.value + 10).clamp(0, 100)} %',
          onIncrease: () => widget.onChanged((widget.value + 10).clamp(0, 100)),
          decreasedValue: '${(widget.value - 10).clamp(0, 100)} %',
          onDecrease: () => widget.onChanged((widget.value - 10).clamp(0, 100)),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              _dragging = true;
              _update(d.localPosition, size);
            },
            onTapUp: (_) => _end(0, size),
            onTapCancel: () => _dragging = false,
            onVerticalDragStart: vertical ? (_) => _dragging = true : null,
            onVerticalDragUpdate: vertical
                ? (d) => _update(d.localPosition, size)
                : null,
            onVerticalDragEnd: vertical
                ? (d) => _end(d.primaryVelocity ?? 0, size)
                : null,
            onHorizontalDragStart: vertical ? null : (_) => _dragging = true,
            onHorizontalDragUpdate: vertical
                ? null
                : (d) => _update(d.localPosition, size),
            onHorizontalDragEnd: vertical
                ? null
                : (d) => _end(d.primaryVelocity ?? 0, size),
            child: RepaintBoundary(
              child: CustomPaint(
                size: size,
                painter: _SliderPainter(
                  spring: _spring,
                  axis: widget.axis,
                  colors: widget.colors,
                  track: hv.s2,
                  line: hv.ln,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SliderPainter extends CustomPainter {
  _SliderPainter({
    required this.spring,
    required this.axis,
    required this.colors,
    required this.track,
    required this.line,
  }) : super(repaint: spring.listenable);

  final SpringValue spring;
  final Axis axis;
  final List<Color> colors;
  final Color track;
  final Color line;

  @override
  void paint(Canvas canvas, Size size) {
    final vertical = axis == Axis.vertical;
    final radius = Radius.circular(vertical ? HavenRadii.xl : size.height / 2);
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, radius);
    canvas.drawRRect(rrect, Paint()..color = track);
    final f = spring.value.clamp(0.0, 1.05);
    canvas.save();
    canvas.clipRRect(rrect);
    if (f > 0.001) {
      final Rect fill;
      final Gradient g;
      if (vertical) {
        fill = Rect.fromLTRB(0, size.height * (1 - f), size.width, size.height);
        g = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: colors,
        );
      } else {
        fill = Rect.fromLTRB(0, 0, size.width * f, size.height);
        g = LinearGradient(colors: colors);
      }
      canvas.drawRect(
        fill,
        Paint()..shader = g.createShader(Offset.zero & size),
      );
      // Griff
      final handle = vertical
          ? RRect.fromRectAndRadius(
              Rect.fromCenter(
                center: Offset(size.width / 2, fill.top + 17),
                width: 44,
                height: 6,
              ),
              const Radius.circular(3),
            )
          : RRect.fromRectAndRadius(
              Rect.fromCenter(
                center: Offset(fill.right - 15, size.height / 2),
                width: 6,
                height: size.height * 0.4,
              ),
              const Radius.circular(3),
            );
      canvas.drawRRect(
        handle.shift(const Offset(0, 1)),
        Paint()..color = const Color(0x40000000),
      );
      canvas.drawRRect(handle, Paint()..color = const Color(0xFFFFFFFF));
    }
    canvas.restore();
    canvas.drawRRect(
      rrect.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = line,
    );
  }

  @override
  bool shouldRepaint(_SliderPainter old) =>
      old.colors != colors ||
      old.track != track ||
      old.line != line ||
      old.axis != axis;
}
