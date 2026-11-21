import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/map/climate_link_overlay.dart';
import 'package:haven/features/map/map_3d.dart' show Map3DView;
import 'package:haven/features/climate/thermostat_dial.dart';
import 'package:haven/features/climate/thermostat_settings.dart';
import 'package:haven/features/climate/heating_widgets.dart';
import 'package:haven/features/climate/thermostat_widgets.dart';
import 'package:haven/features/map/floor_plan_store.dart';
import 'package:haven/features/map/map_panels.dart';
import 'package:haven/features/map/map_thermostat.dart';
import 'package:haven/features/zigbee/zigbee_providers.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _salon = '0x00124b0000000030';

class _Plans implements FloorPlanRepository {
  @override
  Future<HavenFloorPlan?> load() async => kFakeFloorPlan;
  @override
  Future<void> save(HavenFloorPlan p) async {}
  @override
  Future<void> clear() async {}
}

/// Merkt sich jeden Z2M-Schreibbefehl.
class _Spy extends FakeRepository {
  _Spy() : super(simulate: false);
  final sets = <(String, Map<String, dynamic>)>[];
  @override
  Future<void> zigbeeSet(String ieee, Map<String, dynamic> values) {
    sets.add((ieee, values));
    return super.zigbeeSet(ieee, values);
  }
}

Future<(ProviderContainer, _Spy)> _pump(
  WidgetTester tester,
  String location, {
  Map<String, Object> prefs = const {},
  ThemeMode? mode,
  bool desktop = false,
  bool heating = true,
}) async {
  SharedPreferences.setMockInitialValues({
    ...prefs,
    if (mode != null) 'theme_mode': mode.name,
  });
  final store = SettingsStore(await SharedPreferences.getInstance());
  final repo = _Spy();
  await tester.runAsync(repo.start);
  // Ohne Raumregelung: das Thermostat zeigt seine eigene Steuerung.
  if (!heating) {
    await tester.runAsync(() => repo.deleteHeating('salon'));
    repo.sets.clear();
  }
  tester.view.physicalSize = desktop
      ? const Size(1400 * 2, 900 * 2)
      : const Size(412 * 2.625, 915 * 2.625);
  tester.view.devicePixelRatio = desktop ? 2 : 2.625;
  addTearDown(tester.view.reset);
  final c = ProviderContainer(
    overrides: [
      settingsStoreProvider.overrideWithValue(store),
      tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
      initialSessionProvider.overrideWithValue(Session(SessionMode.fake, repo)),
      floorPlanRepositoryProvider.overrideWithValue(_Plans()),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: HavenApp(initialLocation: location),
    ),
  );
  await _settle(tester);
  return (c, repo);
}

