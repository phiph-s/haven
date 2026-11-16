import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/light/color_math.dart';
import '../../../core/light/room_palette.dart';
import '../../../core/state/providers.dart';
import '../../../core/theme/tokens.dart';
import '../../../data/models/lamp.dart';
import '../../../data/models/zigbee_network.dart';
import '../../map/floor_plan_view.dart';
import 'mesh_painter.dart';
import 'mesh_scene.dart';

/// Ziehen des Koordinators („Koordinator platzieren“). [onUpdate] bekommt die
/// Verschiebung in Pixeln der Zeichenfläche.
class MeshCoordinatorDrag {
  const MeshCoordinatorDrag({
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
  });
  final VoidCallback onStart;
  final ValueChanged<Offset> onUpdate;
  final VoidCallback onEnd;
}

/// Der Netz-Graph auf dem Grundriss: `FloorPlanView` mit Abstand, Kanten als
/// ein Overlay-Painter, Knoten als Widgets. Gleiche Ansicht für Vollbild und
/// Miniatur ([mini]: ohne Beschriftung, ohne Interaktion).
class MeshGraph extends StatelessWidget {
  const MeshGraph({
    super.key,
    required this.scene,
    required this.map,
    required this.state,
    this.gap = 2,
    this.mini = false,
    this.interactive = true,
    this.onNodeTap,
    this.onRoomTap,
    this.coordinatorDrag,
    this.transformationController,
  });

  final MeshScene scene;
  final ZbNetworkMap map;
  final ValueListenable<MeshViewState> state;
  final double gap;
  final bool mini;
  final bool interactive;
  final ValueChanged<String>? onNodeTap;
  final VoidCallback? onRoomTap;
  final MeshCoordinatorDrag? coordinatorDrag;
  final TransformationController? transformationController;

