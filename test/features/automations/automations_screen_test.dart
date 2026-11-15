import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/core/widgets/haven_switch.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

late FakeRepository _repo;

Future<Widget> _app(String location) async {
  SharedPreferences.setMockInitialValues({});
  final store = SettingsStore(await SharedPreferences.getInstance());
  _repo = FakeRepository(simulate: false);
  await _repo.start();
  return ProviderScope(
    overrides: [
      settingsStoreProvider.overrideWithValue(store),
      tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
      initialSessionProvider.overrideWithValue(
        Session(SessionMode.fake, _repo),
      ),
    ],
    child: HavenApp(initialLocation: location),
  );
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(412 * 2.625, 915 * 2.625);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
}

Future<void> _pump(WidgetTester tester, String loc) async {
  _phone(tester);
  await tester.runAsync(() async => tester.pumpWidget(await _app(loc)));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  testWidgets('Abläufe rendern mit den Beispieldaten', (tester) async {
    await _pump(tester, '/automations');
    expect(find.text('Abläufe'), findsWidgets);
    expect(find.text('6 von 7 aktiv'), findsOneWidget);
    expect(find.text('Neuer Ablauf'), findsOneWidget);
    expect(find.text('Salon'), findsWidgets);
    expect(find.textContaining('zuletzt vor'), findsWidgets);
    expect(find.text('Salon Licht bei Bewegung'), findsOneWidget);
  });

  testWidgets('Suche filtert', (tester) async {
    await _pump(tester, '/automations');
    await tester.enterText(find.byType(TextField), 'Feuchte');
    await tester.pumpAndSettle();
    expect(find.text('Lüfter bei hoher Feuchte'), findsOneWidget);
    expect(find.text('Salon Licht bei Bewegung'), findsNothing);
    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pumpAndSettle();
    expect(find.text('Nichts gefunden.'), findsOneWidget);
  });

  testWidgets('Schalter legt Ablauf um und dämpft ihn', (tester) async {
    await _pump(tester, '/automations');
    const id = 'automation.lufter_bei_hoher_feuchte';
    await tester.enterText(find.byType(TextField), 'hoher Feuchte');
    await tester.pumpAndSettle();
    expect(_repo.snapshot.entity(id)!.isOn, isTrue);
    final sw = find.descendant(
      of: find.ancestor(
        of: find.text('Lüfter bei hoher Feuchte'),
        matching: find.byType(Dismissible),
      ),
      matching: find.byType(HavenSwitch),
    );
    await tester.ensureVisible(sw.first);
    await tester.tap(sw.first, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_repo.snapshot.entity(id)!.isOn, isFalse);
    await tester.pump(const Duration(seconds: 3));
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('5 von 7 aktiv'), findsOneWidget);
  });

  testWidgets('Jetzt ausführen setzt last_triggered', (tester) async {
    await _pump(tester, '/automations');
    DateTime? newest() => _repo.snapshot.entities.values
        .where((e) => e.domain == 'automation')
        .map((e) => DateTime.tryParse('${e.attributes['last_triggered']}'))
        .whereType<DateTime>()
        .fold<DateTime?>(null, (m, d) => m == null || d.isAfter(m) ? d : m);
    await tester.enterText(find.byType(TextField), 'hoher Feuchte');
    await tester.pumpAndSettle();
    final before = newest();
    final run = find.byIcon(Icons.play_arrow_rounded);
    await tester.ensureVisible(run.first);
    await tester.tap(run.first, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(newest()!.isAfter(before!), isTrue);
    expect(find.textContaining('ausgeführt'), findsWidgets);
    await tester.pump(const Duration(seconds: 3));
  });
}
