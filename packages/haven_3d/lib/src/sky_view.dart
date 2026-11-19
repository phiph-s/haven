import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'camera.dart';
import 'model.dart';
import 'sky.dart';
import 'view.dart';

/// Himmel um eine 3D-Ansicht: Sonne mit leichtem Blendeffekt, nachts Mond
/// (mit Phase) und Sterne, Wolken nach dem Grad der Bewölkung (um die
/// Wohnung herum, nicht über ihr) und Regen mit Spritzern auf dem Boden.
///
/// Sonne und Mond stehen auf der Seite, von der ihr Licht kommt: Die
/// Richtung zu ihnen wird mit der Kamera auf den Bildschirm projiziert, so
/// passen sie zu den Schatten. Alles ist 2D und billig: Wolken sind einmal
/// vorgerenderte Bilder, die nur verschoben werden, Sterne ein fester
/// Punktsatz. Die Animation läuft nur bei Regen, Schnee oder Gewitter;
/// Wolken und Sterne stehen still.
///
/// [child] ist die 3D-Ansicht (durchsichtiger Hintergrund); der Himmel liegt
/// dahinter, Blendung und ein Teil der Wolken davor.
class SkyLayers extends StatefulWidget {
  const SkyLayers({
    super.key,
    required this.sky,
    required this.controller,
    required this.child,
    this.center = V3.zero,
    this.extent,
    this.height = 2.5,
    this.animate = true,
    this.insets = EdgeInsets.zero,
    this.dark = false,
  });

  final SceneSky sky;

  /// Dunkles Design: Sonne etwas gedämpft (die Farben des Himmels kommen
  /// vom Hintergrund, siehe [paintSkyBackdrop]).
  final bool dark;

  /// Verdeckte Ränder (Kopf, Leisten, Seitenspalte): Sonne und Mond stehen
  /// nur in der freien Fläche.
  final EdgeInsets insets;

  /// Kamera der 3D-Ansicht (für die Lage von Sonne und Mond).
  final SceneController controller;

  /// Mitte der Szene (Welt), von der aus Sonne und Mond gepeilt werden.
  final V3 center;

  /// Grundfläche der Wohnung (Welt, Meter) und ihre Höhe: Wolken ziehen um
  /// diese Fläche herum, Regen ist über ihr leiser.
  final Rect? extent;
  final double height;
  final bool animate;
  final Widget child;

  @override
  State<SkyLayers> createState() => _SkyLayersState();
}

class _SkyLayersState extends State<SkyLayers>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final ValueNotifier<double> _time = ValueNotifier(0);
  List<ui.Image>? _clouds;

  void _tick(Duration d) => _time.value = d.inMilliseconds / 1000;

  bool get _moving {
    final s = widget.sky;
    return widget.animate &&
        // Nur Regen, Schnee und Gewitter bewegen sich; Wolken und Sterne
        // stehen still (spart in der App Bilder, den ganzen Tag lang).
        (s.wetness > 0.02 || s.snow > 0.02 || s.storm > 0.02);
  }

  void _sync() {
    if (_moving && !_ticker.isActive) _ticker.start();
    if (!_moving && _ticker.isActive) _ticker.stop();
  }

  @override
  void initState() {
    super.initState();
    _clouds = [for (var i = 0; i < 3; i++) _cloudSprite(i)];
    _sync();
  }

  @override
  void didUpdateWidget(SkyLayers old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    for (final c in _clouds ?? const <ui.Image>[]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repaint = Listenable.merge([widget.controller, _time]);
    _SkyFrame frame() => _SkyFrame(
      sky: widget.sky,
      camera: widget.controller.camera,
      center: widget.center,
      extent: widget.extent,
      height: widget.height,
      insets: widget.insets,
      time: _time.value,
      clouds: _clouds!,
      dark: widget.dark,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _SkyPainter(frame, repaint, front: false),
            ),
          ),
        ),
        widget.child,
        IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _SkyPainter(frame, repaint, front: true),
            ),
          ),
        ),
      ],
    );
  }
}

