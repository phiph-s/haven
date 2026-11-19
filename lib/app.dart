import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'core/router/router.dart';
import 'core/state/providers.dart';
import 'core/theme/theme.dart';
import 'core/widgets/system_bars.dart';
import 'features/home_widget/room_widget_bridge.dart';
import 'features/zigbee/widgets/zb_common.dart' show zbToast;

/// Wurzel der App: Theme (Hell, Dunkel, System), Router, Deutsch.
class HavenApp extends ConsumerWidget {
  const HavenApp({super.key, this.initialLocation});

  /// Nur für Screenshots und Tests.
  final String? initialLocation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider(initialLocation));
    // Raum-Widgets auf dem Startbildschirm aktuell halten (nur Android).
    ref.watch(roomWidgetSyncProvider);
    final mode = ref.watch(themeModeProvider);
    // Hinweise beim Speichern geteilter Daten (z. B. ohne Admin-Rechte).
    ref.listen(syncNoticeProvider, (_, n) {
      final ctx = rootNavigatorKey.currentContext;
      if (n != null && ctx != null) zbToast(ctx, n.text, error: true);
    });
    return MaterialApp.router(
      title: 'Haven',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      theme: havenLightTheme,
      darkTheme: havenDarkTheme,
      themeMode: mode,
      themeAnimationDuration: const Duration(milliseconds: 320),
      locale: const Locale('de'),
      supportedLocales: const [Locale('de')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        // Rückfall für alles ohne eigene Region (Onboarding, Sheets). Die
        // Bildschirme setzen ihre eigene über `SystemBars`.
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemBars.styleFor(dark: dark),
          child: child!,
        );
      },
    );
  }
}
