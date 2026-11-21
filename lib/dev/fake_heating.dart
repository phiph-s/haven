import 'dart:async';
import 'dart:math' as math;

import '../data/haven_repository.dart';
import '../data/models/entity_state.dart';
import '../data/models/room_heating.dart';

/// Heizungsregelung der Entwicklungsdaten. Vereinfachte Fassung der Logik in
/// `integration/custom_components/haven/heating.py`: Raumthermometer
/// (Mittelwert), Kalibrierung bzw. verschobener Sollwert, Gruppe, Fenster,
/// Sommer, Betriebsarten, Übernahme von Änderungen am Thermostat.
/// Das `FakeRepository` ruft [tick] alle 4 s auf.
class FakeHeating {
  FakeHeating({
    required this.entities,
    required this.trvState,
    required this.trvSet,
    required this.trvName,
    required this.thermostats,
  });

  /// Aktuelle HA-Entities der Beispielwohnung.
  final Map<String, EntityState> Function() entities;

  /// Z2M-Zustand eines Thermostats.
  final Map<String, dynamic> Function(String ieee) trvState;

  /// Schreibt an ein Thermostat (wie `haven/zigbee/set`).
  final Future<void> Function(String ieee, Map<String, dynamic> values) trvSet;
  final String Function(String ieee) trvName;

  /// IEEEs aller Thermostate.
  final Iterable<String> Function() thermostats;

  static const salonTrv = '0x00124b0000000030';

  final _updates = StreamController<HeatingUpdate>.broadcast();
  final _changed = StreamController<void>.broadcast();

  /// Der Salon ist eingerichtet, der Ruheraum noch nicht.
  final Map<String, HeatingConfig> _configs = {
    'salon': const HeatingConfig(
      areaId: 'salon',
      trvs: [salonTrv],
      sensors: [
        'sensor.sensor_salon_temperature',
        'sensor.sensor_salon_fenster_temperature',
      ],
      outdoorEntity: 'sensor.sensor_terrasse_temperature',
    ),
  };
  final Map<String, _RoomState> _state = {'salon': _RoomState(target: 21)};
  final Map<String, HeatingStatus> _last = {};

  static const ruheraumDisplay = '0x00124b0000000032';

  /// Als reines Display markierte Thermostate (das Wandthermostat im
  /// Ruheraum ist es von Anfang an).
  final Set<String> _displays = {ruheraumDisplay};

  Stream<HeatingUpdate> get updates => _updates.stream;
  Stream<void> get changed => _changed.stream;

  /// Nur lesen: Befehle gehen erst mit [tick], [save] oder [control] raus.
  Future<HeatingRooms> list() async {
    return HeatingRooms(
      rooms: [
        for (final c
            in (_configs.values.toList()
              ..sort((a, b) => a.areaId.compareTo(b.areaId))))
          RoomHeating(c, status(c.areaId)!),
      ],
      displays: {..._displays},
    );
  }

  Future<Set<String>> setDisplay(String ieee, bool display) async {
    if (!thermostats().contains(ieee)) {
      throw HavenException(
        '$ieee ist kein bekanntes Thermostat',
        code: 'not_found',
      );
    }
    if (display) {
      final room = _configs.values.where((c) => c.trvs.contains(ieee));
      if (room.isNotEmpty) {
        throw HavenException(
          '${trvName(ieee)} wird als Heizkörperthermostat in einem Raum '
          'geregelt',
          code: 'device_taken',
        );
      }
      _displays.add(ieee);
    } else {
      _displays.remove(ieee);
      for (final c in _configs.values.toList()) {
        if (c.display == ieee) {
          _configs[c.areaId] = c.copyWith(clearDisplay: true);
          _state[c.areaId]?.display = null;
        }
      }
    }
    tick(DateTime.now());
    if (!_changed.isClosed) _changed.add(null);
    return {..._displays};
  }