double _smooth(double a, double b, double x) {
  final t = ((x - a) / (b - a)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// Wie dunkel es ist (0 Tag … 1 Nacht).
double _night(SceneSky s) => 1 - _smooth(-12, -1, s.sunElevation);

class _SkyFrame {
  _SkyFrame({
    required this.sky,
    required this.camera,
    required this.center,
    required this.extent,
    required this.height,
    required this.insets,
    required this.time,
    required this.clouds,
    this.dark = false,
  });
  final bool dark;
  final EdgeInsets insets;
  final SceneSky sky;
  final OrbitCamera camera;
  final V3 center;
  final Rect? extent;
  final double height;
  final double time;
  final List<ui.Image> clouds;
}

class _SkyPainter extends CustomPainter {
  _SkyPainter(this.frame, Listenable repaint, {required this.front})
    : super(repaint: repaint);

  final _SkyFrame Function() frame;

  /// Vor der Szene: Blendung und einige Wolken; dahinter: Sterne, Mond,
  /// Sonne, die übrigen Wolken.
  final bool front;

  /// Bildschirmpunkt der Himmelsrichtung [dir] (Welt) auf der
  /// Himmelskugel, `null` wenn sie nicht im Bild liegt.
  Offset? _placed(_SkyFrame f, Size size, V3 dir) =>
      _SkyDome(f.camera, Offset.zero & size).project(dir);

  /// Sichtbare Fläche ohne die verdeckten Ränder (zu klein: alles).
  static Rect _free(_SkyFrame f, Size size) {
    final all = Offset.zero & size;
    final area = f.insets.deflateRect(all);
    return area.width < 120 || area.height < 120 ? all : area;
  }

  /// Die Wohnung auf dem Bildschirm (Umriss aus Boden und Wandhöhe, mit
  /// [floorOnly] nur die Grundfläche).
  Rect _home(_SkyFrame f, Size size, {bool floorOnly = false}) {
    final e = f.extent;
    if (e == null) {
      final c = f.camera.project(f.center, size).offset;
      return Rect.fromCenter(center: c, width: 1, height: 1);
    }
    Rect? r;
    for (final x in [e.left, e.right]) {
      for (final y in [e.top, e.bottom]) {
        for (final z in [0.0, if (!floorOnly) f.height]) {
          final p = f.camera.project(V3(x, y, z), size).offset;
          r = r == null
              ? Rect.fromPoints(p, p)
              : r.expandToInclude(Rect.fromPoints(p, p));
        }
      }
    }
    return r!;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final f = frame();
    final s = f.sky;
    final night = _night(s);
    final cloud = s.cover;
    final home = _home(f, size);
    final sunUp = _smooth(-5, 2, s.sunElevation);
    final moonUp = _smooth(-3, 3, s.moonElevation);
    final sunAt = _placed(f, size, s.sunVector);
    final moonAt = _placed(f, size, s.moonVector);
    final unit = math.min(size.width, size.height);

    if (!front) {
      // Sterne: fester Satz auf der Himmelskuppel (dreht mit der Kamera wie
      // Sonne und Mond), hinter Wolken weg.
      final stars = night * (1 - 0.85 * cloud);
      if (stars > 0.02) _stars(canvas, size, f, stars);
    }
    // Wolken vorn: Sie ziehen um die Wohnung, nie über sie, und liegen so
    // auch über einem großen Boden (Dunst) sichtbar.
    // Wolken hinter der Wohnung liegen hinter der Szene (das Haus verdeckt
    // sie), die davor vorn und durchsichtig, wo sie die Wohnung verdecken.
    if (cloud > 0.02) {
      _clouds(canvas, size, f, home, cloud, night, front: front);
    }
    if (front && s.wetness > 0.02) {
      _rain(canvas, size, f, home, _home(f, size, floorOnly: true), night);
    }
    if (front && s.snow > 0.02) _snow(canvas, size, f, s.snow, night);
    if (front && s.storm > 0.02) {
      _lightning(canvas, size, f.time, s.storm, home);
    }
    if (front) {
      // Mond und Sonne vorn (sonst lägen sie hinter Boden und Wohnung),
      // Wolken dämpfen sie.
      final moonA = moonUp * (0.3 + 0.7 * night) * (1 - 0.9 * cloud);
      if (moonA > 0.02 && moonAt != null) {
        _moon(canvas, moonAt, unit * 0.03, s, moonA);
      }
      final sunA = sunUp * (1 - 0.85 * cloud) * (f.dark ? 0.8 : 1);
      if (sunA > 0.02 && sunAt != null) {
        _sun(canvas, sunAt, unit * 0.035, s, sunA);
      }
      // Leichte Blendung über allem, nur bei freier Sonne.
      final glare = sunUp * (1 - cloud) * (1 - night);
      if (glare > 0.02 && sunAt != null) _glare(canvas, size, sunAt, glare, s);
    }
  }

  void _sun(Canvas canvas, Offset at, double r, SceneSky s, double a) {
    final warm = _smooth(2, 30, s.sunElevation);
    final core = Color.lerp(
      const Color(0xFFFFD08A),
      const Color(0xFFFFFBEF),
      warm,
    )!;
    canvas.drawCircle(
      at,
      r * 4,
      Paint()
        ..shader = ui.Gradient.radial(at, r * 4, [
          core.withValues(alpha: 0.45 * a),
          core.withValues(alpha: 0),
        ]),
    );
    canvas.drawCircle(at, r, Paint()..color = core.withValues(alpha: a));
  }

  void _moon(Canvas canvas, Offset at, double r, SceneSky s, double a) {
    canvas.drawCircle(
      at,
      r * 3,
      Paint()
        ..shader = ui.Gradient.radial(at, r * 3, [
          // Der Hof wächst mit dem hellen Anteil.
          const Color(
            0xFFCFDCFF,
          ).withValues(alpha: 0.25 * a * (0.25 + 0.75 * s.moonIllumination)),
          const Color(0x00CFDCFF),
        ]),
    );
    // Dunkler Teil ganz schwach (Erdschein), dann der helle Teil: eine
    // Seite des Rands plus der Terminator als Halbellipse.
    canvas.drawCircle(
      at,
      r,
      Paint()..color = const Color(0xFF9AA6C0).withValues(alpha: 0.16 * a),
    );
    final lit = s.moonIllumination.clamp(0.0, 1.0);
    if (lit > 0.01) {
      canvas.drawPath(
        moonLitPath(at, r, lit, waxing: s.moonPhase < 0.5),
        Paint()..color = const Color(0xFFF2F4F8).withValues(alpha: a),
      );
    }
  }

  /// Sterne auf der Himmelskugel: Richtung (Welt, Länge 1, über dem
  /// Horizont oder darunter), Größe und Phase des Funkelns. Gleichmäßig verteilt.
  static final List<(V3, double, double)> _starField = () {
    final rnd = math.Random(7);
    final out = <(V3, double, double)>[];
    while (out.length < 2800) {
      final z = rnd.nextDouble() * 2 - 1;
      final a = rnd.nextDouble() * math.pi * 2;
      final r = math.sqrt(1 - z * z);
      // Ein paar helle, viele schwache.
      final m = rnd.nextDouble();
      out.add((
        V3(r * math.cos(a), r * math.sin(a), z),
        0.45 + m * m * m * 1.6,
        rnd.nextDouble() * math.pi * 2,
      ));
    }
    return out;
  }();

  void _stars(Canvas canvas, Size size, _SkyFrame f, double a) {
    final p = Paint();
    final dome = _SkyDome(f.camera, Offset.zero & size);
    final ground = skyGroundFade(f.camera);
    final bounds = (Offset.zero & size).inflate(4);
    for (final (d, r, ph) in _starField) {
      final at = dome.project(d);
      if (at == null || !bounds.contains(at)) continue;
      // Zum Horizont hin im Dunst schwächer; unter dem Horizont nur, soweit
      // der Boden weggeblendet ist (Draufsicht).
      final haze = d.z >= 0
          ? _smooth(0.02, 0.25, d.z)
          : (1 - ground) * _smooth(0.02, 0.25, -d.z);
      if (haze <= 0.01) continue;
      final tw = 0.7 + 0.3 * math.sin(f.time * 1.3 + ph);
      p.color = const Color(0xFFFFFFFF).withValues(alpha: a * tw * 0.85 * haze);
      canvas.drawCircle(at, r, p);
    }
  }

  /// Grundfläche der Wohnung in der Welt (Meter).
  Rect _area(_SkyFrame f) =>
      f.extent ?? Rect.fromCenter(center: f.center.xy, width: 8, height: 8);

  Offset _pt(_SkyFrame f, Size size, double x, double y, double z) =>
      f.camera.project(V3(x, y, z), size).offset;

  /// Bildpunkte je Meter am Boden (für Größen in der Welt).
  double _ppm(_SkyFrame f, Size size, Offset c) {
    final o = _pt(f, size, c.dx, c.dy, 0);
    final ax = _pt(f, size, c.dx + 1, c.dy, 0);
    final ay = _pt(f, size, c.dx, c.dy + 1, 0);
    return math.max((ax - o).distance, (ay - o).distance);
  }

  /// Punkt knapp außerhalb der Wohnung (fast rechteckiger Ring) unter
  /// Winkel [ang], [d] Meter von der Außenwand.
  static Offset _around(Rect a, double ang, double d) {
    final u = math.cos(ang), v = math.sin(ang);
    double sq(double x) => x.sign * math.pow(x.abs(), 0.3).toDouble();
    return a.center +
        Offset(sq(u) * (a.width / 2 + d), sq(v) * (a.height / 2 + d));
  }

  /// Wolken in der Welt: auf einem Ring um die Wohnung, ein paar Meter über
  /// dem Dach, fest an ihrem Platz. Sie drehen mit der Kamera mit.
  void _clouds(
    Canvas canvas,
    Size size,
    _SkyFrame f,
    Rect home,
    double cloud,
    double night, {
    required bool front,
  }) {
    final area = _area(f);
    final ppm = _ppm(f, size, area.center);
    final rnd = math.Random(11);
    // Wenige, große Wolken.
    final n = (2 + cloud * 5).round();
    // Nachts vom Mond kaum beleuchtet, tagsüber weiß bis grau (bedeckt).
    final day = Color.lerp(
      const Color(0xFFFFFFFF),
      const Color(0xFFB9C0C8),
      cloud,
    )!;
    final tint = Color.lerp(day, const Color(0xFF39404C), night)!;
    final paint = Paint()
      ..colorFilter = ColorFilter.mode(tint, BlendMode.modulate)
      ..filterQuality = FilterQuality.low;
    for (var i = 0; i < n; i++) {
      final a0 = rnd.nextDouble() * math.pi * 2;
      // Tief und etwas abseits: wie Dunst um das Haus, nicht über ihm.
      final dist = 3.5 + rnd.nextDouble() * 4;
      final z = f.height * 0.5 + rnd.nextDouble() * 0.8;
      final meters = (6 + rnd.nextDouble() * 4) * (0.85 + cloud * 0.4);
      final img = f.clouds[i % f.clouds.length];
      // Fest an ihrem Platz: ziehende Wolken lenkten ab (und sprangen auf
      // dem gestauchten Ring an den Seiten schnell hinüber).
      final at = _around(area, a0, dist);
      final vp = f.camera.project(V3(at.dx, at.dy, z), size);
      // Näher an der Kamera als die Mitte der Wohnung: davor.
      final mid = f.camera.project(V3(area.center.dx, area.center.dy, z), size);
      final isFront = vp.depth > mid.depth;
      if (isFront != front) continue;
      final w = meters * ppm;
      final h = w * img.height / img.width;
      final rect = Rect.fromCenter(center: vp.offset, width: w, height: h);
      var alpha = (0.6 + 0.35 * cloud) * (0.55 + 0.45 * cloud);
      if (front) {
        // Durchsichtig, soweit die Wolke die Wohnung verdeckt.
        final hit = rect.intersect(home);
        final cover = hit.isEmpty
            ? 0.0
            : (hit.width * hit.height) / (rect.width * rect.height);
        alpha *= 1 - (cover * 2.5).clamp(0.0, 0.9);
      }
      if (alpha < 0.02) continue;
      paint.color = Color.fromRGBO(255, 255, 255, alpha);
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        rect,
        paint,
      );
    }
  }

  /// Feste Tropfen (Lage, Länge, Geschwindigkeit, Startphase), einmal erzeugt.
  static final List<(double, double, double, double, double)> _drops = () {
    final rnd = math.Random(23);
    return [
      for (var i = 0; i < 300; i++)
        (
          rnd.nextDouble(),
          rnd.nextDouble(),
          0.6 + rnd.nextDouble() * 0.8,
          0.8 + rnd.nextDouble() * 0.5,
          rnd.nextDouble(),
        ),
    ];
  }();

  /// Regen in der Welt: Tropfen fallen über und um die Wohnung (über der
  /// Wohnung leiser), dazu Spritzer auf dem Boden dicht an den Außenwänden.
  /// Ein Zeichenaufruf je Helligkeit; alles dreht mit der Kamera.
  void _rain(
    Canvas canvas,
    Size size,
    _SkyFrame f,
    Rect home,
    Rect floor,
    double night,
  ) {
    final r = f.sky.wetness;
    final area = _area(f);
    final box = area.inflate(4);
    final n = (_drops.length * (0.25 + 0.75 * r)).round();
    const top = 7.0;
    final outside = <Offset>[], inside = <Offset>[];
    for (var i = 0; i < n; i++) {
      final (x0, y0, l, v, ph) = _drops[i];
      final x = box.left + x0 * box.width;
      final y = box.top + y0 * box.height;
      final z = top - ((ph + f.time * 1.6 * v) % 1.0) * top;
      final a = _pt(f, size, x, y, z);
      // Etwas Wind: leicht schräg.
      final b = _pt(f, size, x - 0.06 * l, y, z - 0.45 * l);
      (area.contains(Offset(x, y)) ? inside : outside)
        ..add(a)
        ..add(b);
    }
    final col = Color.lerp(
      const Color(0xFFDDE6F0),
      const Color(0xFF8EA0B8),
      night,
    )!;
    final p = Paint()
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round;
    canvas.drawPoints(
      ui.PointMode.lines,
      outside,
      p..color = col.withValues(alpha: 0.35 + 0.3 * r),
    );
    canvas.drawPoints(
      ui.PointMode.lines,
      inside,
      p..color = col.withValues(alpha: 0.12 + 0.1 * r),
    );
    // Spritzer: kleine Ringe auf dem Boden dicht an den Außenwänden, flach
    // wie der Boden unter der Kamera.
    final ppm = _ppm(f, size, area.center);
    final flat = math.cos(f.camera.pitch).clamp(0.25, 1.0);
    final rnd = math.Random(5);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final m = (14 + 36 * r).round();
    for (var i = 0; i < m; i++) {
      final ang = rnd.nextDouble() * math.pi * 2;
      final d = 0.15 + rnd.nextDouble() * 0.8;
      final ph = (f.time * (0.9 + rnd.nextDouble()) + rnd.nextDouble()) % 1.0;
      final w = _around(area, ang, d);
      final at = _pt(f, size, w.dx, w.dy, 0);
      final rad = (0.04 + ph * 0.16) * ppm;
      ring.color = col.withValues(alpha: (1 - ph) * 0.55 * r);
      canvas.drawOval(
        Rect.fromCenter(center: at, width: rad * 2, height: rad * 2 * flat),
        ring,
      );
    }
  }

  /// Feste Flocken (Lage, Größe, Fallgeschwindigkeit, Phase).
  static final List<(double, double, double, double, double)> _flakes = () {
    final rnd = math.Random(41);
    return [
      for (var i = 0; i < 300; i++)
        (
          rnd.nextDouble(),
          rnd.nextDouble(),
          rnd.nextDouble(),
          0.6 + rnd.nextDouble() * 0.8,
          rnd.nextDouble() * math.pi * 2,
        ),
    ];
  }();

  /// Schnee in der Welt: langsam fallende, leicht schwankende Flocken über
  /// und um die Wohnung, drei Größen (drei Zeichenaufrufe).
  void _snow(
    Canvas canvas,
    Size size,
    _SkyFrame f,
    double amount,
    double night,
  ) {
    final area = _area(f).inflate(4);
    final t = f.time;
    final n = (_flakes.length * amount.clamp(0.0, 1.0)).round();
    final buckets = [<Offset>[], <Offset>[], <Offset>[]];
    const top = 6.0;
    for (var i = 0; i < n; i++) {
      final (x0, y0, sz, v, ph) = _flakes[i];
      final z = top - ((ph / (math.pi * 2) + t * 0.12 * v) % 1.0) * top;
      final x = area.left + x0 * area.width + math.sin(t * 0.9 * v + ph) * 0.3;
      final y = area.top + y0 * area.height;
      buckets[(sz * 3).floor().clamp(0, 2)].add(_pt(f, size, x, y, z));
    }
    final col = Color.lerp(
      const Color(0xFFFFFFFF),
      const Color(0xFFB8C4D8),
      night,
    )!;
    final p = Paint()..strokeCap = StrokeCap.round;
    for (var b = 0; b < 3; b++) {
      canvas.drawPoints(
        ui.PointMode.points,
        buckets[b],
        p
          ..strokeWidth = 1.8 + b * 1.3
          ..color = col.withValues(alpha: 0.55 + 0.15 * b),
      );
    }
  }

  /// Gewitter: in unregelmäßigen Abständen ein Blitz (flackernde Aufhellung
  /// des ganzen Bilds, ein gezackter Strahl in Richtung Haus). Kostet nur
  /// während eines Blitzes etwas.
  void _lightning(Canvas canvas, Size size, double t, double storm, Rect home) {
    final flash = lightningFlash(t, storm);
    if (flash <= 0) return;
    final slot = 7.0 - 3.5 * storm.clamp(0.0, 1.0);
    final rnd = math.Random((t / slot).floor() * 7919 + 13)..nextDouble();
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..blendMode = BlendMode.screen
        ..color = const Color(
          0xFFE6ECFF,
        ).withValues(alpha: 0.45 * flash * storm),
    );
    if (flash < 0.4) return;
    // Strahl von oben bis knapp an die Wohnung, mit Zacken.
    final x0 = size.width * (0.15 + rnd.nextDouble() * 0.7);
    final end = Offset(
      home.center.dx + (rnd.nextDouble() - 0.5) * home.width * 1.4,
      home.top - 4,
    );
    final path = Path()..moveTo(x0, 0);
    const steps = 9;
    for (var i = 1; i <= steps; i++) {
      final q = Offset.lerp(Offset(x0, 0), end, i / steps)!;
      path.lineTo(q.dx + (i < steps ? (rnd.nextDouble() - 0.5) * 36 : 0), q.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..color = const Color(0xFFB8C8FF).withValues(alpha: 0.35 * flash)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xFFFFFFFF).withValues(alpha: flash),
    );
  }

  void _glare(Canvas canvas, Size size, Offset sun, double a, SceneSky s) {
    final unit = math.min(size.width, size.height);
    final warm = _smooth(2, 30, s.sunElevation);
    final c = Color.lerp(
      const Color(0xFFFFB46B),
      const Color(0xFFFFF6E0),
      warm,
    )!;
    // Weicher Schein vom Sonnenrand ins Bild.
    canvas.drawCircle(
      sun,
      unit * 0.55,
      Paint()
        ..blendMode = BlendMode.screen
        ..shader = ui.Gradient.radial(sun, unit * 0.55, [
          c.withValues(alpha: 0.22 * a),
          c.withValues(alpha: 0),
        ]),
    );
    // Ein paar Linsenreflexe auf der Linie durch die Mitte der freien
    // Fläche.
    final mid = _free(frame(), size).center;
    for (final (k, r, al) in const [
      (0.35, 0.03, 0.10),
      (0.7, 0.05, 0.07),
      (1.25, 0.02, 0.12),
      (1.6, 0.07, 0.05),
    ]) {
      final p = Offset.lerp(sun, mid, k)!;
      canvas.drawCircle(
        p,
        unit * r,
        Paint()
          ..blendMode = BlendMode.screen
          ..color = c.withValues(alpha: al * a),
      );
    }
  }

  @override
  bool shouldRepaint(_SkyPainter old) => true;
}

