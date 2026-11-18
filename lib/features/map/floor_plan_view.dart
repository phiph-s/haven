import 'dart:math' as math;
import 'dart:ui' show PathMetric, PointMode;

import 'package:material_ui/material_ui.dart';

import '../../core/theme/tokens.dart';
import '../../data/models/floor_plan.dart';
import '../../data/models/polygon.dart';
import 'furniture_painter.dart';

/// Ein Knoten auf dem Grundriss: ein Widget an einem Punkt in Zellen.
/// [id] ist frei wählbar (Entity-ID, Geräte-ID, `coordinator`) und taucht in
/// [FloorGeometry.nodes] und den Callbacks wieder auf. Knoten auf derselben
/// Rasterzelle werden zu einer Gruppe, wenn [groupable] gilt.
@immutable
class FloorNode {
  const FloorNode({
    required this.id,
    required this.point,
    this.size = 48,
    this.groupable = true,
  });
  final String id;
  final PlanPoint point;

  /// Kantenlänge der Trefferfläche. Das Widget wird darin zentriert.
  final double size;
  final bool groupable;
}

/// Mehrere Knoten auf derselben Zelle.
@immutable
class FloorNodeGroup {
  const FloorNodeGroup(this.cell, this.members);
  final GridPoint cell;
  final List<FloorNode> members;

  String get key => 'group:${cell.x}:${cell.y}';
  PlanPoint get point =>
      PlanPoint(cell.x + 0.5, cell.y + 0.5, members.first.point.roomId);
}

/// Teilt [nodes] in einzelne und Gruppen (gleiche Zelle). Die Reihenfolge der
/// Gruppen folgt dem ersten Mitglied.
({List<FloorNode> single, List<FloorNodeGroup> groups}) groupFloorNodes(
  List<FloorNode> nodes,
) {
  final byCell = <GridPoint, List<FloorNode>>{};
  final single = <FloorNode>[];
  for (final n in nodes) {
    if (!n.groupable) {
      single.add(n);
      continue;
    }
    (byCell[n.point.cell] ??= []).add(n);
  }
  final groups = <FloorNodeGroup>[];
  for (final e in byCell.entries) {
    if (e.value.length == 1) {
      single.add(e.value.single);
    } else {
      groups.add(FloorNodeGroup(e.key, e.value));
    }
  }
  return (single: single, groups: groups);
}

/// Versatz des Mitglieds [i] von [n] beim Auffächern (Pixel).
Offset fanOffset(int i, int n) {
  final r = math.max(34.0, n * 9.0);
  final a = -math.pi / 2 + 2 * math.pi * i / n;
  return Offset(math.cos(a), math.sin(a)) * r;
}

/// Pixel-Geometrie des Grundrisses zu einem Zeitpunkt der Animation.
/// Alle Maße im Koordinatensystem der Zeichenfläche (vor Zoom und Pan).
class FloorGeometry {
  FloorGeometry({
    required this.plan,
    required this.size,
    required this.scale,
    required this.origin,
    required this.gap,
    required this.roomOffsets,
    required this.rooms,
    required this.polygons,
    required this.nodes,
    required this.groups,
    required this.outside,
  });

  final HavenFloorPlan plan;
  final Size size;

  /// Pixel je Zelle.
  final double scale;

  /// Pixelposition des Rasterpunkts (0, 0).
  final Offset origin;

  /// Aktueller (animierter) Abstand in Zellen.
  final double gap;

  /// Verschiebung je Raum in Zellen (bei [gap]).
  final Map<String, Offset> roomOffsets;

  /// Umschließende Rechtecke der Räume in Pixeln.
  final Map<String, Rect> rooms;

  /// Ecken der Räume in Pixeln.
  final Map<String, List<Offset>> polygons;

  /// Knotenmitten in Pixeln nach Knoten-ID (aufgefächert, wenn offen).
  final Map<String, Offset> nodes;

  /// Mitten der Gruppen in Pixeln nach [FloorNodeGroup.key].
  final Map<String, Offset> groups;

  /// Außenbereich in Pixeln oder `null`.
  final Rect? outside;

  final Map<String, Path> _paths = {};

  Offset cellToPx(Offset c) => origin + c * scale;
  Offset pxToCell(Offset p) => (p - origin) / scale;

