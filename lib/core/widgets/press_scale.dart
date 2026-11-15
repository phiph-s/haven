import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';

/// Drücken skaliert auf 0,95 und federt zurück. Nur Transform.
class PressScale extends StatefulWidget {
  const PressScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = HavenMotion.pressScale,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double pressedScale;
  final HitTestBehavior behavior;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final reduce = context.reduceMotion;
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down ? widget.pressedScale : 1,
        duration: reduce
            ? Duration.zero
            : (_down ? const Duration(milliseconds: 100) : HavenMotion.d2),
        curve: _down ? HavenMotion.out : HavenMotion.spring,
        child: widget.child,
      ),
    );
  }
}