  Future<RoomHeating> save(HeatingConfig c) async {
    if (c.trvs.isEmpty) {
      throw HavenException(
        'Wähle mindestens ein Thermostat.',
        code: 'invalid_format',
      );
    }
    final asTrv = c.trvs.where(_displays.contains).firstOrNull;
    if (asTrv != null) {
      throw HavenException(
        '${trvName(asTrv)} ist als Display markiert und kein '
        'Heizkörperthermostat',
        code: 'invalid_format',
      );
    }
    if (c.display case final d?) {
      if (!_displays.contains(d)) {
        throw HavenException(
          '${trvName(d)} ist nicht als Display markiert',
          code: 'invalid_format',
        );
      }
      final other = _configs.values
          .where((o) => o.areaId != c.areaId && o.display == d)
          .firstOrNull;
      if (other != null) {
        throw HavenException(
          '${trvName(d)} steuert schon einen anderen Raum',
          code: 'device_taken',
        );
      }
    }
    for (final other in _configs.values) {
      if (other.areaId == c.areaId) continue;
      final taken = other.trvs.where(c.trvs.contains).firstOrNull;
      if (taken != null) {
        throw HavenException(
          '${trvName(taken)} wird schon in einem anderen Raum geregelt',
          code: 'device_taken',
        );
      }
    }
    final before = _configs[c.areaId];
    _configs[c.areaId] = c;
    _state.putIfAbsent(c.areaId, () {
      final sp = [?c.display, ...c.trvs]
          .map((i) => (trvState(i)['current_heating_setpoint'] as num?))
          .whereType<num>()
          .firstOrNull;
      return _RoomState(target: sp?.toDouble() ?? 21);
    });
    if (before != null) {
      for (final ieee in before.trvs.where((i) => !c.trvs.contains(i))) {
        await _resetCalibration(c.areaId, ieee);
      }
    }
    tick(DateTime.now());
    if (!_changed.isClosed) _changed.add(null);
    return RoomHeating(c, status(c.areaId)!);
  }

  Future<void> delete(String areaId) async {
    final c = _configs.remove(areaId);
    if (c == null) {
      throw HavenException(
        'Für diesen Raum ist keine Heizungsregelung eingerichtet',
        code: 'not_found',
      );
    }
    for (final ieee in c.trvs) {
      await _resetCalibration(areaId, ieee);
    }
    _state.remove(areaId);
    _last.remove(areaId);
    if (!_changed.isClosed) _changed.add(null);
  }

  Future<void> _resetCalibration(String areaId, String ieee) async {
    final memo = _state[areaId]?.trvs[ieee];
    if (memo?.sentCal != null && memo!.sentCal != 0) {
      await trvSet(ieee, {'local_temperature_calibration': 0});
    }
  }

  Future<HeatingStatus> control(
    String areaId, {
    double? target,
    HeatingMode? mode,
    bool resume = false,
  }) async {
    final st = _state[areaId];
    if (st == null || !_configs.containsKey(areaId)) {
      throw HavenException(
        'Für diesen Raum ist keine Heizungsregelung eingerichtet',
        code: 'not_found',
      );
    }
    for (final m in st.trvs.values) {
      m.released = m.releaseUntil = null;
    }
    if (mode != null) st.mode = mode;
    if (target != null) {
      st.target = ((target.clamp(5, 30) * 2).round() / 2).toDouble();
      if (mode == null) st.mode = HeatingMode.heat;
    }
    st.userChange = true;
    tick(DateTime.now());
    return status(areaId)!;
  }

  // ---- Eingänge -----------------------------------------------------------

  double? _sensor(String id) {
    final e = entities()[id];
    if (e == null || !e.isAvailable) return null;
    return e.number;
  }

  bool? _contact(String id) {
    final e = entities()[id];
    if (e == null || !e.isAvailable) return null;
    return e.isOn;
  }

