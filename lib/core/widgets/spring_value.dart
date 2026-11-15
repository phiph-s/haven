import 'package:material_ui/material_ui.dart';
import 'package:flutter/physics.dart';

import '../theme/tokens.dart';

/// Ein Wert, der per Feder zu seinem Ziel läuft. Painter hören auf
/// [listenable] und zeichnen neu, ohne dass Widgets neu bauen.
class SpringValue {
  SpringValue(TickerProvider vsync, double initial)
    : _c = AnimationController.unbounded(vsync: vsync, value: initial);

  final AnimationController _c;

  double get value => _c.value;
  Listenable get listenable => _c;

  /// Folgt dem Finger ohne Verzögerung.
  void jumpTo(double v) {
    _c.stop();
    _c.value = v;
  }

  /// Federt zum Ziel, optional mit Anfangsgeschwindigkeit (Einheiten/s).
  void springTo(double target, {double velocity = 0, bool instant = false}) {
    if (instant) {
      jumpTo(target);
      return;
    }
    _c.animateWith(
      SpringSimulation(HavenMotion.springDesc, _c.value, target, velocity),
    );
  }

  void dispose() => _c.dispose();
}
