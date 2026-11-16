import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import '../../../data/models/entity_state.dart';
import '../../../data/models/floor_plan.dart';
import '../../../data/models/zigbee_network.dart';
import '../zigbee_model.dart';

/// ID des Bereichs „Ohne Raum“ neben dem Grundriss.
const String kNoRoomId = '__ohne_raum';

/// Was der Graph über einen Knoten wissen muss.
@immutable
class MeshNodeInfo {
  const MeshNodeInfo({
    required this.ieee,
    required this.name,
    required this.kind,
    this.roomName,
    this.lightId,
    this.available = true,
  });

  final String ieee;
  final String name;
  final ZbNodeKind kind;
  final String? roomName;

  /// Entity der Lampe, deren Lichtfarbe der Knoten trägt.
  final String? lightId;
  final bool available;

  @override
  bool operator ==(Object other) =>
      other is MeshNodeInfo &&
      other.ieee == ieee &&
      other.name == name &&
      other.kind == kind &&
      other.roomName == roomName &&
      other.lightId == lightId &&
      other.available == available;

  @override
  int get hashCode =>
      Object.hash(ieee, name, kind, roomName, lightId, available);
}

/// Grundriss mit Knotenpositionen für den Graphen.
///
/// [plan] enthält bei Bedarf den Bereich „Ohne Raum“ ([kNoRoomId]) als
/// zusätzlichen Raum unter den echten Räumen. Er wird nie gespeichert.
@immutable
class MeshScene {
  const MeshScene({
    required this.plan,
    required this.points,
    required this.infos,
    required this.autoLayout,
    required this.coordinatorIeee,
  });

  final HavenFloorPlan plan;

  /// Knoten-IEEE → Punkt im Grundriss (auch der Koordinator).
  final Map<String, PlanPoint> points;
  final Map<String, MeshNodeInfo> infos;

  /// Es gibt keinen gespeicherten Grundriss: Räume liegen im Raster.
  final bool autoLayout;
  final String? coordinatorIeee;

  /// Raum eines Knotens (Plan-Raum-ID oder [kNoRoomId]).
  String? roomOf(String ieee) => points[ieee]?.roomId;

  bool get hasNoRoom => plan.room(kNoRoomId) != null;

  MeshScene withCoordinator(PlanPoint p) => MeshScene(
    plan: plan,
    points: {...points, ?coordinatorIeee: p},
    infos: infos,
    autoLayout: autoLayout,
    coordinatorIeee: coordinatorIeee,
  );

  @override
  bool operator ==(Object other) =>
      other is MeshScene &&
      other.plan == plan &&
      other.autoLayout == autoLayout &&
      other.coordinatorIeee == coordinatorIeee &&
      mapEquals(other.points, points) &&
      mapEquals(other.infos, infos);

  @override
  int get hashCode =>
      Object.hash(plan, autoLayout, points.length, infos.length);
}

