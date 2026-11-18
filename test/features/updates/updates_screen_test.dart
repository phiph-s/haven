import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Scrollable;
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/dev/fake_updates.dart';
import 'package:haven/features/updates/app_installer.dart';
import 'package:haven/features/updates/app_release.dart';
import 'package:haven/features/updates/app_update_provider.dart';
import 'package:haven/features/updates/ha_updates_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Harness {
  _Harness(this.repo, this.store, this.installer, this.widget);
  final FakeRepository repo;
  final SettingsStore store;
  final AppInstaller installer;
  final ProviderScope widget;
}

Future<_Harness> _build({
  String? location,
  http.Client? client,
  Map<String, Object> prefs = const {},
  AppInstaller? installer,
  String version = '0.3.0',
  List<Override> extra = const [],
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final store = SettingsStore(await SharedPreferences.getInstance());
  final repo = FakeRepository(simulate: false, localPrefs: store);
  await repo.start();
  final inst = installer ?? FakeAppInstaller();
  return _Harness(
    repo,
    store,
    inst,
    ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(store),
        tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
        initialSessionProvider.overrideWithValue(
          Session(SessionMode.fake, repo),
        ),
        appVersionProvider.overrideWithValue(version),
        httpClientProvider.overrideWithValue(
          client ?? buildFakeReleaseClient(),
        ),
        appInstallerProvider.overrideWithValue(inst),
        urlOpenerProvider.overrideWithValue((_) async => true),
        ...extra,
      ],
      child: HavenApp(initialLocation: location),
    ),
  );
}

/// Gemerktes Release, wie es die Prüfung beim Start in den Einstellungen ablegt.
final _storedRelease = <String, Object>{
  'update_latest_release': jsonEncode(
    ReleaseInfo(
      version: '0.6.0',
      tag: 'v0.6.0',
      notes: '## Neu\n\n- Schnellere **Raumansicht**',
      pageUrl: 'https://github.com/phiph-s/haven/releases/tag/v0.6.0',
      apkUrl:
          'https://github.com/phiph-s/haven/releases/download/v0.6.0/haven-0.6.0.apk',
      apkSize: 1000,
    ).toJson(),
  ),
};

void _phone(WidgetTester tester, {double height = 915}) {
  tester.view.physicalSize = Size(412 * 2.625, height * 2.625);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
}

/// Lässt Frames und Zeitgeber laufen, bis auch die Netzantwort da ist.
Future<void> _settle(WidgetTester tester) async {
  // Die Prüfung startet in der echten Zone (runAsync), also echt warten.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump();
  await tester.pumpAndSettle();
}