/// Eine weiche Wolke als Bild (einmal gerendert, danach nur gezeichnet):
/// mehrere überlappende Kreise mit weichem Rand.
ui.Image _cloudSprite(int seed) {
  // Bauschig: viele weiche Kreise, unten flacher, oben aufgetürmt.
  const w = 320, h = 170;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  final rnd = math.Random(seed * 31 + 5);
  for (var i = 0; i < 16; i++) {
    final t = rnd.nextDouble();
    final cx = 50 + t * (w - 100);
    // In der Mitte höher aufgetürmt.
    final lift = math.sin(t * math.pi) * 34;
    final cy = 112 - lift - rnd.nextDouble() * 18;
    final r = 26 + rnd.nextDouble() * 26 + lift * 0.5;
    c.drawCircle(
      Offset(cx, cy),
      r,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(cx, cy),
          r,
          const [Color(0xCCFFFFFF), Color(0x66FFFFFF), Color(0x00FFFFFF)],
          const [0, 0.6, 1],
        ),
    );
  }
  return rec.endRecording().toImageSync(w, h);
}

/// Heller Teil der Mondscheibe um [c] mit Radius [r] bei beleuchtetem Anteil
/// [lit] (0 … 1). Zunehmend ist die rechte Seite hell, abnehmend die linke.
@visibleForTesting
Path moonLitPath(Offset c, double r, double lit, {required bool waxing}) {
  // Terminator: Halbellipse mit Halbachse |1 − 2·lit|·r; bei einer Sichel
  // wölbt sie sich zur hellen Seite, bei mehr als halb zur dunklen.
  final k = 1 - 2 * lit.clamp(0.0, 1.0);
  final a = r * k.abs();
  final path = Path()
    ..moveTo(c.dx, c.dy - r)
    // Rand: rechte Hälfte von oben nach unten.
    ..arcTo(Rect.fromCircle(center: c, radius: r), -math.pi / 2, math.pi, false)
    // Zurück nach oben über den Terminator.
    ..arcTo(
      Rect.fromCenter(center: c, width: 2 * math.max(a, 0.01), height: 2 * r),
      math.pi / 2,
      k > 0 ? -math.pi : math.pi,
      false,
    )
    ..close();
  if (waxing) return path;
  // Abnehmend: gespiegelt (linke Seite hell).
  final m = Matrix4.identity()
    ..translateByDouble(c.dx, 0, 0, 1)
    ..scaleByDouble(-1, 1, 1, 1)
    ..translateByDouble(-c.dx, 0, 0, 1);
  return path.transform(m.storage);
}

