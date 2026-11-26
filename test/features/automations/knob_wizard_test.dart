import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/core/widgets/haven_switch.dart';
import 'package:haven/data/models/haven_automation.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/dev/fake_automations.dart';
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
  Future<void> Function()? before,
}) async {
  tester.view.physicalSize = const Size(412 * 2.625, 915 * 2.625);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  await tester.runAsync(() async {
    final app = await _app(loc);
    await before?.call();
    await tester.pumpWidget(app);
  });
  await tester.pumpAndSettle();
}

Future<void> _next(WidgetTester tester) async {
  await tester.tap(find.text('Weiter'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  testWidgets('Assistent läuft im Fake von Raum bis Speichern', (tester) async {
    await _pump(
      tester,
      '/automations',
      // Der Drehregler im Salon soll frei sein.
      before: () => _repo.deleteHavenAutomation('demo-salon'),
    );
    await tester.tap(find.text('Neue Automation'));
    await tester.pumpAndSettle();
    // Erst die Art wählen
    expect(find.text('Bewegungslicht'), findsWidgets);
    await tester.tap(find.text('Drehregler für einen Raum'));
    await tester.pumpAndSettle();
    expect(find.text('Drehregler für einen Raum'), findsOneWidget);
    expect(find.text('Welcher Raum?'), findsOneWidget);

    // Ohne Raum geht es nicht weiter
    await _next(tester);
    expect(find.text('Wähl einen Raum'), findsOneWidget);

    // 1. Raum
    await tester.tap(find.text('Salon'));
    await tester.pumpAndSettle();
    await _next(tester);

    // 2. Regler: der Drehregler des Raums ist schon gewählt, der Taster
    // im Ruheraum gehört zu einer anderen Automation.
    expect(find.text('Welche Regler und Taster?'), findsOneWidget);
    expect(find.text('Drehknopf Salon 1'), findsOneWidget);
    expect(find.textContaining('steuert schon Ruheraum'), findsOneWidget);
    await _next(tester);

    // 3. Gesten: Halten auf eine Szene legen
    expect(find.text('Was soll passieren?'), findsOneWidget);
    expect(find.text('Helligkeit'), findsOneWidget);
    expect(find.text('Ein/Aus'), findsOneWidget);
    expect(find.text('Nächste Szene'), findsOneWidget);
    await tester.tap(find.text('Halten'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Szene Kinoabend'));
    await tester.pumpAndSettle();
    expect(find.text('Szene Kinoabend'), findsOneWidget);
    await _next(tester);

    // 4. Szenen: Fokus aus dem Umlauf nehmen
    expect(find.text('Golden Hour'), findsOneWidget);
    await tester.tap(find.text('Fokus'));
    await tester.pumpAndSettle();
    expect(find.text('nicht im Umlauf'), findsOneWidget);
    await _next(tester);

    // 5. Optionen
    expect(find.text('Schrittweite'), findsOneWidget);
    expect(find.text('14 % je Rastung'), findsOneWidget);
    await _next(tester);

    // 6. Live-Test: echte Geste erscheint, Test-Knöpfe erst nach dem Speichern
    expect(find.text('Dreh jetzt am Regler'), findsOneWidget);
    expect(find.text('Noch nichts empfangen.'), findsOneWidget);
    await tester.runAsync(
      () => _repo.simulateGesture(FakeAutomations.salonKnob, 'rotate_right'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Nach rechts gedreht'), findsWidgets);
    expect(
      find.textContaining('sobald die Automation gespeichert'),
      findsOneWidget,
    );
    await _next(tester);

    // 7. Speichern
    expect(find.text('Alles klar?'), findsOneWidget);
    expect(
      find.text('Golden Hour → Neon Tokyo → Nordlicht → Kinoabend'),
      findsOneWidget,
    );
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();

    final all = await _repo.havenAutomations();
    final saved = all.automations.firstWhere((a) => a.roomAreaId == 'salon');
    expect(saved.devices, [FakeAutomations.salonKnob]);
    expect(saved.name, 'Drehregler Salon');
    expect(
      saved.options.binding(KnobGesture.hold),
      const GestureBinding(GestureAction.scene, scene: 3),
    );
    expect(saved.options.scenes, [0, 1, 2, 3]);
    // zurück im Tab, die neue Karte ist da
    expect(find.text('Haven-Automationen'), findsOneWidget);
    expect(find.text('3 von 3 Haven-Automationen aktiv'), findsOneWidget);
  });

  testWidgets('Drehen schaltet Szenen, Lampen beim Dimmen ausnehmen', (
    tester,
  ) async {
    await _pump(
      tester,
      '/automations',
      before: () => _repo.deleteHavenAutomation('demo-salon'),
    );
    await tester.tap(find.text('Neue Automation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Drehregler für einen Raum'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salon'));
    await tester.pumpAndSettle();
    await _next(tester);
    await _next(tester);

    // Drehen: Szene vor/zurück
    await tester.tap(find.text('Drehen'));
    await tester.pumpAndSettle();
    expect(find.text('Rechts nächste, links vorige Szene'), findsOneWidget);
    await tester.tap(find.text('Szene vor/zurück'));
    await tester.pumpAndSettle();
    expect(find.text('Szene vor/zurück'), findsOneWidget);
    // Wieder auf Helligkeit für die Dimm-Optionen
    await tester.tap(find.text('Drehen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Helligkeit').last);
    await tester.pumpAndSettle();
    await _next(tester);
    await _next(tester);

    // Optionen: eine Lampe nicht mitdimmen
    final rows = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('dim-lamp-'),
    );
    expect(rows, findsWidgets);
    final first = tester.widget(rows.first).key! as ValueKey<String>;
    final id = first.value.substring('dim-lamp-'.length);
    await tester.ensureVisible(rows.first);
    await tester.tap(
      find.descendant(of: rows.first, matching: find.byType(HavenSwitch)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Lampen'), findsWidgets);
    await _next(tester);
    await _next(tester);
    expect(find.textContaining('1 Lampe ausgenommen'), findsOneWidget);
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();

    var saved = (await _repo.havenAutomations()).automations.firstWhere(
      (a) => a.roomAreaId == 'salon',
    );
    expect(saved.options.dimExclude, [id]);

    // Drehen auf Szenen gespeichert: rechts nächste, links vorige
    await tester.runAsync(
      () => _repo.saveHavenAutomation(
        saved.copyWith(
          options: saved.options.withBinding(
            KnobGesture.rotate,
            const GestureBinding(GestureAction.sceneStep),
          ),
        ),
      ),
    );
    saved = (await _repo.havenAutomations()).automations.firstWhere(
      (a) => a.roomAreaId == 'salon',
    );
    expect(
      saved.toJson()['options']['gestures']['rotate'],
      containsPair('action', 'scene_step'),
    );
  });

  testWidgets('Halten stellt eigene Lampen ein (an, aus, Farbe)', (
    tester,
  ) async {
    await _pump(
      tester,
      '/automations',
      before: () => _repo.deleteHavenAutomation('demo-salon'),
    );
    await tester.tap(find.text('Neue Automation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Drehregler für einen Raum'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salon'));
    await tester.pumpAndSettle();
    await _next(tester);
    await _next(tester);
    // Gesten: Halten auf „Lampen einstellen“
    await tester.tap(find.text('Halten'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lampen wählen'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('light-targets-editor')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('light-targets-add')));
    await tester.pumpAndSettle();
    for (final name in ['Tischlampe Salon', 'Stehleuchte Diele']) {
      await tester.ensureVisible(find.text(name));
      await tester.tap(find.text(name));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const ValueKey('lamp-picker-done')));
    await tester.pumpAndSettle();
    // Die Stehleuchte aus, die Tischlampe an in Orange.
    final diele = find.byKey(
      const ValueKey('light-target-light.stehleuchte_diele'),
    );
    expect(diele, findsOneWidget);
    final salon = find.byKey(
      const ValueKey('light-target-light.tischlampe_salon'),
    );
    await tester.ensureVisible(salon);
    await tester.tap(find.bySemanticsLabel('Tischlampe Salon an'));
    await tester.pumpAndSettle();
    final on = _repo.snapshot.lamp('light.tischlampe_salon')!.on;
    // Schalter steht jetzt auf dem Gegenteil des jetzigen Zustands; einmal
    // so, dass sie an ist.
    if (on) {
      await tester.tap(find.bySemanticsLabel('Tischlampe Salon an'));
      await tester.pumpAndSettle();
    }
    if (find
        .descendant(of: salon, matching: find.text('Farbe'))
        .evaluate()
        .isNotEmpty) {
      await tester.tap(
        find.descendant(of: salon, matching: find.text('Farbe')),
      );
      await tester.pumpAndSettle();
    }
    if (_repo.snapshot.lamp('light.stehleuchte_diele')!.on) {
      await tester.ensureVisible(diele);
      await tester.tap(find.bySemanticsLabel('Stehleuchte Diele an'));
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(
      find.byKey(const ValueKey('light-targets-done')),
    );
    await tester.tap(find.byKey(const ValueKey('light-targets-done')));
    await tester.pumpAndSettle();
    expect(find.text('2 Lampen einstellen'), findsOneWidget);
    for (var i = 0; i < 4; i++) {
      await _next(tester);
    }
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();

    final all = await _repo.havenAutomations();
    final saved = all.automations.firstWhere((a) => a.roomAreaId == 'salon');
    final b = saved.options.binding(KnobGesture.hold);
    expect(b.action, GestureAction.lights);
    final byId = {for (final t in b.lights) t.entityId: t};
    expect(byId.keys, {'light.tischlampe_salon', 'light.stehleuchte_diele'});
    expect(byId['light.stehleuchte_diele']!.on, isFalse);
    expect(byId['light.tischlampe_salon']!.on, isTrue);
    expect(b.toJson()['lights'], isA<List<dynamic>>());

    // Halten setzt genau diesen Zustand.
    await tester.runAsync(
      () => _repo.simulateGesture(FakeAutomations.salonKnob, 'hold'),
    );
    await tester.pumpAndSettle();
    expect(_repo.snapshot.lamp('light.stehleuchte_diele')!.on, isFalse);
    expect(_repo.snapshot.lamp('light.tischlampe_salon')!.on, isTrue);
  });

  testWidgets(
    'Editor zeigt Hinweis auf doppelte HA-Automation und schaltet sie aus',
    (tester) async {
      await _pump(tester, '/automations/knob/demo-ruheraum?step=1');
      // Dashboard dahinter und Sheet „Regler und Taster“ zeigen den Hinweis.
      expect(find.text('Taster Ruheraum'), findsWidgets);
      expect(find.text('Welche Regler und Taster?'), findsOneWidget);
      expect(find.text('Doppelt gesteuert'), findsNWidgets(2));
      expect(
        find.text(
          'Diese HA-Automationen steuern dieselben Regler. Deaktiviere sie, '
          'sonst passiert alles doppelt.',
        ),
        findsWidgets,
      );
      final off = find.text('In Home Assistant ausschalten').last;
      await tester.ensureVisible(off);
      await tester.tap(off);
      await tester.pumpAndSettle();
      expect(find.text('HA-Automation ausschalten?'), findsOneWidget);
      await tester.tap(find.text('Ausschalten'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        _repo.snapshot.entity('automation.knopf_schaltet_ruheraum')!.isOn,
        isFalse,
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('Doppelt gesteuert'), findsNothing);
    },
  );

  testWidgets('Live-Test einer gespeicherten Automation mit Test-Knopf', (
    tester,
  ) async {
    await _pump(tester, '/automations/knob/demo-salon?step=5');
    expect(find.text('Dreh jetzt am Regler'), findsOneWidget);
    final before = _repo.snapshot.entity('light.tischlampe_salon')!.isOn;
    await tester.runAsync(() async {
      await tester.tap(find.text('Drücken'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.text('Gedrückt'), findsWidgets);
    expect(find.text('ausgeführt'), findsOneWidget);
    expect(find.text('Test'), findsOneWidget);
    expect(_repo.snapshot.entity('light.tischlampe_salon')!.isOn, !before);
  });

  testWidgets('Gerät-Detail eines Knobs verlinkt die Automation', (
    tester,
  ) async {
    await _pump(tester, '/zigbee/device/${FakeAutomations.salonKnob}');
    final link = find.textContaining('Haven-Automation', findRichText: true);
    expect(link, findsOneWidget);
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    // Öffnet das Dashboard, nicht den Assistenten.
    expect(find.text('Drehregler Salon'), findsWidgets);
    expect(find.text('Einstellungen'.toUpperCase()), findsOneWidget);
    expect(find.textContaining('von 7'), findsNothing);
  });
}
