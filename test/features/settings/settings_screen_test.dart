import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Scrollable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  testWidgets('Einstellungen rendern, Räume und HA-Platzhalter öffnen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412 * 2.625, 915 * 2.625);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore(await SharedPreferences.getInstance());
    late FakeRepository repo;
    await tester.runAsync(() async {
      repo = FakeRepository(simulate: false, localPrefs: store);
      await repo.start();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsStoreProvider.overrideWithValue(store),
            tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
            initialSessionProvider.overrideWithValue(
              Session(SessionMode.fake, repo),
            ),
          ],
          child: const HavenApp(initialLocation: '/settings'),
        ),
      );
    });
    await tester.pumpAndSettle();

    expect(find.text('Erscheinungsbild'), findsOneWidget);
    expect(find.text('Entwicklungsdaten'), findsOneWidget);
    expect(find.text('Trennen'), findsNothing);
    expect(find.text('Grundriss bearbeiten'), findsOneWidget);
    expect(find.text('Räume verwalten'), findsOneWidget);
    // Einmal in „Zuhause“, einmal in „Synchronisation“.
    expect(find.text('Lichtsteuerung'), findsNWidgets(2));
    expect(find.text('Synchronisation'), findsOneWidget);
    expect(find.text('Jetzt abgleichen'), findsOneWidget);
    expect(find.text('Alle Lichter gehören dazu'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Home Assistant öffnen'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Home Assistant öffnen'), findsOneWidget);

    // Lichtsteuerung: ein Licht ausnehmen, gilt sofort und bleibt lokal.
    await tester.ensureVisible(find.text('Lichtsteuerung').first);
    await tester.tap(find.text('Lichtsteuerung').first);
    await tester.pumpAndSettle();
    final lamp = find.bySemanticsLabel(
      'Tischlampe Salon in der Lichtsteuerung',
    );
    expect(lamp, findsOneWidget);
    await tester.tap(lamp);
    await tester.pumpAndSettle();
    expect(repo.snapshot.excludedLights, {'light.tischlampe_salon'});
    expect(store.excludedLights, {'light.tischlampe_salon'});
    final wz = repo.snapshot.room('salon')!;
    expect(
      repo.snapshot.lampsOf(wz).map((l) => l.entityId),
      isNot(contains('light.tischlampe_salon')),
    );
    await tester.tapAt(const Offset(200, 60));
    await tester.pumpAndSettle();
    expect(find.text('1 Licht ausgenommen'), findsOneWidget);

    await tester.ensureVisible(find.text('Räume verwalten'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Räume verwalten'));
    await tester.pumpAndSettle();
    expect(find.text('Salon'), findsOneWidget);
    expect(find.textContaining('Geräte'), findsWidgets);
    await tester.tapAt(const Offset(200, 60));
    await tester.pumpAndSettle();

    // Karte: Perspektive und Qualität der 3D-Karte.
    await tester.scrollUntilVisible(
      find.text('Ausgewogen'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Perspektive'), findsOneWidget);

    // Wetter: Außenthermometer statt Temperatur vom Wetterdienst.
    await tester.scrollUntilVisible(
      find.text('Außentemperatur'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Wetterdienst'), findsOneWidget);
    expect(find.textContaining('Automatisch: '), findsOneWidget);
    expect(find.text('Vom Wetterdienst'), findsOneWidget);
    final thermo = repo.snapshot
        .byDomain('sensor')
        .firstWhere((e) => e.deviceClass == 'temperature');
    await tester.tap(find.text('Außentemperatur'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(thermo.name).last);
    await tester.tap(find.text(thermo.name).last);
    await tester.pumpAndSettle();
    expect(repo.snapshot.weather.temperature, thermo.entityId);
    expect(find.text(thermo.name), findsWidgets);
    // Zurück auf den Standard.
    await tester.tap(find.text('Außentemperatur'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vom Wetterdienst').last);
    await tester.pumpAndSettle();
    expect(repo.snapshot.weather.temperature, isNull);

    await tester.scrollUntilVisible(
      find.text('Home Assistant öffnen'),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Home Assistant öffnen'));
    await tester.tap(find.text('Home Assistant öffnen'));
    await tester.pumpAndSettle();
    expect(find.text('Öffnet in Home Assistant'), findsOneWidget);
    expect(find.textContaining('external_auth'), findsNothing);
  });
}