  double? _outdoor(String id) {
    final e = entities()[id];
    if (e == null) return null;
    if (e.domain == 'weather') {
      final t = e.attributes['temperature'];
      return t is num ? t.toDouble() : null;
    }
    return e.number;
  }

  /// Messung des Displays (zählt als Raumthermometer).
  double? _displayLocal(HeatingConfig c) => switch (c.display) {
    final d? => (trvState(d)['local_temperature'] as num?)?.toDouble(),
    null => null,
  };

  (double?, String?) _room(HeatingConfig c) {
    final vals = [for (final s in c.sensors) ?_sensor(s)];
    final display = _displayLocal(c);
    if (vals.isNotEmpty || display != null) {
      final all = [...vals, ?display];
      return (
        all.reduce((a, b) => a + b) / all.length,
        vals.isNotEmpty ? 'sensors' : 'display',
      );
    }
    final locals = [
      for (final t in c.trvs)
        if (trvState(t)['local_temperature'] case final num v) v.toDouble(),
    ];
    if (locals.isNotEmpty) {
      return (locals.reduce((a, b) => a + b) / locals.length, 'trv');
    }
    return (null, null);
  }

  double? _effective(HeatingConfig c, _RoomState st) => switch (st.mode) {
    HeatingMode.off => null,
    HeatingMode.heat => st.target,
    final m => c.presets[m] ?? kDefaultHeatingPresets[m],
  };

  /// Sollzustand des Displays: aus bei Aus und in der Fensterpause, sonst
  /// an; Eco als eigenes Preset (Sollwert dann vom Gerät), sonst Manuell mit
  /// dem Ziel des Raums. Eco-Temperatur immer die des Raums.
  ({String power, String? preset, double? setpoint, double eco}) _displayWant(
    HeatingConfig c,
    _RoomState st,
    double? target,
  ) {
    final eco = (c.presets[HeatingMode.eco] ??
            kDefaultHeatingPresets[HeatingMode.eco]!)
        .toDouble();
    if (target == null || st.paused) {
      return (power: 'off', preset: null, setpoint: null, eco: eco);
    }
    final isEco = st.mode == HeatingMode.eco;
    return (
      power: 'heat',
      preset: isEco ? 'eco' : 'manual',
      setpoint: isEco ? null : target,
      eco: eco,
    );
  }

  HeatingPause? _pause(_RoomState st) {
    if (st.mode == HeatingMode.off) return HeatingPause.off;
    if (st.paused) return HeatingPause.window;
    if (st.summer) return HeatingPause.summer;
    return null;
  }

  // ---- Takt ----------------------------------------------------------------

  /// Eine Auswertung aller Räume: beobachten, Befehle senden, Status melden.
  void tick(DateTime now) {
    for (final c in _configs.values) {
      final st = _state.putIfAbsent(c.areaId, () => _RoomState(target: 21));
      if (c.enabled) _evaluate(c, st, now);
      final s = status(c.areaId)!;
      final prev = _last[c.areaId];
      if (prev == null || _differs(prev, s)) {
        _last[c.areaId] = s;
        if (!_updates.isClosed) _updates.add((areaId: c.areaId, status: s));
      }
    }
  }

  bool _differs(HeatingStatus a, HeatingStatus b) =>
      a.mode != b.mode ||
      a.target != b.target ||
      a.roomTemperature != b.roomTemperature ||
      a.pause != b.pause ||
      a.heating != b.heating ||
      a.windowOpen != b.windowOpen ||
      a.outdoorValue != b.outdoorValue ||
      a.released != b.released ||
      a.display?.setpoint != b.display?.setpoint ||
      a.display?.localTemperature != b.display?.localTemperature ||
      a.display?.mode != b.display?.mode ||
      a.display?.preset != b.display?.preset ||
      a.display?.ecoTemperature != b.display?.ecoTemperature ||
      a.display?.pending != b.display?.pending ||
      a.windowOverride != b.windowOverride ||
      (a.display == null) != (b.display == null) ||
      a.trvs.length != b.trvs.length ||
      [
        for (var i = 0; i < a.trvs.length; i++)
          a.trvs[i].localTemperature != b.trvs[i].localTemperature ||
              a.trvs[i].setpoint != b.trvs[i].setpoint ||
              a.trvs[i].calibration != b.trvs[i].calibration ||
              a.trvs[i].pending != b.trvs[i].pending,
      ].any((x) => x);

