import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import 'thermostat_model.dart';

/// Farbe einer Zieltemperatur: kühl blau, angenehm bernstein, warm orange.
Color thermoColor(double t) {
  const stops = <(double, Color)>[
    (12, Color(0xFF4F8EF7)),
    (17, Color(0xFF3FB6C6)),
    (20, Color(0xFFF2A93B)),
    (24, Color(0xFFF0703C)),
    (28, Color(0xFFE5484D)),
  ];
  if (t <= stops.first.$1) return stops.first.$2;
  for (var i = 1; i < stops.length; i++) {
    final (b, cb) = stops[i];
    if (t <= b) {
      final (a, ca) = stops[i - 1];
      return Color.lerp(ca, cb, (t - a) / (b - a))!;
    }
  }
  return stops.last.$2;
}

/// Wärme beim Heizen (Glow, Flamme).
const Color kHeatColor = Color(0xFFF0703C);

/// Anfang und Umfang des Bogens: 270°, unten offen.
const double _kStart = math.pi * 0.75;
const double _kSweep = math.pi * 1.5;

/// Rundes Stellrad für die Zieltemperatur. Ziehen am Ring stellt in
/// Schritten von [ThermostatState.step] (mit Haptik je Schritt), losgelassen
/// geht der Wert an [onCommit]. Die gemessene Temperatur steht als Marke auf
/// dem Ring. Malt per `CustomPainter` mit `repaint`, beim Ziehen baut nur die
/// Mitte neu.
class ThermostatDial extends StatefulWidget {
  const ThermostatDial({
    super.key,
    required this.state,
    required this.onCommit,
    this.size = 248,
  });
  final ThermostatState state;
  final ValueChanged<double> onCommit;
  final double size;

  @override
  State<ThermostatDial> createState() => ThermostatDialState();
}

class ThermostatDialState extends State<ThermostatDial> {
  late final ValueNotifier<double?> _value = ValueNotifier(_target);
  bool _dragging = false;
  DateTime? _holdUntil;
  Timer? _debounce;

  double? get _target => widget.state.shownTarget;
  ThermostatState get t => widget.state;

  @override
  void didUpdateWidget(ThermostatDial oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = _target;
    if (_dragging) return;
    final hold = _holdUntil;
    // Nach dem Loslassen kurz den eigenen Wert halten, bis das Gerät ihn
    // bestätigt (HA-Dienste melden verzögert).
    if (hold != null &&
        DateTime.now().isBefore(hold) &&
        incoming != _value.value) {
      return;
    }
    _holdUntil = null;
    if (incoming != _value.value) _value.value = incoming;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _value.dispose();
    super.dispose();
  }

  double? _valueAt(Offset local) {
    final c = Offset(widget.size / 2, widget.size / 2);
    final d = local - c;
    var a = math.atan2(d.dy, d.dx);
    // Winkel relativ zum Anfang, 0..2π.
    var rel = (a - _kStart) % (2 * math.pi);
    if (rel < 0) rel += 2 * math.pi;
    if (rel > _kSweep) {
      // In der Lücke unten: zum näheren Ende.
      rel = rel - _kSweep < (2 * math.pi - _kSweep) / 2 ? _kSweep : 0;
    }
    a = rel / _kSweep;
    return t.clampTarget(t.minTarget + a * (t.maxTarget - t.minTarget));
  }

  bool _onRing(Offset local) {
    final r = widget.size / 2;
    final d = (local - Offset(r, r)).distance;
    return d > r * 0.52 && d < r + 12;
  }

  /// Berührung nahe am Griff (aktueller Wert)?
  bool _onKnob(Offset local) {
    final v = _value.value;
    if (v == null) return false;
    final r = widget.size / 2;
    final ring = r - 8 - 6;
    final f = ((v - t.minTarget) / (t.maxTarget - t.minTarget)).clamp(0.0, 1.0);
    final a = _kStart + _kSweep * f;
    final knob = Offset(r, r) + Offset(math.cos(a), math.sin(a)) * ring;
    return (local - knob).distance < 34;
  }

  void _set(double v) {
    if (v != _value.value) {
      Haptics.tick();
      _value.value = v;
    }
  }

  void _commit() {
    final v = _value.value;
    if (v == null) return;
    _holdUntil = DateTime.now().add(const Duration(seconds: 4));
    widget.onCommit(v);
  }

