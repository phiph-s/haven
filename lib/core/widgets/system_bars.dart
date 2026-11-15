import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';

/// Status- und Navigationsleiste für einen Bildschirm: beide durchsichtig,
/// der Hintergrund läuft dahinter weiter. Die Symbole sind hell auf dunklem
/// und dunkel auf hellem Grund. Ohne [dark] gilt das Theme.
///
/// Jede Route legt das um ihren Inhalt (Router und Unterseiten). Flutter
/// nimmt die oberste Region an der Position der Leiste, deshalb gewinnt der
/// Bildschirm, der gerade oben liegt, auch während eines Übergangs.
class SystemBars extends StatelessWidget {
  const SystemBars({super.key, required this.child, this.dark});
  final Widget child;

  /// Hintergrund hinter den Leisten ist dunkel. `null` = Theme.
  final bool? dark;

  static SystemUiOverlayStyle styleFor({required bool dark}) =>
      SystemUiOverlayStyle(
        statusBarColor: const Color(0x00000000),
        systemNavigationBarColor: const Color(0x00000000),
        systemNavigationBarDividerColor: const Color(0x00000000),
        systemNavigationBarContrastEnforced: false,
        systemStatusBarContrastEnforced: false,
        // Android: Symbolfarbe, iOS: Textfarbe der Statusleiste.
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        systemNavigationBarIconBrightness: dark
            ? Brightness.light
            : Brightness.dark,
      );

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: styleFor(dark: dark ?? context.hv.isDark),
      child: child,
    );
  }
}