Future<void> _scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(
    f,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  group('Updates-Screen mit Fake', () {
    testWidgets('zeigt Gruppen, Versionen und Fortschritt', (tester) async {
      _phone(tester, height: 2600);
      final h = await _build(location: '/settings/updates');
      await tester.runAsync(() async => tester.pumpWidget(h.widget));
      await _settle(tester);

      expect(find.text('Updates'), findsOneWidget);
      expect(find.text('5 Updates verfügbar'), findsOneWidget);
      expect(find.text('Haven'), findsWidgets);
      expect(find.text('Home Assistant'), findsOneWidget);
      expect(find.text('Home Assistant Core'), findsOneWidget);
      expect(find.textContaining('2026.11.1'), findsOneWidget);
      expect(find.text('Add-ons'), findsOneWidget);
      // Das Add-on läuft: Fortschritt statt Knöpfen.
      expect(find.text('Wird installiert, 42 %'), findsOneWidget);
      expect(find.text('Alle aktualisieren'), findsOneWidget);
      await _scrollTo(tester, find.text('Geräte'));
      expect(find.text('Dimmer Flur'), findsOneWidget);
      // Kein Hinweis „nicht über HACS“, die Entity für Haven existiert.
      expect(find.textContaining('nicht über HACS'), findsNothing);
    });

    testWidgets('Versionshinweise kommen über update/release_notes', (
      tester,
    ) async {
      _phone(tester, height: 2600);
      final h = await _build(location: '/settings/updates');
      await tester.runAsync(() async => tester.pumpWidget(h.widget));
      await _settle(tester);
      await _scrollTo(tester, find.text('Integrationen'));
      final notes = find.text('Versionshinweise');
      expect(notes, findsWidgets);
      await tester.tap(notes.first);
      await tester.pumpAndSettle();
      expect(find.text('Haven 0.3.0'), findsWidgets);
      expect(find.textContaining('Updates in der App'), findsOneWidget);
    });

    testWidgets('Aktualisieren ohne Backup-Bit startet direkt', (tester) async {
      _phone(tester, height: 2600);
      final h = await _build(location: '/settings/updates');
      await tester.runAsync(() async => tester.pumpWidget(h.widget));
      await _settle(tester);
      await _scrollTo(tester, find.text('Integrationen'));
      expect(h.repo.snapshot.entity('update.sonnenstand_update')!.isOn, isTrue);
      final install = find.text('Aktualisieren');
      // Reihenfolge: Haven, Core, Add-on (läuft), Integration, Gerät.
      await tester.ensureVisible(install.at(2));
      await tester.tap(install.at(2));
      await tester.pumpAndSettle();
      expect(
        h.repo.snapshot.entity('update.sonnenstand_update')!.isOn,
        isFalse,
      );
      expect(find.text('Sonnenstand'), findsNothing);
    });

    testWidgets('Core fragt nach, nennt den Neustart und bietet Backup an', (
      tester,
    ) async {
      _phone(tester, height: 2600);
      final h = await _build(location: '/settings/updates');
      await tester.runAsync(() async => tester.pumpWidget(h.widget));
      await _settle(tester);
      await tester.tap(find.text('Aktualisieren').at(1));
      await tester.pumpAndSettle();
      expect(find.text('Home Assistant Core aktualisieren'), findsOneWidget);
      expect(find.textContaining('HA startet neu'), findsOneWidget);
      expect(find.text('Vorher Backup'), findsOneWidget);
      expect(
        h.repo.snapshot.entity('update.home_assistant_core_update')!.isOn,
        isTrue,
      );
      await tester.tap(find.text('Aktualisieren').last);
      await tester.pumpAndSettle();
      expect(
        h.repo.snapshot.entity('update.home_assistant_core_update')!.isOn,
        isFalse,
      );
    });

    testWidgets('Alle aktualisieren bestätigt und nimmt Core aus', (
      tester,
    ) async {
      _phone(tester, height: 2600);
      final h = await _build(location: '/settings/updates');
      await tester.runAsync(() async => tester.pumpWidget(h.widget));
      await _settle(tester);
      await tester.tap(find.text('Alle aktualisieren'));
      await tester.pumpAndSettle();
      expect(find.text('3 Updates installieren?'), findsOneWidget);
      expect(find.textContaining('Core, OS und Supervisor'), findsOneWidget);
      await tester.tap(find.text('Alle aktualisieren').last);
      await tester.pumpAndSettle();
      final s = h.repo.snapshot;
      expect(s.entity('update.sonnenstand_update')!.isOn, isFalse);
      expect(s.entity('update.dimmer_flur_firmware')!.isOn, isFalse);
      expect(s.entity('update.haven_update')!.isOn, isFalse);
      expect(s.entity('update.home_assistant_core_update')!.isOn, isTrue);
    });

    testWidgets('Überspringen ruft update.skip', (tester) async {
      _phone(tester, height: 2600);
      final h = await _build(location: '/settings/updates');
      await tester.runAsync(() async => tester.pumpWidget(h.widget));
      await _settle(tester);
      await tester.tap(find.text('Überspringen').first);
      await tester.pumpAndSettle();
      expect(h.repo.snapshot.entity('update.haven_update')!.isOn, isFalse);
      expect(
        h.repo.snapshot
            .entity('update.haven_update')!
            .attributes['skipped_version'],
        '0.3.0',
      );
    });

    testWidgets('Hinweis zu HACS und neue Integration, wenn die Entity fehlt', (
      tester,
    ) async {
      _phone(tester, height: 2600);
      final h = await _build(
        location: '/settings/updates',
        extra: [havenUpdateEntityProvider.overrideWithValue(false)],
      );
      await tester.runAsync(() async => tester.pumpWidget(h.widget));
      await _settle(tester);
      expect(
        find.text('Haven-Integration nicht über HACS installiert'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Installiert ist Version 0.2.0'),
        findsOneWidget,
      );
      expect(find.text('Integration 0.3.0 verfügbar'), findsOneWidget);
    });

    testWidgets('kein Hinweis, solange HACS die Entity liefert', (
      tester,
    ) async {
      _phone(tester, height: 2600);
      final h = await _build(location: '/settings/updates');
      await tester.runAsync(() async => tester.pumpWidget(h.widget));
      await _settle(tester);
      expect(find.textContaining('nicht über HACS'), findsNothing);
    });
  });

  group('Update-Karte der App', () {
    testWidgets('erscheint auf Zuhause und lässt sich schließen', (
      tester,
    ) async {
      _phone(tester);
      final h = await _build(location: '/home');
      await tester.runAsync(() async => tester.pumpWidget(h.widget));
      await _settle(tester);
      expect(find.text('Haven 0.6.0 ist da'), findsOneWidget);
      expect(find.text('5 Updates verfügbar'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Haven 0.6.0 ist da'), findsNothing);
      expect(h.store.updateDismissed, '0.6.0');
      expect(h.store.updateLastCheck, isNotNull);
    });

    testWidgets('bleibt weg, wenn die Version schon weggewischt wurde', (
      tester,
    ) async {
      _phone(tester);
      final h = await _build(
        location: '/home',
        prefs: {'update_dismissed': '0.6.0'},
      );
      await tester.runAsync(() async => tester.pumpWidget(h.widget));
      await _settle(tester);
      expect(find.text('Haven 0.6.0 ist da'), findsNothing);
    });

    testWidgets('keine Karte bei gleicher Version, kein Aufruf im Intervall', (
      tester,
    ) async {
      _phone(tester);
      var calls = 0;
      final h = await _build(
        location: '/home',
        version: '0.6.0',
        client: MockClient((req) async {
          calls++;
          return buildFakeReleaseClient(appVersion: '0.6.0').get(req.url);
        }),
      );
      await tester.runAsync(() async => tester.pumpWidget(h.widget));
      await _settle(tester);
      expect(calls, 1);
      expect(find.textContaining('ist da'), findsNothing);

      final recent = await _build(
        location: '/home',
        prefs: {
          'update_last_check': DateTime.now()
              .subtract(const Duration(hours: 1))
              .millisecondsSinceEpoch,
        },
        client: MockClient((req) async {
          calls++;
          return http.Response('{}', 500);
        }),
      );
      await tester.runAsync(() async => tester.pumpWidget(recent.widget));
      await tester.pumpAndSettle();
      expect(calls, 1);
    });

    testWidgets(
      'Einstellungen zeigen Release-Notes und den Installationsknopf',
      (tester) async {
        _phone(tester, height: 2600);
        final h = await _build(location: '/settings', prefs: _storedRelease);
        await tester.runAsync(() async => tester.pumpWidget(h.widget));
        await tester.pumpAndSettle();
        await _scrollTo(tester, find.text('Haven 0.6.0 ist verfügbar'));
        expect(find.text('Du hast 0.3.0.'), findsOneWidget);
        expect(find.textContaining('Schnellere'), findsOneWidget);
        await _scrollTo(tester, find.text('Herunterladen und installieren'));
        expect(find.text('Herunterladen und installieren'), findsOneWidget);
        expect(find.text('Updates in Home Assistant'), findsOneWidget);
      },
    );

    testWidgets('ohne Android nur die Release-Seite', (tester) async {
      _phone(tester, height: 2600);
      final h = await _build(
        location: '/settings',
        prefs: _storedRelease,
        installer: const UnsupportedAppInstaller(),
      );
      await tester.runAsync(() async => tester.pumpWidget(h.widget));
      await _settle(tester);
      await _scrollTo(tester, find.text('Neue Version 0.6.0 verfügbar'));
      expect(find.text('Release-Seite öffnen'), findsOneWidget);
    });
  });
}
