import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:material_ui/material_ui.dart';

import '../../core/theme/tokens.dart';
import '../../data/models/floor_plan.dart';

/// Ein Knoten auf dem Grundriss: ein Widget an einem raumrelativen Punkt.
/// [id] ist frei wählbar (Entity-ID, Geräte-ID, `coordinator`) und taucht in
/// [FloorGeometry.nodes] und den Callbacks wieder auf.
@immutable
class FloorNode {
  const FloorNode({required this.id, required this.point, this.size = 48});
  final String id;
  final PlanPoint point;

  /// Kantenlänge der Trefferfläche. Das Widget wird darin zentriert.
  final double size;
}

/// Pixel-Geometrie des Grundrisses zu einem Zeitpunkt der Animation.
/// Alle Maße im Koordinatensystem der Zeichenfläche (vor Zoom und Pan).
@immutable
class FloorGeometry {
  const FloorGeometry({
    required this.size,
    required this.scale,
    required this.origin,
    required this.gap,
    required this.rooms,
    required this.nodes,
  });

  final Size size;

  /// Pixel je Zelle.
  final double scale;

  /// Pixelposition der Zelle (0, 0).
  final Offset origin;

  /// Aktueller (animierter) Abstand in Zellen.
  final double gap;

  /// Raumrechtecke in Pixeln nach Raum-ID.
  final Map<String, Rect> rooms;

  /// Knotenmitten in Pixeln nach Knoten-ID.
  final Map<String, Offset> nodes;

  Offset cellToPx(Offset c) => origin + c * scale;
  Offset pxToCell(Offset p) => (p - origin) / scale;

  /// Pixelposition eines raumrelativen Punkts.
  Offset pointToPx(PlanPoint p) {
    final r = rooms[p.roomId];
    if (r == null) return Offset.zero;
    return Offset(r.left + p.rx * r.width, r.top + p.ry * r.height);
  }

  /// Raum unter dem Pixel [p] oder `null`.
  String? roomAt(Offset p) {
    for (final e in rooms.entries) {
      if (e.value.contains(p)) return e.key;
    }
    return null;
  }

  /// Weich gerundete Fläche eines Raums (1,5 px Fuge zu den Nachbarn).
  static RRect roomShape(Rect r) {
    final inset = r.deflate(1.5);
    final radius = math.min(22.0, 0.16 * math.min(inset.width, inset.height));
    return RRect.fromRectAndRadius(inset, Radius.circular(radius));
  }

  static FloorGeometry compute({
    required HavenFloorPlan plan,
    required Size size,
    double gap = 0,
    List<FloorNode> nodes = const [],
    bool fitGrid = false,
    double padding = 12,
  }) {
    final cells = plan.layout(gap: gap);
    final bounds = fitGrid
        ? Rect.fromLTWH(
            0,
            0,
            plan.grid.cols.toDouble(),
            plan.grid.rows.toDouble(),
          )
        : plan.layoutBounds(gap: gap);
    final bw = math.max(bounds.width, 1.0);
    final bh = math.max(bounds.height, 1.0);
    final s = math.max(
      1.0,
      math.min(
        (size.width - 2 * padding) / bw,
        (size.height - 2 * padding) / bh,
      ),
    );
    final origin = Offset(
      size.width / 2 - bounds.center.dx * s,
      size.height / 2 - bounds.center.dy * s,
    );
    final rooms = {
      for (final e in cells.entries)
        e.key: Rect.fromLTWH(
          origin.dx + e.value.left * s,
          origin.dy + e.value.top * s,
          e.value.width * s,
          e.value.height * s,
        ),
    };
    final nodePx = <String, Offset>{};
    for (final n in nodes) {
      final r = rooms[n.point.roomId];
      if (r == null) continue;
      nodePx[n.id] = Offset(
        r.left + n.point.rx * r.width,
        r.top + n.point.ry * r.height,
      );
    }
    return FloorGeometry(
      size: size,
      scale: s,
      origin: origin,
      gap: gap,
      rooms: rooms,
      nodes: nodePx,
    );
  }
}

/// Darstellung eines Raums.
@immutable
class FloorRoomStyle {
  const FloorRoomStyle({this.fill, this.border, this.borderWidth = 1});
  final Color? fill;
  final Color? border;
  final double borderWidth;

  @override
  bool operator ==(Object other) =>
      other is FloorRoomStyle &&
      other.fill == fill &&
      other.border == border &&
      other.borderWidth == borderWidth;

