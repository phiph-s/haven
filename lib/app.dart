import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'core/router/router.dart';
import 'core/state/providers.dart';
import 'core/theme/theme.dart';
import 'core/widgets/system_bars.dart';
import 'features/home_widget/room_widget_bridge.dart';
import 'features/map/map_3d.dart' show mapPreloadProvider;
import 'features/zigbee/widgets/zb_common.dart' show zbToast;
import 'features/search/search_sheet.dart';

/// Kommt die App wieder nach vorne, stößt sie die Verbindung zu Home
/// Assistant an (siehe `HavenRepository.nudgeConnection`): Im Hintergrund
/// kann sie unbemerkt gestorben oder die Wartezeit lang geworden sein.
final connectionNudgeProvider = Provider<void>((ref) {
  final l = AppLifecycleListener(
    onResume: () => ref.read(repositoryProvider).nudgeConnection(),
  );
  ref.onDispose(l.dispose);
});

void _search() {
  final ctx = rootNavigatorKey.currentContext;
  if (ctx != null) showHavenSearch(ctx);
}

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
    // Wieder vorne: Verbindung zu HA gleich prüfen bzw. neu aufbauen.
    ref.watch(connectionNudgeProvider);
    // Karte schon jetzt aufbauen (Baking im Hintergrund). Nicht in der
    // Widget-Einrichtung: deren Activity endet gleich wieder, und eine
    // abgebaute Engine mit 3D-Szene stürzt beim Freigeben der GPU-Puffer
    // ab (Vulkan-Gerät schon weg).
    if (!(initialLocation?.startsWith('/widget-config') ?? false)) {
      ref.watch(mapPreloadProvider);
    }
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
          // Strg+K (macOS: Cmd+K) öffnet überall die Suche.
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.keyK, control: true):
                  _search,
              const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
                  _search,
            },
            child: child!,
          ),
        );
      },
    );
  }
}
