import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';

/// Einblenden beim ersten Aufbau: 14 px nach oben, Skalierung .97 nach 1,
/// gestaffelt (30 ms je Index, höchstens 8 Stufen). Nur Transform und
/// FadeTransition (kein Opacity-Layer pro Frame). Die Staffelung steckt im
/// Intervall eines Controllers, es laufen keine Timer.
class EntryAnimation extends StatefulWidget {
  const EntryAnimation({super.key, required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  State<EntryAnimation> createState() => _EntryAnimationState();
}

class _EntryAnimationState extends State<EntryAnimation>
    with SingleTickerProviderStateMixin {
  static const _base = 320;
  late final int _delay = 30 * widget.index.clamp(0, 8);
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: _base + _delay),
  );
  late final Animation<double> _spring = CurvedAnimation(
    parent: _c,
    curve: Interval(_delay / (_base + _delay), 1, curve: HavenMotion.spring),
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _c,
    curve: Interval(
      _delay / (_base + _delay),
      (_delay + _base * 0.5) / (_base + _delay),
      curve: Curves.easeOut,
    ),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (context.reduceMotion) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _fade, child: _transform());
  }

  Widget _transform() {
    return AnimatedBuilder(
      animation: _spring,
      child: widget.child,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, 14 * (1 - _spring.value)),
        child: Transform.scale(
          scale: 0.97 + 0.03 * _spring.value,
          child: child,
        ),
      ),
    );
  }
}
