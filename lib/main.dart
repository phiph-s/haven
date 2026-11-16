import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/state/providers.dart';
import 'dev/fake_flag.dart';
import 'dev/fake_repository.dart';
import 'data/ha/ha_repository.dart';
import 'data/storage/settings_store.dart';
import 'debug_launch.dart';
import 'dev/fake_updates.dart';
import 'features/updates/app_update_provider.dart';

import 'package:package_info_plus/package_info_plus.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  unawaited(
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
  );

  final launch = LaunchOverrides.fromUri(Uri.base);
  final store = SettingsStore(await SharedPreferences.getInstance());
  final tokens = SecureTokenStore();
  if (launch.theme != null) await store.setThemeMode(launch.theme!);
  if (launch.layer != null) await store.setMapLayer(launch.layer!);

  final session = await _bootstrap(store, tokens, launch);

  runApp(
    ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(store),
        tokenStoreProvider.overrideWithValue(tokens),
        initialSessionProvider.overrideWithValue(session),
        appVersionProvider.overrideWithValue(await _appVersion()),
        // Entwicklungsdaten: erfundene Releases, kein Netz zu GitHub.
        if (kHavenFake && session.mode == SessionMode.fake) ...[
          httpClientProvider.overrideWithValue(buildFakeReleaseClient()),
          if (launch.screen != null)
            appInstallerProvider.overrideWithValue(FakeAppInstaller()),
        ],
      ],
      child: HavenApp(initialLocation: launch.location),
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

/// Version aus `pubspec.yaml` (über das Plattform-Paket).
Future<String> _appVersion() async {
  try {
    final v = (await PackageInfo.fromPlatform()).version;
    if (v.isNotEmpty) return v;
  } catch (_) {}
  return kFallbackAppVersion;
}
