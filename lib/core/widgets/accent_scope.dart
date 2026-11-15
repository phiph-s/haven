import 'package:material_ui/material_ui.dart';

import '../light/room_palette.dart';
import '../theme/tokens.dart';

/// Färbt Akzent, Zweitakzent und Schrift auf Akzent für den Teilbaum nach der
/// Lichtfarbe (Spec 2.6). Ohne Licht bleibt der Standardakzent. Der Wechsel
/// wird gelerpt.
class AccentScope extends StatelessWidget {
  const AccentScope({super.key, required this.palette, required this.child});

  final RoomPalette palette;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final base = context.hv;
    final target = palette.isOn
        ? palette
        : RoomPalette(
            isOn: false,
            primary: base.acc,
            secondary: base.acc2,
            mix: base.acc,
            onAccent: base.ai,
            intensity: 0,
            brightness: 0,
          );
    return TweenAnimationBuilder<_Accent>(
      tween: _AccentTween(
        end: _Accent(target.primary, target.secondary, target.onAccent),
      ),
      // Kurz halten: Während des Lerps baut der ganze Teilbaum je Frame neu
      // (Theme ändert sich). Der Glow lerpt länger, der malt nur.
      duration: context.motion(HavenMotion.d3),
      curve: Curves.easeInOut,
      child: child,
      builder: (context, a, child) => Theme(
        data: Theme.of(context)
            .copyWith(extensions: [base.withAccent(a.acc, a.acc2, a.on)]),
        child: child!,
      ),
    );
  }
}

class _Accent {
  const _Accent(this.acc, this.acc2, this.on);
  final Color acc;
  final Color acc2;
  final Color on;

  @override
  bool operator ==(Object other) =>
      other is _Accent &&
      other.acc == acc &&
      other.acc2 == acc2 &&
      other.on == on;
  @override
  int get hashCode => Object.hash(acc, acc2, on);
}

class _AccentTween extends Tween<_Accent> {
  _AccentTween({super.end});
  @override
  _Accent lerp(double t) => _Accent(
    Color.lerp(begin!.acc, end!.acc, t)!,
    Color.lerp(begin!.acc2, end!.acc2, t)!,
    Color.lerp(begin!.on, end!.on, t)!,
  );
}
