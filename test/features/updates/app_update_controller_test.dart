import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/dev/fake_updates.dart';
import 'package:haven/features/updates/app_update_provider.dart';
import 'package:haven/features/updates/app_installer.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory dir;
  late FakeAppInstaller installer;
  late ProviderContainer container;
  late List<Uri> opened;
  late List<String> apkRequests;

  Future<void> setUpWith({bool allowed = true}) async {
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore(await SharedPreferences.getInstance());
    dir = Directory.systemTemp.createTempSync('haven_upd');
    installer = FakeAppInstaller(allowed: allowed, dir: dir.path);
    opened = [];
    apkRequests = [];
    final api = buildFakeReleaseClient(apkSize: 2000);
    final client = MockClient.streaming((req, body) async {
      if (req.url.host == 'api.github.com') {
        final r = await api.get(req.url);
        return http.StreamedResponse(
          Stream.value(r.bodyBytes),
          r.statusCode,
          headers: r.headers,
        );
      }
      apkRequests.add(req.url.toString());
      return http.StreamedResponse(
        Stream.fromIterable([List.filled(1000, 1), List.filled(1000, 2)]),
        200,
        contentLength: 2000,
      );
    });
    container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(store),
        appVersionProvider.overrideWithValue('0.3.0'),
        httpClientProvider.overrideWithValue(client),
        appInstallerProvider.overrideWithValue(installer),
        urlOpenerProvider.overrideWithValue((u) async {
          opened.add(u);
          return true;
        }),
      ],
    );
    addTearDown(() {
      container.dispose();
      dir.deleteSync(recursive: true);
    });
  }

  test('Prüfung findet 0.4.0 und merkt sich Zeit und Release', () async {
    await setUpWith();
    final ctl = container.read(appUpdateProvider.notifier);
    expect(container.read(appUpdateProvider).available, isFalse);
    await ctl.check();
    final s = container.read(appUpdateProvider);
    expect(s.release?.version, '0.4.0');
    expect(s.showCard, isTrue);
    expect(s.lastChecked, isNotNull);
    ctl.dismiss();
    expect(container.read(appUpdateProvider).showCard, isFalse);
    expect(container.read(appUpdateProvider).available, isTrue);
  });

  test('Fehler beim Prüfen: manuell sichtbar, automatisch still', () async {
    await setUpWith();
    final broken = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(
          SettingsStore(await SharedPreferences.getInstance()),
        ),
        httpClientProvider.overrideWithValue(
          MockClient((_) async => http.Response('', 500)),
        ),
      ],
    );
    addTearDown(broken.dispose);
    final ctl = broken.read(appUpdateProvider.notifier);
    await ctl.check(manual: false);
    expect(broken.read(appUpdateProvider).error, isNull);
    expect(broken.read(appUpdateProvider).lastChecked, isNull);
    await ctl.check();
    expect(broken.read(appUpdateProvider).error, isNotNull);
  });

  test('Download in den Cache, dann Installation per Intent', () async {
    await setUpWith();
    final ctl = container.read(appUpdateProvider.notifier);
    await ctl.check();
    await ctl.downloadAndInstall();
    final s = container.read(appUpdateProvider);
    expect(s.error, isNull);
    expect(s.phase, AppUpdatePhase.idle);
    final path = '${dir.path}/haven-0.4.0.apk';
    expect(installer.installed, [path]);
    expect(File(path).lengthSync(), 2000);
    // Zweiter Versuch nimmt die fertige Datei, kein neuer Download.
    await ctl.downloadAndInstall();
    expect(apkRequests, hasLength(1));
    expect(installer.installed, hasLength(2));
  });

  test('Falsche Dateigröße: Fehler, nichts installiert', () async {
    await setUpWith();
    final c = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(
          SettingsStore(await SharedPreferences.getInstance()),
        ),
        httpClientProvider.overrideWithValue(
          MockClient.streaming((req, _) async {
            if (req.url.host == 'api.github.com') {
              final r = await buildFakeReleaseClient(apkSize: 5000)
                  .get(req.url);
              return http.StreamedResponse(Stream.value(r.bodyBytes), 200);
            }
            return http.StreamedResponse(Stream.value([1, 2, 3]), 200);
          }),
        ),
        appInstallerProvider.overrideWithValue(installer),
      ],
    );
    addTearDown(c.dispose);
    await c.read(appUpdateProvider.notifier).check();
    await c.read(appUpdateProvider.notifier).downloadAndInstall();
    expect(c.read(appUpdateProvider).error, isNotNull);
    expect(installer.installed, isEmpty);
    expect(dir.listSync(), isEmpty);
  });

  test('Fehlende Erlaubnis führt zur Erklärung, nicht zum Download', () async {
    await setUpWith(allowed: false);
    final ctl = container.read(appUpdateProvider.notifier);
    await ctl.check();
    await ctl.downloadAndInstall();
    final s = container.read(appUpdateProvider);
    expect(s.needsPermission, isTrue);
    expect(apkRequests, isEmpty);
    await ctl.openInstallSettings();
    expect(installer.settingsOpened, 1);
    // Danach erlaubt: Der nächste Versuch lädt.
    installer.allowed = true;
    await ctl.downloadAndInstall();
    expect(container.read(appUpdateProvider).needsPermission, isFalse);
    expect(apkRequests.single, endsWith('haven-0.4.0.apk'));
  });

  test('Ohne Android öffnet der Knopf die Release-Seite', () async {
    await setUpWith();
    final c = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(
          SettingsStore(await SharedPreferences.getInstance()),
        ),
        httpClientProvider.overrideWithValue(buildFakeReleaseClient()),
        appInstallerProvider.overrideWithValue(const UnsupportedAppInstaller()),
        urlOpenerProvider.overrideWithValue((u) async {
          opened.add(u);
          return true;
        }),
      ],
    );
    addTearDown(c.dispose);
    await c.read(appUpdateProvider.notifier).check();
    await c.read(appUpdateProvider.notifier).downloadAndInstall();
    expect(opened.single.toString(), contains('/releases/tag/v0.4.0'));
  });
}