/// Helligkeit eines Blitzes zur Zeit [t] (Sekunden) bei Gewitter [storm]:
/// je Zeitfenster (7 s, heftig 3,5 s) ein Blitz an zufälliger, fester Stelle,
/// doppelt flackernd und abklingend; sonst 0.
@visibleForTesting
double lightningFlash(double t, double storm) {
  if (storm <= 0) return 0;
  final slot = 7.0 - 3.5 * storm.clamp(0.0, 1.0);
  final k = (t / slot).floor();
  final rnd = math.Random(k * 7919 + 13);
  final u = t - (k * slot + rnd.nextDouble() * (slot - 1));
  if (u < 0 || u > 0.6) return 0;
  return u < 0.06
      ? 1.0
      : u < 0.12
      ? 0.25
      : u < 0.2
      ? 0.85
      : math.exp(-(u - 0.2) * 9);
}

/// Farben des Hintergrunds: Himmel oben (Zenit), am Horizont und Boden
/// darunter.
@immutable
class SkyColors {
  const SkyColors({
    required this.zenith,
    required this.horizon,
    required this.ground,
  });
  final Color zenith;
  final Color horizon;
  final Color ground;

  @override
  bool operator ==(Object other) =>
      other is SkyColors &&
      other.zenith == zenith &&
      other.horizon == horizon &&
      other.ground == ground;