  /// Ein Schritt nach oben (+1) oder unten (-1), z. B. von den Knöpfen.
  /// Mehrere schnelle Schritte gehen als ein Befehl raus.
  void nudge(int dir) {
    if (!t.canSetTarget) return;
    final base = _value.value ?? t.current ?? 20;
    _set(t.clampTarget(base + dir * t.step));
    _holdUntil = DateTime.now().add(const Duration(seconds: 5));
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 650), _commit);
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final enabled = t.canSetTarget;
    final s = widget.size;
    final dial = CustomPaint(
      size: Size.square(s),
      painter: _DialPainter(
        value: _value,
        min: t.minTarget,
        max: t.maxTarget,
        current: t.current,
        enabled: enabled,
        heating: t.heating == true,
        track: hv.s2,
        line: hv.ln2,
        knob: hv.s1,
        mark: hv.tx,
      ),
      child: SizedBox.square(
        dimension: s,
        child: Center(
          child: ValueListenableBuilder<double?>(
            valueListenable: _value,
            builder: (context, v, _) => _Center(state: t, value: v, size: s),
          ),
        ),
      ),
    );
    return Semantics(
      label: 'Zieltemperatur ${t.name}',
      value: !enabled
          ? 'aus'
          : (_value.value == null ? 'unbekannt' : fmtTemp(_value.value!)),
      increasedValue: enabled
          ? fmtTemp(t.clampTarget((_value.value ?? 20) + t.step))
          : null,
      decreasedValue: enabled
          ? fmtTemp(t.clampTarget((_value.value ?? 20) - t.step))
          : null,
      onIncrease: enabled ? () => nudge(1) : null,
      onDecrease: enabled ? () => nudge(-1) : null,
      slider: true,
      child: !enabled
          ? dial
          : RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              gestures: {
                _RingPanRecognizer:
                    GestureRecognizerFactoryWithHandlers<_RingPanRecognizer>(
                      () =>
                          _RingPanRecognizer(onRing: _onRing, onKnob: _onKnob),
                      (r) => r
                        ..onRing = _onRing
                        ..onKnob = _onKnob
                        ..dragStartBehavior = DragStartBehavior.down
                        ..onStart = (d) {
                          _debounce?.cancel();
                          _dragging = true;
                          final v = _valueAt(d.localPosition);
                          if (v != null) _set(v);
                        }
                        ..onUpdate = (d) {
                          if (!_dragging) return;
                          final v = _valueAt(d.localPosition);
                          if (v != null) _set(v);
                        }
                        ..onEnd = (_) {
                          if (!_dragging) return;
                          _dragging = false;
                          HapticFeedback.lightImpact();
                          _commit();
                        }
                        ..onCancel = () => _dragging = false,
                    ),
              },
              child: dial,
            ),
    );
  }
}