  @override
  int get hashCode => Object.hash(fill, border, borderWidth);
}

/// Zeichenebene über oder unter den Räumen (Lichtkegel, Kanten, Pfeile,
/// Beschriftungen). Bekommt bei jedem Frame der Animation die aktuellen
/// Pixelrechtecke der Räume und die Knotenpositionen.
abstract class FloorOverlayPainter {
  const FloorOverlayPainter();

  void paint(Canvas canvas, Size size, FloorGeometry geometry);

  /// `true`, wenn sich gegenüber [old] etwas geändert hat.
  bool shouldRepaint(covariant FloorOverlayPainter old);

  /// Optional: zusätzliche Neuzeichnung (z. B. laufende Pfeile).
  Listenable? get repaint => null;
}

typedef FloorNodeBuilder = Widget Function(
  BuildContext context,
  FloorNode node,
);

/// Karte des Grundrisses: Räume als weiche Flächen, Knoten als Widgets an
/// raumrelativen Punkten, Zeichenebenen darunter und darüber, Zoom und Pan.
///
/// Schichten von unten: Raster (optional), Räume, [underlayPainter]
/// (z. B. Lichtkegel, auf den Raum zu clippen), Raumnamen, [overlayPainter]
/// (Kanten, Pfeile), Knoten.
///
/// Der Wechsel von [gap] animiert die Räume per Raumrechteck weich
/// auseinander oder zusammen. Die Knoten wandern mit, ihre Widgets werden
/// dabei nur per `Transform` verschoben, nicht neu gebaut oder gelayoutet.
class FloorPlanView extends StatefulWidget {
  const FloorPlanView({
    super.key,
    required this.plan,
    this.gap = 0,
    this.gapDuration = const Duration(milliseconds: 560),
    this.gapCurve = HavenMotion.out,
    this.reserveGap,
    this.nodes = const [],
    this.nodeBuilder,
    this.underlayPainter,
    this.overlayPainter,
    this.roomStyle,
    this.roomSubtitle,
    this.onRoomTap,
    this.onNodeTap,
    this.interactive = true,
    this.fitGrid = false,
    this.fill = false,
    this.showGrid = false,
    this.showLabels = true,
    this.padding = 12,
    this.minScale = 1,
    this.maxScale = 4,
    this.transformationController,
  });

  final HavenFloorPlan plan;

  /// Zusätzlicher Abstand zwischen allen Räumen in Zellen. Ändert er sich,
  /// fahren die Räume in [gapDuration] dorthin (Bewegungsreduzierung: sofort).
  final double gap;
  final Duration gapDuration;
  final Curve gapCurve;

  /// Abstand, für den die Höhe der Fläche reserviert wird. Standard: [gap].
  /// Für 0 bis 2 `reserveGap: 2` setzen, dann springt die Höhe nicht.
  final double? reserveGap;

  /// Knoten und ihr Widget. Fehlt [nodeBuilder], gibt es keine Knoten.
  final List<FloorNode> nodes;
  final FloorNodeBuilder? nodeBuilder;

  final FloorOverlayPainter? underlayPainter;
  final FloorOverlayPainter? overlayPainter;

  /// Stil je Raum, sonst Fläche `s1` mit Haarlinie.
  final FloorRoomStyle? Function(FloorRoom room)? roomStyle;

  /// Zweite Zeile unter dem Raumnamen, z. B. `22,2° · 45 %`.
  final String? Function(FloorRoom room)? roomSubtitle;

  final ValueChanged<FloorRoom>? onRoomTap;
  final ValueChanged<FloorNode>? onNodeTap;

  /// Zoom (Pinch) und Pan per `InteractiveViewer`.
  final bool interactive;

  /// Das ganze Raster einpassen statt nur die Räume (Editor).
  final bool fitGrid;

  /// Die ganze verfügbare Fläche nutzen (braucht beschränkte Höhe), sonst
  /// ergibt sich die Höhe aus dem Seitenverhältnis des Grundrisses.
  final bool fill;
  final bool showGrid;
  final bool showLabels;
  final double padding;
  final double minScale;
  final double maxScale;
  final TransformationController? transformationController;

