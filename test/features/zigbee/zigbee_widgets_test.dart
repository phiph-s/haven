import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/core/widgets/haven_switch.dart';
import 'package:haven/data/haven_repository.dart';
import 'package:haven/dev/fake_data.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fake-Repository, dessen Z2M-Schreibbefehle auf Wunsch scheitern.
class _FailingFake extends FakeRepository {
  _FailingFake({super.simulate});
  @override
  Future<void> zigbeeSet(String ieee, Map<String, dynamic> values) async =>
      throw Exception('Zigbee2MQTT antwortet nicht.');
}

/// Merkt sich, mit welchem `force` entfernt wurde.
class _RemoveSpy extends FakeRepository {
  _RemoveSpy() : super(simulate: false);
  final removed = <(String, bool)>[];
  @override
  Future<void> zigbeeRemove(String ieee, {bool force = false}) {
    removed.add((ieee, force));
    return super.zigbeeRemove(ieee, force: force);
  }
}

String _ieeeOf(String model) =>
    ((kFakeZigbee['devices'] as List).firstWhere(
          (d) => d['model'] == model,
        ))['ieee']
        as String;

Future<Widget> _app(
  String location, {
  bool failing = false,
  ThemeMode? mode,
  FakeRepository? spy,
}) async {
  SharedPreferences.setMockInitialValues({
    if (mode != null) 'theme_mode': mode.name,
  });
  final store = SettingsStore(await SharedPreferences.getInstance());
  final repo =
      spy ??
      (failing
          ? _FailingFake(simulate: false)
          : FakeRepository(simulate: false));
  await repo.start();
  return ProviderScope(
    overrides: [
      settingsStoreProvider.overrideWithValue(store),
      tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
      initialSessionProvider.overrideWithValue(Session(SessionMode.fake, repo)),
    ],
    child: HavenApp(initialLocation: location),
  );
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(412 * 2.625, 915 * 2.625);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
}

