import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../data/models/floor_plan.dart';
import '../../data/models/polygon.dart';

// Geometrie des Grundrisses in Pixeln (Zellen ↔ Bildschirm). Die Karte
// selbst ist 3D (`map_3d.dart`); der Editor rechnet mit dieser Abbildung und
// stellt die 3D-Kamera so, dass sie genau passt.

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

/// Zeichenebene über dem Grundriss (Editor: Auswahl, Griffe, Entwürfe),
/// bekommt die aktuelle Geometrie (Raum-Polygone, Knotenpositionen).
abstract class FloorOverlayPainter {
  const FloorOverlayPainter();

  void paint(Canvas canvas, Size size, FloorGeometry geometry);

  /// `true`, wenn sich gegenüber [old] etwas geändert hat.
  bool shouldRepaint(covariant FloorOverlayPainter old);

  /// Optional: zusätzliche Neuzeichnung (z. B. laufende Pfeile).
  Listenable? get repaint => null;
}

typedef FloorNodeBuilder =
    Widget Function(BuildContext context, FloorNode node);
