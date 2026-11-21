import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/features/home/widgets/room_row.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/core/widgets/haven_card.dart';
import 'package:haven/core/widgets/haven_sheet.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/room/widgets/scene_card.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<Widget> _app({
  String? location,
  bool connected = true,
  ThemeMode? mode,
  bool detailed = false,
}) async {
  SharedPreferences.setMockInitialValues({
    if (mode != null) 'theme_mode': mode.name,
    'home_rooms_detailed': detailed,
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
  // Deutlich höher als ein Handy: Update-Karte und Räume schieben die Widgets nach unten.
  tester.view.physicalSize = const Size(412 * 2.625, 1800 * 2.625);
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
    // Kompakt: Räume mit Heizungsregelung zeigen die Raumtemperatur im
    // Status (der Regler steht ausführlich im Tab Heizung).
    expect(find.textContaining('21,3°'), findsWidgets);
    // Ohne Sensor steht dort nichts (kein „kein Sensor“).
    expect(find.textContaining('kein Sensor'), findsNothing);
    expect(find.text('Strom jetzt'), findsOneWidget);
    expect(find.textContaining('142', findRichText: true), findsWidgets);
    expect(find.text('Batterien'), findsOneWidget);
    // Navigation
    for (final t in ['Zuhause', 'Karte', 'Netzwerk', 'Abläufe']) {
      expect(find.text(t), findsWidgets);
    }
  });

  testWidgets('Der runde Knopf schaltet den Raum', (tester) async {
    _phone(tester);
    await tester.runAsync(() async => tester.pumpWidget(await _app()));
    await tester.pumpAndSettle();
    // Vier Räume aus (der Salon leuchtet; die Diele hat eine Matter-Lampe).
    // Status beginnt mit „Aus“ (ohne Regler steht die Temperatur dahinter).
    final off = find.textContaining(RegExp(r'^Aus'));
    expect(off, findsNWidgets(4));
    await tester.ensureVisible(find.bySemanticsLabel('Licht Waschraum'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Licht Waschraum'));
    await tester.pumpAndSettle();
    expect(off, findsNWidgets(3));
    expect(find.textContaining('Lampe · 100 %'), findsOneWidget);
  });

  testWidgets('Waagrecht übers Bild ziehen dimmt den Raum', (tester) async {
    _phone(tester);
    await tester.runAsync(() async => tester.pumpWidget(await _app()));
    await tester.pumpAndSettle();
    // Waschraum ist aus: nach rechts ziehen schaltet ihn gedimmt ein.
    final tile = find.ancestor(
      of: find.text('Waschraum'),
      matching: find.byType(RoomRow),
    );
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    final picture = find.descendant(
      of: tile,
      matching: find.byIcon(Icons.meeting_room_outlined),
    );
    final w = tester.getSize(tile).width;
    final gesture = await tester.startGesture(tester.getCenter(picture));
    await gesture.moveBy(Offset(w * 0.2, 0));
    await gesture.moveBy(Offset(w * 0.2, 0));
    await tester.pump();
    expect(find.textContaining('Helligkeit'), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.textContaining('Helligkeit'), findsNothing);
    final status = find.descendant(
      of: tile,
      matching: find.textContaining('Lampe ·'),
    );
    expect(status, findsOneWidget);
    final pct = int.parse(
      RegExp(
        r'(\d+) %',
      ).firstMatch((tester.widget<Text>(status)).data!)!.group(1)!,
    );
    expect(pct, inInclusiveRange(30, 50));
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

      final roomList = find
          .ancestor(of: find.text('Szenen'), matching: find.byType(Scrollable))
          .first;
      await tester.drag(roomList, const Offset(0, -3000));
      await tester.pumpAndSettle();
      // Drehregler gehören in die Geräteansicht, nicht in den Raum.
      expect(find.text('Bedienelemente'), findsNothing);
      expect(find.text('Drehregler'), findsNothing);
      expect(find.text('Drehknopf Salon 1'), findsNothing);

      // Nach oben scrollen und im selben Zug weiterziehen: Am oberen Ende
      // übernimmt das Sheet und schließt. In kleinen Schritten wie ein
      // Finger, damit der Zug nach dem Scrollen beim Sheet ankommt.
      final pull = await tester.startGesture(tester.getCenter(roomList));
      for (var i = 0; i < 30; i++) {
        await pull.moveBy(const Offset(0, 100));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await pull.up();
      await tester.pumpAndSettle();
      expect(find.text('Szenen'), findsNothing);
      expect(find.text('Strom jetzt'), findsOneWidget);

      // Wieder öffnen, Knopf schließt.
      await tester.tap(find.bySemanticsLabel('Salon öffnen'));
      await tester.pumpAndSettle();
      expect(find.text('Szenen'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Szenen'), findsNothing);
      sem.dispose();
    },
  );

  testWidgets('Szenen prüfen: fehlende Lampe finden und abgleichen', (
    tester,
  ) async {
    _phone(tester);
    final sem = tester.ensureSemantics();
    await tester.runAsync(() async => tester.pumpWidget(await _app()));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Salon öffnen'));
    await tester.pumpAndSettle();
    // Eine Szene ist neu abzugleichen: Punkt an Karte und Knopf.
    expect(find.byType(SceneSyncDot), findsWidgets);

    await tester.tap(find.bySemanticsLabel('Szenen prüfen'));
    await tester.pumpAndSettle();
    expect(find.text('Die Lampen schalten dabei kurz um.'), findsOneWidget);
    expect(find.text('Lampe fehlt'), findsNothing);

    await tester.tap(find.text('Alle prüfen'));
    await tester.pumpAndSettle();
    expect(find.text('Lampe fehlt'), findsOneWidget);
    expect(find.text('Farbe weicht ab'), findsOneWidget);
    expect(find.text('In Ordnung'), findsNWidgets(3));
    // Abweichende Szenen klappen auf: Lampenzeilen mit Soll und Messung.
    expect(find.text('reagiert nicht'), findsOneWidget);
    expect(find.text('kein Soll'), findsOneWidget);

    final row = find.ancestor(
      of: find.text('Lampe fehlt'),
      matching: find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('scene-check-'),
      ),
    );
    final repair = find.descendant(of: row, matching: find.text('Abgleichen'));
    await tester.ensureVisible(repair);
    await tester.pumpAndSettle();
    await tester.tap(repair);
    await tester.pumpAndSettle();

    expect(find.text('Lampe fehlt'), findsNothing);
    expect(find.text('In Ordnung'), findsNWidgets(4));
    expect(find.text('reagiert nicht'), findsNothing);
    sem.dispose();
  });

  testWidgets('Raum-Sheet: kurz ziehen federt zurück, weit ziehen schließt', (
    tester,
  ) async {
    _phone(tester);
    await tester.runAsync(() async => tester.pumpWidget(await _app()));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Salon'));
    await tester.pumpAndSettle();
    final grab = find.byType(SheetGrabber);
    expect(grab, findsOneWidget);
    final top = tester.getTopLeft(grab).dy;

    // Langsam ein Stück: zurück auf ganz offen.
    await tester.timedDrag(
      grab,
      const Offset(0, 200),
      const Duration(milliseconds: 800),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(grab).dy, moreOrLessEquals(top, epsilon: 0.5));

    // Halb gezogen (während des Ziehens) folgt das Sheet dem Finger.
    final g = await tester.startGesture(tester.getCenter(grab));
    await g.moveBy(const Offset(0, 30));
    await g.moveBy(const Offset(0, 300));
    await tester.pump();
    expect(tester.getTopLeft(grab).dy, greaterThan(top + 250));
    // Langsam über die Hälfte: schließt.
    await g.moveBy(const Offset(0, 800));
    await tester.pump(const Duration(milliseconds: 600));
    await g.up();
    await tester.pumpAndSettle();
    expect(find.text('Szenen'), findsNothing);

    // Schneller Wisch nach unten schließt auch nach kurzem Weg.
    await tester.longPress(find.text('Salon'));
    await tester.pumpAndSettle();
    await tester.fling(find.byType(SheetGrabber), const Offset(0, 160), 1800);
    await tester.pumpAndSettle();
    expect(find.text('Szenen'), findsNothing);
  });

  testWidgets('Raum-Sheet: Android-Zurück schließt', (tester) async {
    _phone(tester);
    await tester.runAsync(() async => tester.pumpWidget(await _app()));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Ruheraum'));
    await tester.pumpAndSettle();
    expect(find.text('Szenen'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Szenen'), findsNothing);
    expect(find.text('Strom jetzt'), findsOneWidget);
  });

  testWidgets('Raum aus der Karte öffnet als Sheet', (tester) async {
    _phone(tester);
    await tester.runAsync(
      () async => tester.pumpWidget(await _app(location: '/room/kochbereich')),
    );
    await tester.pumpAndSettle();
    // Alte Adresse leitet um, dahinter liegt Zuhause.
    expect(find.byType(SheetGrabber), findsOneWidget);
    expect(find.text('Szenen'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Strom jetzt'), findsOneWidget);
  });

  test('Loslassen: Regel für Schließen', () {
    expect(sheetShouldClose(0.9, 1200), isTrue);
    expect(sheetShouldClose(0.9, 200), isFalse);
    expect(sheetShouldClose(0.4, 0), isTrue);
    expect(sheetShouldClose(0.4, -900), isFalse);
    expect(sheetShouldClose(0.6, 100), isFalse);
  });

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
    await tester.tap(find.text('Netzwerk'));
    await tester.pumpAndSettle();
    expect(find.text('Funknetz'), findsOneWidget);
    await tester.tap(find.text('Abläufe'));
    await tester.pumpAndSettle();
    expect(find.text('Neue Automation'), findsWidgets);
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
    await tester.tap(find.bySemanticsLabel('Übersicht bearbeiten'));
    await tester.pumpAndSettle();
    expect(find.text('Widget hinzufügen'), findsOneWidget);
    // Alle Widgets in einer Liste; der Kopf bleibt (ohne Entfernen).
    final n = find.byIcon(Icons.remove_rounded).evaluate().length;
    expect(n, greaterThan(5));
    await tester.scrollUntilVisible(
      find.text('Strom'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    final row = find.ancestor(
      of: find.text('Strom'),
      matching: find.byType(HavenCard),
    );
    await tester.tap(
      find.descendant(of: row, matching: find.byIcon(Icons.remove_rounded)),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.remove_rounded), findsNWidgets(n - 1));
    await tester.tap(find.bySemanticsLabel('Bearbeiten beenden'));
    await tester.pumpAndSettle();
    expect(find.text('Strom jetzt'), findsNothing);
    sem.dispose();
  });

  testWidgets('Szene halten zeigt sie vorab, Tippen ruft sie auf', (
    tester,
  ) async {
    _phone(tester);
    await tester.runAsync(
      () async => tester.pumpWidget(await _app(detailed: true)),
    );
    await tester.pumpAndSettle();
    final chip = find.bySemanticsLabel('Szene Neon Tokyo').first;
    final gesture = await tester.startGesture(tester.getCenter(chip));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Vorschau: Neon Tokyo'), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('Vorschau: Neon Tokyo'), findsNothing);
  });

  testWidgets('Raum-Widget einstellen: kompakt, zwei nebeneinander', (
    tester,
  ) async {
    _phone(tester);
    await tester.runAsync(() async => tester.pumpWidget(await _app()));
    await tester.pumpAndSettle();
    double top(String name) => tester.getTopLeft(find.text(name).first).dy;
    expect(top('Ruheraum'), greaterThan(top('Salon') + 50));
    await tester.tap(find.bySemanticsLabel('Übersicht bearbeiten'));
    await tester.pumpAndSettle();
    for (final i in [0, 1]) {
      await tester.tap(find.byTooltip('Einstellen').at(i));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kompakt'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.bySemanticsLabel('Bearbeiten beenden'));
    await tester.pumpAndSettle();
    expect(top('Ruheraum'), closeTo(top('Salon'), 1));
    expect(find.bySemanticsLabel('Szene Golden Hour'), findsNothing);
  });

  testWidgets('Knöpfe über den Szenen: Heizung im Blatt, Bewegungslicht', (
    tester,
  ) async {
    _phone(tester);
    await tester.runAsync(() async => tester.pumpWidget(await _app()));
    await tester.pumpAndSettle();
    // Salon: Heizung öffnet ein Blatt mit Raumtemperatur und Ziel.
    await tester.tap(find.bySemanticsLabel('Heizung Salon'));
    await tester.pumpAndSettle();
    expect(find.text('Heizung Salon'), findsOneWidget);
    expect(find.text('21,0°'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Wärmer').first);
    await tester.pump();
    expect(find.text('21,5°'), findsOneWidget);
    await tester.pump(const Duration(seconds: 8));
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    // Waschraum: Bewegungslicht direkt schalten.
    final row = find.ancestor(
      of: find.text('Waschraum'),
      matching: find.byType(RoomRow),
    );
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    final chip = find.descendant(
      of: row,
      matching: find.bySemanticsLabel('Bewegungslicht'),
    );
    expect(tester.getSemantics(chip).value, 'an');
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(tester.getSemantics(chip).value, 'aus');
  });
}
