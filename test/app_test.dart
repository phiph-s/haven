import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<Widget> _app({
  String? location,
  bool connected = true,
  ThemeMode? mode,
}) async {
  SharedPreferences.setMockInitialValues({
    if (mode != null) 'theme_mode': mode.name,
  });
  final store = SettingsStore(await SharedPreferences.getInstance());
  Session session = const Session(SessionMode.none);
  if (connected) {
    final repo = FakeRepository(simulate: false);
    await repo.start();
    session = Session(SessionMode.fake, repo);
  }
  return ProviderScope(
    overrides: [
      settingsStoreProvider.overrideWithValue(store),
      tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
      initialSessionProvider.overrideWithValue(session),
    ],
    child: HavenApp(initialLocation: location),
  );
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(412 * 2.625, 915 * 2.625);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() {
    // Haptik-Aufrufe ins Leere laufen lassen.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  testWidgets('Zuhause rendert mit den Beispieldaten: Räume, Werte, Widgets', (
    tester,
  ) async {
    _phone(tester);
    await tester.runAsync(() async {
      await tester.pumpWidget(await _app());
    });
    await tester.pumpAndSettle();

    expect(find.text('Zuhause'), findsWidgets);
    expect(find.text('Salon'), findsOneWidget);
    expect(find.text('Ruheraum'), findsOneWidget);
    expect(find.text('Kochbereich'), findsOneWidget);
    expect(find.text('Waschraum'), findsOneWidget);
    expect(find.textContaining('Tischlampe'), findsWidgets);
    expect(find.text('22,2°'), findsOneWidget);
    expect(find.text('kein Sensor'), findsWidgets);
    expect(find.text('Strom jetzt'), findsOneWidget);
    expect(find.textContaining('142', findRichText: true), findsWidgets);
    expect(find.text('Batterien'), findsOneWidget);
    // Navigation
    for (final t in ['Zuhause', 'Karte', 'Zigbee', 'Abläufe']) {
      expect(find.text(t), findsWidgets);
    }
  });

  testWidgets('Tippen auf die Kachel schaltet den Raum', (tester) async {
    _phone(tester);
    await tester.runAsync(() async => tester.pumpWidget(await _app()));
    await tester.pumpAndSettle();
    // Drei Räume aus (der Salon leuchtet).
    expect(find.text('Aus'), findsNWidgets(3));
    await tester.tap(find.text('Waschraum'));
    await tester.pumpAndSettle();
    expect(find.text('Aus'), findsNWidgets(2));
    expect(find.text('Lampe · 100 %'), findsOneWidget);
  });

  testWidgets(
    'Raum öffnet über den Pfeil und zeigt Regler, Szenen und Lampen, keine Drehregler',
    (tester) async {
      _phone(tester);
      final sem = tester.ensureSemantics();
      await tester.runAsync(() async => tester.pumpWidget(await _app()));
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Salon öffnen'));
      await tester.pumpAndSettle();

      expect(find.text('Szenen'), findsOneWidget);
      expect(find.text('Neon Tokyo'), findsOneWidget);
      expect(find.text('Lampen'), findsOneWidget);
      expect(find.text('Tischlampe Salon'), findsOneWidget);
      // Szene antippen färbt die Lampen
      await tester.tap(find.text('Neon Tokyo'));
      await tester.pumpAndSettle();
      expect(find.text('Szene Neon Tokyo'), findsOneWidget);
      expect(find.textContaining('90', findRichText: true), findsWidgets);

      await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
      await tester.pumpAndSettle();
      // Drehregler gehören in die Geräteansicht, nicht in den Raum.
      expect(find.text('Bedienelemente'), findsNothing);
      expect(find.text('Drehregler'), findsNothing);
      expect(find.text('Drehknopf Salon 1'), findsNothing);

      // Zurück
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Zurück'));
      await tester.pumpAndSettle();
      expect(find.text('Strom jetzt'), findsOneWidget);
      sem.dispose();
    },
  );

  testWidgets('Raum öffnet auch per langem Drücken', (tester) async {
    _phone(tester);
    await tester.runAsync(() async => tester.pumpWidget(await _app()));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Ruheraum'));
    await tester.pumpAndSettle();
    expect(find.text('Szenen'), findsOneWidget);
    expect(find.text('Lichtleiste Links'), findsOneWidget);
  });

  testWidgets('Dunkel und Hell rendern ohne Fehler', (tester) async {
    _phone(tester);
    for (final m in [ThemeMode.dark, ThemeMode.light]) {
      await tester.runAsync(
        () async =>
            tester.pumpWidget(await _app(location: '/room/salon', mode: m)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Szenen'), findsOneWidget);
      final ctx = tester.element(find.text('Szenen'));
      expect(
        Theme.of(ctx).brightness,
        m == ThemeMode.dark ? Brightness.dark : Brightness.light,
      );
    }
  });

  testWidgets('Navigation zwischen den Tabs', (tester) async {
    _phone(tester);
    await tester.runAsync(() async => tester.pumpWidget(await _app()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zigbee'));
    await tester.pumpAndSettle();
    expect(find.text('Funknetz'), findsOneWidget);
    await tester.tap(find.text('Abläufe'));
    await tester.pumpAndSettle();
    expect(find.text('Neuer Ablauf'), findsWidgets);
  });

  testWidgets('Ohne Verbindung startet die App direkt mit dem Verbinden', (
    tester,
  ) async {
    _phone(tester);
    await tester.runAsync(
      () async => tester.pumpWidget(await _app(connected: false)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Demo ansehen'), findsNothing);
    expect(find.text('Adresse'), findsOneWidget);
    expect(find.text('Token'), findsOneWidget);
    expect(find.text('Mit Home Assistant verbinden'), findsOneWidget);

    await tester.tap(find.text('Mit Home Assistant verbinden'));
    await tester.pumpAndSettle();
    expect(find.text('Trage Adresse und Token ein.'), findsOneWidget);
  });

  testWidgets('Widgets bearbeiten: entfernen', (tester) async {
    _phone(tester);
    final sem = tester.ensureSemantics();
    await tester.runAsync(() async => tester.pumpWidget(await _app()));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Widgets bearbeiten'));
    await tester.pumpAndSettle();
    expect(find.text('Widget hinzufügen'), findsOneWidget);
    expect(find.byIcon(Icons.remove_rounded), findsNWidgets(3));
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.remove_rounded).first);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.remove_rounded), findsNWidgets(2));
    expect(find.text('Strom jetzt'), findsNothing);
    sem.dispose();
  });
}
