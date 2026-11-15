import 'package:flutter/services.dart';

/// Haptik nach Spec 4: selectionClick bei Schalter, Szene und jeder
/// 10. Prozentstufe.
abstract final class Haptics {
  static void tick() => HapticFeedback.selectionClick();
  static void tap() => HapticFeedback.lightImpact();
}
