import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/core/widgets/haven_switch.dart';
import 'package:haven/data/models/haven_automation.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/dev/fake_repository.dart';
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

Future<void> _pump(
  WidgetTester tester,
  String loc, {
  Size size = const Size(412, 915),
}) async {
  tester.view.physicalSize = size * 2.625;
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  await tester.runAsync(() async {
    await tester.pumpWidget(await _app(loc));
  });
  await tester.pumpAndSettle();
}

Future<HavenAutomation> _stored(WidgetTester tester, String id) async {
  HavenAutomation? a;
  await tester.runAsync(() async {
    a = (await _repo.havenAutomations()).byId(id);
  });
  return a!;
}

/// Dashboard-Liste baut lazy: bis [f] scrollen.
Future<void> _show(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      f,
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await _show(tester, f);
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.tap(find.text('Speichern'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pumpAndSettle();
}

Finder _switch(String label) =>
    find.byWidgetPredicate((w) => w is HavenSwitch && w.semanticLabel == label);

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  group('Bewegungslicht-Dashboard', () {
    testWidgets('zeigt Zustand und alle Einstellungen statt des Assistenten', (
      tester,
    ) async {
      await _pump(tester, '/automations/motion/demo-waschraum');
      expect(find.textContaining('Schritt 1 von'), findsNothing);
      expect(find.text('Bewegungslicht Waschraum'), findsOneWidget);
      // Live-Zustand: Phase, Besitzer, Ausschaltzeit
      expect(find.textContaining('Licht vom Melder, aus in'), findsOneWidget);
      expect(find.text('Licht gehört: Melder'), findsOneWidget);
      expect(find.textContaining('Aus um '), findsOneWidget);
      for (final t in [
        'Raum',
        'Melder',
        'Wann aktiv',
        'Licht',
        'Name, Nachlauf und Optionen',
      ]) {
        await _show(tester, find.text(t));
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.textContaining('18:00 bis 07:00'), findsWidgets);
      await _show(tester, find.text('Nachlauf 1,5 min, mit Vorwarnung'));
    });

    testWidgets('Abschnitt im Sheet ändern und speichern', (tester) async {
      await _pump(tester, '/automations/motion/demo-waschraum');
      await _tap(tester, find.text('Name, Nachlauf und Optionen'));
      expect(find.text('Nachlauf und Optionen'), findsOneWidget);
      await _tap(tester, find.text('5 min'));
      await _save(tester);
      expect(find.text('Nachlauf und Optionen'), findsNothing);
      expect(find.text('Gespeichert'), findsOneWidget);
      expect(find.text('Nachlauf 5 min, mit Vorwarnung'), findsOneWidget);
      final a = await _stored(tester, 'demo-waschraum');
      expect(a.motion!.delay, 300);
      // Der Rest bleibt, wie er war
      expect(a.motion!.windows, isNotEmpty);
      expect(a.motion!.warn, isTrue);
    });

    testWidgets('Abbrechen speichert nichts', (tester) async {
      await _pump(tester, '/automations/motion/demo-waschraum');
      await _tap(tester, find.text('Wann aktiv'));
      expect(find.text('Wann soll es gelten?'), findsOneWidget);
      await _tap(tester, _switch('Zeitfenster').last);
      await _tap(tester, find.text('Abbrechen'));
      expect(find.text('Wann soll es gelten?'), findsNothing);
      final a = await _stored(tester, 'demo-waschraum');
      expect(a.motion!.windows, isNotEmpty);
      expect(find.textContaining('18:00 bis 07:00'), findsWidgets);
    });

    testWidgets('Aktiv-Schalter, Live-Test und Löschen', (tester) async {
      await _pump(tester, '/automations/motion/demo-waschraum');
      await _tap(tester, _switch('Aktiv'));
      expect((await _stored(tester, 'demo-waschraum')).enabled, isFalse);
      expect(find.text('Ausgeschaltet', skipOffstage: false), findsOneWidget);

      await _tap(tester, find.text('Live-Test'));
      expect(find.text('Lauf einmal durch den Raum'), findsOneWidget);
      await _tap(tester, find.byIcon(Icons.close_rounded).last);
      await tester.pumpAndSettle();

      await _tap(tester, find.text('Automation löschen'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Löschen'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      HavenAutomations? all;
      await tester.runAsync(() async => all = await _repo.havenAutomations());
      expect(all!.byId('demo-waschraum'), isNull);
      expect(find.text('Haven-Automationen'), findsOneWidget);
    });

    testWidgets('?step= öffnet den Abschnitt direkt', (tester) async {
      await _pump(tester, '/automations/motion/demo-waschraum?step=3');
      expect(find.text('Was soll angehen?'), findsOneWidget);
    });

    testWidgets('Desktop: Zustand links, Einstellungen rechts', (tester) async {
      await _pump(
        tester,
        '/automations/motion/demo-waschraum',
        size: const Size(1400, 900),
      );
      final status = tester.getTopLeft(find.text('Jetzt'));
      final tile = tester.getTopLeft(find.text('Raum'));
      expect(tile.dx, greaterThan(status.dx + 300));
      expect((tile.dy - status.dy).abs(), lessThan(200));
    });
  });

  group('Drehregler-Dashboard', () {
    testWidgets('Name im Feinschliff ändern', (tester) async {
      await _pump(tester, '/automations/knob/demo-salon');
      expect(find.text('Gesten'), findsOneWidget);
      expect(find.text('Szenen'), findsOneWidget);
      await _tap(tester, find.text('Name und Feinschliff'));
      expect(find.text('Feinschliff'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Regler Lesesessel');
      await tester.pumpAndSettle();
      await _save(tester);
      expect(find.text('Regler Lesesessel'), findsOneWidget);
      expect((await _stored(tester, 'demo-salon')).name, 'Regler Lesesessel');
    });

    testWidgets('Fehler im Abschnitt hält das Speichern auf', (tester) async {
      await _pump(tester, '/automations/knob/demo-salon?step=1');
      expect(find.text('Welche Regler und Taster?'), findsOneWidget);
      final before = await _stored(tester, 'demo-salon');
      expect(before.devices, isNotEmpty);
      // Der Haken einer gewählten Zeile: tippen, bis nichts mehr gewählt ist
      while (true) {
        final selected = find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.properties.selected == true &&
              w.properties.button == true,
        );
        final inSheet = find.descendant(
          of: find.ancestor(
            of: find.text('Welche Regler und Taster?'),
            matching: find.byType(ListView),
          ),
          matching: selected,
        );
        if (inSheet.evaluate().isEmpty) break;
        await _tap(tester, inSheet.first);
      }
      await _save(tester);
      expect(
        find.text('Wähl mindestens einen Regler oder Taster'),
        findsOneWidget,
      );
      expect((await _stored(tester, 'demo-salon')).devices, before.devices);
    });
  });
}