Future<void> _settle(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Map<String, dynamic> _state(ProviderContainer c) =>
    c.read(zigbeeProvider).states[_salon] ?? const {};

Future<void> _scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(
    f,
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(f.first);
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  group('Gerät-Detail', () {
    testWidgets('zeigt Zustand, Rad, Betriebsarten, Boost und Werte', (
      tester,
    ) async {
      await _pump(tester, '/zigbee/device/$_salon', heating: false);
      expect(find.byType(ThermostatMain), findsOneWidget);
      expect(find.byType(ThermostatDial), findsOneWidget);
      expect(find.text('Heizt auf 21 °C'), findsOneWidget);
      expect(find.text('Raum 19,6 °C'), findsOneWidget);
      for (final m in ['Ventil offen', 'Zeitplan', 'Komfort', 'Eco', 'Aus']) {
        expect(find.text(m), findsOneWidget, reason: m);
      }
      expect(find.text('Frostschutz'), findsOneWidget);
      await _scrollTo(tester, find.text('Boost'));
      expect(find.text('Ventil 42 %'), findsOneWidget);
      expect(find.text('Fenster zu'), findsOneWidget);
      expect(find.text('Batterie 76 %'), findsWidgets);
    });

    testWidgets('Betriebsart Eco setzt preset, der Sollwert folgt', (
      tester,
    ) async {
      final (c, spy) = await _pump(
        tester,
        '/zigbee/device/$_salon',
        heating: false,
      );
      await tester.tap(find.text('Eco'));
      await _settle(tester);
      expect(spy.sets.last.$1, _salon);
      expect(spy.sets.last.$2, {'preset': 'eco'});
      expect(_state(c)['preset'], 'eco');
      expect(_state(c)['current_heating_setpoint'], 17.0);
      expect(
        find.text('Heizt sparsam auf die Eco-Temperatur (17 °C).'),
        findsOneWidget,
      );
    });

    testWidgets('Plus stellt in Schritten, ein Befehl für mehrere Tipps', (
      tester,
    ) async {
      final (c, spy) = await _pump(
        tester,
        '/zigbee/device/$_salon',
        heating: false,
      );
      final plus = find.bySemanticsLabel('Wärmer');
      await tester.tap(plus);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(plus);
      await tester.pump(const Duration(milliseconds: 200));
      expect(spy.sets, isEmpty, reason: 'noch in der Wartezeit');
      await _settle(tester);
      expect(spy.sets, hasLength(1));
      expect(spy.sets.single.$2, {'current_heating_setpoint': 22.0});
      expect(_state(c)['current_heating_setpoint'], 22.0);
    });

    testWidgets('Aus sperrt das Rad und die Knöpfe', (tester) async {
      final (c, spy) = await _pump(
        tester,
        '/zigbee/device/$_salon',
        heating: false,
      );
      // „Ventil offen“ ist breit: die Reihe scrollt.
      await tester.ensureVisible(find.text('Aus').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Aus').first);
      await _settle(tester);
      expect(_state(c)['preset'], 'off');
      expect(find.text('Aus'), findsWidgets);
      spy.sets.clear();
      await tester.tap(find.bySemanticsLabel('Wärmer'));
      await _settle(tester);
      expect(spy.sets, isEmpty);
    });

    testWidgets('Boost startet mit gewählter Dauer', (tester) async {
      final (c, _) = await _pump(
        tester,
        '/zigbee/device/$_salon',
        heating: false,
      );
      await _scrollTo(tester, find.text('Starten'));
      await tester.tap(find.text('Starten'));
      await _settle(tester);
      await tester.tap(find.text('30 Minuten'));
      await _settle(tester);
      expect(_state(c)['boost_timeset_countdown'], 30);
      expect(find.text('Boost läuft'), findsOneWidget);
    });

    testWidgets('Einstellungen deutsch, Temperatur per Plus', (tester) async {
      final (c, spy) = await _pump(
        tester,
        '/zigbee/device/$_salon',
        heating: false,
      );
      await _scrollTo(tester, find.text('Komforttemperatur'));
      expect(find.text('Wochenplan'), findsOneWidget);
      expect(find.text('Temperaturen'), findsOneWidget);
      // Nicht doppelt: Betriebsart und Boost stehen nur oben.
      expect(find.text('Preset'), findsNothing);
      expect(find.text('Boost timeset countdown'), findsNothing);
      await tester.tap(find.bySemanticsLabel('Mehr, Komforttemperatur'));
      await _settle(tester, 10);
      expect(spy.sets.last.$2, {'comfort_temperature': 22});
      expect(_state(c)['comfort_temperature'], 22);
      await _scrollTo(tester, find.text('Kindersicherung'));
      expect(find.text('Fenster-offen-Erkennung'), findsOneWidget);
      await _scrollTo(tester, find.text('Temperatur abgleichen'));
      expect(find.text('-1,5 °C'), findsOneWidget);
    });

    testWidgets('Wochenplan: Tag ändern und für alle Tage speichern', (
      tester,
    ) async {
      final (c, spy) = await _pump(
        tester,
        '/zigbee/device/$_salon',
        heating: false,
      );
      await _scrollTo(tester, find.byType(WeekScheduleCard));
      await tester.tap(find.bySemanticsLabel(RegExp('^Montag:')));
      await _settle(tester);
      expect(find.byType(ScheduleEditor), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Wärmer, Wechsel 1'));
      await tester.tap(find.bySemanticsLabel('Später, Wechsel 1'));
      await tester.pump();
      expect(find.text('06:15'), findsOneWidget);
      await tester.tap(find.text('Alle Tage'));
      await tester.pump();
      await tester.tap(find.text('Speichern'));
      await _settle(tester, 20);
      final scheduleSets = [
        for (final s in spy.sets)
          for (final k in s.$2.keys)
            if (k.startsWith('schedule_')) k,
      ];
      expect(scheduleSets, hasLength(7));
      expect(
        _state(c)['schedule_sunday'],
        '06:15/21.5/3 08:00/17.0/2 12:00/21.0/3 14:00/17.0/2 17:00/21.5/3 22:00/17.0/2',
      );
      expect(find.byType(ScheduleEditor), findsNothing);
    });

    testWidgets('Desktop: Master-Detail mit Rad und Wochenplan', (
      tester,
    ) async {
      await _pump(tester, '/zigbee?select=0x00124b0000000031', desktop: true);
      expect(find.byType(ThermostatDial), findsOneWidget);
      expect(find.text('Hält 18 °C'), findsOneWidget);
      final card = find.byType(WeekScheduleCard);
      await tester.scrollUntilVisible(
        card,
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView).last,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(card);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.bySemanticsLabel(RegExp('^Freitag:')));
      await _settle(tester);
      expect(find.byType(ScheduleEditor), findsOneWidget);
      expect(find.text('Freitag'), findsOneWidget);
      expect(find.text('Mo bis Fr'), findsOneWidget);
    });

    testWidgets('hell und dunkel ohne Fehler', (tester) async {
      for (final m in [ThemeMode.light, ThemeMode.dark]) {
        await _pump(tester, '/zigbee/device/$_salon', mode: m, heating: false);
        expect(tester.takeException(), isNull);
        expect(find.byType(ThermostatDial), findsOneWidget);
      }
    });
  });

  testWidgets('Raum ohne Regelung: Zeilen mit Plus, Sheet und Hinweis', (
    tester,
  ) async {
    const ruheraum = '0x00124b0000000031';
    final (c, spy) = await _pump(tester, '/home/room/ruheraum');
    await _scrollTo(tester, find.text('Heizung'));
    // Thermostat und Wandthermostat (Display) des Raums.
    expect(find.byType(ThermostatRow), findsNWidgets(2));
    expect(find.text('Thermostat Ruheraum'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Wärmer Thermostat Ruheraum'));
    await _settle(tester, 10);
    expect(spy.sets.last.$1, ruheraum);
    expect(spy.sets.last.$2, {'current_heating_setpoint': 18.5});
    expect(
      c.read(zigbeeProvider).states[ruheraum]?['current_heating_setpoint'],
      18.5,
    );
    await _scrollTo(tester, find.text('Nach Raumthermometer regeln'));
    expect(find.text('Nach Raumthermometer regeln'), findsOneWidget);
    await tester.tap(find.text('Thermostat Ruheraum'));
    await _settle(tester);
    expect(find.byType(ThermostatControl), findsOneWidget);
    expect(find.text('Gerät öffnen'), findsOneWidget);
  });

  group('Karte', () {
    testWidgets('Temperatur: Thermostat mit Ziel, Antippen öffnet Panel', (
      tester,
    ) async {
      await _pump(tester, '/map', prefs: {'map_layer': 'temperature'});
      final marker = find.byWidgetPredicate(
        (w) =>
            w is ThermostatMarker && w.entityId == 'climate.thermostat_salon',
      );
      expect(marker, findsOneWidget);
      expect(find.text('→ 21°'), findsWidgets);
      // Klima: Heizkörper rot pulsierend, solange er heizt.
      final tint = tester
          .widget<Map3DView>(find.byType(Map3DView))
          .deviceTints['climate.thermostat_salon'];
      expect(tint?.pulse, isTrue);
      expect(tint?.color, kHeatingLinkColor);
      // Klima: Leitungen von den Thermometern zum Thermostat im Boden.
      expect(find.byType(ClimateLinkOverlay), findsOneWidget);
      expect(
        tester
            .widget<ClimateLinkOverlay>(find.byType(ClimateLinkOverlay))
            .links,
        isNotEmpty,
      );
      await tester.tap(marker);
      await _settle(tester);
      expect(find.byType(ThermostatPanel), findsOneWidget);
      // Teil der Raumregelung: der Raum oben, das Thermostat als Zeile.
      expect(find.byType(RoomHeatingCard), findsOneWidget);
      expect(find.byType(ThermostatRow), findsOneWidget);
      expect(find.byType(ThermostatDial), findsNothing);
      expect(find.text('Heizung · Salon'), findsOneWidget);
    });

    testWidgets('Thermostat ohne Raumregelung: eigene Steuerung', (
      tester,
    ) async {
      await _pump(
        tester,
        '/map',
        prefs: {'map_layer': 'temperature'},
        heating: false,
      );
      await tester.tap(
        find.byWidgetPredicate(
          (w) =>
              w is ThermostatMarker && w.entityId == 'climate.thermostat_salon',
        ),
      );
      await _settle(tester);
      expect(find.byType(ThermostatDial), findsOneWidget);
      expect(find.byType(RoomHeatingCard), findsNothing);
      expect(find.text('Thermostat · Salon'), findsOneWidget);
    });

    testWidgets('Ziehen am Ring im Sheet stellt die Temperatur', (
      tester,
    ) async {
      final (c, spy) = await _pump(
        tester,
        '/map',
        prefs: {'map_layer': 'temperature'},
        heating: false,
      );
      await tester.tap(
        find.byWidgetPredicate(
          (w) =>
              w is ThermostatMarker && w.entityId == 'climate.thermostat_salon',
        ),
      );
      await _settle(tester);
      final rect = tester.getRect(find.byType(ThermostatDial));
      final r = rect.width / 2 - 14;
      Offset at(double t) {
        // Bogen: 270° ab 135°, Bereich 5 bis 30 °C.
        final a = math.pi * 0.75 + math.pi * 1.5 * (t - 5) / 25;
        return rect.center + Offset(math.cos(a), math.sin(a)) * r;
      }

      final g = await tester.startGesture(at(21));
      for (var t = 21.5; t <= 25; t += 0.5) {
        await g.moveTo(at(t));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await _settle(tester);
      expect(
        find.byType(ThermostatPanel),
        findsOneWidget,
        reason: 'Sheet bleibt',
      );
      expect(spy.sets, hasLength(1));
      expect(spy.sets.single.$2['current_heating_setpoint'], 25.0);
      expect(_state(c)['current_heating_setpoint'], 25.0);
    });

    testWidgets('Kombi: nur heizende Thermostate, Antippen öffnet das Panel', (
      tester,
    ) async {
      await _pump(tester, '/map', prefs: {'map_layer': 'combo'});
      Finder thermostat(String id) => find.byWidgetPredicate(
        (w) => w is ThermostatMarker && w.entityId == id,
      );
      // Ruheraum ruht gerade: in der Kombi-Ansicht nicht zu sehen.
      expect(thermostat('climate.thermostat_ruheraum'), findsNothing);
      final salon = thermostat('climate.thermostat_salon');
      expect(salon, findsOneWidget);
      await tester.tap(salon);
      await _settle(tester);
      expect(find.byType(ThermostatPanel), findsOneWidget);
    });

    testWidgets('Raum-Klima nennt Thermostate unter Heizung', (tester) async {
      await _pump(tester, '/map', prefs: {'map_layer': 'temperature'});
      // Raumfläche des Salons neben dem Thermostat antippen.
      final m = find.byWidgetPredicate(
        (w) =>
            w is ThermostatMarker && w.entityId == 'climate.thermostat_salon',
      );
      await tester.tapAt(tester.getCenter(m) + const Offset(60, -50));
      await _settle(tester);
      expect(find.byType(RoomClimatePanel), findsOneWidget);
      expect(find.text('Heizung'), findsOneWidget);
      expect(find.byType(ThermostatRow), findsOneWidget);
      expect(
        find.textContaining('zählen hier nicht mit'),
        findsOneWidget,
        reason: 'Der Salon hat eigene Sensoren',
      );
    });
  });
}
