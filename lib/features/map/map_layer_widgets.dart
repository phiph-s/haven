import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/light/color_math.dart';
import '../../core/light/room_palette.dart';
import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/floor_plan.dart';
import '../../data/models/state_history.dart';
import 'floor_plan_view.dart';
import 'heatmap.dart';
import 'map_readings.dart';

Color onFill(Color c) => colorOf(onColorFor(rgbOf(c)));

/// Farbe der Anwesenheit (ruhiges Grün, wie „ok“).
Color presenceColor(HavenColors hv) => hv.ok;

/// Messwert als Pille in der Farbe der Skala, mit Punkt an der Messstelle.
class HeatValueMarker extends StatelessWidget {
  const HeatValueMarker({
    super.key,
    required this.label,
    required this.text,
    required this.color,
    this.outside = false,
  });
  final String label;
  final String text;
  final Color color;

  /// Draußen: neutral mit Baum-Symbol, nicht in der Innenskala.
  final bool outside;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final fill = outside ? hv.s1 : color;
    final fg = outside ? hv.tx : onFill(color);
    return Semantics(
      label: '$label $text',
      // Die Pille darf breiter sein als die Trefferfläche.
      child: OverflowBox(
        maxWidth: 140,
        child: Center(
          child: Container(
            height: 26,
            padding: EdgeInsets.only(left: outside ? 6 : 9, right: 9),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                color: outside ? hv.ln2 : hv.s1.withValues(alpha: 0.9),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF000000)
                      .withValues(alpha: hv.isDark ? 0.4 : 0.14),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (outside) ...[
                  Icon(Icons.park_outlined, size: 13, color: hv.ok),
                  const SizedBox(width: 3),
                ],
                Text(
                  text,
                  maxLines: 1,
                  style: HavenText.caption.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Melder auf der Anwesenheitskarte. Löst er aus, laufen Wellen nach außen,
/// solange Bewegung da ist, atmet er ruhig.
class PresenceMarker extends ConsumerStatefulWidget {
  const PresenceMarker({
    super.key,
    required this.entityId,
    this.level = 0,
    this.historic,
  });
  final String entityId;

  /// Zustand aus der History (Zeitstrahl): ersetzt den aktuellen, ohne Puls.
  final bool? historic;

  /// Nachleuchten 0..1 (für die Deckkraft im Ruhezustand).
  final double level;

  @override
  ConsumerState<PresenceMarker> createState() => _PresenceMarkerState();
}

class _PresenceMarkerState extends ConsumerState<PresenceMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );
  bool? _was;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _sync(bool on) {
    if (_was == on) return;
    final rising = _was == false && on;
    _was = on;
    if (context.reduceMotion) {
      _c.value = 0;
      return;
    }
    if (on) {
      // Auslösen: von vorn, dann weiter im Takt.
      if (rising) _c.value = 0;
      _c.repeat();
    } else {
      _c.animateTo(1, duration: const Duration(milliseconds: 600)).then((_) {
        if (mounted && _was == false) _c.value = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = ref.watch(entityProvider(widget.entityId));
    final hv = context.hv;
    final live = e?.isOn ?? false;
    final on = widget.historic ?? live;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync(widget.historic == null && live);
    });
    final color = presenceColor(hv);
    final dot = AnimatedContainer(
      duration: context.motion(HavenMotion.d2),
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on
            ? color
            : Color.alphaBlend(
                color.withValues(alpha: 0.12 + 0.5 * widget.level),
                hv.s2,
              ),
        border: Border.all(color: on ? hv.s1 : hv.ln2, width: on ? 2 : 1),
      ),
      child: Icon(
        Icons.sensors_rounded,
        size: 16,
        color: on ? onFill(color) : hv.tx2,
      ),
    );
    return Semantics(
      label: '${e?.name ?? widget.entityId}, ${on ? 'Bewegung' : 'ruhig'}',
      child: Center(
        child: SizedBox(
          width: 30,
          height: 30,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              RepaintBoundary(
                child: CustomPaint(
                  size: const Size(30, 30),
                  painter: _RipplePainter(_c, color, on),
                ),
              ),
              dot,
            ],
          ),
        ),
      ),
    );
  }
}

class _RipplePainter extends CustomPainter {
  _RipplePainter(this.t, this.color, this.on) : super(repaint: t);
  final Animation<double> t;
  final Color color;
  final bool on;