  /// Pixelposition eines Punkts im Grundriss.
  Offset pointToPx(PlanPoint p) => cellToPx(
    plan.explodePoint(p.offset, p.roomId, gap: gap, offsets: roomOffsets),
  );

  /// Raum unter dem Pixel [p] oder `null`.
  String? roomAt(Offset p) {
    for (final e in polygons.entries) {
      if (!rooms[e.key]!.inflate(0.5).contains(p)) continue;
      if (locatePoint(e.value, p) != PointLocation.outside) return e.key;
    }
    return null;
  }

  /// Zelle des Grundrisses unter dem Pixel [p] (rechnet den Abstand heraus).
  GridPoint planCellAt(Offset p) {
    var c = pxToCell(p);
    final room = roomAt(p);
    if (room != null) {
      c -= roomOffsets[room] ?? Offset.zero;
    } else if (gap != 0) {
      final m = plan.explodeCenter;
      c = m + (c - m) / (1 + plan.explodeFactor(gap));
    }
    return GridPoint(c.dx.floor(), c.dy.floor());
  }

  /// Weich gerundete Fläche eines Raums (1,5 px Fuge zu den Nachbarn).
  Path roomPath(String id) => _paths.putIfAbsent(id, () {
    final pts = polygons[id];
    if (pts == null) return Path();
    final b = rooms[id]!;
    final radius = math.min(16.0, 0.14 * math.min(b.width, b.height));
    return roundedPolygonPath(insetPolygon(pts, 1.5), radius);
  });

  /// Rechteck in Pixeln für ein Rechteck in Zellen eines Raums (mit Abstand).
  Rect roomCellRect(String roomId, Rect cells) {
    final o = roomOffsets[roomId] ?? Offset.zero;
    final s = cells.shift(o);
    return Rect.fromPoints(cellToPx(s.topLeft), cellToPx(s.bottomRight));
  }

  static FloorGeometry compute({
    required HavenFloorPlan plan,
    required Size size,
    double gap = 0,
    List<FloorNode> nodes = const [],
    bool fitGrid = false,
    bool withOutside = false,
    double padding = 12,
    EdgeInsets insets = EdgeInsets.zero,
    String? openGroup,
    double fan = 0,
  }) {
    final offs = plan.roomOffsets(gap: gap);
    final bounds = fitGrid
        ? plan.grid.rect
        : plan.layoutBounds(gap: gap, withOutside: withOutside);
    final bw = math.max(bounds.width, 1.0);
    final bh = math.max(bounds.height, 1.0);
    // Eingepasst wird in die Fläche ohne [insets]; gezeichnet wird überall.
    final free = insets.deflateSize(size);
    final s = math.max(
      1.0,
      math.min(
        (free.width - 2 * padding) / bw,
        (free.height - 2 * padding) / bh,
      ),
    );
    final origin = Offset(
      insets.left + free.width / 2 - bounds.center.dx * s,
      insets.top + free.height / 2 - bounds.center.dy * s,
    );
    Offset px(Offset c) => origin + c * s;
    final polys = <String, List<Offset>>{};
    final rects = <String, Rect>{};
    for (final r in plan.rooms) {
      final o = offs[r.id]!;
      final pts = [for (final p in r.offsets) px(p + o)];
      polys[r.id] = pts;
      rects[r.id] = polygonBounds(pts);
    }
    Offset pointPx(PlanPoint p) =>
        px(plan.explodePoint(p.offset, p.roomId, gap: gap, offsets: offs));

    final nodePx = <String, Offset>{};
    final groupPx = <String, Offset>{};
    final g = groupFloorNodes(nodes);
    for (final n in g.single) {
      nodePx[n.id] = pointPx(n.point);
    }
    for (final grp in g.groups) {
      final c = pointPx(grp.point);
      groupPx[grp.key] = c;
      final t = grp.key == openGroup ? fan : 0.0;
      for (var i = 0; i < grp.members.length; i++) {
        nodePx[grp.members[i].id] = c + fanOffset(i, grp.members.length) * t;
      }
    }
    Rect? out;
    if (withOutside && plan.rooms.isNotEmpty) {
      final o = plan.outsideRect;
      final m = plan.explodeCenter;
      final k = 1 + plan.explodeFactor(gap);
      out = Rect.fromPoints(
        px(m + (o.topLeft - m) * k),
        px(m + (o.bottomRight - m) * k),
      );
    }
    return FloorGeometry(
      plan: plan,
      size: size,
      scale: s,
      origin: origin,
      gap: gap,
      roomOffsets: offs,
      rooms: rects,
      polygons: polys,
      nodes: nodePx,
      groups: groupPx,
      outside: out,
    );
  }
}

