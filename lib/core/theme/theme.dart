import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

/// Baut das [ThemeData] aus den Haven-Tokens. Die Komponenten lesen ihre
/// Farben aus der [HavenColors]-Extension, nicht aus dem ColorScheme.
ThemeData buildHavenTheme(HavenColors c) {
  final scheme = ColorScheme(
    brightness: c.brightness,
    primary: c.acc,
    onPrimary: c.ai,
    secondary: c.acc2,
    onSecondary: c.ai,
    error: c.bad,
    onError: c.ai,
    surface: c.s1,
    onSurface: c.tx,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: c.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    splashFactory: NoSplash.splashFactory,
    highlightColor: const Color(0x00000000),
    dividerColor: c.ln,
    textTheme: Typography.material2021().black.apply(
      bodyColor: c.tx,
      displayColor: c.tx,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Color(0x00000000),
      surfaceTintColor: Color(0x00000000),
    ),
    extensions: [c],
  );
}

final ThemeData havenLightTheme = buildHavenTheme(HavenColors.light);
final ThemeData havenDarkTheme = buildHavenTheme(HavenColors.dark);
