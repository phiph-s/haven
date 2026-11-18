import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/tokens.dart';
import '../../../data/models/zigbee_network.dart';
import '../zigbee_model.dart';
import 'mesh_scene.dart';

/// Radius der Knoten, damit Kanten und Pfeile am Rand enden.
double meshNodeRadius(ZbNodeKind k, {bool mini = false}) => switch (k) {
  ZbNodeKind.coordinator => mini ? 6.5 : 17,
  ZbNodeKind.router => mini ? 4.5 : 12,
  ZbNodeKind.endDevice => mini ? 2.8 : 7.5,
};

/// Alle Kanten des Graphen in einem Painter (Overlay der 3D-Karte, die
/// Knotenpunkte kommen als Bildschirmpunkte über [nodes]).
///
/// - Quadratische Bézierkurven, deren Ausschlag je Kante wechselt, damit
///   parallele Kanten sich nicht decken. Pfeil zum Elternknoten.
/// - Farbe nach LQI-Stufe (`ok`, `warn`, `bad`). Kanten im Raum sind dezent,
///   Kanten zwischen Räumen kräftiger.
/// - LQI-Zahl nur an schwachen Kanten und an den Kanten des gewählten Knotens
///   (bei wenigen Kanten an allen).
/// - Auswahl und Filter kommen über [state]. Sie lösen nur ein Neuzeichnen
///   dieses Painters aus.
class MeshEdgePainter extends CustomPainter {
  MeshEdgePainter({
    required this.edges,
    required this.scene,
    required this.state,
    required this.hv,
    required this.nodes,
    this.mini = false,
  }) : super(repaint: state);

  /// Knoten-IEEE → Bildschirmpunkt.
  final Map<String, Offset> nodes;

  final List<ZbMeshEdge> edges;
  final MeshScene scene;
  final ValueListenable<MeshViewState> state;
  final HavenColors hv;
  final bool mini;

  final _text = <String, TextPainter>{};

  Color _levelColor(int lqi) => switch (LqiLevel.of(lqi)) {
    LqiLevel.good => hv.ok,
    LqiLevel.medium => hv.warn,
    LqiLevel.weak => hv.bad,
  };