/// Polygon als Pfad mit gerundeten Ecken (Radius je Ecke höchstens 45 %
/// der angrenzenden Kanten).
Path roundedPolygonPath(List<Offset> pts, double radius) {
  final n = pts.length;
  final path = Path();
  if (n < 3) return path;
  for (var i = 0; i < n; i++) {
    final prev = pts[(i - 1 + n) % n];
    final cur = pts[i];
    final next = pts[(i + 1) % n];
    final a = prev - cur;
    final b = next - cur;
    final la = a.distance;
    final lb = b.distance;
    if (la < 1e-6 || lb < 1e-6) continue;
    // Gerade Durchgänge (eingefügte Ecken auf einer Kante) brauchen keinen
    // Bogen.
    final cross = (a.dx * b.dy - a.dy * b.dx).abs() / (la * lb);
    final r = cross < 0.02 ? 0.0 : math.min(radius, math.min(la, lb) * 0.45);
    final p1 = cur + a / la * r;
    final p2 = cur + b / lb * r;
    if (i == 0) {
      path.moveTo(p1.dx, p1.dy);
    } else {
      path.lineTo(p1.dx, p1.dy);
    }
    if (r > 0) path.quadraticBezierTo(cur.dx, cur.dy, p2.dx, p2.dy);
  }
  path.close();
  return path;
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
/// Beschriftungen). Bekommt bei jedem Frame der Animation die aktuelle
/// Geometrie (Raum-Polygone, Knotenpositionen).
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

typedef FloorGroupBuilder = Widget Function(
  BuildContext context,
  FloorNodeGroup group,
);

/// Karte des Grundrisses: Räume als weiche Polygone, „Draußen“ als Garten um
/// die Wohnung, Knoten als Widgets an Punkten in Zellen, Zeichenebenen
/// darunter und darüber, Zoom und Pan.
///
/// Schichten von unten: Draußen (optional), Raster (optional), Räume,
/// [underlayPainter] (Lichtkegel, Heatmap, auf den Raum zu clippen),
/// Raumnamen, [overlayPainter] (Kanten, Pfeile), Knoten.
///
/// Der Wechsel von [gap] animiert die Räume weich auseinander oder zusammen:
/// jedes Polygon rückt als Ganzes vom Mittelpunkt weg. Die Knoten wandern
/// mit, ihre Widgets werden dabei nur per `Transform` verschoben.
///
/// Knoten auf derselben Zelle erscheinen als Gruppe mit Zahl. Antippen
/// fächert sie auf, ein Tippen daneben schließt sie wieder.
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
    this.groupBuilder,
    this.underlayPainter,
    this.overlayPainter,
    this.roomStyle,
    this.roomSubtitle,
    this.onRoomTap,
    this.onOutsideTap,
    this.onNodeTap,
    this.onNodeLongPress,
    this.onNodeSecondaryTap,
    this.onGroupOpen,
    this.interactive = true,
    this.fitGrid = false,
    this.fill = false,
    this.showGrid = false,
    this.showLabels = true,
    this.showOutside = true,
    this.padding = 12,
    this.insets = EdgeInsets.zero,
    this.minScale = 1,
    this.maxScale = 4,
    this.transformationController,
    this.showFurniture = true,
    this.furnitureInk,
    this.onRoomSecondaryTap,
  });

  final HavenFloorPlan plan;

  /// Zusätzlicher Abstand zwischen den Räumen in Zellen. Ändert er sich,
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

  /// Widget einer Gruppe, sonst [FloorGroupBadge] mit dem ersten Mitglied.
  final FloorGroupBuilder? groupBuilder;

  final FloorOverlayPainter? underlayPainter;
  final FloorOverlayPainter? overlayPainter;

  /// Stil je Raum, sonst Fläche `s1` mit Haarlinie.
  final FloorRoomStyle? Function(FloorRoom room)? roomStyle;

  /// Zweite Zeile unter dem Raumnamen, z. B. `22,2° · 45 %`.
  final String? Function(FloorRoom room)? roomSubtitle;

  final ValueChanged<FloorRoom>? onRoomTap;
  final VoidCallback? onOutsideTap;
  final ValueChanged<FloorNode>? onNodeTap;

  /// Langes Drücken auf einen Knoten.
  final ValueChanged<FloorNode>? onNodeLongPress;

  /// Rechtsklick (zweite Taste) auf einen Knoten.
  final ValueChanged<FloorNode>? onNodeSecondaryTap;

  /// Eine Gruppe wurde aufgefächert (`null`: geschlossen).
  final ValueChanged<FloorNodeGroup?>? onGroupOpen;

  /// Zoom (Pinch) und Pan per `InteractiveViewer`.
  final bool interactive;

  /// Das ganze Raster einpassen statt nur die Räume (Editor).
  final bool fitGrid;

  /// Die ganze verfügbare Fläche nutzen (braucht beschränkte Höhe), sonst
  /// ergibt sich die Höhe aus dem Seitenverhältnis des Grundrisses.
  final bool fill;
  final bool showGrid;
  final bool showLabels;

  /// Außenbereich „Draußen“ um die Wohnung zeigen.
  final bool showOutside;
  final double padding;

  /// Ränder, in die der Grundriss beim Einpassen nicht gelegt wird (z. B.
  /// ein Kopf, der über der Karte liegt). Gezeichnet und verschoben wird
  /// trotzdem über die ganze Fläche. Nur sinnvoll mit [fill].
  final EdgeInsets insets;
  final double minScale;
  final double maxScale;
  final TransformationController? transformationController;

  /// Möbel als Linienzeichnung über den Räumen, unter Licht und Heatmap.
  final bool showFurniture;

  /// Stifte für die Möbel, sonst dezent ([FurnitureInk.map]).
  final FurnitureInk? furnitureInk;

  /// Rechtsklick (bzw. zweite Taste) auf einen Raum oder ins Freie
  /// (`room == null`), mit der globalen Position fürs Kontextmenü.
  final void Function(FloorRoom? room, Offset globalPosition)?
  onRoomSecondaryTap;

  /// Größe der Zeichenfläche für den gegebenen Rahmen.
  static Size canvasSize({
    required HavenFloorPlan plan,
    required BoxConstraints constraints,
    double gap = 0,
    bool fitGrid = false,
    bool fill = false,
    bool withOutside = true,
    double padding = 12,
  }) {
    final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 360.0;
    if (fill && constraints.hasBoundedHeight) {
      return Size(w, constraints.maxHeight);
    }
    final b = fitGrid
        ? Size(plan.grid.cols.toDouble(), plan.grid.rows.toDouble())
        : plan.layoutSize(gap: gap, withOutside: withOutside);
    final bw = math.max(b.width, 1.0);
    var h = (w - 2 * padding) * b.height / bw + 2 * padding;
    if (constraints.hasBoundedHeight) h = math.min(h, constraints.maxHeight);
    return Size(w, h);
  }

  @override
  State<FloorPlanView> createState() => _FloorPlanViewState();
}

