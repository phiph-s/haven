import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Scrollable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:material_ui/material_ui.dart' show Icons, Slider;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  testWidgets('Lampen kalibrieren: Typen, Korrektur speichern, Testwert', (
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

    // Zeile in den Einstellungen.
    final row = find.text('Lampen kalibrieren');
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Lampentypen'), findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();

    // Liste der Typen: Modell, Anzahl, Beispiel.
    expect(find.text('Tuya TS0505B_hs'), findsOneWidget);
    expect(find.text('3 Lampen · z. B. Lampe Decke Ruheraum'), findsOneWidget);
    expect(find.text('YSRSAI YSR-MINI-01_dimmer'), findsOneWidget);

    await tester.tap(find.text('Tuya TS0505B_hs'));
    await tester.pumpAndSettle();
    expect(find.text('Vorschau'), findsOneWidget);
    expect(find.text('Mit echter Lampe vergleichen'), findsOneWidget);

    // Testwert an die echte Lampe: 2700 K und 50 %.
    final before = repo.snapshot.lamp('light.lampe_decke_ruheraum')!;
    expect(before.kelvin, isNot(2700));
    await tester.tap(find.text('An Lampe zeigen'));
    await tester.pumpAndSettle();
    var now = repo.snapshot.lamp('light.lampe_decke_ruheraum')!;
    expect(now.kelvin, 2700);
    expect(now.brightness, 50);
    expect(find.text('Zurückstellen'), findsOneWidget);

    // Helligkeit insgesamt herunter: gespeichert nach kurzer Pause.
    await tester.scrollUntilVisible(
      find.text('2700 K wirkt wie'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('4000 K wirkt wie'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Insgesamt'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    final gain = find.byType(Slider).first;
    await tester.drag(gain, const Offset(-120, 0));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    final cal = repo.snapshot.lampCalibration.byModel['Tuya|TS0505B_hs'];
    expect(cal, isNotNull);
    expect(cal!.gain, lessThan(1));
    expect((store.lampCalibration['Tuya|TS0505B_hs'] as Map)['gain'], cal.gain);
    // Die Korrektur gilt für alle Lampen des Typs, nicht für andere.
    expect(
      repo.snapshot.lamp('light.lampe_waschraum')!.calibration.gain,
      cal.gain,
    );
    expect(repo.snapshot.lamp('light.tischlampe_salon')!.calibration.gain, 1);
    await tester.scrollUntilVisible(
      find.text('Korrektur zurücksetzen'),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    // Zurück: Die Lampe bekommt ihr voriges Licht, die Liste zeigt
    // „angepasst“.
    final back = find.byIcon(Icons.arrow_back_rounded);
    await tester.scrollUntilVisible(
      back,
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(back);
    await tester.pumpAndSettle();
    now = repo.snapshot.lamp('light.lampe_decke_ruheraum')!;
    expect(now.kelvin, before.kelvin);
    expect(now.brightness, before.brightness);
    expect(
      find.text('3 Lampen · z. B. Lampe Decke Ruheraum · angepasst'),
      findsOneWidget,
    );
  });
}
