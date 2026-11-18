import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/models/entity_state.dart';
import 'package:haven/data/models/zigbee.dart';
import 'package:haven/dev/fake_data.dart';
import 'package:haven/dev/fake_thermostat_sim.dart';
import 'package:haven/features/climate/thermostat_model.dart';
import 'package:haven/features/zigbee/zigbee_model.dart';

ZbDevice _trv() => ZbDevice.fromJson(
  Map<String, dynamic>.from(
    (kFakeZigbee['devices'] as List).firstWhere((d) => d['model'] == 'TRV602Z'),
  ),
);

ZbDeviceView _view(Map<String, dynamic> values, [List<EntityState>? ents]) =>
    ZbDeviceView(device: _trv(), values: values, entities: ents ?? const []);

void main() {
  group('ThermoMode', () {
    test('Z2M- und HA-Presets', () {
      expect(ThermoMode.fromPreset('on'), ThermoMode.manual);
      expect(ThermoMode.fromPreset('auto'), ThermoMode.schedule);
      expect(ThermoMode.fromPreset('antifrost'), ThermoMode.frost);
      expect(ThermoMode.fromPreset('eco'), ThermoMode.eco);
      expect(ThermoMode.fromPreset('none'), isNull);
      expect(ThermoMode.manual.z2m, 'on');
      expect(ThermoMode.frost.z2m, 'antifrost');
    });
  });

  group('ThermostatState aus Z2M-Werten', () {
    test('liest Ist, Soll, Modus, Ventil, Fenster, Sperre', () {
      final t = ThermostatState.from(
        view: _view({
          ...kFakeThermostatStates['Thermostat Salon']!,
          'child_lock': 'LOCK',
        }),
      );
      expect(t.current, 19.6);
      expect(t.target, 21.0);
      expect(t.mode, ThermoMode.manual);
      expect(t.heating, isTrue);
      expect(t.valve, 42);
      expect(t.windowOpen, isFalse);
      expect(t.childLock, isTrue);
      expect(t.windowDetection, isTrue);
      expect(t.comfortTemp, 21);
      expect(t.ecoTemp, 17);
      expect(t.frostTemp, 8);
      expect(t.minTarget, 5);
      expect(t.maxTarget, 30);
      expect(t.step, 0.5);
      expect(t.canBoost, isTrue);
      expect(t.isZigbee, isTrue);
      // Alle sechs Presets des TRV602Z, in fester Reihenfolge.
      expect(t.modes, ThermoMode.values);
      expect(t.statusText, 'Heizt auf 21 °C');
      expect(t.shortText, '19,6° → 21°');
    });

    test('Zustandstexte', () {
      ThermostatState s(Map<String, dynamic> v) => ThermostatState.from(
        view: _view({
          'local_temperature': 20.9,
          'current_heating_setpoint': 21,
          'preset': 'on',
          'running_state': 'idle',
          ...v,
        }),
      );
      expect(s({}).statusText, 'Hält 21 °C');
      expect(s({'local_temperature': 18}).statusText, 'Ziel 21 °C');
      expect(
        s({'window': 'OPEN'}).statusText,
        'Fenster offen, Heizung pausiert',
      );
      expect(s({'preset': 'off'}).statusText, 'Aus');
      expect(s({'preset': 'off'}).canSetTarget, isFalse);
      expect(s({'preset': 'off'}).shortText, '20,9° · aus');
      expect(
        s({'boost_timeset_countdown': 12}).statusText,
        'Boost, noch 12 min',
      );
      expect(
        ThermostatState.from(view: _view(const {})).statusText,
        'Wartet auf die erste Meldung',
      );
    });

    test('Sollwert wird auf Schritt und Grenzen gerundet', () {
      final t = ThermostatState.from(
        view: _view({'min_temperature': 8, 'max_temperature': 25}),
      );
      expect(t.clampTarget(21.26), 21.5);
      expect(t.clampTarget(21.2), 21.0);
      expect(t.clampTarget(3), 8);
      expect(t.clampTarget(40), 25);
    });

    test('unplausible Grenzen fallen auf die des Sollwerts zurück', () {
      final t = ThermostatState.from(
        view: _view({'min_temperature': 15, 'max_temperature': 15}),
      );
      expect(t.minTarget, 5);
      expect(t.maxTarget, 35);
    });

    test('Komfort ohne gemeldeten Sollwert zeigt die Komforttemperatur', () {
      final t = ThermostatState.from(
        view: _view({'preset': 'comfort', 'comfort_temperature': 22}),
      );
      expect(t.target, isNull);
      expect(t.shownTarget, 22);
    });
  });

  group('ThermostatState aus HA', () {
    // Form der Climate-Entity eines TRV602Z, kurz nach dem Anlernen.
    const fresh = EntityState('climate.thermostat_x', 'unknown', {
      'hvac_modes': ['auto', 'heat', 'off'],
      'min_temp': 5.0,
      'max_temp': 35.0,
      'target_temp_step': 0.5,
      'preset_modes': [
        'none',
        'off',
        'antifrost',
        'eco',
        'comfort',
        'auto',
        'on',
      ],
      'current_temperature': 24.0,
      'temperature': null,
      'preset_mode': 'none',
      'friendly_name': 'Thermostat X',
    });

    test('Werte aus den Attributen, auch bei Zustand unknown', () {
      final t = ThermostatState.from(climate: fresh);
      expect(t.name, 'Thermostat X');
      expect(t.current, 24);
      expect(t.target, isNull);
      expect(t.mode, isNull);
      expect(t.modes, hasLength(6));
      expect(t.isZigbee, isFalse);
      expect(t.canBoost, isFalse);
      expect(t.climateEntityId, 'climate.thermostat_x');
    });

    test('hvac_action und hvac_mode', () {
      final t = ThermostatState.from(
        climate: const EntityState('climate.y', 'heat', {
          'current_temperature': 19,
          'temperature': 22,
          'hvac_action': 'heating',
        }),
      );
      expect(t.heating, isTrue);
      expect(t.mode, ThermoMode.manual);
      expect(t.target, 22);
      final off = ThermostatState.from(
        climate: const EntityState('climate.y', 'off', {}),
      );
      expect(off.mode, ThermoMode.off);
    });

    test('Entities des Zigbee-Geräts ergänzen fehlende Z2M-Werte', () {
      final t = ThermostatState.from(
        view: _view(const {}, [
          const EntityState('binary_sensor.trv_window', 'on', {}),
          const EntityState('sensor.trv_position', '35', {}),
          const EntityState('switch.trv_child_lock', 'on', {}),
          const EntityState('climate.trv', 'auto', {
            'current_temperature': 20.5,
            'temperature': 19,
            'preset_mode': 'auto',
          }),
        ]),
      );
      expect(t.windowOpen, isTrue);
      expect(t.valve, 35);
      expect(t.childLock, isTrue);
      expect(t.current, 20.5);
      expect(t.target, 19);
      expect(t.mode, ThermoMode.schedule);
    });
  });

  group('Einstellungen', () {
    test('deutsch, gruppiert, ohne Hauptfunktionen und Wochenplan', () {
      final groups = thermostatSettingGroups(_trv().classified);
      final names = [for (final (g, _) in groups) g];
      expect(names, [
        kThermoGroupTemps,
        kThermoGroupBehavior,
        kThermoGroupDevice,
        kThermoGroupCalibration,
      ]);
      final all = {
        for (final (_, fs) in groups)
          for (final f in fs) f.property: f,
      };
      expect(all.keys, isNot(contains('preset')));
      expect(all.keys, isNot(contains('boost_timeset_countdown')));
      expect(all.keys.where((k) => k.startsWith('schedule_')), isEmpty);
      expect(all['comfort_temperature']!.label, 'Komforttemperatur');
      expect(all['holiday_temperature']!.label, 'Frostschutztemperatur');
      expect(all['frost_protection']!.label, 'Frostwächter');
      expect(all['hysteresis']!.labelOf('comfort'), 'Stufenlos');
      expect(all['motor_thrust']!.labelOf('weak'), 'Schwach');
      expect(all['screen_orientation']!.labelOf('down'), 'Gedreht');
      // Schreibrechte und Grenzen bleiben.
      expect(all['local_temperature_calibration']!.canWrite, isTrue);
      expect(all['local_temperature_calibration']!.step, 0.1);
      // Reihenfolge in der Gruppe Temperaturen.
      expect(
        [for (final f in groups.first.$2) f.property],
        [
          'comfort_temperature',
          'eco_temperature',
          'holiday_temperature',
          'min_temperature',
          'max_temperature',
        ],
      );
    });

    test('Unbekanntes landet unter Weitere', () {
      final c = ZbClassified(
        settings: [
          const ZbFeature(property: 'valve_detection', label: 'Valve'),
          const ZbFeature(property: 'preset', label: 'Preset'),
        ],
      );
      final g = thermostatSettingGroups(c);
      expect(g, hasLength(1));
      expect(g.first.$1, kThermoGroupMore);
      expect(g.first.$2.single.property, 'valve_detection');
    });
  });

  group('Wochenplan', () {
    const day =
        '06:00/20.0/3 08:00/15.0/2 12:00/20.0/3 14:00/15.0/2 18:00/20.0/3 22:00/15.0/2';

    test('liest und schreibt das Z2M-Format verlustfrei', () {
      final s = parseSchedule(day)!;
      expect(s, hasLength(6));
      expect(s.first, const ScheduleSlot(360, 20));
      expect(s[1], const ScheduleSlot(480, 15, comfort: false));
      expect(formatSchedule(s), day);
      expect(validateSchedule(s), isNull);
    });

    test('ungültige Texte', () {
      expect(parseSchedule(null), isNull);
      expect(parseSchedule(''), isNull);
      expect(parseSchedule('unknown'), isNull);
      expect(parseSchedule('25:00/20/3'), isNull);
    });

    test('Prüfung wie Zigbee2MQTT', () {
      final s = parseSchedule(day)!;
      expect(validateSchedule(s.sublist(0, 5)), contains('genau 6'));
      expect(
        validateSchedule([...s]..[2] = s[2].copyWith(temp: 31)),
        contains('5 bis 30'),
      );
      expect(
        validateSchedule([...s]..[2] = s[2].copyWith(minute: 7 * 60)),
        contains('aufsteigen'),
      );
    });

    test('Temperatur zu einer Uhrzeit, über Nacht der letzte Wechsel', () {
      final s = parseSchedule(day)!;
      expect(scheduleTempAt(s, 5 * 60), 15);
      expect(scheduleTempAt(s, 7 * 60), 20);
      expect(scheduleTempAt(s, 13 * 60), 20);
      expect(scheduleTempAt(s, 23 * 60), 15);
    });

    test('Wochentag aus der Eigenschaft', () {
      expect(parseScheduleDay('schedule_monday'), 0);
      expect(parseScheduleDay('schedule_sunday'), 6);
      expect(parseScheduleDay('schedule_x'), isNull);
      expect(parseScheduleDay('preset'), isNull);
    });
  });

  group('Fake-Simulation', () {
    final base = {...kFakeThermostatStates['Thermostat Salon']!};

    test('Betriebsart setzt system_mode und Sollwert wie das Gerät', () {
      final now = DateTime(2026, 11, 16, 7); // Montag 7 Uhr
      expect(thermostatDerived(base, {'preset': 'eco'}, now), {
        'system_mode': 'auto',
        'current_heating_setpoint': 17.0,
      });
      final off = thermostatDerived(base, {'preset': 'off'}, now);
      expect(off['system_mode'], 'off');
      expect(off['running_state'], 'idle');
      expect(thermostatDerived(base, {'preset': 'on'}, now), {
        'system_mode': 'heat',
      });
      final auto = thermostatDerived(
        {...base, 'schedule_monday': kFakeThermostatSchedule},
        {'preset': 'auto'},
        now,
      );
      expect(auto['current_heating_setpoint'], 21.0);
    });

    test('Takt: heizt unter dem Sollwert, sonst nicht', () {
      final heat = thermostatStep(base, 1);
      expect(heat['local_temperature'], greaterThan(19.6));
      final warm = thermostatStep({
        ...base,
        'local_temperature': 22.0,
        'running_state': 'heat',
      }, 1);
      expect(warm['running_state'], 'idle');
      expect(warm['position'], 0);
      final open = thermostatStep({...base, 'window': 'OPEN'}, 1);
      expect(open['running_state'], 'idle');
    });

    test('HA-Entities folgen dem Z2M-Zustand', () {
      final cur = {
        'climate.trv': const EntityState('climate.trv', 'heat', {
          'friendly_name': 'TRV',
        }),
        'binary_sensor.trv_window': const EntityState(
          'binary_sensor.trv_window',
          'off',
          {},
        ),
      };
      final out = thermostatEntities('trv', {
        ...base,
        'window': 'OPEN',
        'preset': 'eco',
        'system_mode': 'auto',
      }, cur);
      expect(out['climate.trv']!.state, 'auto');
      expect(out['climate.trv']!.attributes['preset_mode'], 'eco');
      expect(out['climate.trv']!.attributes['hvac_action'], 'heating');
      expect(out['climate.trv']!.attributes['friendly_name'], 'TRV');
      expect(out['binary_sensor.trv_window']!.state, 'on');
    });
  });
}
