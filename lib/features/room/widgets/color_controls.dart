import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../core/light/color_math.dart';
import '../../../core/light/room_palette.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/haptics.dart';

/// Farbrad: Farbton = Winkel (0 Grad oben, im Uhrzeigersinn), Sättigung = Radius.
class ColorWheel extends StatefulWidget {
  const ColorWheel({
    super.key,
    required this.color,
    required this.onChanged,
    this.size = 224,
  });

  final Rgb color;
  final ValueChanged<Rgb> onChanged;
  final double size;

  @override
  State<ColorWheel> createState() => _ColorWheelState();
}

class _ColorWheelState extends State<ColorWheel> {
  double _h = 0, _s = 0;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(ColorWheel old) {
    super.didUpdateWidget(old);
    if (!_dragging && old.color != widget.color) _sync();
  }

  void _sync() {
    final (h, s, _) = rgbToHsv(widget.color);
    _h = h;
    _s = s;
  }

  void _touch(Offset p) {
    final r = widget.size / 2;
    final dx = p.dx - r, dy = p.dy - r;
    var h = math.atan2(dx, -dy) * 180 / math.pi;
    if (h < 0) h += 360;
    final s = math.min(1.0, math.sqrt(dx * dx + dy * dy) / r);
    setState(() {
      _h = h;
      _s = s;
    });
    widget.onChanged(hsvToRgb(h, s, 1));
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.size / 2;
    final a = _h * math.pi / 180;
    final tr = _s * r;
    final thumbColor = colorOf(hsvToRgb(_h, _s, 1));
    return Semantics(
      label: 'Farbrad',
      child: GestureDetector(
        onPanStart: (d) {
          _dragging = true;
          Haptics.tick();
          _touch(d.localPosition);
        },
        onPanUpdate: (d) => _touch(d.localPosition),
        onPanEnd: (_) => _dragging = false,
        onTapDown: (d) {
          Haptics.tick();
          _touch(d.localPosition);
        },
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(
            children: [
              const RepaintBoundary(child: _WheelFace()),
              Transform.translate(
                offset: Offset(
                  r + math.sin(a) * tr - 14,
                  r - math.cos(a) * tr - 14,
                ),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: thumbColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFFFFFFFF),
                      width: 3,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 6,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WheelFace extends StatelessWidget {
  const _WheelFace();
  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(child: CustomPaint(painter: _WheelPainter()));
}

class _WheelPainter extends CustomPainter {
  const _WheelPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final sweep = SweepGradient(
      startAngle: -math.pi / 2,
      endAngle: 3 * math.pi / 2,
      colors: [
        for (var h = 0; h <= 360; h += 30)
          colorOf(hsvToRgb(h.toDouble(), 1, 1)),
      ],
    ).createShader(rect);
    canvas.drawCircle(c, r, Paint()..shader = sweep);
    final white = RadialGradient(
      colors: const [Color(0xFFFFFFFF), Color(0x00FFFFFF)],
    ).createShader(Rect.fromCircle(center: c, radius: r));
    canvas.drawCircle(c, r, Paint()..shader = white);
  }

  @override
  bool shouldRepaint(_WheelPainter old) => false;
}

/// Schnellwahl: Farbpunkte.
class ColorSwatches extends StatelessWidget {
  const ColorSwatches({super.key, required this.onPick});
  final ValueChanged<Rgb> onPick;

  static const _hex = [
    '#FF3B5C',
    '#FF8A1F',
    '#FFD23F',
    '#3DDC84',
    '#22D3EE',
    '#3B82F6',
    '#8B5CF6',
    '#FF4FA3',
  ];

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Wrap(
      alignment: WrapAlignment.center,
      children: [
        for (final h in _hex)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              Haptics.tick();
              onPick(rgbFromHex(h));
            },
            child: SizedBox(
              width: 44,
              height: HavenSpace.touch,
              child: Center(
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: colorOf(rgbFromHex(h)),
                    shape: BoxShape.circle,
                    border: Border.all(color: hv.ln2),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Regler für Weißtöne, Verlauf in den echten Kelvin-Farben.
class KelvinSlider extends StatefulWidget {
  const KelvinSlider({
    super.key,
    required this.kelvin,
    required this.onChanged,
    this.min = 2000,
    this.max = 6535,
  });

  final int kelvin;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  State<KelvinSlider> createState() => _KelvinSliderState();
}

class _KelvinSliderState extends State<KelvinSlider> {
  late double _f = _frac(widget.kelvin);
  bool _dragging = false;

  double _frac(int k) =>
      ((k - widget.min) / (widget.max - widget.min)).clamp(0.0, 1.0);

  @override
  void didUpdateWidget(KelvinSlider old) {
    super.didUpdateWidget(old);
    if (!_dragging && old.kelvin != widget.kelvin) _f = _frac(widget.kelvin);
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final stops = [
      for (var i = 0; i <= 6; i++)
        colorOf(kelvinToRgb(widget.min + (widget.max - widget.min) * i / 6)),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        void touch(double x) {
          final f = (x / w).clamp(0.0, 1.0);
          setState(() => _f = f);
          widget.onChanged(
            (widget.min + f * (widget.max - widget.min)).round(),
          );
        }

        return Semantics(
          slider: true,
          label: 'Weißton',
          value:
              '${(widget.min + _f * (widget.max - widget.min)).round()} Kelvin',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => _dragging = true,
            onHorizontalDragUpdate: (d) => touch(d.localPosition.dx),
            onHorizontalDragEnd: (_) => _dragging = false,
            onTapDown: (d) => touch(d.localPosition.dx),
            child: SizedBox(
              height: HavenSpace.touch,
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    height: 22,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(11),
                      gradient: LinearGradient(colors: stops),
                      border: Border.all(color: hv.ln2),
                    ),
                  ),
                  Transform.translate(
                    offset: Offset(_f * (w - 30), 0),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colorOf(
                          kelvinToRgb(
                            widget.min + _f * (widget.max - widget.min),
                          ),
                        ),
                        border: Border.all(
                          color: const Color(0xFFFFFFFF),
                          width: 3,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x66000000),
                            blurRadius: 6,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