class _FloorPlanViewState extends State<FloorPlanView>
    with TickerProviderStateMixin {
  late final AnimationController _c;
  late final AnimationController _fan;
  late double _from;
  late double _to;
  final _labels = _LabelCache();
  String? _open;

  // Geometrie-Cache, damit Räume, Ebenen und Knoten pro Frame nur einmal
  // rechnen.
  FloorGeometry? _geo;
  double _geoT = -1;
  double _geoFan = -1;
  String? _geoOpen;
  Size _geoSize = Size.zero;
  EdgeInsets _geoInsets = EdgeInsets.zero;
  HavenFloorPlan? _geoPlan;
  List<FloorNode>? _geoNodes;
  double _geoFrom = 0;
  double _geoTo = 0;

  // Grashalme im Außenbereich (Zellen), je Plan einmal.
  HavenFloorPlan? _tuftPlan;
  List<Offset> _tufts = const [];

  double get _gapNow =>
      _from + (_to - _from) * widget.gapCurve.transform(_c.value);

  bool get _withOutside => widget.showOutside && !widget.fitGrid;

  @override
  void initState() {
    super.initState();
    _from = _to = widget.gap;
    _c = AnimationController(vsync: this, value: 1);
    _fan = AnimationController(vsync: this, duration: HavenMotion.d3);
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
    if (_open != null &&
        !groupFloorNodes(widget.nodes).groups.any((g) => g.key == _open)) {
      _open = null;
      _fan.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _fan.dispose();
    super.dispose();
  }

  FloorGeometry _geometry(Size size) {
    final t = _c.value;
    final f = HavenMotion.out.transform(_fan.value);
    if (_geo != null &&
        _geoT == t &&
        _geoFan == f &&
        _geoOpen == _open &&
        _geoSize == size &&
        _geoInsets == widget.insets &&
        identical(_geoPlan, widget.plan) &&
        identical(_geoNodes, widget.nodes) &&
        _geoFrom == _from &&
        _geoTo == _to) {
      return _geo!;
    }
    _geoT = t;
    _geoFan = f;
    _geoOpen = _open;
    _geoSize = size;
    _geoInsets = widget.insets;
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
      withOutside: _withOutside || (widget.fitGrid && widget.showOutside),
      padding: widget.padding,
      insets: widget.insets,
      openGroup: _open,
      fan: f,
    );
  }

  List<Offset> _tuftsFor(HavenFloorPlan plan) {
    if (identical(_tuftPlan, plan)) return _tufts;
    _tuftPlan = plan;
    final o = plan.outsideRect;
    final out = <Offset>[];
    var seed = 7;
    double rnd() {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed / 0x7fffffff;
    }

    for (var y = o.top; y < o.bottom - 0.5; y += 1.6) {
      for (var x = o.left; x < o.right - 0.5; x += 1.6) {
        final p = Offset(x + 0.3 + rnd() * 1.0, y + 0.3 + rnd() * 1.0);
        if (rnd() < 0.45) continue;
        if (plan.houseBounds.inflate(0.4).contains(p) &&
            plan.roomAt(p) != null) {
          continue;
        }
        // Nicht direkt an der Wand.
        var near = false;
        for (final r in plan.rooms) {
          if (r.bounds.inflate(0.5).contains(p)) {
            near = true;
            break;
          }
        }
        if (!near) out.add(p);
      }
    }
    return _tufts = out;
  }

  void _toggleGroup(FloorNodeGroup g) {
    if (_open == g.key) {
      _closeGroup();
      return;
    }
    setState(() => _open = g.key);
    _fan.duration = context.motion(HavenMotion.d3);
    if (_fan.duration == Duration.zero) {
      _fan.value = 1;
    } else {
      _fan.forward(from: 0);
    }
    widget.onGroupOpen?.call(g);
  }

  void _closeGroup() {
    if (_open == null) return;
    widget.onGroupOpen?.call(null);
    final d = context.motion(HavenMotion.d2);
    if (d == Duration.zero) {
      setState(() {
        _open = null;
        _fan.value = 0;
      });
      return;
    }
    _fan.duration = d;
    _fan.reverse().whenComplete(() {
      if (mounted && _fan.value == 0) setState(() => _open = null);
    });
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
          withOutside: _withOutside,
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
    final grouped = groupFloorNodes(widget.nodes);
    final groupOf = <String, FloorNodeGroup>{
      for (final g in grouped.groups)
        for (final m in g.members) m.id: g,
    };
    // Widgets der Knoten einmal bauen. Pro Frame ändert sich nur die
    // Translation darum.
    final built = <String, Widget>{};
    final groupWidgets = <String, Widget>{};
    if (nodeBuilder != null) {
      for (final n in widget.nodes) {
        Widget w = nodeBuilder(context, n);
        if (widget.onNodeTap != null ||
            widget.onNodeLongPress != null ||
            widget.onNodeSecondaryTap != null) {
          w = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onNodeTap == null ? null : () => widget.onNodeTap!(n),
            onLongPress: widget.onNodeLongPress == null
                ? null
                : () => widget.onNodeLongPress!(n),
            onSecondaryTap: widget.onNodeSecondaryTap == null
                ? null
                : () => widget.onNodeSecondaryTap!(n),
            child: w,
          );
        }
        built[n.id] = KeyedSubtree(key: ValueKey(n.id), child: w);
      }
      for (final g in grouped.groups) {
        final w =
            widget.groupBuilder?.call(context, g) ??
            FloorGroupBadge(
              count: g.members.length,
              child: nodeBuilder(context, g.members.first),
            );
        groupWidgets[g.key] = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _toggleGroup(g),
          child: Semantics(
            button: true,
            label:
                '${g.members.length} Geräte auf einem Feld, antippen '
                'fächert sie auf',
            child: w,
          ),
        );
      }
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              if (_open != null) {
                _closeGroup();
                return;
              }
              final id = _geometry(size).roomAt(d.localPosition);
              final r = id == null ? null : widget.plan.room(id);
              if (r != null) {
                widget.onRoomTap?.call(r);
              } else {
                widget.onOutsideTap?.call();
              }
            },
            onSecondaryTapUp: widget.onRoomSecondaryTap == null
                ? null
                : (d) {
                    final id = _geometry(size).roomAt(d.localPosition);
                    widget.onRoomSecondaryTap!(
                      id == null ? null : widget.plan.room(id),
                      d.globalPosition,
                    );
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
                  showOutside: widget.showOutside,
                  furniture: widget.showFurniture
                      ? (widget.furnitureInk ?? FurnitureInk.map(hv))
                      : null,
                  labels: _labels,
                  repaint: Listenable.merge([
                    _c,
                    _fan,
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
            animation: Listenable.merge([_c, _fan]),
            builder: (context, _) {
              final geo = _geometry(size);
              final fan = HavenMotion.out.transform(_fan.value);
              Widget place(String key, double side, Offset p, Widget child) =>
                  Positioned(
                    key: ValueKey('pos:$key'),
                    left: 0,
                    top: 0,
                    width: side,
                    height: side,
                    child: Transform.translate(
                      offset: p - Offset(side / 2, side / 2),
                      child: child,
                    ),
                  );
              return Stack(
                fit: StackFit.expand,
                clipBehavior: Clip.none,
                children: [
                  // Einzelne Knoten, dann Gruppen, aufgefächerte zuoberst,
                  // damit ihre Trefferflächen gewinnen.
                  for (final n in widget.nodes)
                    if (groupOf[n.id] == null)
                      if (geo.nodes[n.id] case final p?)
                        place(n.id, n.size, p, built[n.id]!),
                  for (final g in grouped.groups)
                    if (geo.groups[g.key] case final p?)
                      place(
                        g.key,
                        48,
                        p,
                        IgnorePointer(
                          ignoring: g.key == _open && fan > 0.5,
                          child: Opacity(
                            opacity: g.key == _open ? 1 - fan * 0.7 : 1,
                            child: groupWidgets[g.key],
                          ),
                        ),
                      ),
                  for (final g in grouped.groups)
                    for (final n in g.members)
                      if (geo.nodes[n.id] case final p?)
                        place(
                          n.id,
                          n.size,
                          p,
                          IgnorePointer(
                            ignoring: g.key != _open || fan < 0.5,
                            child: Opacity(
                              opacity: g.key == _open ? fan : 0,
                              child: built[n.id],
                            ),
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

/// Gruppenknoten: das erste Gerät mit einer Zahl daran.
class FloorGroupBadge extends StatelessWidget {
  const FloorGroupBadge({super.key, required this.count, required this.child});
  final int count;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        // Angedeuteter Stapel hinter dem ersten Gerät.
        Transform.translate(
          offset: const Offset(3, -3),
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: hv.s2,
              border: Border.all(color: hv.ln2),
            ),
          ),
        ),
        child,
        Positioned(
          right: 2,
          top: 2,
          child: Container(
            constraints: const BoxConstraints(minWidth: 19),
            height: 19,
            padding: const EdgeInsets.symmetric(horizontal: 5),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hv.tx,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: hv.bg, width: 1.5),
            ),
            child: Text(
              '$count',
              style: HavenText.caption.copyWith(
                color: hv.bg,
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Textpainter-Cache, damit pro Frame nichts neu gesetzt wird.
class _LabelCache {
  final _m = <String, TextPainter>{};

  TextPainter get(String text, TextStyle style, {double? maxWidth}) {
    final key =
        '${style.color?.toARGB32()}|${style.fontSize}|${maxWidth?.round()}|$text';
    return _m.putIfAbsent(key, () {
      if (_m.length > 96) _m.clear();
      return TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: maxWidth ?? double.infinity);
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
    required this.showOutside,
    required this.furniture,
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
  final bool showOutside;

  /// Stifte für die Möbel, `null`: keine Möbel.
  final FurnitureInk? furniture;
  final _LabelCache labels;

  @override
  void paint(Canvas canvas, Size _) {
    final geo = state._geometry(size);
    if (showOutside && geo.outside != null) _outside(canvas, geo);
    if (showGrid) _grid(canvas, geo);
    for (final room in plan.rooms) {
      if (!geo.polygons.containsKey(room.id)) continue;
      final st = roomStyle?.call(room);
      final path = geo.roomPath(room.id);
      canvas.drawPath(path, Paint()..color = st?.fill ?? hv.s1);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = st?.borderWidth ?? 1
          ..color = st?.border ?? hv.ln2,
      );
    }
    final ink = furniture;
    if (ink != null && plan.furniture.isNotEmpty) {
      paintPlanFurniture(canvas, plan, geo, ink);
    }
    underlay?.paint(canvas, size, geo);
    if (showLabels) _labelsPaint(canvas, geo);
    overlay?.paint(canvas, size, geo);
  }

  void _outside(Canvas canvas, FloorGeometry g) {
    final r = g.outside!;
    final rr = RRect.fromRectAndRadius(r, const Radius.circular(22));
    final green = hv.ok;
    canvas.drawRRect(
      rr,
      Paint()..color = green.withValues(alpha: hv.isDark ? 0.06 : 0.07),
    );
    // Gestrichelter Rand, wie ein Zaun.
    final path = Path()..addRRect(rr.deflate(0.5));
    final dash = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..color = green.withValues(alpha: hv.isDark ? 0.32 : 0.38);
    for (final PathMetric m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 9) {
        canvas.drawPath(m.extractPath(d, math.min(d + 4.5, m.length)), dash);
      }
    }
    // Ein paar Grashalme.
    final tuft = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..color = green.withValues(alpha: hv.isDark ? 0.28 : 0.34);
    final s = g.scale;
    final m = plan.explodeCenter;
    final k = 1 + plan.explodeFactor(g.gap);
    final h = math.min(6.0, s * 0.4);
    for (final t in state._tuftsFor(plan)) {
      final p = g.cellToPx(m + (t - m) * k);
      canvas.drawLine(p, p + Offset(-h * 0.35, -h), tuft);
      canvas.drawLine(p, p + Offset(0, -h * 1.2), tuft);
      canvas.drawLine(p, p + Offset(h * 0.4, -h * 0.9), tuft);
    }
    final label = labels.get(
      kOutsideName,
      HavenText.caption.copyWith(
        color: Color.alphaBlend(green.withValues(alpha: 0.55), hv.tx3),
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    );
    label.paint(canvas, r.topLeft + const Offset(12, 7));
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
      if (!g.polygons.containsKey(room.id)) continue;
      final rect = g.roomCellRect(room.id, room.innerRect);
      if (rect.width < 44 || rect.height < 26) continue;
      final maxW = rect.width - 16;
      final title = labels.get(
        room.name,
        HavenText.label.copyWith(
          color: hv.tx,
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
        ),
        maxWidth: maxW,
      );
      final at = Offset(rect.left + 8, rect.top + 7);
      title.paint(canvas, at);
      final sub = roomSubtitle?.call(room);
      if (sub != null && sub.isNotEmpty) {
        labels
            .get(
              sub,
              HavenText.caption.copyWith(color: hv.tx2, fontSize: 11.5),
              maxWidth: maxW,
            )
            .paint(canvas, at + Offset(0, title.height + 1));
      }
    }
  }

  // Stile und Untertitel stecken in Closures, darum immer neu zeichnen, wenn
  // das Elternwidget neu baut. Pro Frame der Animation gilt `repaint`.
  @override
  bool shouldRepaint(_LayersPainter old) => true;
}

/// Zeichnet alle Möbel des Plans (Teppiche zuerst). Im Abstand-Modus wandern
/// sie mit dem Raum, in dem ihre Mitte liegt. [skip] lässt eines aus (wird
/// gerade gezogen und anders gezeichnet).
void paintPlanFurniture(
  Canvas canvas,
  HavenFloorPlan plan,
  FloorGeometry geo,
  FurnitureInk ink, {
  String? skip,
}) {
  for (final f in furnitureInPaintOrder(plan.furniture)) {
    if (f.id == skip) continue;
    final c = geo.gap == 0
        ? geo.cellToPx(f.center)
        : geo.pointToPx(PlanPoint(f.x, f.y, plan.locationOfFurniture(f)));
    paintFurniture(canvas, f, c, geo.scale, ink);
  }
}
