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
    );
  }

  Future<RoomHeating> save(HeatingConfig c) async {
    if (c.trvs.isEmpty) {
      throw HavenException(
        'Wähle mindestens ein Thermostat.',
        code: 'invalid_format',
      );
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
      final sp = c.trvs
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

  (double?, String?) _room(HeatingConfig c) {
    final vals = [for (final s in c.sensors) ?_sensor(s)];
    if (vals.isNotEmpty) {
      return (vals.reduce((a, b) => a + b) / vals.length, 'sensors');
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
    if (open) {
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
    for (final ieee in c.trvs) {
      final s = trvState(ieee);
      final memo = st.trvs[ieee]!;
      final values = <String, dynamic>{};
      final local = (s['local_temperature'] as num?)?.toDouble();
      final cal = (s['local_temperature_calibration'] as num?)?.toDouble() ?? 0;
      final sp = (s['current_heating_setpoint'] as num?)?.toDouble();
      final released = memo.released != null;
      final method = source == 'sensors' && !(released && !c.calibrateReleased)
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
      final method = source == 'sensors'
          ? c.calibration
          : HeatingCalibration.none;
      final raw = local == null ? null : local - (cal ?? 0);
      final corr = room != null && raw != null && source == 'sensors'
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
  bool summer = false;
  double? outdoorEma;
  DateTime? outdoorAt;
  final Map<String, _TrvMemo> trvs = {};
}

class _TrvMemo {
  double? seenSp;
  double? sentSp;
  DateTime? sentSpAt;
  double? sentCal;
  DateTime? sentCalAt;
  double shift = 0;
  String? seenPreset;
  String? sentPreset;

  /// Am Gerät auf eigene Steuerung gestellt (`on`, `auto`), sonst `null`.
  String? released;
  DateTime? releaseUntil;
}