/// Baut die Szene aus Netzkarte, Geräten und Grundriss.
///
/// - Position eines Geräts: Platzierung seiner Entities, sonst Raummitte
///   (mehrere im Kreis), sonst „Ohne Raum“ (`FloorPlan.devicePoints`).
/// - Ohne [plan] (oder ohne Räume) entsteht ein Raster aus den Räumen der
///   Geräte (8 x 8 Zellen je Raum).
/// - Der Koordinator liegt auf [plan.coordinator], sonst in dem Raum, in dem
///   die meisten seiner direkten Geräte liegen.
MeshScene buildMeshScene({
  required ZbNetworkMap map,
  required List<ZbDeviceView> views,
  HavenFloorPlan? plan,
}) {
  final byIeee = {for (final v in views) v.ieee: v};
  final auto = plan == null || plan.rooms.isEmpty;

  // Räume bestimmen.
  var base = plan ?? HavenFloorPlan(rooms: const []);
  if (auto) {
    final names = <String, String>{};
    for (final n in map.nodes) {
      final v = byIeee[n.ieee];
      final id = v?.device.areaId ?? v?.roomId;
      if (v == null || id == null) continue;
      names[id] = v.roomName ?? id;
    }
    final ids = names.keys.toList()
      ..sort((a, b) => names[a]!.compareTo(names[b]!));
    final cols = math.max(1, math.sqrt(ids.length).ceil());
    final rows = math.max(1, (ids.length / cols).ceil());
    base = HavenFloorPlan(
      grid: FloorGrid(cols: math.max(8, cols * 8), rows: math.max(8, rows * 8)),
      rooms: [
        for (var i = 0; i < ids.length; i++)
          FloorRoom.rect(
            id: ids[i],
            name: names[ids[i]]!,
            areaId: ids[i],
            x: (i % cols) * 8,
            y: (i ~/ cols) * 8,
            w: 8,
            h: 8,
          ),
      ],
    );
  }

  final infos = <String, MeshNodeInfo>{};
  final devices = <FloorDevice>[];
  for (final n in map.nodes) {
    final v = byIeee[n.ieee];
    infos[n.ieee] = MeshNodeInfo(
      ieee: n.ieee,
      name: n.isCoordinator ? 'Koordinator' : (v?.name ?? n.name),
      kind: n.kind,
      roomName: v?.roomName,
      lightId: v?.entities
          .where((e) => e.domain == 'light')
          .map((e) => e.entityId)
          .firstOrNull,
      available: v?.available ?? true,
    );
    if (n.isCoordinator) continue;
    final ents = <String>[
      ?v?.mainEntity?.entityId,
      for (final e in v?.entities ?? const <EntityState>[]) e.entityId,
    ];
    // Bereichs-ID, sonst Raum-ID: je nachdem, was im Grundriss existiert.
    String? room;
    for (final c in [v?.device.areaId, v?.roomId]) {
      if (c != null && base.roomByIdOrArea(c) != null) {
        room = c;
        break;
      }
    }
    devices.add(FloorDevice(n.ieee, ents, roomId: room));
  }
  final points = Map<String, PlanPoint>.of(base.devicePoints(devices));

  // „Ohne Raum“ unter dem Grundriss.
  final lost = [
    for (final d in devices)
      if (!points.containsKey(d.id)) d.id,
  ];
  var plan2 = base;
  if (lost.isNotEmpty) {
    final b = base.rooms.isEmpty
        ? const Rect.fromLTWH(0, 0, 8, 0)
        : (auto ? base.houseBounds : base.outsideRect);
    final w = math.max(8, b.width.round());
    // Rasterzellen mit 2 Zellen Abstand.
    final cols = math.max(1, ((w - 1) / 2).floor());
    final rows = (lost.length / cols).ceil();
    final h = math.max(5, rows * 2 + 3);
    final top = b.bottom.round() + (auto ? 0 : 1);
    plan2 = base
        .copyWith(
          grid: base.grid.copyWith(
            rows: math.max(base.grid.rows, top + h),
            cols: math.max(base.grid.cols, b.left.round() + w),
          ),
        )
        .withRoom(
          FloorRoom.rect(
            id: kNoRoomId,
            name: 'Ohne Raum',
            x: b.left.round(),
            y: top,
            w: w,
            h: h,
            detached: true,
          ),
        );
    for (var i = 0; i < lost.length; i++) {
      final c = i % cols;
      final r = i ~/ cols;
      final inRow = math.min(cols, lost.length - r * cols);
      final x = b.left.round() + ((w - (inRow - 1) * 2) / 2).floor() + c * 2;
      final y = top + 2 + r * 2;
      points[lost[i]] = PlanPoint(x + 0.5, y + 0.5, kNoRoomId);
    }
  }

  // Koordinator.
  final ci = map.coordinator;
  if (ci != null) {
    PlanPoint? cp = plan == null || auto ? null : plan.coordinatorPoint;
    if (cp == null && plan2.rooms.isNotEmpty) {
      final count = <String, int>{};
      for (final k in map.childrenOf(ci)) {
        final r = points[k]?.roomId;
        if (r != null && r != kNoRoomId) count[r] = (count[r] ?? 0) + 1;
      }
      var best = plan2.rooms.first;
      var bn = -1;
      for (final r in plan2.rooms) {
        if ((count[r.id] ?? 0) > bn && r.id != kNoRoomId) {
          bn = count[r.id] ?? 0;
          best = r;
        }
      }
      final used = {for (final p in points.values) p.cell};
      final cell = HavenFloorPlan.quickCells(best, 1, occupied: used).first;
      cp = PlanPoint(cell.x + 0.5, cell.y + 0.5, best.id);
    }
    if (cp != null) points[ci] = cp;
  }

  return MeshScene(
    plan: plan2,
    points: points,
    infos: infos,
    autoLayout: auto,
    coordinatorIeee: ci,
  );
}

