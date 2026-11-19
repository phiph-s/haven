import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/panel/panel_host.dart';
import 'core/state/providers.dart';
import 'dev/fake_flag.dart';
import 'dev/fake_repository.dart';
import 'data/ha/ha_repository.dart';
import 'data/storage/settings_store.dart';
import 'debug_launch.dart';
import 'dev/fake_updates.dart';
import 'features/home_widget/room_widget_bridge.dart';
import 'features/updates/app_update_provider.dart';

import 'package:package_info_plus/package_info_plus.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  unawaited(
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
  );

  // Als Seitenleisten-Eintrag in Home Assistant (Web, `haven-panel.js`):
  // Anmeldung, Theme und Adresse kommen aus HA, die URL gehört HA.
  final panel = detectPanelHost();
  if (panel != null) setUrlStrategy(null);
  // Nur Entwicklungsdaten: Panel-Probe in einer HA-Attrappe mit `?screen=`,
  // dann laufen Fake-Daten im echten Panel-Rahmen (Screenshots).
  final panelProbe =
      kHavenFake &&
      panel != null &&
      Uri.base.queryParameters.containsKey('screen');

  final launch = panel != null && !panelProbe
      ? LaunchOverrides.none
      : LaunchOverrides.fromUri(Uri.base);
  final store = SettingsStore(await SharedPreferences.getInstance());
  final tokens = SecureTokenStore();
  if (launch.theme != null) await store.setThemeMode(launch.theme!);
  if (launch.layer != null) await store.setMapLayer(launch.layer!);

  final session = panel != null && !panelProbe
      ? panelSession(panel, store)
      : await _bootstrap(store, tokens, launch);

  // Einrichten eines Raum-Widgets: Android startet Haven mit dieser Route.
  final platformRoute =
      WidgetsBinding.instance.platformDispatcher.defaultRouteName;
  final widgetRoute = platformRoute.startsWith('/widget-config/')
      ? platformRoute
      : null;

  runApp(
    ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(store),
        tokenStoreProvider.overrideWithValue(tokens),
        initialSessionProvider.overrideWithValue(session),
        appVersionProvider.overrideWithValue(await _appVersion()),
        if (panel != null) ...[
          panelHostProvider.overrideWithValue(panel),
          themeModeProvider.overrideWith(() => PanelThemeModeController(panel)),
        ],
        // Entwicklungsdaten: erfundene Releases, kein Netz zu GitHub.
        if (kHavenFake && session.mode == SessionMode.fake) ...[
          httpClientProvider.overrideWithValue(buildFakeReleaseClient()),
          if (launch.screen != null)
            appInstallerProvider.overrideWithValue(FakeAppInstaller()),
        ],
      ],
      child: RoomWidgetLaunchHandler(
        child: HavenApp(initialLocation: widgetRoute ?? launch.location),
      ),
    ),
  );
}

/// Baut die Sitzung aus den gespeicherten Einstellungen.
Future<Session> _bootstrap(
  SettingsStore store,
  TokenStore tokens,
  LaunchOverrides launch,
) async {
  // Nur mit --dart-define=HAVEN_FAKE=true: Der Compiler entfernt diesen Zweig
  // samt `lib/dev/` im Release-Build.
  if (kHavenFake && launch.screen != 'onboarding') {
    // Mit `screen=` (Screenshots) ohne Zeitgeber, damit Bilder stabil sind.
    final repo = FakeRepository(
      simulate: launch.screen == null,
      localPrefs: store,
    );
    await repo.start();
    if (launch.preset == 'party') {
      await repo.applyScene('salon', 'neon_tokyo');
      await repo.applyScene('ruheraum', 'chill');
    }
    return Session(SessionMode.fake, repo);
  }
  switch (store.connectionMode) {
    case 'ha':
      final url = store.haUrl;
      final token = await tokens.read();
      if (url == null || token == null) return const Session(SessionMode.none);
      final repo = HaRepository(url: url, token: token, localPrefs: store);
      // Läuft im Hintergrund, der Status erscheint in der Oberfläche.
      unawaited(repo.start().catchError((Object _) {}));
      return Session(SessionMode.ha, repo);
  }
  return const Session(SessionMode.none);
}

/// Sitzung im HA-Panel: dieselbe Herkunft wie HA, Token aus `hass.auth`
/// (vor jedem Verbindungsaufbau frisch geholt). Kein Onboarding.
Session panelSession(PanelHost panel, SettingsStore store) {
  final s = panel.state;
  final repo = HaRepository(
    url: s.origin ?? Uri.base.origin,
    token: s.token ?? '',
    tokenProvider: panel.freshToken,
    localPrefs: store,
  );
  unawaited(repo.start().catchError((Object _) {}));
  return Session(SessionMode.ha, repo);
}

/// Version aus `pubspec.yaml` (über das Plattform-Paket).
Future<String> _appVersion() async {
  try {
    final v = (await PackageInfo.fromPlatform()).version;
    if (v.isNotEmpty) return v;
  } catch (_) {}
  return kFallbackAppVersion;
}
