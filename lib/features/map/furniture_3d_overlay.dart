import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:haven_3d/haven_3d.dart' as h3;
import 'package:material_ui/material_ui.dart';

import '../../core/adaptive/breakpoints.dart';
import '../../core/adaptive/hover.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/press_scale.dart';
import '../../data/models/floor_plan.dart';
import 'furniture_painter.dart';
import 'placement_3d.dart';

/// Was über der 3D-Szene beim Einrichten liegt: Grundfläche des gewählten
/// (oder gezogenen, neuen) Möbelstücks, der Drehring mit Griff und eine
/// kleine Werkzeugleiste über dem Möbelstück. Folgt der Kamera, weil es in
/// jedem Bild aus der Projektion [projection] entsteht.
class Furniture3dOverlay extends StatelessWidget {
  const Furniture3dOverlay({
    super.key,
    required this.projection,
    required this.item,
    required this.cellMeters,
    this.ring = false,
    this.ghost = false,
    this.label,
    this.toolbar,
    this.shift = Offset.zero,
  });

  /// Verschiebung (Meter), mit der die Szene das Möbelstück in den Raum
  /// rückt (siehe `sceneFitShift`).
  final Offset shift;

  final h3.SceneProjection projection;

  /// Gewähltes, gezogenes oder neues Möbelstück (`null`: nichts).
  final FloorFurniture? item;
  final double cellMeters;

  /// Drehring mit Griff zeigen.
  final bool ring;

  /// Neues Möbelstück, noch nicht abgestellt (gestrichelte Grundfläche).
  final bool ghost;

  /// Kurzinfo neben dem Möbelstück (z. B. der Winkel beim Drehen).
  final String? label;

  /// Werkzeuge über dem Möbelstück.
  final Widget? toolbar;

  /// Griffradius in Pixeln (am Touchscreen größer).
  static double knobRadius(BuildContext context) =>
      context.isDesktopLayout ? 11 : 15;

  /// Liegt [local] auf dem Drehgriff von [f]?
  static bool onKnob(
    BuildContext context,
    h3.SceneProjection p,
    FloorFurniture f,
    double cellMeters,
    Offset local,
  ) {
    final k = rotationKnob(f, cellMeters);
    final at = p.project(h3.V3(k.dx, k.dy, 0.02));
    return (at - local).distance <=
        knobRadius(context) + (context.isDesktopLayout ? 4 : 10);
  }

  @override
  Widget build(BuildContext context) {
    final f = item;
    if (f == null) return const SizedBox.shrink();
    final hv = context.hv;
    final p = projection;
    // Umriss des Quaders auf dem Bildschirm (für Werkzeuge und Beschriftung).
    final d = h3.V3(shift.dx, shift.dy, 0);
    final pts = [for (final q in furnitureBox(f, cellMeters)) p.project(q + d)];
    var top = double.infinity, bottom = -double.infinity;
    var left = double.infinity, right = -double.infinity;
    for (final q in pts) {
      top = math.min(top, q.dy);
      bottom = math.max(bottom, q.dy);
      left = math.min(left, q.dx);
      right = math.max(right, q.dx);
    }
    final size = p.size;
    final mid = (left + right) / 2;
    const barH = 52.0;
    // Über dem Möbelstück, sonst darunter; immer ganz im Bild.
    final above = top - 12 - barH >= 4;
    final barTop = above
        ? top - 12 - barH
        : math.min(bottom + 12, size.height - barH - 4);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _FootprintPainter(
                projection: p,
                item: f,
                cellMeters: cellMeters,
                ring: ring,
                ghost: ghost,
                knob: knobRadius(context),
                shift: shift,
                hv: hv,
              ),
            ),
          ),
        ),
        if (label != null)
          Positioned(
            left: mid - 60,
            width: 120,
            top: math.max(4, top - 36),
            child: IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: hv.acc,
                    borderRadius: BorderRadius.circular(HavenRadii.pill),
                  ),
                  child: Text(
                    label!,
                    style: HavenText.caption.copyWith(
                      color: hv.ai,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (toolbar != null)
          Positioned(
            left: 0,
            right: 0,
            top: barTop,
            height: barH,
            child: _CenterAt(x: mid, child: toolbar!),
          ),
      ],
    );
  }
}

/// Kind waagerecht um [x] zentriert, aber ganz in der Breite.
class _CenterAt extends SingleChildRenderObjectWidget {
  const _CenterAt({required this.x, super.child});
  final double x;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderCenterAt(x);

  @override
  void updateRenderObject(BuildContext context, _RenderCenterAt r) => r.x = x;
}

