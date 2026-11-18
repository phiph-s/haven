import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/light/color_math.dart';
import '../../../core/light/room_palette.dart';
import '../../../core/state/providers.dart';
import '../../../core/theme/tokens.dart';
import '../../../data/models/lamp.dart';
import '../../../data/models/zigbee_network.dart';
import '../../map/floor_geometry.dart' show FloorNode;
import '../../map/map_3d.dart';
import 'package:haven_3d/haven_3d.dart' as h3;
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

/// Bildschirm-Projektion der Netzkarte zum Zeitpunkt des letzten Bildes
/// (für Ziehen und Ausweichen). Ändert sich ohne Benachrichtigung.
class MeshProjection {
  h3.SceneProjection? current;
}

/// Kamera und Szene der Netzkarte (Vollbild und Kartenart Funknetz): eigene
/// Szene, weil der Netzplan den Bereich „Ohne Raum“ enthält.
final meshControllerProvider = Provider<h3.SceneController>((ref) {
  final c = h3.SceneController();
  ref.onDispose(c.dispose);
  return c;
});

/// Der Netz-Graph auf der 3D-Karte: Kanten als Overlay, Knoten als Widgets.
/// Gleiche Ansicht für Vollbild und Miniatur ([mini]: ohne Beschriftung,
/// ohne Interaktion, eigene kleine Szene).
class MeshGraph extends ConsumerStatefulWidget {
  const MeshGraph({
    super.key,
    required this.scene,
    required this.map,
    required this.state,
    this.mini = false,
    this.interactive = true,
    this.onNodeTap,
    this.onRoomTap,
    this.coordinatorDrag,
    this.projection,
    this.insets = EdgeInsets.zero,
  });

  final MeshScene scene;
  final ZbNetworkMap map;
  final ValueListenable<MeshViewState> state;
  final bool mini;
  final bool interactive;
  final ValueChanged<String>? onNodeTap;
  final VoidCallback? onRoomTap;
  final MeshCoordinatorDrag? coordinatorDrag;

  /// Bekommt die Projektion jedes Bildes (Knotenpunkte, Boden ↔ Schirm).
  final MeshProjection? projection;
  final EdgeInsets insets;

  /// Knoten für die Karte: Endgeräte unten, Koordinator oben.
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
  ConsumerState<MeshGraph> createState() => _MeshGraphState();
}

class _MeshGraphState extends ConsumerState<MeshGraph> {
  /// Miniatur: eigene, kleine Szene (die große Netzkarte behält ihre).
  h3.SceneController? _own;

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final w = widget;
    final c = w.mini
        ? (_own ??= h3.SceneController())
        : ref.watch(meshControllerProvider);
    return Map3DView(
      key: ValueKey(w.mini ? 'mesh-mini' : 'mesh'),
      plan: w.scene.plan,
      controller: c,
      nodes: MeshGraph.floorNodes(w.scene, w.map, mini: w.mini),
      nodeBuilder: (context, node) => MeshNodeDot(
        info: w.scene.infos[node.id]!,
        map: w.map,
        state: w.state,
        mini: w.mini,
        drag: node.id == w.scene.coordinatorIeee ? w.coordinatorDrag : null,
      ),
      markerKind: (_) => h3.MarkerKind.device,
      overlayBuilder: (context, p) {
        w.projection?.current = p;
        return RepaintBoundary(
          child: CustomPaint(
            painter: MeshEdgePainter(
              edges: w.map.edges,
              scene: w.scene,
              state: w.state,
              hv: hv,
              mini: w.mini,
              nodes: p.markers,
            ),
          ),
        );
      },
      onNodeTap: w.onNodeTap == null ? null : (n) => w.onNodeTap!(n.id),
      onRoomTap: w.onRoomTap == null ? null : (_) => w.onRoomTap!(),
      onOutsideTap: w.onRoomTap,
      interactive: w.interactive && !w.mini,
      interactiveMarkers: w.coordinatorDrag != null,
      showLabels: !w.mini,
      quality: w.mini ? h3.SceneQuality.low : null,
      followSettings: !w.mini,
      insets: w.insets,
    );
  }
}

/// Ein Knoten: Router rund mit Ring, Endgerät als kleines abgerundetes
/// Quadrat, Koordinator als großer Akzentknoten. Lampen tragen ihre
/// Lichtfarbe.
/// Kleines Warnzeichen am Knoten: Z2M hat ihn bei der Messung nicht erreicht.
class _FailedBadge extends StatelessWidget {
  const _FailedBadge({required this.color, required this.mini});
  final Color color;
  final bool mini;

  @override
  Widget build(BuildContext context) {
    final d = mini ? 6.0 : 10.0;
    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: context.hv.bg, width: mini ? 0.5 : 1.5),
      ),
    );
  }
}

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
        if (info.ghost) o = 0.4;
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
              if (info.ghost)
                CustomPaint(
                  size: Size.square(r * 2 + 4),
                  painter: _DashedRing(
                    color: hv.warn,
                    round: info.kind != ZbNodeKind.endDevice,
                    width: mini ? 1 : 1.8,
                  ),
                ),
              if (info.failed)
                Transform.translate(
                  offset: Offset(r * 0.85, -r * 0.85),
                  child: _FailedBadge(color: hv.warn, mini: mini),
                ),
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
    final ring = info.ghost
        ? const Color(0x00000000)
        : info.available
        ? (lamp == null ? hv.tx2 : hv.tx)
        : hv.bad;
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
        color: info.ghost
            ? const Color(0x00000000)
            : info.available
            ? hv.tx3
            : hv.bad,
        width: mini ? 0.8 : 1.6,
      ),
    ),
  );
}

/// Gestrichelter Rand für Geister-Geräte.
class _DashedRing extends CustomPainter {
  const _DashedRing({
    required this.color,
    required this.round,
    required this.width,
  });
  final Color color;
  final bool round;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(width);
    final path = Path()
      ..addRRect(
        round
            ? RRect.fromRectAndRadius(
                rect,
                Radius.circular(rect.shortestSide / 2),
              )
            : RRect.fromRectAndRadius(rect, const Radius.circular(5)),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      final dash = width * 3, gap = width * 2.2;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, math.min(d + dash, m.length)), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRing old) =>
      old.color != color || old.round != round || old.width != width;
}