class _Center extends StatelessWidget {
  const _Center({required this.state, required this.value, required this.size});
  final ThermostatState state;
  final double? value;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final k = size / 248;
    final off = state.isOff;
    final big = off ? 'Aus' : (value == null ? '–' : fmtNum1(value!));
    final heating = state.heating == true && !off;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          heating ? 'Heizt auf' : 'Ziel',
          style: HavenText.caption.copyWith(
            color: heating ? kHeatColor : hv.tx2,
            fontSize: 13 * k,
            fontWeight: FontWeight.w700,
          ),
        ),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: size * 0.62),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  big,
                  style: HavenText.percent.copyWith(
                    color: off ? hv.tx2 : hv.tx,
                    fontSize: (off ? 44 : 62) * k,
                  ),
                ),
                if (!off && value != null)
                  Padding(
                    padding: EdgeInsets.only(top: 8 * k, left: 2),
                    child: Text(
                      '°C',
                      style: HavenText.headline.copyWith(
                        color: hv.tx2,
                        fontSize: 18 * k,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (state.current != null)
          Text(
            'Raum ${fmtTemp(state.current!)}',
            style: HavenText.label.copyWith(color: hv.tx2, fontSize: 13.5 * k),
          ),
      ],
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.value,
    required this.min,
    required this.max,
    required this.current,
    required this.enabled,
    required this.heating,
    required this.track,
    required this.line,
    required this.knob,
    required this.mark,
  }) : super(repaint: value);

  final ValueNotifier<double?> value;
  final double min;
  final double max;
  final double? current;
  final bool enabled;
  final bool heating;
  final Color track;
  final Color line;
  final Color knob;
  final Color mark;

  double _frac(double v) => ((v - min) / (max - min)).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    const stroke = 16.0;
    final c = Offset(r, r);
    final ring = r - stroke / 2 - 6;
    final rect = Rect.fromCircle(center: c, radius: ring);

    // Skala: feine Striche je Grad.
    final ticks = Paint()
      ..color = line
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    final steps = (max - min).round();
    for (var i = 0; i <= steps; i++) {
      final a = _kStart + _kSweep * i / steps;
      final dir = Offset(math.cos(a), math.sin(a));
      final major = (min + i) % 5 == 0;
      final inner = ring - stroke / 2 - (major ? 11 : 7);
      canvas.drawLine(
        c + dir * inner,
        c + dir * (ring - stroke / 2 - 3),
        ticks..strokeWidth = major ? 2 : 1.2,
      );
    }

    // Grundspur.
    canvas.drawArc(
      rect,
      _kStart,
      _kSweep,
      false,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round,
    );

    final v = value.value;
    if (enabled && v != null) {
      final f = _frac(v);
      // Verlauf von kühl bis zur Farbe des Ziels. Die runde Kappe am Anfang
      // liegt knapp vor dem Winkel 0 und bekommt so ebenfalls die kühle Farbe.
      final end = (0.75 * f).clamp(0.01, 0.74);
      final shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi * 2,
        transform: const GradientRotation(_kStart),
        colors: [
          thermoColor(min),
          thermoColor((min + v) / 2),
          thermoColor(v),
          thermoColor(v),
          thermoColor(min),
        ],
        stops: [0, end / 2, end, 0.875, 1],
      ).createShader(rect);
      if (f > 0.001) {
        canvas.drawArc(
          rect,
          _kStart,
          _kSweep * f,
          false,
          Paint()
            ..shader = shader
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..strokeCap = StrokeCap.round,
        );
      }
      // Schein am Griff beim Heizen.
      final a = _kStart + _kSweep * f;
      final p = c + Offset(math.cos(a), math.sin(a)) * ring;
      if (heating) {
        canvas.drawCircle(
          p,
          22,
          Paint()
            ..shader = RadialGradient(
              colors: [
                kHeatColor.withValues(alpha: 0.45),
                kHeatColor.withValues(alpha: 0),
              ],
            ).createShader(Rect.fromCircle(center: p, radius: 22)),
        );
      }
      canvas.drawCircle(p, 13, Paint()..color = const Color(0x33000000));
      canvas.drawCircle(p, 12, Paint()..color = knob);
      canvas.drawCircle(p, 6, Paint()..color = thermoColor(v));
    }

    // Gemessene Temperatur als Marke außen am Ring.
    final cur = current;
    if (cur != null && cur >= min - 5 && cur <= max + 5) {
      final a = _kStart + _kSweep * _frac(cur);
      final dir = Offset(math.cos(a), math.sin(a));
      final tip = c + dir * (ring + stroke / 2 + 2);
      final perp = Offset(-dir.dy, dir.dx);
      final path = Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo((tip + dir * 8 + perp * 5).dx, (tip + dir * 8 + perp * 5).dy)
        ..lineTo((tip + dir * 8 - perp * 5).dx, (tip + dir * 8 - perp * 5).dy)
        ..close();
      canvas.drawPath(path, Paint()..color = mark.withValues(alpha: 0.75));
    }
  }

  @override
  bool shouldRepaint(_DialPainter o) =>
      o.min != min ||
      o.max != max ||
      o.current != current ||
      o.enabled != enabled ||
      o.heating != heating ||
      o.track != track ||
      o.line != line ||
      o.knob != knob ||
      o.mark != mark ||
      o.value != value;
}

/// Ziehen am Ring. Am Griff gewinnt das Rad sofort, damit ein umgebendes
/// Sheet das senkrechte Ziehen nicht übernimmt. Die Mitte bleibt frei.
class _RingPanRecognizer extends PanGestureRecognizer {
  _RingPanRecognizer({required this.onRing, required this.onKnob});
  bool Function(Offset local) onRing;
  bool Function(Offset local) onKnob;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (!onRing(event.localPosition)) return;
    super.addAllowedPointer(event);
    // Am Griff gehört die Berührung sofort dem Rad. Sonst am Ring entscheidet
    // die Arena: senkrecht scrollt die Liste, seitlich stellt das Rad.
    if (onKnob(event.localPosition)) resolve(GestureDisposition.accepted);
  }
}
