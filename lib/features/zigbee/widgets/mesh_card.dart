import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/haven_card.dart';
import '../mesh/mesh_graph.dart';
import '../mesh/mesh_providers.dart';
import '../mesh/mesh_scene.dart';
import '../mesh/mesh_screen.dart' show zigbeeMeshPath;
import '../zigbee_model.dart';

/// Karte „Funknetz“ auf der Zigbee-Seite: Zusammenfassung und eine
/// Miniatur desselben Grundrisses mit Graph (ohne Interaktion). Antippen
/// öffnet die Vollbild-Ansicht. Solange es keine Netzkarte gibt (lädt oder
/// die Integration kennt den Befehl noch nicht), steht eine Skizze da.
class ZigbeeMeshCard extends ConsumerStatefulWidget {
  const ZigbeeMeshCard({super.key, required this.views});
  final List<ZbDeviceView> views;

  @override
  ConsumerState<ZigbeeMeshCard> createState() => _ZigbeeMeshCardState();
}

class _ZigbeeMeshCardState extends ConsumerState<ZigbeeMeshCard> {
  // Die Miniatur zeigt immer den Stand ohne Auswahl.
  final _state = ValueNotifier(const MeshViewState());

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final views = widget.views;
    final scene = ref.watch(meshSceneProvider);
    final map = ref.watch(zigbeeMeshProvider.select((d) => d.map));
    final routers = views.where((v) => v.device.isRouter).length;
    final ends = views
        .where((v) => !v.device.isRouter && !v.device.isCoordinator)
        .length;
    final lqis = [for (final v in views) ?v.lqi];
    final weak = lqis.where((q) => q < kWeakLqi).length;
    final avg = lqis.isEmpty
        ? null
        : (lqis.reduce((a, b) => a + b) / lqis.length).round();
    final showMap = scene != null && map != null;
    return HavenCard(
      radius: HavenRadii.l,
      padding: const EdgeInsets.all(16),
      onTap: () => context.push(zigbeeMeshPath),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (!showMap) ...[
                SizedBox(
                  width: 72,
                  height: 72,
                  child: CustomPaint(
                    painter: _MeshSketch(
                      line: hv.ln2,
                      node: hv.tx3,
                      hub: hv.acc,
                      router: hv.tx2,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Funknetz',
                      style: HavenText.headline.copyWith(color: hv.tx),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$routers Router, $ends Endgeräte'
                      '${avg == null ? '' : ' · Ø Signal $avg'}',
                      style: HavenText.body.copyWith(
                        color: hv.tx2,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      weak == 0
                          ? 'Keine schwachen Verbindungen'
                          : '$weak ${weak == 1 ? 'Gerät mit schwachem' : 'Geräte mit schwachem'} Signal',
                      style: HavenText.caption.copyWith(
                        color: weak == 0 ? hv.tx3 : hv.warn,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: hv.tx3),
            ],
          ),
          if (showMap) ...[
            const SizedBox(height: 12),
            ExcludeSemantics(
              child: SizedBox(
                height: 230,
                child: IgnorePointer(
                  child: MeshGraph(
                    scene: scene,
                    map: map,
                    state: _state,
                    mini: true,
                    interactive: false,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MeshSketch extends CustomPainter {
  const _MeshSketch({
    required this.line,
    required this.node,
    required this.hub,
    required this.router,
  });
  final Color line;
  final Color node;
  final Color hub;
  final Color router;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 84;
    Offset p(double x, double y) => Offset(x * s, y * s);
    final c = p(42, 42);
    final routers = [p(14, 20), p(70, 16), p(66, 66), p(18, 66)];
    final ends = [p(6, 40), p(40, 6), p(80, 42), p(44, 78)];
    final l = Paint()
      ..color = line
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    for (final r in routers) {
      canvas.drawLine(c, r, l);
    }
    for (var i = 0; i < ends.length; i++) {
      canvas.drawLine(routers[i], ends[i], l);
    }
    for (final e in ends) {
      canvas.drawCircle(e, 3 * s, Paint()..color = node);
    }
    for (final r in routers) {
      canvas.drawCircle(r, 5 * s, Paint()..color = router);
    }
    canvas.drawCircle(c, 9 * s, Paint()..color = hub.withValues(alpha: 0.25));
    canvas.drawCircle(c, 6 * s, Paint()..color = hub);
  }

  @override
  bool shouldRepaint(_MeshSketch old) =>
      old.line != line || old.hub != hub || old.node != node;
}