  @override
  void paint(Canvas canvas, Size size) {
    final v = t.value;
    if (v == 0 && !on) return;
    final c = size.center(Offset.zero);
    for (var i = 0; i < 2; i++) {
      final p = (v + i * 0.5) % 1.0;
      final r = 15 + p * 30;
      final a = (1 - p) * (on ? 0.5 : 0.25);
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5 * (1 - p) + 0.5
          ..color = color.withValues(alpha: a),
      );
    }
  }

  @override
  bool shouldRepaint(_RipplePainter old) => old.color != color || old.on != on;
}

/// Räume leuchten bei Bewegung und klingen ab.
class PresencePainter extends FloorOverlayPainter {
  const PresencePainter({
    required this.plan,
    required this.levels,
    required this.sensors,
    required this.hv,
  });

  final HavenFloorPlan plan;
  final Map<String, RoomPresence> levels;

  /// Melder mit ihrer Leuchtkraft (Zellen).
  final List<(Offset, double)> sensors;
  final HavenColors hv;

  @override
  void paint(Canvas canvas, Size size, FloorGeometry geo) {
    final color = presenceColor(hv);
    for (final room in plan.rooms) {
      final l = levels[room.id];
      if (l == null || l.level <= 0.01) continue;
      final path = geo.roomPath(room.id);
      canvas.save();
      canvas.clipPath(path);
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(
            alpha: (hv.isDark ? 0.10 : 0.08) + 0.22 * l.level,
          ),
      );
      final b = geo.rooms[room.id]!;
      for (final (at, lv) in sensors) {
        if (lv <= 0.01 || plan.roomAt(at)?.id != room.id) continue;
        final c = geo.pointToPx(PlanPoint(at.dx, at.dy, room.id));
        final r = b.longestSide * 0.7;
        canvas.drawCircle(
          c,
          r,
          Paint()
            ..shader = RadialGradient(
              colors: [
                color.withValues(alpha: 0.42 * lv),
                color.withValues(alpha: 0.12 * lv),
                color.withValues(alpha: 0),
              ],
              stops: const [0, 0.5, 1],
            ).createShader(Rect.fromCircle(center: c, radius: r)),
        );
      }
      canvas.restore();
      if (l.active) {
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = color.withValues(alpha: 0.8),
        );
      }
    }
  }

  @override
  bool shouldRepaint(PresencePainter old) =>
      old.plan != plan ||
      old.hv != hv ||
      old.sensors.length != sensors.length ||
      !_sameLevels(old.levels, levels) ||
      !_sameSensors(old.sensors, sensors);

  static bool _sameLevels(
    Map<String, RoomPresence> a,
    Map<String, RoomPresence> b,
  ) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  static bool _sameSensors(List<(Offset, double)> a, List<(Offset, double)> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Batteriestand als Ring mit Zahl, schwache Batterien rot hervorgehoben.
class BatteryMarker extends StatelessWidget {
  const BatteryMarker({super.key, required this.label, required this.level});
  final String label;
  final double level;

  static Color colorOf(HavenColors hv, double level) =>
      level < 20 ? hv.bad : (level < 40 ? hv.warn : hv.ok);

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final c = colorOf(hv, level);
    final weak = level < 20;
    return Semantics(
      label: '$label, Batterie ${level.round()} %',
      child: Center(
        child: Container(
          width: weak ? 38 : 32,
          height: weak ? 38 : 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: hv.s1,
            boxShadow: [
              if (weak)
                BoxShadow(color: c.withValues(alpha: 0.55), blurRadius: 14),
            ],
          ),
          child: CustomPaint(
            painter: _RingPainter(level / 100, c, hv.s3),
            child: Center(
              child: Text(
                '${level.round()}',
                style: HavenText.caption.copyWith(
                  color: weak ? c : hv.tx,
                  fontWeight: FontWeight.w800,
                  fontSize: weak ? 12.5 : 11,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.v, this.color, this.track);
  final double v;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.width / 2 - 2.5,
    );
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(r, 0, math.pi * 2, false, p..color = track);
    canvas.drawArc(
      r,
      -math.pi / 2,
      math.pi * 2 * v.clamp(0.02, 1.0),
      false,
      p..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.v != v || old.color != color;
}

/// Legende der Heatmap: Verlauf mit Grenzen, dazu der Wert draußen.
class HeatLegend extends StatelessWidget {
  const HeatLegend({super.key, required this.data});
  final HeatData data;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final s = data.scale;
    final unit = data.kind.unit;
    String f(double v) =>
        '${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1).replaceAll('.', ',')}$unit';
    final title = data.kind == HeatKind.temperature
        ? 'Temperatur innen'
        : 'Luftfeuchte innen';
    final out = data.outsideValue;
    return Row(
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s == null ? '$title: keine Messung' : title,
                style: HavenText.label.copyWith(color: hv.tx, fontSize: 13.5),
              ),
              if (s != null) ...[
                const SizedBox(height: 7),
                Container(
                  height: 10,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(5),
                    gradient: LinearGradient(colors: data.kind.ramp.colors),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      f(s.lo),
                      style: HavenText.caption.copyWith(color: hv.tx2),
                    ),
                    const Spacer(),
                    Text(
                      f((s.lo + s.hi) / 2),
                      style: HavenText.caption.copyWith(color: hv.tx3),
                    ),
                    const Spacer(),
                    Text(
                      f(s.hi),
                      style: HavenText.caption.copyWith(color: hv.tx2),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (out != null) ...[
          const SizedBox(width: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: hv.ok.withValues(alpha: hv.isDark ? 0.12 : 0.1),
              borderRadius: BorderRadius.circular(HavenRadii.s),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.park_outlined, size: 13, color: hv.ok),
                    const SizedBox(width: 4),
                    Text(
                      kOutsideName,
                      style: HavenText.caption.copyWith(
                        color: hv.tx2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                Text(
                  '${heatValue(out, data.kind)}$unit',
                  style: HavenText.headline.copyWith(color: hv.tx),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Zeitstrahl der letzten [window] mit den Bewegungen je Melder als Balken.
class MotionTimeline extends StatelessWidget {
  const MotionTimeline({
    super.key,
    required this.history,
    required this.now,
    required this.minutes,
    required this.onChanged,
    this.window = const Duration(minutes: 60),
  });

  final Map<String, List<StateChange>> history;
  final DateTime now;

  /// Gewählter Zeitpunkt in Minuten vor jetzt (0 = jetzt, negativ).
  final double minutes;
  final ValueChanged<double> onChanged;
  final Duration window;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final w = window.inMinutes.toDouble();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 14,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: CustomPaint(
              size: const Size(double.infinity, 14),
              painter: _TimelinePainter(
                history: history,
                now: now,
                window: window,
                color: presenceColor(hv),
                track: hv.s2,
              ),
            ),
          ),
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            activeTrackColor: hv.acc,
            inactiveTrackColor: hv.s3,
            thumbColor: hv.acc,
            overlayColor: hv.acc.withValues(alpha: 0.14),
          ),
          child: SizedBox(
            height: 30,
            child: Slider(
              value: minutes.clamp(-w, 0),
              min: -w,
              max: 0,
              divisions: window.inMinutes,
              semanticFormatterCallback: (v) =>
                  v == 0 ? 'jetzt' : 'vor ${(-v).round()} Minuten',
              onChanged: onChanged,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Text(
                'vor ${window.inMinutes} min',
                style: HavenText.caption.copyWith(color: hv.tx3),
              ),
              const Spacer(),
              Text('jetzt', style: HavenText.caption.copyWith(color: hv.tx3)),
            ],
          ),
        ),
      ],
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter({
    required this.history,
    required this.now,
    required this.window,
    required this.color,
    required this.track,
  });
  final Map<String, List<StateChange>> history;
  final DateTime now;
  final Duration window;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final start = now.subtract(window);
    double x(DateTime t) =>
        size.width *
        (t.difference(start).inMilliseconds / window.inMilliseconds).clamp(
          0.0,
          1.0,
        );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, size.height / 2 - 2, size.width, 4),
        const Radius.circular(2),
      ),
      Paint()..color = track,
    );
    final p = Paint()..color = color.withValues(alpha: 0.85);
    for (final list in history.values) {
      for (var i = 0; i < list.length; i++) {
        if (!list[i].isOn) continue;
        final a = x(list[i].at);
        final b = i + 1 < list.length ? x(list[i + 1].at) : size.width;
        if (b <= 0 || a >= size.width) continue;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(a, 2, math.max(a + 3, b), size.height - 2),
            const Radius.circular(3),
          ),
          p,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_TimelinePainter old) =>
      old.history != history || old.now != now || old.color != color;
}