class _RenderCenterAt extends RenderShiftedBox {
  _RenderCenterAt(this._x) : super(null);
  double _x;
  set x(double v) {
    if (v == _x) return;
    _x = v;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    final c = child;
    if (c == null) return;
    c.layout(constraints.loosen(), parentUsesSize: true);
    final w = c.size.width;
    final left = (_x - w / 2)
        .clamp(6.0, math.max(6.0, size.width - w - 6))
        .toDouble();
    (c.parentData! as BoxParentData).offset = Offset(
      left,
      (size.height - c.size.height) / 2,
    );
  }
}

class _FootprintPainter extends CustomPainter {
  _FootprintPainter({
    required this.projection,
    required this.item,
    required this.cellMeters,
    required this.ring,
    required this.ghost,
    required this.knob,
    required this.hv,
    this.shift = Offset.zero,
  });

  final Offset shift;

  final h3.SceneProjection projection;
  final FloorFurniture item;
  final double cellMeters;
  final bool ring;
  final bool ghost;
  final double knob;
  final HavenColors hv;

  Offset _at(Offset m, [double z = 0.015]) =>
      projection.project(h3.V3(m.dx + shift.dx, m.dy + shift.dy, z));

  @override
  void paint(Canvas canvas, Size size) {
    final f = item;
    final m = cellMeters;
    final acc = hv.acc;
    // Grundfläche auf dem Boden: Fläche leicht getönt, Rand im Akzent.
    final foot = Path()
      ..addPolygon([for (final c in f.corners) _at(c * m)], true);
    canvas.drawPath(
      foot,
      Paint()..color = acc.withValues(alpha: ghost ? 0.22 : 0.14),
    );
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round
      ..color = acc.withValues(alpha: 0.95);
    if (ghost) {
      _dashed(canvas, [for (final c in f.corners) _at(c * m)], stroke);
    } else {
      canvas.drawPath(foot, stroke);
      // Umriss als Quader: in der hellen Szene sonst kaum zu sehen.
      final box = [
        for (final q in furnitureBox(f, m))
          projection.project(q + h3.V3(shift.dx, shift.dy, 0)),
      ];
      final edge = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..strokeJoin = StrokeJoin.round
        ..color = acc.withValues(alpha: 0.75);
      canvas.drawPath(Path()..addPolygon(box.sublist(4), true), edge);
      for (var i = 0; i < 4; i++) {
        canvas.drawLine(box[i], box[i + 4], edge);
      }
    }
    if (!ring) return;
    // Drehring um die Mitte, Griff vor der Vorderseite.
    final r = rotationRingRadius(f, m);
    final c = f.center * m;
    final ringPts = [
      for (var i = 0; i < 64; i++)
        _at(c + Offset.fromDirection(i / 64 * 2 * math.pi, r), 0.02),
    ];
    canvas.drawPath(
      Path()..addPolygon(ringPts, true),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = acc.withValues(alpha: 0.55),
    );
    final k = _at(rotationKnob(f, m), 0.02);
    final centre = _at(c, 0.02);
    canvas.drawLine(
      centre,
      k,
      Paint()
        ..strokeWidth = 1.4
        ..color = acc.withValues(alpha: 0.4),
    );
    canvas.drawCircle(
      k + const Offset(0, 1.5),
      knob + 1,
      Paint()
        ..color = const Color(0x33000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(k, knob, Paint()..color = acc);
    canvas.drawCircle(
      k,
      knob,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = hv.ai,
    );
    // Gebogener Pfeil im Griff.
    final arc = Rect.fromCircle(center: k, radius: knob * 0.48);
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..color = hv.ai;
    canvas.drawArc(arc, -math.pi * 0.9, math.pi * 1.45, false, pen);
    final end = k + Offset.fromDirection(math.pi * 0.55, knob * 0.48);
    canvas.drawLine(end, end + Offset(-knob * 0.3, -knob * 0.05), pen);
    canvas.drawLine(end, end + Offset(knob * 0.02, -knob * 0.3), pen);
  }

  void _dashed(Canvas canvas, List<Offset> pts, Paint paint) {
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i], b = pts[(i + 1) % pts.length];
      final len = (b - a).distance;
      if (len < 1) continue;
      for (var t = 0.0; t < len; t += 10) {
        canvas.drawLine(
          Offset.lerp(a, b, t / len)!,
          Offset.lerp(a, b, math.min(len, t + 6) / len)!,
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_FootprintPainter old) =>
      old.projection.camera != projection.camera ||
      old.projection.size != projection.size ||
      old.item != item ||
      old.ring != ring ||
      old.ghost != ghost ||
      old.knob != knob ||
      old.shift != shift ||
      old.hv != hv;
}

/// Werkzeugleiste über dem gewählten Möbelstück in 3D.
class FurnitureToolbar3d extends StatelessWidget {
  const FurnitureToolbar3d({
    super.key,
    required this.onRotateLeft,
    required this.onRotateRight,
    required this.onDuplicate,
    required this.onDelete,
    this.duplicateShortcut,
  });

  final VoidCallback onRotateLeft;
  final VoidCallback onRotateRight;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;
  final String? duplicateShortcut;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Container(
      key: const ValueKey('furniture-toolbar-3d'),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      decoration: BoxDecoration(
        color: hv.s1.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(HavenRadii.pill),
        border: Border.all(color: hv.ln2),
        boxShadow: hv.shadowSmall,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MiniTool(
            label: 'Um 90° nach links drehen',
            icon: Icons.rotate_left_rounded,
            onTap: onRotateLeft,
          ),
          MiniTool(
            label: 'Um 90° nach rechts drehen',
            shortcut: 'R',
            icon: Icons.rotate_right_rounded,
            onTap: onRotateRight,
          ),
          Container(
            width: 1,
            height: 22,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            color: hv.ln2,
          ),
          MiniTool(
            label: 'Duplizieren',
            shortcut: duplicateShortcut,
            icon: Icons.copy_all_rounded,
            onTap: onDuplicate,
          ),
          MiniTool(
            label: 'Löschen',
            shortcut: 'Entf',
            icon: Icons.delete_outline_rounded,
            destructive: true,
            onTap: onDelete,
          ),
        ],
      ),
    );
  }
}

/// Kleiner runder Knopf (Werkzeugleisten über der Szene).
class MiniTool extends StatelessWidget {
  const MiniTool({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.destructive = false,
    this.accent = false,
    this.shortcut,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool destructive;
  final bool accent;
  final String? shortcut;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final s = context.isDesktopLayout ? 38.0 : 44.0;
    final fg = destructive ? hv.bad : (accent ? hv.ai : hv.tx);
    return DesktopTooltip(
      message: label,
      shortcut: shortcut,
      child: Semantics(
        button: true,
        label: label,
        child: HoverBuilder(
          builder: (context, hover) => PressScale(
            onTap: () {
              Haptics.tick();
              onTap();
            },
            child: AnimatedContainer(
              duration: context.motion(HavenMotion.d1),
              width: s,
              height: s,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent
                    ? Color.alphaBlend(
                        hover ? hv.ai.withValues(alpha: 0.12) : hv.acc,
                        hv.acc,
                      )
                    : hoverOverlay(hv, hover),
              ),
              child: Icon(icon, size: 21, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}

/// Leiste beim Platzieren eines neuen Möbelstücks: was, wie, Drehen,
/// Abstellen und Abbrechen.
class PlacingBar extends StatelessWidget {
  const PlacingBar({
    super.key,
    required this.item,
    required this.onRotate,
    required this.onDrop,
    required this.onCancel,
  });

  final FloorFurniture item;
  final VoidCallback onRotate;
  final VoidCallback onDrop;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final desktop = context.isDesktopLayout;
    return Container(
      key: const ValueKey('placing-bar'),
      constraints: const BoxConstraints(maxWidth: 520),
      padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
      decoration: BoxDecoration(
        color: hv.s1.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(HavenRadii.pill),
        border: Border.all(color: hv.ln2),
        boxShadow: hv.shadowSmall,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: hv.acc.withValues(alpha: 0.14),
            ),
            child: Center(child: FurnitureThumb(kind: item.kind, size: 26)),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.type?.name ?? 'Möbelstück',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HavenText.label.copyWith(color: hv.tx, fontSize: 14),
                ),
                Text(
                  desktop
                      ? 'Klick stellt es ab, Esc bricht ab'
                      : 'Ziehen schiebt, Tippen stellt ab',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HavenText.caption.copyWith(
                    color: hv.tx2,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          MiniTool(
            label: 'Um 90° drehen',
            shortcut: 'R',
            icon: Icons.rotate_right_rounded,
            onTap: onRotate,
          ),
          MiniTool(
            label: 'Abbrechen',
            shortcut: 'Esc',
            icon: Icons.close_rounded,
            onTap: onCancel,
          ),
          const SizedBox(width: 2),
          MiniTool(
            label: 'Abstellen',
            shortcut: '↵',
            icon: Icons.check_rounded,
            accent: true,
            onTap: onDrop,
          ),
        ],
      ),
    );
  }
}