/// Filter der Graph-Ansicht. Standard sind nur die Wege zum Koordinator
/// (Baumkanten, je Gerät eine). „Alle Verbindungen“ zeigt zusätzlich jede
/// gemessene Nachbarschaft, bei echten Netzen einige Hundert.
enum MeshFilter {
  tree('Wege'),
  all('Alle Verbindungen'),
  weak('Schwache'),
  routers('Router');

  const MeshFilter(this.label);
  final String label;
}

/// Anzeigezustand des Graphen: Filter und gewählter Knoten samt Pfad. Liegt in
/// einem `ValueNotifier`, damit nur das Overlay und die Knoten reagieren, nicht
/// der ganze Bildschirm.
@immutable
class MeshViewState {
  const MeshViewState({
    this.filter = MeshFilter.tree,
    this.selected,
    this.pathNodes = const {},
    this.pathEdges = const {},
  });

  factory MeshViewState.of(
    ZbNetworkMap map, {
    MeshFilter filter = MeshFilter.tree,
    String? selected,
  }) {
    if (selected == null || map.node(selected) == null) {
      return MeshViewState(filter: filter);
    }
    return MeshViewState(
      filter: filter,
      selected: selected,
      pathNodes: map.pathToCoordinator(selected).toSet(),
      pathEdges: {for (final e in map.pathEdges(selected)) e.key},
    );
  }

  final MeshFilter filter;
  final String? selected;

  /// Knoten des Wegs vom gewählten Knoten zum Koordinator.
  final Set<String> pathNodes;
  final Set<String> pathEdges;

  bool get hasSelection => selected != null;

  /// Gehört die Kante zum Filter?
  bool edgeShown(ZbMeshEdge e, Map<String, MeshNodeInfo> infos) =>
      switch (filter) {
        MeshFilter.tree => e.inTree,
        MeshFilter.all => true,
        MeshFilter.weak => e.inTree && e.lqi < kWeakLqi,
        MeshFilter.routers =>
          e.inTree &&
              infos[e.a]?.kind != ZbNodeKind.endDevice &&
              infos[e.b]?.kind != ZbNodeKind.endDevice,
      };

  /// Knoten bleibt hell, wenn der Filter ihn betrifft.
  bool nodeActive(
    String ieee,
    ZbNetworkMap map,
    Map<String, MeshNodeInfo> infos,
  ) => switch (filter) {
    MeshFilter.tree || MeshFilter.all => true,
    MeshFilter.weak => map.treeEdges.any(
      (e) => e.touches(ieee) && e.lqi < kWeakLqi,
    ),
    MeshFilter.routers => infos[ieee]?.kind != ZbNodeKind.endDevice,
  };

  @override
  bool operator ==(Object other) =>
      other is MeshViewState &&
      other.filter == filter &&
      other.selected == selected;

  @override
  int get hashCode => Object.hash(filter, selected);
}
