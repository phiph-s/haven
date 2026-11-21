import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/data/ha/ha_heating.dart';
import 'package:haven/data/haven_repository.dart';
import 'package:haven/data/models/entity_state.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/data/models/room_heating.dart';
import 'package:haven/data/models/snapshot.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/dev/fake_heating.dart';
import 'package:haven/dev/fake_thermostat_sim.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/climate/heating_logic.dart';
import 'package:haven/features/climate/heating_providers.dart';
import 'package:haven/features/climate/heating_setup_screen.dart';
import 'package:haven/features/climate/heating_widgets.dart';
import 'package:haven/features/map/floor_plan_store.dart';
import 'package:haven/features/zigbee/zigbee_providers.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _salonTrv = '0x00124b0000000030';
const _ruheraumTrv = '0x00124b0000000031';

class _Plans implements FloorPlanRepository {
  @override
  Future<HavenFloorPlan?> load() async => kFakeFloorPlan;
  @override
  Future<void> save(HavenFloorPlan p) async {}
  @override
  Future<void> clear() async {}
}

/// Merkt sich Z2M-Befehle und Aufrufe der Regelung.
class _Spy extends FakeRepository {
  _Spy() : super(simulate: false);
  final sets = <(String, Map<String, dynamic>)>[];
  final controls = <(String, double?, HeatingMode?)>[];
  @override
  Future<void> zigbeeSet(String ieee, Map<String, dynamic> values) {
    sets.add((ieee, values));
    return super.zigbeeSet(ieee, values);
  }

  @override
  Future<HeatingStatus> controlHeating(
    String areaId, {
    double? target,
    HeatingMode? mode,
    bool resume = false,
  }) {
    controls.add((areaId, target, mode));
    return super.controlHeating(
      areaId,
      target: target,
      mode: mode,
      resume: resume,
    );
  }
}