  TextPainter _label(
    String text,
    Color color,
    double size,
    FontWeight w, {
    double maxWidth = double.infinity,
  }) => _text.putIfAbsent('$text|${color.toARGB32()}|$size|$maxWidth', () {
    if (_text.length > 120) _text.clear();
    return TextPainter(
      text: TextSpan(
        text: text,
        style: HavenText.caption.copyWith(
          color: color,
          fontSize: size,
          fontWeight: w,
          height: 1.1,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
  });

  @override
  void paint(Canvas canvas, Size size) {
    final st = state.value;
    final infos = scene.infos;
    final shown = [
      for (final e in edges)
        if (st.edgeShown(e, infos)) e,
    ];
    final labelAll = !mini && shown.length <= 12;
    // Bei „Alle Verbindungen“ nur am gewählten Knoten beschriften, sonst
    // werden es Hunderte Zahlen.
    final many = st.filter == MeshFilter.all;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final fill = Paint()..style = PaintingStyle.fill;

    // Erst gedimmte, dann normale, zuletzt hervorgehobene Kanten.
    int rank(ZbMeshEdge e) {
      final base = e.inTree ? 1 : 0;
      if (!st.hasSelection) return base;
      return st.pathEdges.contains(e.key) ? 3 : base;
    }

    final ordered = [...shown]..sort((a, b) => rank(a).compareTo(rank(b)));
    final labels = <_Label>[];
    for (final e in ordered) {
      final pa = nodes[e.a];
      final pb = nodes[e.b];
      if (pa == null || pb == null) continue;
      final d = pb - pa;
      final len = d.distance;
      if (len < 2) continue;
      final nrm = Offset(-d.dy, d.dx) / len;
      final side = (e.key.codeUnits.fold<int>(0, (a, c) => a + c) & 1) == 0
          ? 1.0
          : -1.0;
      final bend = math.min(0.13 * len, mini ? 7.0 : 20.0) * side;
      final ctrl = (pa + pb) / 2 + nrm * bend * 2;

      final ra = meshNodeRadius(
        infos[e.a]?.kind ?? ZbNodeKind.endDevice,
        mini: mini,
      );
      final rb = meshNodeRadius(
        infos[e.b]?.kind ?? ZbNodeKind.endDevice,
        mini: mini,
      );
      final start = pa + _unit(ctrl - pa) * (ra + 1);
      final tip = pb + _unit(ctrl - pb) * (rb + 1.5);
      final arrow = e.inTree ? (mini ? 3.4 : 6.5) : 0.0;
      final dirEnd = _unit(tip - ctrl);
      final lineEnd = tip - dirEnd * arrow * 0.8;

      final inter = scene.roomOf(e.a) != scene.roomOf(e.b);
      final weak = e.lqi < kWeakLqi;
      final onPath = st.pathEdges.contains(e.key);
      final touchSel = st.selected != null && e.touches(st.selected!);
      var alpha = weak ? 0.95 : (inter ? 0.8 : 0.42);
      var width = (inter ? 1.9 : 1.2) * (mini ? 0.7 : 1.0);
      if (!e.inTree) {
        // Nachbarschaft ohne Weg: dünn und leise, damit der Baum lesbar bleibt.
        alpha = weak ? 0.32 : 0.2;
        width = mini ? 0.5 : 0.8;
      }
      if (st.hasSelection) {
        if (onPath) {
          alpha = 1;
          width += 1.4;
        } else if (touchSel) {
          alpha = math.max(alpha, 0.7);
        } else {
          alpha *= 0.13;
        }
      }
      final color = _levelColor(e.lqi).withValues(alpha: alpha.clamp(0, 1));
      stroke
        ..color = color
        ..strokeWidth = width;
      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, lineEnd.dx, lineEnd.dy);
      canvas.drawPath(path, stroke);
      if (e.inTree) {
        final n = Offset(-dirEnd.dy, dirEnd.dx);
        final base = tip - dirEnd * arrow;
        final head = Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(base.dx + n.dx * arrow * 0.5, base.dy + n.dy * arrow * 0.5)
          ..lineTo(base.dx - n.dx * arrow * 0.5, base.dy - n.dy * arrow * 0.5)
          ..close();
        canvas.drawPath(head, fill..color = color);
      }
      final dimmed = st.hasSelection && !onPath && !touchSel;
      final wantLabel = many
          ? (touchSel || onPath)
          : (weak || touchSel || onPath || labelAll);
      if (!mini && !dimmed && (e.inTree || touchSel) && wantLabel) {
        labels.add(
          _Label(
            (pa + ctrl * 2 + pb) / 4,
            '${e.lqi}',
            _levelColor(e.lqi),
            weak || touchSel || onPath,
          ),
        );
      }
    }

    for (final l in labels) {
      final tp = _label(l.text, l.color, 10.5, FontWeight.w700);
      final r = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: l.at,
          width: tp.width + 8,
          height: tp.height + 3,
        ),
        const Radius.circular(8),
      );
      canvas.drawRRect(r, fill..color = hv.bg.withValues(alpha: 0.92));
      canvas.drawRRect(
        r,
        stroke
          ..color = l.color.withValues(alpha: l.strong ? 0.8 : 0.4)
          ..strokeWidth = 1,
      );
      tp.paint(canvas, l.at - Offset(tp.width / 2, tp.height / 2));
    }

    // Name des gewählten Knotens unter dem Knoten.
    final sel = st.selected;
    final at = sel == null ? null : nodes[sel];
    if (!mini && sel != null && at != null) {
      final info = infos[sel];
      final tp = _label(
        info?.name ?? sel,
        hv.tx,
        11.5,
        FontWeight.w700,
        maxWidth: 150,
      );
      final w = tp.width;
      final c =
          at +
          Offset(0, meshNodeRadius(info?.kind ?? ZbNodeKind.endDevice) + 14);
      final r = RRect.fromRectAndRadius(
        Rect.fromCenter(center: c, width: w + 14, height: tp.height + 8),
        const Radius.circular(10),
      );
      canvas.drawRRect(r, fill..color = hv.s1.withValues(alpha: 0.96));
      canvas.drawRRect(
        r,
        stroke
          ..color = hv.ln2
          ..strokeWidth = 1,
      );
      tp.paint(canvas, c - Offset(w / 2, tp.height / 2));
    }
  }

  static Offset _unit(Offset o) {
    final d = o.distance;
    return d == 0 ? Offset.zero : o / d;
  }

  @override
  bool shouldRepaint(MeshEdgePainter old) =>
      !identical(old.edges, edges) ||
      old.scene != scene ||
      old.hv != hv ||
      old.mini != mini ||
      !mapEquals(old.nodes, nodes);
}

class _Label {
  const _Label(this.at, this.text, this.color, this.strong);
  final Offset at;
  final String text;
  final Color color;
  final bool strong;
}