  /// Knoten für den `FloorPlanView`: Endgeräte unten, Koordinator oben.
  static List<FloorNode> floorNodes(
    MeshScene scene,
    ZbNetworkMap map, {
    bool mini = false,
  }) {
    int z(ZbNodeKind k) => switch (k) {
      ZbNodeKind.endDevice => 0,
      ZbNodeKind.router => 1,
      ZbNodeKind.coordinator => 2,
    };
    final list = [
      for (final n in map.nodes)
        if (scene.points[n.ieee] != null) n,
    ]..sort((a, b) => z(a.kind).compareTo(z(b.kind)));
    return [
      for (final n in list)
        FloorNode(
          id: n.ieee,
          point: scene.points[n.ieee]!,
          size: mini ? 14 : (n.isCoordinator ? 48 : 44),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return FloorPlanView(
      plan: scene.plan,
      gap: gap,
      reserveGap: 2,
      nodes: floorNodes(scene, map, mini: mini),
      nodeBuilder: (context, node) => MeshNodeDot(
        info: scene.infos[node.id]!,
        map: map,
        state: state,
        mini: mini,
        drag: node.id == scene.coordinatorIeee ? coordinatorDrag : null,
      ),
      overlayPainter: MeshEdgePainter(
        edges: map.edges,
        scene: scene,
        state: state,
        hv: hv,
        mini: mini,
      ),
      roomStyle: (room) => FloorRoomStyle(
        fill: room.id == kNoRoomId
            ? hv.s2.withValues(alpha: 0.55)
            : (mini ? hv.s2 : null),
        border: hv.ln2,
      ),
      onNodeTap: onNodeTap == null ? null : (n) => onNodeTap!(n.id),
      onRoomTap: onRoomTap == null ? null : (_) => onRoomTap!(),
      interactive: interactive,
      showLabels: !mini,
      showOutside: !scene.autoLayout,
      fill: true,
      padding: mini ? 6 : 12,
      transformationController: transformationController,
    );
  }
}

/// Ein Knoten: Router rund mit Ring, Endgerät als kleines abgerundetes
/// Quadrat, Koordinator als großer Akzentknoten. Lampen tragen ihre
/// Lichtfarbe.
class MeshNodeDot extends ConsumerWidget {
  const MeshNodeDot({
    super.key,
    required this.info,
    required this.map,
    required this.state,
    this.mini = false,
    this.drag,
  });

  final MeshNodeInfo info;
  final ZbNetworkMap map;
  final ValueListenable<MeshViewState> state;
  final bool mini;
  final MeshCoordinatorDrag? drag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    Color? lamp;
    if (info.lightId != null) {
      final e = ref.watch(entityProvider(info.lightId!));
      if (e != null && e.isAvailable) {
        final l = Lamp.fromEntity(e);
        if (l.on) lamp = colorOf(uiColor(l.color, dark: hv.isDark));
      }
    }
    final r = meshNodeRadius(info.kind, mini: mini);
    Widget dot = switch (info.kind) {
      ZbNodeKind.coordinator => _coordinator(hv, r),
      ZbNodeKind.router => _router(hv, r, lamp),
      ZbNodeKind.endDevice => _end(hv, r, lamp),
    };
    if (drag != null) {
      dot = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => drag!.onStart(),
        onPanUpdate: (d) => drag!.onUpdate(d.delta),
        onPanEnd: (_) => drag!.onEnd(),
        onPanCancel: drag!.onEnd,
        child: SizedBox.expand(child: Center(child: dot)),
      );
    }
    final child = Semantics(
      label: info.name,
      button: !mini,
      child: Center(child: dot),
    );
    return ValueListenableBuilder<MeshViewState>(
      valueListenable: state,
      child: child,
      builder: (context, st, child) {
        double o = info.available ? 1 : 0.5;
        if (st.hasSelection) {
          o = st.pathNodes.contains(info.ieee) ? 1 : 0.25;
        } else if (!st.nodeActive(info.ieee, map, {info.ieee: info})) {
          o = 0.15;
        }
        final sel = st.selected == info.ieee;
        return AnimatedOpacity(
          duration: context.motion(HavenMotion.d1),
          opacity: o,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (sel)
                Container(
                  width: r * 2 + 14,
                  height: r * 2 + 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: hv.acc.withValues(alpha: 0.22),
                    border: Border.all(color: hv.acc, width: 1.5),
                  ),
                ),
              child!,
            ],
          ),
        );
      },
    );
  }

  Widget _coordinator(HavenColors hv, double r) => Container(
    width: r * 2,
    height: r * 2,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: hv.acc,
      border: Border.all(color: hv.acc2, width: mini ? 1.5 : 3),
      boxShadow: [
        BoxShadow(
          color: hv.acc.withValues(alpha: 0.4),
          blurRadius: mini ? 4 : 10,
        ),
      ],
    ),
    child: mini
        ? null
        : Icon(
            drag == null ? Icons.hub_rounded : Icons.open_with_rounded,
            size: 18,
            color: hv.ai,
          ),
  );

  Widget _router(HavenColors hv, double r, Color? lamp) {
    final ring = info.available ? (lamp == null ? hv.tx2 : hv.tx) : hv.bad;
    return Container(
      width: r * 2,
      height: r * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: lamp ?? hv.s2,
        border: Border.all(color: ring, width: mini ? 1.2 : 2.2),
      ),
      child: mini || info.lightId == null
          ? null
          : Icon(
              Icons.lightbulb_rounded,
              size: 13,
              color: lamp == null ? hv.tx3 : colorOf(onColorFor(rgbOf(lamp))),
            ),
    );
  }

  Widget _end(HavenColors hv, double r, Color? lamp) => Container(
    width: r * 2,
    height: r * 2,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(mini ? 1.6 : 5),
      color: lamp ?? hv.s3,
      border: Border.all(
        color: info.available ? hv.tx3 : hv.bad,
        width: mini ? 0.8 : 1.6,
      ),
    ),
  );
}