  @override
  int get hashCode => Object.hash(zenith, horizon, ground);
}

/// Halber senkrechter Blickwinkel der Himmelskugel (perspektivisch, auch
/// wenn die Karte orthografisch ist).
const double _kSkyHalfFov = 55 * math.pi / 180;

/// Himmelskugel: eine feste Kugel um die Szene. Richtungen (Welt) kommen
/// über die Blickrichtung der Kartenkamera aufs Bild, perspektivisch mit
/// [_kSkyHalfFov]. Drehen und Kippen bewegen Himmel und Wohnung gemeinsam;
/// der Horizont liegt, wo er liegt (schräg oben im Bild, in der Draufsicht
/// gar nicht sichtbar).
class _SkyDome {
  _SkyDome(OrbitCamera cam, Rect view)
    : _center = view.center,
      _focal = (view.height / 2) / math.tan(_kSkyHalfFov) {
    final b = cam.basis;
    _right = b.right;
    _down = b.down;
    _fwd = -b.toCam;
  }

  final Offset _center;
  final double _focal;
  late final V3 _right;
  late final V3 _down;
  late final V3 _fwd;

  /// Bildpunkt der Richtung [dir], `null` hinter der Kamera.
  Offset? project(V3 dir) {
    final d = dir.normalized;
    final z = d.dot(_fwd);
    if (z <= 0.05) return null;
    return _center + Offset(d.dot(_right) / z, d.dot(_down) / z) * _focal;
  }

