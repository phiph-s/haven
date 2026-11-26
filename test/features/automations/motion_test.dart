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
import 'package:haven/features/automations/motion_logic.dart';
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

const _doc = {
  'id': 'm1',
  'type': 'room_motion',
  'name': 'Bewegungslicht Bad',
  'enabled': true,
  'room_area_id': 'bad',
  'devices': ['0x1'],
  'options': {
    'windows': [
      {'from': '18:00', 'to': '07:00'},
    ],
    'sun': {
      'from': {'event': 'sunset', 'offset': -30},
      'until': {'event': 'sunrise', 'offset': 60},
    },
    'lux': {'below': 30, 'entity': null},
    'light': {'mode': 'scene', 'scene': 2, 'transition': 3},
    'night': {
      'from': '23:00',
      'to': '06:00',
      'light': {'mode': 'brightness', 'brightness': 25, 'color_temp': 2200},
    },
    'delay': 90,
    'warn': true,
    'warn_seconds': 20,
    'relight': false,
    'manual_delay': 600,
    'zukunft': 1,
  },
  'motion': {
    'phase': 'motion',
    'occupied': false,
    'off_at': '2026-11-16T20:01:20+00:00',
    'inactive': null,
    'night': false,
    'lux': 12.5,
    'detectors': ['binary_sensor.melder_occupancy'],
    'lux_entity': 'sensor.melder_illuminance',
  },
};

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  group('Modell', () {
    test('Parsen und Zurückschreiben bleiben stabil', () {
      final a = HavenAutomation.fromJson(Map<String, dynamic>.from(_doc));
      expect(a.isMotion, isTrue);
      final o = a.motion!;
      expect(o.windows, [const TimeWindow('18:00', '07:00')]);
      expect(o.sun!.from, const SunEdge('sunset', -30));
      expect(o.sun!.until, const SunEdge('sunrise', 60));
      expect(o.luxBelow, 30);
      expect(o.luxEntity, isNull);
      expect(o.light.isScene, isTrue);
      expect(o.light.scene, 2);
      expect(o.light.transition, 3);
      expect(o.night!.light.percent, 10);
      expect(o.night!.light.colorTemp, 2200);
      expect(o.delay, 90);
      expect(o.warn, isTrue);
      expect(o.relight, isFalse);
      expect(o.manualDelay, 600);
      expect(o.extra, {'zukunft': 1});
      expect(a.motionStatus!.phase, MotionPhase.motion);
      expect(a.motionStatus!.lux, 12.5);
      expect(a.motionStatus!.offAt, isNotNull);
      final json = a.toJson();
      expect(json['type'], 'room_motion');
      final opts = json['options'] as Map;
      expect(opts['zukunft'], 1);
      expect(opts['lux'], {'below': 30.0, 'entity': null});
      expect(
        HavenAutomation.fromJson(Map<String, dynamic>.from(json)).motion,
        o,
      );
      expect(json.containsKey('motion'), isFalse);
    });

    test('Standardwerte und Knob bleibt Knob', () {
      final o = MotionOptions.fromJson(null);
      expect(o.delay, 120);
      expect(o.warn, isFalse);
      expect(o.relight, isTrue);
      expect(o.manualDelay, isNull);
      expect(o.light.isScene, isFalse);
      final knob = HavenAutomation.fromJson({
        'id': 'k',
        'room_area_id': 'salon',
        'devices': ['0x2'],
      });
      expect(knob.isMotion, isFalse);
      expect(knob.motion, isNull);
      expect((knob.toJson()['options'] as Map).containsKey('gestures'), isTrue);
    });

    test('Ereignis mit Zustand', () {
      final t = AutomationTrigger.fromEvent({
        'data': {
          'id': 'm1',
          'action': 'warn',
          'at': '2026-11-16T20:00:00+00:00',
          'state': {'phase': 'warn', 'off_at': '2026-11-16T20:00:20+00:00'},
        },
      })!;
      expect(t.action, 'warn');
      expect(t.motion!.phase, MotionPhase.warn);
      expect(t.motion!.offAt, isNotNull);
      expect(
        AutomationTrigger.fromEvent({
          'data': {'id': 'k', 'action': 'single'},
        })!.motion,
        isNull,
      );
    });
  });

  group('Logik', () {
    test('Texte', () {
      final now = DateTime(2026, 11, 16, 20);
      expect(
        motionStatusLine(
          MotionStatus(
            phase: MotionPhase.motion,
            offAt: now.add(const Duration(seconds: 80)),
          ),
          now,
        ),
        'Licht vom Melder, aus in 1:20',
      );
      expect(
        motionStatusLine(const MotionStatus(phase: MotionPhase.manual), now),
        'Manuell übernommen',
      );
      expect(
        motionStatusLine(
          const MotionStatus(phase: MotionPhase.inactive, inactive: 'lux'),
          now,
        ),
        'Inaktiv (zu hell)',
      );
      expect(motionStatusLine(null, now, enabled: false), 'Ausgeschaltet');
      expect(delayLabel(90), '1,5 min');
      expect(delayLabel(120), '2 min');
      expect(delayLabel(3600), '1 h');
      expect(delayLabel(125), '2 min 5 s');
      expect(delayLabel(5400), '1 h 30 min');
      expect(delayLabel(3725), '1 h 2 min 5 s');
      expect(
        sunWindowLabel(
          const SunWindow(
            from: SunEdge('sunset'),
            until: SunEdge('sunrise', 60),
          ),
        ),
        'Sonnenuntergang bis 60 min nach Sonnenaufgang',
      );
      expect(windowCrossesMidnight('18:00', '07:00'), isTrue);
      expect(windowCrossesMidnight('08:00', '10:00'), isFalse);
      expect(formatHhmm(parseHhmm('07:05')!), '07:05');
      expect(parseHhmm('7:5'), isNull);
    });

    test('Lux-Regler rund und umkehrbar', () {
      expect(percentToLux(luxToPercent(30)), closeTo(30, 4));
      expect(percentToLux(0), 5);
      expect(percentToLux(100), 1000);
    });

    test('Validierung', () {
      const all = HavenAutomations(
        rooms: {
          'bad': AutomationRoom(
            areaId: 'bad',
            name: 'Bad',
            lights: ['light.a'],
          ),
          'leer': AutomationRoom(areaId: 'leer', name: 'Leer'),
        },
        automations: [
          HavenAutomation(
            id: 'x',
            type: kMotionType,
            name: 'Andere',
            roomAreaId: 'bad',
            devices: ['0x1'],
            motion: MotionOptions(),
          ),
          HavenAutomation(
            id: 'k',
            name: 'Knob',
            roomAreaId: 'bad',
            devices: ['0x9'],
          ),
        ],
      );
      HavenAutomation d({
        String room = 'bad',
        List<String> devices = const ['0x2'],
        MotionOptions o = const MotionOptions(),
      }) => HavenAutomation(
        type: kMotionType,
        name: 'n',
        roomAreaId: room,
        devices: devices,
        motion: o,
      );
      expect(validateMotionDraft(d(), all), isEmpty);
      expect(validateMotionDraft(d(room: ''), all)[0], 'Wähl einen Raum');
      expect(
        validateMotionDraft(d(room: 'leer'), all)[0],
        contains('keine Lichter'),
      );
      expect(
        validateMotionDraft(d(devices: []), all)[1],
        'Wähl mindestens einen Melder',
      );
      expect(
        validateMotionDraft(
          d(devices: ['0x1']),
          all,
          deviceNames: {'0x1': 'Melder'},
        )[1],
        'Melder meldet schon für Andere',
      );
      // Knob und Motion im selben Raum sind kein Konflikt, derselbe Melder schon
      expect(validateMotionDraft(d(devices: ['0x9']), all), isEmpty);
      // Szene ohne Gruppe geht nicht, HA-Szene schon
      final scene = const MotionOptions(
        light: MotionLight(useScene: true, scene: 1),
      );
      expect(validateMotionDraft(d(o: scene), all)[3], contains('keine Szenen'));
      final ha = const MotionOptions(
        light: MotionLight(useScene: true, sceneEntity: 'scene.bad_nacht'),
      );
      expect(validateMotionDraft(d(o: ha), all), isEmpty);
      expect(
        validateMotionDraft(
          d(o: const MotionOptions(windows: [TimeWindow('25:00', '07:00')])),
          all,
        )[2],
        isNotNull,
      );
    });
  });

  group('Assistent im Fake', () {
    testWidgets('Bewegungslicht von Raum bis Speichern', (tester) async {
      await _pump(
        tester,
        '/automations',
        before: () => _repo.deleteHavenAutomation('demo-waschraum'),
      );
      await tester.tap(find.text('Neue Automation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bewegungslicht').last);
      await tester.pumpAndSettle();
      expect(find.text('Welcher Raum?'), findsOneWidget);

      await _next(tester);
      expect(find.text('Wähl einen Raum'), findsOneWidget);
      await tester.tap(find.text('Waschraum'));
      await tester.pumpAndSettle();
      await _next(tester);

      // Melder: der Präsenzmelder des Raums ist schon gewählt
      expect(find.text('Welcher Melder?'), findsOneWidget);
      expect(find.text('Präsenz Waschraum'), findsOneWidget);
      await _next(tester);

      // Wann aktiv: Zeitfenster einschalten
      expect(find.text('Wann soll es gelten?'), findsOneWidget);
      await tester.tap(find.byType(HavenSwitch).first);
      await _next(tester);

      // Licht
      expect(find.text('Was soll angehen?'), findsOneWidget);
      await _next(tester);

      // Nachlauf
      expect(find.text('Nachlauf und Optionen'), findsOneWidget);
      await tester.tap(find.text('5 min'));
      await tester.pumpAndSettle();
      // Eigene Zeit: 5 min + 1 min + 5 s
      await tester.tap(find.byKey(const ValueKey('motion-delay-custom')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('duration-m-up')));
      await tester.tap(find.byKey(const ValueKey('duration-s-up')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('duration-done')));
      await tester.pumpAndSettle();
      expect(find.text('Eigene: 6 min 5 s'), findsOneWidget);
      await _next(tester);

      // Live-Test
      expect(find.text('Lauf einmal durch den Raum'), findsOneWidget);
      expect(find.text('Erst nach dem Speichern'), findsOneWidget);
      await _next(tester);

      // Speichern
      expect(find.text('Alles klar?'), findsOneWidget);
      await tester.tap(find.text('Speichern').last);
      await tester.pumpAndSettle();
      final all = await _repo.havenAutomations();
      final saved = all.automations.firstWhere((a) => a.isMotion);
      expect(saved.roomAreaId, 'waschraum');
      expect(saved.devices, [FakeAutomations.waschraumPresence]);
      expect(saved.name, 'Bewegungslicht Waschraum');
      expect(saved.motion!.delay, 365);
      expect(find.text('Haven-Automationen'), findsOneWidget);
    });

    testWidgets('Karte zeigt den Zustand, Dashboard öffnet', (tester) async {
      await _pump(tester, '/automations');
      expect(find.text('Waschraum'), findsOneWidget);
      expect(find.textContaining('Licht vom Melder, aus in'), findsOneWidget);
      expect(find.textContaining('1 Melder'), findsOneWidget);
      // Zustandszeile steht linksbündig neben dem Punkt, nicht zentriert
      final status = find.textContaining('Licht vom Melder, aus in');
      final dx = tester.getTopLeft(status).dx;
      expect(dx, lessThan(tester.getTopLeft(find.text('Waschraum')).dx + 40));
      await tester.tap(find.text('Waschraum'));
      await tester.pumpAndSettle();
      expect(find.text('Welcher Raum?'), findsNothing);
      expect(find.text('Wann aktiv'), findsOneWidget);
    });

    testWidgets('Live-Test: Testknopf löst Bewegung aus', (tester) async {
      await _pump(tester, '/automations/motion/demo-waschraum?step=5&demo=1');
      expect(find.text('Lauf einmal durch den Raum'), findsOneWidget);
      expect(find.text('Bewegung erkannt'), findsWidgets);
      await tester.tap(find.text('Von Hand übernehmen'));
      await tester.pumpAndSettle();
      expect(find.text('Von Hand übernommen'), findsOneWidget);
      // Live-Test im Sheet und Zustand im Dashboard dahinter
      expect(find.text('Manuell übernommen'), findsWidgets);
    });

    testWidgets('Zusammenfassung nennt Bedingungen und Licht', (tester) async {
      await _pump(tester, '/automations/motion/demo-waschraum?wizard=1&step=6');
      expect(find.text('Alles klar?'), findsOneWidget);
      expect(find.textContaining('18:00 bis 07:00'), findsWidgets);
      expect(find.textContaining('unter 30 lx'), findsOneWidget);
      expect(find.textContaining('mit Vorwarnung'), findsOneWidget);
    });
  });
}