  /// Größe der Zeichenfläche für den gegebenen Rahmen.
  static Size canvasSize({
    required HavenFloorPlan plan,
    required BoxConstraints constraints,
    double gap = 0,
    bool fitGrid = false,
    bool fill = false,
    double padding = 12,
  }) {
    final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 360.0;
    if (fill && constraints.hasBoundedHeight) {
      return Size(w, constraints.maxHeight);
    }
    final b = fitGrid
        ? Size(plan.grid.cols.toDouble(), plan.grid.rows.toDouble())
        : plan.layoutSize(gap: gap);
    final bw = math.max(b.width, 1.0);
    var h = (w - 2 * padding) * b.height / bw + 2 * padding;
    if (constraints.hasBoundedHeight) h = math.min(h, constraints.maxHeight);
    return Size(w, h);
  }

  @override
  State<FloorPlanView> createState() => _FloorPlanViewState();
}

class _FloorPlanViewState extends State<FloorPlanView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late double _from;
  late double _to;
  final _labels = _LabelCache();

  // Geometrie-Cache, damit Räume, Ebenen und Knoten pro Frame nur einmal
  // rechnen.
  FloorGeometry? _geo;
  double _geoT = -1;
  Size _geoSize = Size.zero;
  HavenFloorPlan? _geoPlan;
  List<FloorNode>? _geoNodes;
  double _geoFrom = 0;
  double _geoTo = 0;

  double get _gapNow =>
      _from + (_to - _from) * widget.gapCurve.transform(_c.value);

  @override
  void initState() {
    super.initState();
    _from = _to = widget.gap;
    _c = AnimationController(vsync: this, value: 1);
  }

  @override
  void didUpdateWidget(FloorPlanView old) {
    super.didUpdateWidget(old);
    if (old.gap != widget.gap) {
      _from = _gapNow;
      _to = widget.gap;
      final d = context.motion(widget.gapDuration);
      _c.duration = d;
      if (d == Duration.zero) {
        _c.value = 1;
      } else {
        _c.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  FloorGeometry _geometry(Size size) {
    final t = _c.value;
    if (_geo != null &&
        _geoT == t &&
        _geoSize == size &&
        identical(_geoPlan, widget.plan) &&
        identical(_geoNodes, widget.nodes) &&
        _geoFrom == _from &&
        _geoTo == _to) {
      return _geo!;
    }
    _geoT = t;
    _geoSize = size;
    _geoPlan = widget.plan;
    _geoNodes = widget.nodes;
    _geoFrom = _from;
    _geoTo = _to;
    return _geo = FloorGeometry.compute(
      plan: widget.plan,
      size: size,
      gap: _gapNow,
      nodes: widget.nodes,
      fitGrid: widget.fitGrid,
      padding: widget.padding,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return LayoutBuilder(
      builder: (context, cons) {
        final size = FloorPlanView.canvasSize(
          plan: widget.plan,
          constraints: cons,
          gap: widget.reserveGap ?? widget.gap,
          fitGrid: widget.fitGrid,
          fill: widget.fill,
          padding: widget.padding,
        );
        final canvas = SizedBox(
          width: size.width,
          height: size.height,
          child: _buildCanvas(context, hv, size),
        );
        if (!widget.interactive) return canvas;
        return SizedBox(
          width: size.width,
          height: size.height,
          child: ClipRect(
            child: InteractiveViewer(
              transformationController: widget.transformationController,
              minScale: widget.minScale,
              maxScale: widget.maxScale,
              boundaryMargin: const EdgeInsets.all(48),
              child: canvas,
            ),
          ),
        );
      },
    );
  }

  Widget _buildCanvas(BuildContext context, HavenColors hv, Size size) {
    final nodeBuilder = widget.nodeBuilder;
    // Widgets der Knoten einmal bauen. Pro Frame ändert sich nur die
    // Translation darum.
    final built = <Widget>[];
    if (nodeBuilder != null) {
      for (final n in widget.nodes) {
        Widget w = nodeBuilder(context, n);
        if (widget.onNodeTap != null) {
          w = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onNodeTap!(n),
            child: w,
          );
        }
        built.add(KeyedSubtree(key: ValueKey(n.id), child: w));
      }
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: widget.onRoomTap == null
                ? null
                : (d) {
                    final id = _geometry(size).roomAt(d.localPosition);
                    final r = id == null ? null : widget.plan.room(id);
                    if (r != null) widget.onRoomTap!(r);
                  },
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _LayersPainter(
                  state: this,
                  size: size,
                  hv: hv,
                  plan: widget.plan,
                  underlay: widget.underlayPainter,
                  overlay: widget.overlayPainter,
                  roomStyle: widget.roomStyle,
                  roomSubtitle: widget.roomSubtitle,
                  showGrid: widget.showGrid,
                  showLabels: widget.showLabels,
                  labels: _labels,
                  repaint: Listenable.merge([
                    _c,
                    ?widget.underlayPainter?.repaint,
                    ?widget.overlayPainter?.repaint,
                  ]),
                ),
              ),
            ),
          ),
        ),
        if (built.isNotEmpty)
          AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final geo = _geometry(size);
              return Stack(
                fit: StackFit.expand,
                clipBehavior: Clip.none,
                children: [
                  for (var i = 0; i < built.length; i++)
                    if (geo.nodes[widget.nodes[i].id] case final p?)
                      Positioned(
                        key: ValueKey(widget.nodes[i].id),
                        left: 0,
                        top: 0,
                        width: widget.nodes[i].size,
                        height: widget.nodes[i].size,
                        child: Transform.translate(
                          offset:
                              p -
                              Offset(
                                widget.nodes[i].size / 2,
                                widget.nodes[i].size / 2,
                              ),
                          child: built[i],
                        ),
                      ),
                ],
              );
            },
          ),
      ],
    );
  }
}