  void _evaluate(HeatingConfig c, _RoomState st, DateTime now) {
    // Fenster
    final open = c.windows.any((w) => _contact(w) == true);
    if (!open || st.mode == HeatingMode.off) st.windowOverride = false;
    if (open && st.windowOverride) {
      // Am Display trotz offenem Fenster eingeschaltet: keine Pause.
      st.openSince = st.closedSince = null;
      st.paused = false;
    } else if (open) {
      st.closedSince = null;
      st.openSince ??= now;
      if (!st.paused &&
          now.difference(st.openSince!).inSeconds >= c.windowOpenDelay) {
        st.paused = true;
      }
    } else {
      st.openSince = null;
      if (st.paused) {
        st.closedSince ??= now;
        if (now.difference(st.closedSince!).inSeconds >= c.windowCloseDelay) {
          st.paused = false;
          st.closedSince = null;
        }
      }
    }
    // Sommer (geglättet wie in der Integration, τ 4 h)
    final out = c.outdoorEntity == null ? null : _outdoor(c.outdoorEntity!);
    if (c.outdoorEntity == null) {
      st.outdoorEma = null;
      st.summer = false;
    } else if (out != null) {
      final at = st.outdoorAt;
      if (st.outdoorEma == null || at == null) {
        st.outdoorEma = out;
      } else {
        final dt = now.difference(at).inSeconds.toDouble();
        st.outdoorEma =
            st.outdoorEma! +
            (out - st.outdoorEma!) * (1 - math.exp(-dt / 14400));
      }
      st.outdoorAt = now;
      if (!st.summer && st.outdoorEma! >= c.outdoorThreshold) st.summer = true;
      if (st.summer && st.outdoorEma! <= c.outdoorThreshold - 1) {
        st.summer = false;
      }
    }
    // Display: was daran eingestellt wird, gilt für den ganzen Raum (auch
    // bei gesperrter Bedienung der Thermostate und bei offenem Fenster).
    if (c.display case final d?) {
      if (st.displayIeee != d) {
        st.display = null;
        st.displayIeee = d;
      }
      final memo = st.display ??= _TrvMemo();
      final s = trvState(d);
      final sp = (s['current_heating_setpoint'] as num?)?.toDouble();
      final power = s['system_mode'] as String?;
      final preset = s['preset'] as String?;
      // Ein/Aus am Display
      if (memo.seenMode != null &&
          power != memo.seenMode &&
          power != memo.sentMode) {
        if (power == 'off') {
          st.mode = HeatingMode.off;
          st.userChange = true;
        } else if (power == 'heat' && st.paused) {
          // Fensterpause: einschalten heißt trotzdem heizen
          st.windowOverride = true;
          st.paused = false;
          st.closedSince = st.openSince = null;
        } else if (power == 'heat' && st.mode == HeatingMode.off) {
          st.mode = HeatingMode.heat;
          st.userChange = true;
        }
      }
      // Bestätigt: ein späteres gleiches Schalten ist wieder Bedienung.
      if (power == memo.sentMode) memo.sentMode = null;
      memo.seenMode = power;
      // Eco/Manuell am Display, eigener Wochenplan zählt nicht
      var presetAdopted = false;
      if (memo.seenPreset != null &&
          preset != memo.seenPreset &&
          preset != memo.sentPreset) {
        if (preset == 'eco') {
          st.mode = HeatingMode.eco;
          st.userChange = presetAdopted = true;
        } else if (preset == 'manual' && memo.seenPreset == 'eco') {
          st.mode = HeatingMode.heat;
          if (sp != null) st.target = ((sp.clamp(5, 30) * 2).round() / 2);
          st.userChange = presetAdopted = true;
        }
      }
      if (preset == memo.sentPreset) memo.sentPreset = null;
      memo.seenPreset = preset;
      if (!presetAdopted &&
          sp != null &&
          memo.seenSp != null &&
          sp != memo.seenSp &&
          sp != memo.sentSp &&
          sp != memo.prevSentSp &&
          power != 'off' &&
          preset == 'manual') {
        st.target = ((sp.clamp(5, 30) * 2).round() / 2).toDouble();
        st.mode = HeatingMode.heat;
        st.userChange = true;
      }
      memo.seenSp = sp;
    } else {
      st.display = st.displayIeee = null;
    }
    // Änderungen am Thermostat übernehmen
    for (final ieee in c.trvs) {
      final s = trvState(ieee);
      final memo = st.trvs.putIfAbsent(ieee, _TrvMemo.new);
      final sp = (s['current_heating_setpoint'] as num?)?.toDouble();
      final preset = s['preset'] as String?;
      // Ventil offen am Gerät: nach 45 min übernimmt Haven wieder.
      if (memo.releaseUntil case final u? when !now.isBefore(u)) {
        memo.released = memo.releaseUntil = null;
      }
      if (!c.lockManual &&
          memo.seenPreset != null &&
          preset != memo.seenPreset &&
          preset != memo.sentPreset) {
        if (preset == 'on' || preset == 'auto') {
          memo.released = preset;
          memo.releaseUntil = preset == 'on'
              ? now.add(const Duration(minutes: 45))
              : null;
        } else {
          memo.released = memo.releaseUntil = null;
        }
      }
      memo.seenPreset = preset;
      if (!c.lockManual &&
          memo.released == null &&
          sp != null &&
          memo.seenSp != null &&
          sp != memo.seenSp &&
          sp != memo.sentSp &&
          sp != memo.prevSentSp &&
          preset == 'comfort' &&
          _pause(st) == null) {
        final shift = c.calibration == HeatingCalibration.target
            ? memo.shift
            : 0.0;
        st.target = (((sp - shift).clamp(5, 30) * 2).round() / 2).toDouble();
        st.mode = HeatingMode.heat;
        st.userChange = true;
      }
      memo.seenSp = sp;
    }
    // Befehle
    final (room, source) = _room(c);
    final target = _effective(c, st);
    final pause = _pause(st);
    // Display zeigt das Ziel des Raums, aus bei Betriebsart Aus und in der
    // Fensterpause. Eco am Display = Eco im Raum. Nie kalibriert.
    if ((c.display, st.display) case (final d?, final memo?)) {
      final s = trvState(d);
      final want = _displayWant(c, st, target);
      final values = <String, dynamic>{};
      if (s['system_mode'] != want.power) {
        values['system_mode'] = memo.sentMode = want.power;
      }
      if (want.preset != null && s['preset'] != want.preset) {
        values['preset'] = memo.sentPreset = want.preset;
      }
      if (want.setpoint != null &&
          ((s['current_heating_setpoint'] as num?)?.toDouble() !=
                  want.setpoint ||
              values.containsKey('preset'))) {
        memo.prevSentSp = memo.sentSp;
        values['current_heating_setpoint'] = memo.sentSp = want.setpoint;
      }
      if ((s['eco_temperature'] as num?)?.toDouble() != want.eco) {
        values['eco_temperature'] = want.eco;
      }
      // Gesehen wird erst, was das Display meldet (es übernimmt verzögert);
      // bis dahin ist sein alter Wert keine Änderung.
      if (values.isNotEmpty) unawaited(trvSet(d, values));
    }
    for (final ieee in c.trvs) {
      final s = trvState(ieee);
      final memo = st.trvs[ieee]!;
      final values = <String, dynamic>{};
      final local = (s['local_temperature'] as num?)?.toDouble();
      final cal = (s['local_temperature_calibration'] as num?)?.toDouble() ?? 0;
      final sp = (s['current_heating_setpoint'] as num?)?.toDouble();
      final released = memo.released != null;
      final method =
          (source == 'sensors' || source == 'display') &&
              !(released && !c.calibrateReleased)
          ? c.calibration
          : HeatingCalibration.none;
      if (released) {
        // Gerät steuert selbst: weder Modus noch Sollwert.
      } else if (pause != null || target == null) {
        if (s['preset'] != 'off') values['preset'] = memo.sentPreset = 'off';
      } else {
        if (s['preset'] != 'comfort') {
          values['preset'] = memo.sentPreset = 'comfort';
        }
        var want = target;
        if (method == HeatingCalibration.target &&
            room != null &&
            local != null) {
          want = ((target + local - room) * 2).round() / 2;
        }
        want = want.clamp(5, 30).toDouble();
        final throttled =
            method == HeatingCalibration.target &&
            !st.userChange &&
            memo.sentSpAt != null &&
            now.difference(memo.sentSpAt!).inSeconds < 60;
        if (sp != want && !throttled) {
          values['current_heating_setpoint'] = want;
          memo.prevSentSp = memo.sentSp;
          memo.sentSp = want;
          memo.sentSpAt = now;
          memo.shift = method == HeatingCalibration.target ? want - target : 0;
        }
      }
      if (method == HeatingCalibration.offset &&
          room != null &&
          local != null) {
        final raw = local - cal;
        final want = ((room - raw).clamp(-10, 10) * 10).round() / 10;
        final due =
            memo.sentCalAt == null ||
            now.difference(memo.sentCalAt!).inSeconds >= 40;
        if ((want - cal).abs() >= 0.3 && due) {
          values['local_temperature_calibration'] = want;
          memo.sentCal = want;
          memo.sentCalAt = now;
        }
      } else if ((c.calibration != HeatingCalibration.offset ||
              method == HeatingCalibration.none && released) &&
          memo.sentCal != null &&
          memo.sentCal != 0 &&
          cal != 0) {
        values['local_temperature_calibration'] = 0;
        memo.sentCal = 0;
      }
      if (values.isNotEmpty) {
        if (values['current_heating_setpoint'] case final num v) {
          memo.seenSp = v.toDouble();
        }
        unawaited(trvSet(ieee, values));
      }
    }
    st.userChange = false;
  }