Future<(ProviderContainer, _Spy)> _pump(
  WidgetTester tester,
  String location, {
  ThemeMode? mode,
}) async {
  SharedPreferences.setMockInitialValues({
    if (mode != null) 'theme_mode': mode.name,
  });
  final store = SettingsStore(await SharedPreferences.getInstance());
  final repo = _Spy();
  await tester.runAsync(repo.start);
  tester.view.physicalSize = const Size(412 * 2.625, 915 * 2.625);
  tester.view.devicePixelRatio = 2.625;
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

Future<void> _scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(
    f,
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(f.first);
  await tester.pump(const Duration(milliseconds: 300));
}

Map<String, dynamic> _trv(ProviderContainer c, String ieee) =>
    c.read(zigbeeProvider).states[ieee] ?? const {};

EntityState _e(String id, String state, [Map<String, dynamic>? attrs]) =>
    EntityState(id, state, {...?attrs});

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  group('Modell', () {
    test('Einstellungen hin und zurück', () {
      const c = HeatingConfig(
        areaId: 'salon',
        trvs: [_salonTrv],
        sensors: ['sensor.a'],
        windows: ['binary_sensor.f'],
        windowOpenDelay: 30,
        calibration: HeatingCalibration.target,
        outdoorEntity: 'weather.home',
        outdoorThreshold: 15.5,
        presets: {
          HeatingMode.comfort: 22,
          HeatingMode.eco: 17,
          HeatingMode.away: 15,
        },
        lockManual: true,
      );
      final j = c.toJson();
      expect(j['outdoor'], {'entity': 'weather.home', 'threshold': 15.5});
      expect(j['presets'], {'comfort': 22.0, 'eco': 17.0, 'away': 15.0});
      expect(HeatingConfig.fromJson(j), c);
      final cleared = c.copyWith(clearOutdoor: true);
      expect(cleared.toJson()['outdoor'], isNull);
      expect(HeatingConfig.fromJson({'area_id': 'x'}).presets, {
        HeatingMode.comfort: 21.0,
        HeatingMode.eco: 18.0,
        HeatingMode.away: 16.0,
      });
    });

    test('Status aus der Integration und Ereignis', () {
      final e = HaHeating.parseEvent({
        'data': {
          'area_id': 'salon',
          'status': {
            'mode': 'eco',
            'target': 21.0,
            'effective_target': 18.0,
            'room_temperature': 20.4,
            'room_source': 'sensors',
            'sensors': [
              {'entity_id': 'sensor.a', 'value': 20.4},
              {'entity_id': 'sensor.b', 'value': null},
            ],
            'reason': 'window',
            'heating': false,
            'window': {
              'open': true,
              'paused': true,
              'pause_at': null,
              'resume_at': '2026-11-18T10:00:00+00:00',
              'contacts': [
                {'entity_id': 'binary_sensor.f', 'open': true},
              ],
            },
            'outdoor': {'value': 7.2, 'current': 6.0, 'summer': false},
            'trvs': [
              {
                'ieee': _salonTrv,
                'name': 'Thermostat Salon',
                'local_temperature': 23.1,
                'calibration': -2.7,
                'method': 'offset',
                'correction': -2.7,
                'desired_calibration': -2.7,
                'pending': true,
              },
            ],
          },
        },
      })!;
      expect(e.areaId, 'salon');
      final s = e.status;
      expect(s.mode, HeatingMode.eco);
      expect(s.pause, HeatingPause.window);
      expect(s.sensorValues, {'sensor.a': 20.4, 'sensor.b': null});
      expect(s.resumeAt, DateTime.utc(2026, 11, 18, 10));
      expect(s.contacts['binary_sensor.f'], isTrue);
      expect(s.outdoorValue, 7.2);
      expect(s.trvs.single.method, HeatingCalibration.offset);
      expect(s.trvs.single.pending, isTrue);
      expect(HaHeating.parseEvent({'data': 'x'}), isNull);
    });
  });

  group('Logik', () {
    final snap = HavenSnapshot(
      entities: {
        'sensor.salon_temp': _e('sensor.salon_temp', '20.5', {
          'device_class': 'temperature',
          'friendly_name': 'Thermometer Salon',
        }),
        'sensor.trv_local': _e('sensor.trv_local', '24.0', {
          'device_class': 'temperature',
          'friendly_name': 'Thermostat Messung',
        }),
        'sensor.flur_temp': _e('sensor.flur_temp', '19.0', {
          'device_class': 'temperature',
          'friendly_name': 'Alpha Flur',
        }),
        'binary_sensor.fenster': _e('binary_sensor.fenster', 'on', {
          'device_class': 'window',
          'friendly_name': 'Fenster Salon',
        }),
        'binary_sensor.bewegung': _e('binary_sensor.bewegung', 'on', {
          'device_class': 'motion',
        }),
        'weather.home': _e('weather.home', 'sunny', {
          'temperature': 12.5,
          'friendly_name': 'Zuhause',
        }),
      },
    );
    const areas = {
      'sensor.salon_temp': 'salon',
      'binary_sensor.fenster': 'salon',
    };

    test('Thermometer: Raum zuerst, ohne die Messung der Thermostate', () {
      final l = temperatureSources(
        snap,
        'salon',
        excluded: {'sensor.trv_local'},
        areas: areas,
      );
      expect(l.map((s) => s.entityId), [
        'sensor.salon_temp',
        'sensor.flur_temp',
      ]);
      expect(l.first.inRoom, isTrue);
      expect(l.first.value, '20,5 °C');
    });

    test('Fensterkontakte und Außenquellen', () {
      final w = windowSources(snap, 'salon', areas: areas);
      expect(w.map((s) => s.entityId), ['binary_sensor.fenster']);
      expect(w.single.value, 'offen');
      final o = outdoorSources(snap, excluded: {'sensor.trv_local'});
      expect(o.first.entityId, 'weather.home');
      expect(o.first.value, '12,5 °C');
      expect(o, hasLength(3));
    });

    test('Mittelwert, Vorschau und Texte', () {
      expect(
        averageOf(snap.entities, ['sensor.salon_temp', 'sensor.flur_temp']),
        19.75,
      );
      expect(averageOf(snap.entities, ['sensor.weg']), isNull);
      expect(correctionPreview(20.5, 23.2), -2.7);
      expect(fmtSigned(-2.7), '−2,7');
      expect(fmtSigned(0.04), '±0');
      expect(fmtSigned(1), '+1');
      expect(nearestDelay(kWindowOpenDelays, 50), 60);
    });

    test('Satz zum Zustand', () {
      expect(
        heatingStatusText(
          const HeatingStatus(effectiveTarget: 21, heating: true),
        ),
        'Heizt auf 21 °C',
      );
      expect(
        heatingStatusText(
          const HeatingStatus(effectiveTarget: 21, roomTemperature: 20.9),
        ),
        'Hält 21 °C',
      );
      expect(
        heatingStatusText(const HeatingStatus(pause: HeatingPause.window)),
        'Fenster offen, Heizung pausiert',
      );
      expect(
        heatingStatusText(
          const HeatingStatus(pause: HeatingPause.summer, outdoorValue: 18.2),
        ),
        'Sommerpause, draußen 18,2 °C',
      );
      expect(
        heatingSourceText(
          const HeatingStatus(
            roomSource: 'sensors',
            sensorValues: {'a': 20, 'b': null},
          ),
          2,
        ),
        'Mittel aus 1 von 2 Thermometern',
      );
      expect(
        heatingSourceText(const HeatingStatus(roomSource: 'trv'), 1),
        'Thermometer ohne Wert, am Thermostat gemessen',
      );
      expect(
        trvCorrectionText(
          const HeatingTrvStatus(
            ieee: 'x',
            method: HeatingCalibration.offset,
            desiredCalibration: -2.1,
          ),
          21,
        ),
        'gleicht −2,1 °C aus',
      );
      expect(
        trvCorrectionText(
          const HeatingTrvStatus(
            ieee: 'x',
            method: HeatingCalibration.target,
            desiredSetpoint: 24.5,
          ),
          21,
        ),
        'stellt 24,5° ein für 21° im Raum',
      );
    });
  });

  group('Entwicklungsdaten', () {
    test('Salon ist eingerichtet, Eco stellt das Thermostat', () async {
      final repo = FakeRepository(simulate: false);
      await repo.start();
      addTearDown(repo.dispose);
      final all = await repo.heatingRooms();
      expect(all.supported, isTrue);
      final salon = all.byArea('salon')!;
      expect(salon.config.sensors, hasLength(2));
      expect(salon.status.roomSource, 'sensors');
      expect(salon.status.roomTemperature, 21.3);
      // TRV zeigt 19,6 bei Kalibrierung −1,5 (roh 21,1), Raum 21,27: +0,2
      expect(salon.status.trvs.single.desiredCalibration, 0.2);

      final s = await repo.controlHeating('salon', mode: HeatingMode.eco);
      expect(s.mode, HeatingMode.eco);
      expect(s.effectiveTarget, 18);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final trv = await repo.zigbeeStates();
      expect(trv[_salonTrv]!['current_heating_setpoint'], 18);
      expect(trv[_salonTrv]!['local_temperature_calibration'], 0.2);
      // Kalibrierung verschiebt die Anzeige des Thermostats mit
      expect(trv[_salonTrv]!['local_temperature'], 21.3);
    });

    test(
      'Ein Thermostat gehört nur zu einem Raum, Löschen setzt zurück',
      () async {
        final repo = FakeRepository(simulate: false);
        await repo.start();
        addTearDown(repo.dispose);
        await expectLater(
          repo.saveHeating(
            const HeatingConfig(areaId: 'ruheraum', trvs: [_salonTrv]),
          ),
          throwsA(isA<Object>()),
        );
        await repo.controlHeating('salon', target: 21);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await repo.deleteHeating('salon');
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final trv = await repo.zigbeeStates();
        expect(trv[_salonTrv]!['local_temperature_calibration'], 0);
        expect((await repo.heatingRooms()).rooms, isEmpty);
      },
    );
  });

  group('Display als Raumregler', () {
    const display = FakeHeating.ruheraumDisplay;

    test('Konfiguration und Status lesen das Display', () {
      final c = HeatingConfig.fromJson({'area_id': 'a', 'display': 'd'});
      expect(c.display, 'd');
      expect(c.toJson()['display'], 'd');
      expect(HeatingConfig.fromJson(c.toJson()), c);
      expect(c.copyWith(clearDisplay: true).display, isNull);
      final s = HeatingStatus.fromJson({
        'room_source': 'display',
        'display': {
          'ieee': 'd',
          'name': 'Display',
          'local_temperature': 19.5,
          'setpoint': 21,
          'mode': 'heat',
          'pending': true,
        },
      });
      expect(s.usesSensors, isTrue);
      expect(s.display!.setpoint, 21);
      expect(s.display!.pending, isTrue);
      expect(heatingSourceText(s, 0), 'Laut Display');
      final rooms = HeatingRooms.fromJson({
        'rooms': [
          {
            'config': {
              'area_id': 'a',
              'trvs': ['t'],
              'display': 'd',
            },
          },
        ],
        'displays': ['d'],
      });
      expect(rooms.isDisplay('d'), isTrue);
      expect(rooms.controlledBy('d')!.areaId, 'a');
    });

    test('Display steuert den Raum, Haven spiegelt das Ziel', () async {
      final repo = FakeRepository(simulate: false);
      await repo.start();
      addTearDown(repo.dispose);
      expect((await repo.heatingRooms()).displays, {display});
      // Als Heizkörperthermostat geht es nicht.
      await expectLater(
        repo.saveHeating(
          const HeatingConfig(areaId: 'ruheraum', trvs: [display]),
        ),
        throwsA(isA<HavenException>()),
      );
      await repo.saveHeating(
        const HeatingConfig(
          areaId: 'ruheraum',
          trvs: [_ruheraumTrv],
          display: display,
        ),
      );
      Future<Map<String, dynamic>> st(String ieee) async =>
          (await repo.zigbeeStates())[ieee]!;
      Future<void> settle() async {
        // Das Fake-Gerät übernimmt Befehle nach 120 ms.
        repo.heatingTick();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        repo.heatingTick();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      await settle();
      // Am Display gedreht: gilt für den Raum, das Thermostat folgt.
      await repo.zigbeeSet(display, {'current_heating_setpoint': 22.5});
      await settle();
      var room = (await repo.heatingRooms()).byArea('ruheraum')!;
      expect(room.status.target, 22.5);
      expect(room.status.mode, HeatingMode.heat);
      expect((await st(_ruheraumTrv))['current_heating_setpoint'], isNotNull);
      expect(room.status.display!.setpoint, 22.5);
      expect(room.status.roomSource, 'display');
      // In der App auf Eco: das Display zeigt das Eco-Ziel.
      await repo.controlHeating('ruheraum', mode: HeatingMode.eco);
      await settle();
      expect((await st(display))['preset'], 'eco');
      expect((await st(display))['eco_temperature'], 18);
      expect((await st(display))['current_heating_setpoint'], 18);
      // Am Display aus: der Raum ist aus.
      await repo.zigbeeSet(display, {'system_mode': 'off'});
      await settle();
      room = (await repo.heatingRooms()).byArea('ruheraum')!;
      expect(room.status.mode, HeatingMode.off);
      expect((await st(_ruheraumTrv))['preset'], 'off');
      // Nie kalibriert.
      expect((await st(display))['local_temperature_calibration'], 0);
    });

    test('Fensterpause, Eco und Wochenplan am Display', () async {
      const win = 'binary_sensor.fenster_test';
      var open = false;
      final states = <String, Map<String, dynamic>>{
        display: {
          'system_mode': 'heat',
          'preset': 'manual',
          'current_heating_setpoint': 20.0,
          'local_temperature': 19.0,
          'eco_temperature': 16,
          'deadzone_temperature': 1,
          'battery': 12,
          for (final d in [
            'monday',
            'tuesday',
            'wednesday',
            'thursday',
            'friday',
            'saturday',
            'sunday',
          ])
            'schedule_$d': '00:00/23',
        },
        _ruheraumTrv: {
          'preset': 'comfort',
          'current_heating_setpoint': 20.0,
          'local_temperature': 19.0,
        },
      };
      void apply(String ieee, Map<String, dynamic> v) {
        final st = states.putIfAbsent(ieee, () => {});
        st
          ..addAll(thermostatDerived(st, v, DateTime.now()))
          ..addAll(v);
      }
      final heat = FakeHeating(
        entities: () => {win: EntityState(win, open ? 'on' : 'off')},
        trvState: (i) => states[i] ?? {},
        trvSet: (i, v) async => apply(i, v),
        trvName: (i) => i == display ? 'Display' : 'TRV',
        thermostats: () => states.keys,
      );
      addTearDown(heat.dispose);
      await heat.save(
        const HeatingConfig(
          areaId: 'ruheraum',
          trvs: [_ruheraumTrv],
          display: display,
          windows: [win],
          windowOpenDelay: 60,
          windowCloseDelay: 120,
        ),
      );
      final t0 = DateTime.now();
      var t = t0;
      HeatingStatus tick([int s = 1]) {
        t = t.add(Duration(seconds: s));
        heat.tick(t);
        return heat.status('ruheraum')!;
      }

      var s = tick();
      expect(s.display!.battery, 12);
      expect(states[display]!['eco_temperature'], 18); // gleich dem Raum
      // Fenster auf: nach der Verzögerung Pause, Display aus.
      open = true;
      tick();
      s = tick(61);
      expect(s.pause, HeatingPause.window);
      expect(states[display]!['system_mode'], 'off');
      expect(states[_ruheraumTrv]!['preset'], 'off');
      s = tick();
      expect(s.mode, HeatingMode.heat, reason: 'eigenes Aus ist keine Bedienung');
      // Am Display eingeschaltet: heizt trotz offenem Fenster.
      apply(display, {'system_mode': 'heat'});
      s = tick();
      expect(s.windowOverride, isTrue);
      expect(s.pause, isNull);
      s = tick(300);
      expect(s.pause, isNull);
      expect(heatingStatusText(s), 'Fenster offen, am Display eingeschaltet');
      expect(states[_ruheraumTrv]!['preset'], 'comfort');
      // Fenster zu: Ausnahme vorbei, nächstes Öffnen pausiert wieder.
      open = false;
      s = tick();
      expect(s.windowOverride, isFalse);
      open = true;
      tick();
      s = tick(61);
      expect(s.pause, HeatingPause.window);
      open = false;
      tick();
      s = tick(121);
      expect(s.pause, isNull);
      expect(states[display]!['system_mode'], 'heat');
      // Eco am Display: Eco im Raum.
      apply(display, {'preset': 'eco'});
      s = tick();
      expect(s.mode, HeatingMode.eco);
      expect(states[display]!['current_heating_setpoint'], 18);
      // Am Display gedreht (geht auf Manuell): Manuell mit dieser Temperatur.
      apply(display, {'current_heating_setpoint': 21.5});
      s = tick();
      expect(s.mode, HeatingMode.heat);
      expect(s.target, 21.5);
      // Eigener Wochenplan: Haven stellt zurück, der Planwert zählt nicht.
      apply(display, {'preset': 'auto'});
      expect(states[display]!['current_heating_setpoint'], isNot(21.5));
      s = tick();
      expect(s.target, 21.5);
      expect(states[display]!['preset'], 'manual');
      expect(states[display]!['current_heating_setpoint'], 21.5);
      s = tick();
      expect(s.target, 21.5);
      expect(s.display!.pending, isFalse);
    });

    test('Markieren und abwählen', () async {
      final repo = FakeRepository(simulate: false);
      await repo.start();
      addTearDown(repo.dispose);
      // Regelt der Salon mit: nicht als Display markierbar.
      await expectLater(
        repo.setHeatingDisplay(_salonTrv, true),
        throwsA(
          isA<HavenException>().having((e) => e.code, 'code', 'device_taken'),
        ),
      );
      await repo.saveHeating(
        const HeatingConfig(
          areaId: 'ruheraum',
          trvs: [_ruheraumTrv],
          display: display,
        ),
      );
      final left = await repo.setHeatingDisplay(display, false);
      expect(left, isEmpty);
      final room = (await repo.heatingRooms()).byArea('ruheraum')!;
      expect(room.config.display, isNull);
      expect(room.status.display, isNull);
      // Ausstehende Befehle ans Fake-Gerät abwarten (120 ms).
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });

    testWidgets('Geräteseite: Schalter „Nur als Display“', (tester) async {
      final (c, _) = await _pump(tester, '/zigbee/device/$display');
      await _scrollTo(
        tester,
        find.byKey(const ValueKey('thermostat-display-toggle')),
      );
      expect(find.text('Nur als Display'), findsOneWidget);
      expect(c.read(heatingProvider).value!.isDisplay(display), isTrue);
      await tester.tap(find.bySemanticsLabel('Nur als Display'));
      await _settle(tester);
      expect(c.read(heatingProvider).value!.isDisplay(display), isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  group('Am Thermostat gesteuert', () {
    test('Ventil offen am Gerät gibt frei, Wieder regeln übernimmt', () async {
      final repo = FakeRepository(simulate: false);
      await repo.start();
      addTearDown(repo.dispose);
      repo.heatingTick();
      await repo.zigbeeSet(_salonTrv, {'preset': 'on'});
      repo.heatingTick();
      var salon = (await repo.heatingRooms()).byArea('salon')!;
      expect(salon.status.released, isTrue);
      final trv = salon.status.trvs.single;
      expect(trv.releasedMode, 'on');
      expect(trvReleasedText(trv), startsWith('Ventil offen bis'));
      // Haven hält still: kein Zurückstellen
      repo.heatingTick();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect((await repo.zigbeeStates())[_salonTrv]!['preset'], 'on');
      final s = await repo.controlHeating('salon', resume: true);
      expect(s.released, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect((await repo.zigbeeStates())[_salonTrv]!['preset'], 'comfort');
      salon = (await repo.heatingRooms()).byArea('salon')!;
      expect(salon.status.trvs.single.released, isFalse);
    });

    test('Status liest Freigabe aus der Integration', () {
      final s = HeatingStatus.fromJson({
        'released': true,
        'trvs': [
          {
            'ieee': 'x',
            'released': true,
            'released_mode': 'auto',
            'release_until': null,
          },
        ],
      });
      expect(s.released, isTrue);
      expect(trvReleasedText(s.trvs.single), 'eigener Wochenplan');
      expect(
        HeatingConfig.fromJson({
          'area_id': 'a',
          'calibrate_released': false,
        }).calibrateReleased,
        isFalse,
      );
    });

    testWidgets('Karte zeigt den Hinweis, Wieder regeln übernimmt', (
      tester,
    ) async {
      final (c, spy) = await _pump(tester, '/home/room/salon');
      spy.heatingTick();
      await tester.runAsync(() => spy.zigbeeSet(_salonTrv, {'preset': 'on'}));
      spy.heatingTick();
      await _settle(tester);
      await _scrollTo(tester, find.byType(RoomHeatingCard));
      expect(find.byKey(const ValueKey('heating-released')), findsOneWidget);
      expect(find.textContaining('Ventil offen bis'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('heating-resume')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('heating-released')), findsNothing);
      expect(_trv(c, _salonTrv)['preset'], 'comfort');
    });
  });

  group('Raum', () {
    testWidgets('Karte zeigt Raumtemperatur, Ziel, Modus und Ausgleich', (
      tester,
    ) async {
      await _pump(tester, '/home/room/salon');
      await _scrollTo(tester, find.byType(RoomHeatingCard));
      expect(find.byType(RoomHeatingCard), findsOneWidget);
      expect(find.byKey(const ValueKey('heating-room-temp')), findsOneWidget);
      expect(find.text('Mittel aus 2 Thermometern'), findsOneWidget);
      expect(find.text('21°'), findsOneWidget);
      expect(find.text('Eco 18°'), findsOneWidget);
      expect(find.textContaining('gleicht +0,2 °C aus'), findsOneWidget);
      expect(find.text('Außen 8 °C'), findsOneWidget);
    });

    testWidgets('Plus bündelt Tipps, Eco schaltet sofort', (tester) async {
      final (c, spy) = await _pump(tester, '/home/room/salon');
      await _scrollTo(tester, find.byType(RoomHeatingCard));
      final plus = find.bySemanticsLabel('Wärmer');
      await tester.tap(plus.first);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.tap(plus.first);
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('22°'), findsOneWidget, reason: 'sofort sichtbar');
      expect(spy.controls, isEmpty);
      await _settle(tester);
      expect(spy.controls, [('salon', 22.0, null)]);
      expect(_trv(c, _salonTrv)['current_heating_setpoint'], 22.0);

      await tester.tap(find.text('Eco 18°'));
      await _settle(tester);
      expect(spy.controls.last, ('salon', null, HeatingMode.eco));
      expect(_trv(c, _salonTrv)['current_heating_setpoint'], 18.0);
      expect(find.text('18°'), findsOneWidget);
    });

    testWidgets('Aus schaltet die Thermostate ab', (tester) async {
      final (c, _) = await _pump(tester, '/home/room/salon');
      await _scrollTo(tester, find.byType(RoomHeatingCard));
      await tester.tap(
        find.descendant(
          of: find.byType(RoomHeatingCard),
          matching: find.text('Aus'),
        ),
      );
      await _settle(tester);
      expect(_trv(c, _salonTrv)['preset'], 'off');
      expect(find.text('Heizung aus'), findsOneWidget);
    });
  });

  group('Einrichtung', () {
    testWidgets('neuer Raum: Vorauswahl, Vorschau, starten', (tester) async {
      final (c, _) = await _pump(tester, '/heating/ruheraum');
      expect(find.byType(HeatingSetupScreen), findsOneWidget);
      expect(find.text('Heizung Ruheraum'), findsOneWidget);
      // Thermostat und Thermometer des Raums sind vorgewählt
      expect(
        find.text('Thermostat Ruheraum: am Heizkörper 18,4 °C'),
        findsOneWidget,
      );
      // Das Wandthermostat ist als Display markiert: es wird der Regler
      // und misst mit.
      expect(find.text('Mittel aus Display und Thermometer'), findsOneWidget);
      expect(find.textContaining('+2,'), findsOneWidget);
      expect(find.text('Thermostat Salon'), findsOneWidget);
      expect(find.text('regelt schon Salon'), findsOneWidget);
      await tester.tap(find.text('Regelung starten'));
      await _settle(tester);
      final saved = c.read(heatingProvider).value!.byArea('ruheraum')!;
      expect(saved.config.trvs, [_ruheraumTrv]);
      expect(saved.config.display, FakeHeating.ruheraumDisplay);
      expect(saved.config.sensors, ['sensor.sensor_ruheraum_temperature']);
      expect(saved.config.calibration, HeatingCalibration.offset);
      expect(find.byType(HeatingSetupScreen), findsNothing);
    });

    testWidgets('bestehender Raum: Ausgleich wählen, Sommer, Entfernen', (
      tester,
    ) async {
      final (c, _) = await _pump(tester, '/heating/salon');
      expect(find.text('Speichern'), findsOneWidget);
      await _scrollTo(tester, find.text('Zieltemperatur verschieben'));
      await tester.tap(find.text('Zieltemperatur verschieben'));
      await tester.pump(const Duration(milliseconds: 300));
      await _scrollTo(tester, find.text('Bei warmem Wetter nicht heizen'));
      expect(find.text('Pause ab'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Pause ab wärmer'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Speichern'));
      await _settle(tester);
      final saved = c.read(heatingProvider).value!.byArea('salon')!.config;
      expect(saved.calibration, HeatingCalibration.target);
      expect(saved.outdoorThreshold, 16.5);

      expect(find.byType(HeatingSetupScreen), findsNothing);
    });

    testWidgets('Entfernen fragt nach und löscht', (tester) async {
      final (c, spy) = await _pump(tester, '/heating/salon');
      await _scrollTo(tester, find.text('Regelung entfernen'));
      await tester.tap(find.text('Regelung entfernen'));
      await _settle(tester);
      expect(find.text('Regelung entfernen?'), findsOneWidget);
      await tester.tap(find.text('Entfernen'));
      await _settle(tester);
      expect(c.read(heatingProvider).value!.byArea('salon'), isNull);
      expect(find.byType(HeatingSetupScreen), findsNothing);
    });

    testWidgets('hell und dunkel ohne Fehler', (tester) async {
      for (final m in [ThemeMode.light, ThemeMode.dark]) {
        await _pump(tester, '/heating/salon', mode: m);
        expect(tester.takeException(), isNull);
        expect(find.byType(HeatingSetupScreen), findsOneWidget);
      }
    });
  });
}