Future<void> _open(
  WidgetTester tester,
  String location, {
  bool failing = false,
  FakeRepository? spy,
}) async {
  _phone(tester);
  late Widget app;
  await tester.runAsync(
    () async => app = await _app(location, failing: failing, spy: spy),
  );
  await tester.pumpWidget(app);
  // Endlosanimationen: nicht settlen, sondern Zeit vorspulen.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  testWidgets('Liste: Kopf, Braucht dich, Räume, Filter', (tester) async {
    await _open(tester, '/zigbee');
    expect(find.text('Zigbee'), findsWidgets);
    expect(find.textContaining('23 Geräte'), findsOneWidget);
    expect(find.textContaining('Kanal 25'), findsOneWidget);
    expect(find.text('Gerät hinzufügen'), findsOneWidget);
    expect(find.text('Funknetz'), findsOneWidget);
    expect(find.text('Braucht dich'), findsOneWidget);
    expect(find.text('Sensor Terrasse'), findsWidgets);
    expect(find.textContaining('Batterie bei 18 %'), findsOneWidget);
    // Filter schränkt ein.
    await tester.scrollUntilVisible(
      find.textContaining('Lichter'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.textContaining('Lichter'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Bewegungsmelder Waschraum'), findsNothing);
    await _close(tester);
  });

  for (final c in [
    (
      'Bewegungsmelder ZG-204ZL',
      'ZG-204ZL',
      'Bewegungsmelder Salon',
      'Empfindlichkeit',
    ),
    (
      'Steckdose mit Messung',
      'HT-SP-ZB-01',
      'Steckdose Messung 5',
      'Kindersicherung',
    ),
    (
      'Hue-Lampe',
      '9290022166',
      'Tischlampe Salon',
      'Verhalten nach Stromausfall',
    ),
  ]) {
    testWidgets('Gerät-Detail rendert: ${c.$1}', (tester) async {
      await _open(tester, '/zigbee/device/${_ieeeOf(c.$2)}');
      expect(tester.takeException(), isNull);
      expect(find.text(c.$3), findsWidgets);
      await tester.scrollUntilVisible(
        find.text('Diagnose'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Diagnose'), findsOneWidget);
      expect(find.textContaining(c.$4), findsWidgets);
      expect(tester.takeException(), isNull);
      await _close(tester);
    });
  }

  testWidgets('Immer an: sperrt die Steckdose gegen Ausschalten', (
    tester,
  ) async {
    final repo = FakeRepository(simulate: false);
    final ieee = _ieeeOf('HT-SP-ZB-01');
    await _open(tester, '/zigbee/device/$ieee', spy: repo);
    final row = find.byKey(const ValueKey('device-lock'));
    await tester.scrollUntilVisible(
      row,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(
      find.descendant(of: row, matching: find.byType(HavenSwitch)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(repo.snapshot.isLocked(ieee), isTrue);
    expect(find.byIcon(Icons.lock_rounded), findsWidgets);
    // Ausschalten geht nicht mehr, Einstellungen schon.
    final plug = repo.snapshot.locked.firstWhere(
      (id) => id.startsWith('switch.'),
    );
    await tester.runAsync(() async {
      await expectLater(
        repo.callService('switch', 'turn_off', entityId: plug),
        throwsA(isA<HavenException>()),
      );
      await expectLater(
        repo.zigbeeSet(ieee, {'state': 'OFF'}),
        throwsA(isA<HavenException>()),
      );
      await repo.zigbeeSet(ieee, {'child_lock': 'LOCK'});
    });
    await _close(tester);
  });

  testWidgets('Einstellung: optimistisch gesetzt, bei Fehler zurück', (
    tester,
  ) async {
    await _open(tester, '/zigbee/device/${_ieeeOf('ZG-204ZL')}', failing: true);
    final scroll = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Empfindlichkeit'),
      300,
      scrollable: scroll,
    );
    // Voreinstellung für den Bewegungsmelder: Hoch. Tippe auf Niedrig.
    await tester.tap(find.text('Niedrig'));
    await tester.pump(const Duration(milliseconds: 50));
    // Rückmeldung mit Fehler, der Wert springt auf Hoch zurück.
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('Nicht gespeichert'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await _close(tester);
  });

  testWidgets('Assistent läuft mit den Beispieldaten durch', (tester) async {
    await _open(tester, '/zigbee/pair');
    expect(find.text('Gerät hinzufügen'), findsOneWidget);
    expect(find.text('Suche starten'), findsOneWidget);

    await tester.tap(find.text('Suche starten'));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Suche läuft'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('3:5'), findsOneWidget);

    // Das Fake findet nach ein paar Sekunden ein Gerät, dann Interview.
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Neues Gerät gefunden'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('Name und Raum'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Sensor Flur');
    await tester.pump();
    await tester.tap(find.text('Kochbereich'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Hinzufügen'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('Sensor Flur ist bereit'), findsOneWidget);
    expect(find.textContaining('Kochbereich'), findsWidgets);
    expect(find.text('Temperatur'), findsOneWidget);
    expect(find.text('21,3'), findsOneWidget);
    await _close(tester);
  });

  testWidgets('Braucht dich zeigt Geister oben, Entfernen fragt nach', (
    tester,
  ) async {
    await _open(tester, '/zigbee');
    // Lampe Ruhebett (180 Tage) und Sensor Ruheraum (5 Tage).
    expect(find.text('Seit 180 Tagen nicht erreichbar'), findsOneWidget);
    expect(
      find.text('Seit 5 Tagen keine Meldung, Batterie prüfen'),
      findsOneWidget,
    );
    expect(find.textContaining('zuletzt gesehen am'), findsWidgets);
    // Geister stehen vor allen anderen Hinweisen.
    final ghostY = tester.getTopLeft(find.text('Lampe Ruhebett').first).dy;
    final otherY = tester.getTopLeft(find.text('Sensor Terrasse').first).dy;
    expect(ghostY, lessThan(otherY));
    // Batterie unter 21 Tagen: nur „Ignorieren“, Netzgerät: „Entfernen“.
    expect(find.text('Entfernen'), findsOneWidget);
    expect(find.text('Entfernen?'), findsNothing);

    await tester.tap(find.text('Entfernen'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.text('Lampe Ruhebett entfernen?'), findsOneWidget);
    expect(find.textContaining('aus Zigbee2MQTT, aus allen Gruppen'), findsOne);
    await tester.tap(find.text('Abbrechen'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.text('Seit 180 Tagen nicht erreichbar'), findsOneWidget);

    // Ignorieren blendet den Geist aus.
    await tester.tap(find.text('Ignorieren').first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Seit 180 Tagen nicht erreichbar'), findsNothing);
    await _close(tester);
  });

  testWidgets('Entfernen eines Geistes sendet force: true', (tester) async {
    final spy = _RemoveSpy();
    await _open(tester, '/zigbee', spy: spy);
    await tester.tap(find.text('Entfernen'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.tap(find.text('Entfernen').last);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(spy.removed, hasLength(1));
    expect(spy.removed.single.$2, isTrue);
    expect(find.text('Seit 180 Tagen nicht erreichbar'), findsNothing);
    await _close(tester);
  });
}