  // ---- Status ---------------------------------------------------------------

  HeatingStatus? status(String areaId) {
    final c = _configs[areaId];
    if (c == null) return null;
    final st = _state[areaId] ?? _RoomState(target: 21);
    final (room, source) = _room(c);
    final pause = c.enabled ? _pause(st) : null;
    final target = _effective(c, st);
    final outdoor = c.outdoorEntity == null ? null : _outdoor(c.outdoorEntity!);
    final trvs = <HeatingTrvStatus>[];
    for (final ieee in c.trvs) {
      final s = trvState(ieee);
      final local = (s['local_temperature'] as num?)?.toDouble();
      final cal = (s['local_temperature_calibration'] as num?)?.toDouble();
      final fromRoom = source == 'sensors' || source == 'display';
      final method = fromRoom ? c.calibration : HeatingCalibration.none;
      final raw = local == null ? null : local - (cal ?? 0);
      final corr = room != null && raw != null && fromRoom
          ? ((room - raw) * 100).round() / 100
          : null;
      final heating = s['running_state'] == null
          ? null
          : s['running_state'] == 'heat';
      final sp = (s['current_heating_setpoint'] as num?)?.toDouble();
      final wantOff = pause != null || target == null;
      final memo = st.trvs[ieee];
      trvs.add(
        HeatingTrvStatus(
          ieee: ieee,
          name: trvName(ieee),
          localTemperature: local,
          setpoint: sp,
          calibration: cal,
          heating: heating,
          valve: (s['position'] as num?)?.round(),
          method: method,
          correction: corr,
          desiredCalibration:
              method == HeatingCalibration.offset && corr != null
              ? (corr.clamp(-10, 10) * 10).round() / 10
              : null,
          pending:
              memo?.released == null &&
              (wantOff ? s['preset'] != 'off' : s['preset'] != 'comfort'),
          released: memo?.released != null,
          releasedMode: memo?.released,
          releaseUntil: memo?.releaseUntil,
        ),
      );
    }
    final flags = [for (final t in trvs) ?t.heating];
    HeatingDisplayStatus? display;
    if (c.display case final d?) {
      final s = trvState(d);
      final sp = (s['current_heating_setpoint'] as num?)?.toDouble();
      final want = _displayWant(c, st, target);
      display = HeatingDisplayStatus(
        ieee: d,
        name: trvName(d),
        localTemperature: (s['local_temperature'] as num?)?.toDouble(),
        setpoint: sp,
        mode: s['system_mode'] as String?,
        preset: s['preset'] as String?,
        ecoTemperature: (s['eco_temperature'] as num?)?.toDouble(),
        battery: (s['battery'] as num?)?.round(),
        pending:
            s['system_mode'] != want.power ||
            (want.preset != null && s['preset'] != want.preset) ||
            (want.setpoint != null && sp != want.setpoint) ||
            (s['eco_temperature'] as num?)?.toDouble() != want.eco,
      );
    }
    return HeatingStatus(
      mode: st.mode,
      target: st.target,
      effectiveTarget: target,
      roomTemperature: room == null ? null : (room * 10).round() / 10,
      roomSource: source,
      sensorValues: {for (final s in c.sensors) s: _sensor(s)},
      pause: pause,
      heating: pause != null
          ? false
          : (flags.isEmpty ? null : flags.any((x) => x)),
      windowOpen: c.windows.any((w) => _contact(w) == true),
      windowPaused: st.paused,
      windowOverride: st.windowOverride,
      pauseAt: st.openSince != null && !st.paused
          ? st.openSince!.add(Duration(seconds: c.windowOpenDelay))
          : null,
      resumeAt: st.paused && st.closedSince != null
          ? st.closedSince!.add(Duration(seconds: c.windowCloseDelay))
          : null,
      contacts: {for (final w in c.windows) w: _contact(w)},
      outdoorValue: switch (st.outdoorEma ?? outdoor) {
        final double v => (v * 10).round() / 10,
        null => null,
      },
      outdoorCurrent: outdoor,
      summer: st.summer,
      trvs: trvs,
      released: trvs.any((t) => t.released),
      display: display,
    );
  }

  Future<void> dispose() async {
    await _updates.close();
    await _changed.close();
  }
}

class _RoomState {
  _RoomState({required this.target});
  double target;
  HeatingMode mode = HeatingMode.heat;
  bool userChange = false;
  DateTime? openSince;
  DateTime? closedSince;
  bool paused = false;

  /// Am Display trotz offenem Fenster eingeschaltet (bis alle zu sind).
  bool windowOverride = false;
  bool summer = false;
  double? outdoorEma;
  DateTime? outdoorAt;
  final Map<String, _TrvMemo> trvs = {};
  String? displayIeee;
  _TrvMemo? display;
}

class _TrvMemo {
  double? seenSp;
  double? sentSp;

  /// Davor gesendet: eine späte Bestätigung zählt nicht als Handarbeit.
  double? prevSentSp;
  DateTime? sentSpAt;
  double? sentCal;
  DateTime? sentCalAt;
  double shift = 0;
  String? seenPreset;
  String? sentPreset;

  /// Ein/Aus eines Displays (`system_mode`).
  String? seenMode;
  String? sentMode;

  /// Am Gerät auf eigene Steuerung gestellt (`on`, `auto`), sonst `null`.
  String? released;
  DateTime? releaseUntil;
}