  /// Höhe des Horizonts im Bild, `null` wenn die Kamera senkrecht nach
  /// unten schaut (kein Himmel im Bild).
  double? get horizonY {
    final h = V3(_fwd.x, _fwd.y, 0);
    if (h.length < 1e-4) return null;
    final d = h.normalized;
    final z = d.dot(_fwd);
    if (z <= 1e-4) return null;
    return _center.dy + _focal * d.dot(_down) / z;
  }

  /// Bildhöhe je Einheit des Tangens nahe der Bildmitte (für Abstände).
  double get focal => _focal;
}

/// Wie viel Boden unter dem Horizont zu sehen ist (0 … 1): schräg ganz, zur
/// Draufsicht hin blendet er weg (dort zeigt die Kugel Himmel und Sterne).
double skyGroundFade(OrbitCamera camera) => _smooth(0.12, 0.5, camera.pitch);

/// Hintergrund der Himmelskugel für [camera]: Himmel über dem Horizont
/// (Zenit- in Horizontfarbe), darunter der Boden. [view] ist die Fläche der
/// 3D-Ansicht in den Koordinaten von [canvas], [area] die zu füllende.
void paintSkyBackdrop(
  Canvas canvas,
  Rect area,
  Rect view,
  OrbitCamera camera,
  SkyColors colors,
) {
  final dome = _SkyDome(camera, view);
  final y = dome.horizonY;
  final paint = Paint();
  // Zur Draufsicht hin blendet der Boden weg: dort ist Himmel.
  final ground = Color.lerp(
    colors.zenith,
    colors.ground,
    skyGroundFade(camera),
  )!;
  if (y == null) {
    paint.color = ground;
  } else {
    // Zenitfarbe etwa 50° über dem Horizont, Boden kurz darunter.
    final top = y - dome.focal * 1.2;
    final blend = view.height * 0.05;
    final y0 = math.min(area.top, top), y1 = math.max(area.bottom, y + blend);
    double at(double v) => ((v - y0) / (y1 - y0)).clamp(0.0, 1.0);
    paint.shader = ui.Gradient.linear(
      Offset(0, y0),
      Offset(0, y1),
      [colors.zenith, colors.zenith, colors.horizon, ground],
      [0, at(top), at(y), at(y + blend)],
    );
  }
  canvas.drawRect(area, paint);
}