/// Textpainter-Cache, damit pro Frame nichts neu gesetzt wird.
class _LabelCache {
  final _m = <String, TextPainter>{};

  TextPainter get(String text, TextStyle style) {
    final key = '${style.color?.toARGB32()}|${style.fontSize}|$text';
    return _m.putIfAbsent(key, () {
      if (_m.length > 64) _m.clear();
      return TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout();
    });
  }
}

class _LayersPainter extends CustomPainter {
  _LayersPainter({
    required this.state,
    required this.size,
    required this.hv,
    required this.plan,
    required this.underlay,
    required this.overlay,
    required this.roomStyle,
    required this.roomSubtitle,
    required this.showGrid,
    required this.showLabels,
    required this.labels,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final _FloorPlanViewState state;
  final Size size;
  final HavenColors hv;
  final HavenFloorPlan plan;
  final FloorOverlayPainter? underlay;
  final FloorOverlayPainter? overlay;
  final FloorRoomStyle? Function(FloorRoom)? roomStyle;
  final String? Function(FloorRoom)? roomSubtitle;
  final bool showGrid;
  final bool showLabels;
  final _LabelCache labels;

  @override
  void paint(Canvas canvas, Size _) {
    final geo = state._geometry(size);
    if (showGrid) _grid(canvas, geo);
    for (final room in plan.rooms) {
      final rect = geo.rooms[room.id];
      if (rect == null) continue;
      final st = roomStyle?.call(room);
      final rr = FloorGeometry.roomShape(rect);
      canvas.drawRRect(rr, Paint()..color = st?.fill ?? hv.s1);
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = st?.borderWidth ?? 1
          ..color = st?.border ?? hv.ln2,
      );
    }
    underlay?.paint(canvas, size, geo);
    if (showLabels) _labelsPaint(canvas, geo);
    overlay?.paint(canvas, size, geo);
  }

  void _grid(Canvas canvas, FloorGeometry g) {
    final dots = <Offset>[];
    for (var y = 0; y <= plan.grid.rows; y++) {
      for (var x = 0; x <= plan.grid.cols; x++) {
        dots.add(g.cellToPx(Offset(x.toDouble(), y.toDouble())));
      }
    }
    canvas.drawPoints(
      PointMode.points,
      dots,
      Paint()
        ..color = hv.tx3.withValues(alpha: 0.35)
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round,
    );
  }

  void _labelsPaint(Canvas canvas, FloorGeometry g) {
    for (final room in plan.rooms) {
      final rect = g.rooms[room.id];
      if (rect == null || rect.width < 48) continue;
      final title = labels.get(
        room.name,
        HavenText.label.copyWith(
          color: hv.tx,
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
        ),
      );
      final maxW = rect.width - 24;
      final at = Offset(rect.left + 12, rect.top + 10);
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(at.dx, at.dy - 2, maxW, 40));
      title.paint(canvas, at);
      final sub = roomSubtitle?.call(room);
      if (sub != null && sub.isNotEmpty) {
        labels
            .get(sub, HavenText.caption.copyWith(color: hv.tx2, fontSize: 11.5))
            .paint(canvas, at + Offset(0, title.height + 1));
      }
      canvas.restore();
    }
  }

  // Stile und Untertitel stecken in Closures, darum immer neu zeichnen, wenn
  // das Elternwidget neu baut. Pro Frame der Animation gilt `repaint`.
  @override
  bool shouldRepaint(_LayersPainter old) => true;
}
