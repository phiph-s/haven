import 'package:flutter/foundation.dart';

import '../../data/models/entity_state.dart';
import '../../data/models/zigbee.dart';
import '../zigbee/zigbee_model.dart';

/// Heizkörperthermostate (z. B. Tuya TRV602Z über Zigbee2MQTT). Reine Logik:
/// Zustand aus Z2M-Werten und der HA-Climate-Entity, Betriebsarten, Texte und
/// die Gruppierung der Einstellungen. Keine Widgets, kein Riverpod.

/// Betriebsart. [z2m] ist der Wert von `preset` bei Zigbee2MQTT (TRV602Z:
/// `off`, `antifrost`, `eco`, `comfort`, `auto`, `on`), [ha] der HA-Preset.
/// Bei Tuya heißt `on` nicht „Manuell“, sondern „Ventil dauerhaft offen“.
enum ThermoMode {
  manual('manual', 'Manuell', 'Hält die Temperatur, die du einstellst.'),
  open(
    'on',
    'Ventil offen',
    'Ventil ganz auf, heizt ohne Regelung. Eine Haven-Regelung hält dann still.',
  ),
  schedule('auto', 'Zeitplan', 'Folgt dem Wochenplan des Thermostats.'),
  comfort('comfort', 'Komfort', 'Heizt auf die Komforttemperatur.'),
  eco('eco', 'Eco', 'Heizt sparsam auf die Eco-Temperatur.'),
  frost('antifrost', 'Frostschutz', 'Hält nur die Frostschutztemperatur.'),
  off('off', 'Aus', 'Heizung aus.');

  const ThermoMode(this.z2m, this.label, this.help);
  final String z2m;
  final String label;
  final String help;

  /// Betriebsart zu einem Z2M- oder HA-Preset, sonst `null`.
  static ThermoMode? fromPreset(String? v) => switch (v?.toLowerCase()) {
    'manual' || 'heat' => manual,
    'on' || 'boost' => open,
    'auto' || 'schedule' || 'program' => schedule,
    'comfort' => comfort,
    'eco' => eco,
    'antifrost' ||
    'frost' ||
    'frost_protection' ||
    'holiday' ||
    'away' => frost,
    'off' => off,
    _ => null,
  };
}

/// Ein Thermostat, wie die Oberfläche es braucht. Alle Werte können fehlen:
/// Batteriegeräte melden selten, frisch angelernte noch gar nicht.
@immutable
class ThermostatState {
  const ThermostatState({
    required this.name,
    this.ieee,
    this.climateEntityId,
    this.current,
    this.target,
    this.mode,
    this.modes = const [],
    this.heating,
    this.valve,
    this.windowOpen,
    this.windowDetection,
    this.childLock,
    this.battery,
    this.boostMinutes,
    this.canBoost = false,
    this.minTarget = 5,
    this.maxTarget = 30,
    this.step = 0.5,
    this.comfortTemp,
    this.ecoTemp,
    this.frostTemp,
    this.setpointProperty = 'current_heating_setpoint',
    this.roomName,
  });

  /// Baut den Zustand aus dem Zigbee-Gerät ([view], Z2M-Werte zuerst, dann
  /// seine HA-Entities) und/oder der Climate-Entity [climate].
  /// [classified] liefert Grenzen und Betriebsarten (`preset`), wenn bekannt.
  factory ThermostatState.from({
    ZbDeviceView? view,
    EntityState? climate,
    ZbClassified? classified,
    String? name,
  }) {
    final c = climate ?? _climateOf(view);
    final attrs = c == null || c.state == 'unavailable'
        ? const <String, dynamic>{}
        : c.attributes;
    double? attr(String k) => _d(attrs[k]);
    num? zb(String p) => view?.number(p);
    String? zs(String p) => _str(view?.raw(p));
    final cls = classified ?? view?.device.classified;

    // Sollwert: TRV602Z nutzt `current_heating_setpoint`, andere Geräte
    // `occupied_heating_setpoint`.
    var setProp = 'current_heating_setpoint';
    if (view != null &&
        !view.values.containsKey(setProp) &&
        (view.values.containsKey('occupied_heating_setpoint') ||
            _feature(cls, 'occupied_heating_setpoint') != null)) {
      setProp = 'occupied_heating_setpoint';
    }
    final setF = _feature(cls, setProp);

    final presetRaw = zs('preset') ?? _str(attrs['preset_mode']);
    var mode = ThermoMode.fromPreset(presetRaw == 'none' ? null : presetRaw);
    final sys = zs('system_mode') ?? _str(c?.state);
    if (mode == null && sys == 'off') mode = ThermoMode.off;
    if (mode == null && sys == 'heat' && presetRaw == null) {
      mode = ThermoMode.manual;
    }
    if (mode == null && sys == 'auto' && presetRaw == null) {
      mode = ThermoMode.schedule;
    }

    final presetF = _feature(cls, 'preset');
    final List<ThermoMode> modes;
    if (presetF != null && presetF.values.isNotEmpty) {
      modes = [
        for (final m in ThermoMode.values)
          if (presetF.values.any((v) => ThermoMode.fromPreset(v.value) == m)) m,
      ];
    } else if (attrs['preset_modes'] is List) {
      final list = (attrs['preset_modes'] as List).map((e) => '$e').toList();
      modes = [
        for (final m in ThermoMode.values)
          if (list.any((v) => ThermoMode.fromPreset(v) == m)) m,
      ];
    } else {
      modes = const [];
    }

    final running = zs('running_state') ?? _str(attrs['hvac_action']);
    final bool? heating = running == null
        ? null
        : (running == 'heat' || running == 'heating');

    final win = view?.raw('window') ?? view?.raw('window_open');
    final bool? windowOpen = switch (win) {
      final bool b => b,
      final String s => switch (s.toUpperCase()) {
        'OPEN' || 'ON' || 'TRUE' => true,
        'CLOSE' || 'CLOSED' || 'OFF' || 'FALSE' => false,
        _ => null,
      },
      _ => null,
    };
    final wd = view?.raw('window_detection');
    final lock = view?.raw('child_lock');

    // Grenzen: zuerst die am Gerät eingestellten, dann die des Sollwerts.
    // Unplausible (Untergrenze nicht unter der Obergrenze) verwerfen.
    double? minT = zb('min_temperature')?.toDouble();
    double? maxT = zb('max_temperature')?.toDouble();
    if (minT != null && maxT != null && minT >= maxT) {
      minT = null;
      maxT = null;
    }
    minT ??= setF?.min?.toDouble() ?? attr('min_temp');
    maxT ??= setF?.max?.toDouble() ?? attr('max_temp');
    if (minT != null && maxT != null && minT >= maxT) {
      minT = null;
      maxT = null;
    }

    final boostF = _feature(cls, 'boost_timeset_countdown');
    return ThermostatState(
      name: name ?? view?.name ?? c?.name ?? '',
      ieee: view?.ieee,
      climateEntityId: c?.entityId,
      current:
          zb('local_temperature')?.toDouble() ?? attr('current_temperature'),
      target: zb(setProp)?.toDouble() ?? attr('temperature'),
      mode: mode,
      modes: modes,
      heating: heating,
      valve: (zb('position') ?? zb('valve_position') ?? zb('pi_heating_demand'))
          ?.round(),
      windowOpen: windowOpen,
      windowDetection: _onOff(wd),
      childLock: lock == null
          ? null
          : (lock is bool ? lock : '$lock'.toUpperCase() == 'LOCK'),
      battery: view?.battery,
      boostMinutes: zb('boost_timeset_countdown')?.round(),
      canBoost:
          view != null &&
          (boostF?.canWrite == true ||
              (boostF == null &&
                  view.values.containsKey('boost_timeset_countdown'))),
      minTarget: minT ?? 5,
      maxTarget: maxT ?? 30,
      step: (setF?.step ?? attr('target_temp_step') ?? 0.5).toDouble(),
      comfortTemp: zb('comfort_temperature')?.toDouble(),
      ecoTemp: zb('eco_temperature')?.toDouble(),
      frostTemp: zb('holiday_temperature')?.toDouble(),
      setpointProperty: setProp,
      roomName: view?.roomName,
    );
  }

  final String name;
  final String? ieee;
  final String? climateEntityId;

  /// Gemessene Temperatur (am Heizkörper).
  final double? current;

  /// Zieltemperatur (Sollwert).
  final double? target;
  final ThermoMode? mode;

  /// Betriebsarten, die das Gerät kennt. Leer: unbekannt.
  final List<ThermoMode> modes;

  /// Heizt gerade (`running_state` bzw. `hvac_action`).
  final bool? heating;

  /// Ventilöffnung in Prozent.
  final int? valve;
  final bool? windowOpen;
  final bool? windowDetection;
  final bool? childLock;
  final int? battery;

  /// Restzeit des Boosts in Minuten, 0 = kein Boost.
  final int? boostMinutes;
  final bool canBoost;
  final double minTarget;
  final double maxTarget;
  final double step;
  final double? comfortTemp;
  final double? ecoTemp;
  final double? frostTemp;

  /// Z2M-Eigenschaft für den Sollwert.
  final String setpointProperty;
  final String? roomName;

  bool get isZigbee => ieee != null;
  bool get isOff => mode == ThermoMode.off;
  bool get boosting => (boostMinutes ?? 0) > 0;

  /// Den Sollwert verstellen geht nicht, wenn das Gerät aus ist.
  bool get canSetTarget => !isOff;

  /// Wert für die Anzeige: im Modus Komfort, Eco oder Frostschutz ohne
  /// gemeldeten Sollwert die Temperatur des Modus.
  double? get shownTarget =>
      target ??
      switch (mode) {
        ThermoMode.comfort => comfortTemp,
        ThermoMode.eco => ecoTemp,
        ThermoMode.frost => frostTemp,
        _ => null,
      };

  /// Sollwert auf Schritt und Grenzen gerundet.
  double clampTarget(double v) {
    final s = step <= 0 ? 0.5 : step;
    final q = (v / s).round() * s;
    final c = q.clamp(minTarget, maxTarget).toDouble();
    return double.parse(c.toStringAsFixed(2));
  }

  /// Ein Satz zum Zustand, z. B. „Heizt auf 21,5 °C“.
  String get statusText {
    final t = shownTarget;
    if (windowOpen == true) return 'Fenster offen, Heizung pausiert';
    if (isOff) return 'Aus';
    if (boosting) return 'Boost, noch $boostMinutes min';
    if (heating == true) {
      return t == null ? 'Heizt' : 'Heizt auf ${fmtTemp(t)}';
    }
    if (t == null) {
      return current == null ? 'Wartet auf die erste Meldung' : 'Bereit';
    }
    if (current != null && current! >= t - 0.2) return 'Hält ${fmtTemp(t)}';
    return 'Ziel ${fmtTemp(t)}';
  }

  /// Kurzform für Listen und die Karte: „19,8° → 21°“.
  String get shortText {
    final cur = current == null ? '–' : '${fmtNum1(current!)}°';
    if (isOff) return '$cur · aus';
    final t = shownTarget;
    if (t == null) return cur;
    return '$cur → ${fmtNum1(t)}°';
  }

  ThermostatState copyWith({double? target, ThermoMode? mode}) =>
      ThermostatState(
        name: name,
        ieee: ieee,
        climateEntityId: climateEntityId,
        current: current,
        target: target ?? this.target,
        mode: mode ?? this.mode,
        modes: modes,
        heating: heating,
        valve: valve,
        windowOpen: windowOpen,
        windowDetection: windowDetection,
        childLock: childLock,
        battery: battery,
        boostMinutes: boostMinutes,
        canBoost: canBoost,
        minTarget: minTarget,
        maxTarget: maxTarget,
        step: step,
        comfortTemp: comfortTemp,
        ecoTemp: ecoTemp,
        frostTemp: frostTemp,
        setpointProperty: setpointProperty,
        roomName: roomName,
      );

  static EntityState? _climateOf(ZbDeviceView? v) {
    if (v == null) return null;
    for (final e in v.entities) {
      if (e.domain == 'climate') return e;
    }
    return null;
  }

  static ZbFeature? _feature(ZbClassified? c, String property) {
    if (c == null) return null;
    for (final f in [...c.primary, ...c.settings, ...c.hidden]) {
      if (f.property == property) return f;
    }
    return null;
  }
}

double? _d(dynamic v) =>
    v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

String? _str(dynamic v) {
  if (v == null) return null;
  final s = '$v';
  if (s.isEmpty || s == 'unknown' || s == 'unavailable' || s == 'null') {
    return null;
  }
  return s;
}

bool? _onOff(dynamic v) => switch (v) {
  final bool b => b,
  final String s when s.toUpperCase() == 'ON' => true,
  final String s when s.toUpperCase() == 'OFF' => false,
  _ => null,
};

/// „21,5“ bzw. „21“.
String fmtNum1(double v) {
  final r = (v * 10).round() / 10;
  if (r == r.roundToDouble()) return r.round().toString();
  return r.toStringAsFixed(1).replaceAll('.', ',');
}

String fmtTemp(double v) => '${fmtNum1(v)} °C';

// ---- Einstellungen --------------------------------------------------------

/// Deutsche Beschriftung für Einstellungen eines Thermostats. `null` bei
/// `values`: die Werte behalten ihre Labels.
typedef _Spec = (String group, String label, String help, Map<String, String>?);

const String kThermoGroupTemps = 'Temperaturen';
const String kThermoGroupBehavior = 'Verhalten';
const String kThermoGroupDevice = 'Am Gerät';
const String kThermoGroupCalibration = 'Kalibrierung';
const String kThermoGroupMore = 'Weitere';

const Map<String, _Spec> _kSpecs = {
  'comfort_temperature': (
    kThermoGroupTemps,
    'Komforttemperatur',
    'Gilt im Modus Komfort.',
    null,
  ),
  'eco_temperature': (
    kThermoGroupTemps,
    'Eco-Temperatur',
    'Gilt im Modus Eco.',
    null,
  ),
  'holiday_temperature': (
    kThermoGroupTemps,
    'Frostschutztemperatur',
    'Gilt im Modus Frostschutz.',
    null,
  ),
  'min_temperature': (
    kThermoGroupTemps,
    'Kleinste Zieltemperatur',
    'Tiefer lässt sich das Thermostat nicht stellen.',
    null,
  ),
  'max_temperature': (
    kThermoGroupTemps,
    'Größte Zieltemperatur',
    'Höher lässt sich das Thermostat nicht stellen.',
    null,
  ),
  'window_detection': (
    kThermoGroupBehavior,
    'Fenster-offen-Erkennung',
    'Fällt die Temperatur plötzlich, pausiert die Heizung eine Weile.',
    null,
  ),
  'frost_protection': (
    kThermoGroupBehavior,
    'Frostwächter',
    'Schützt den Heizkörper vor Frost, auch wenn das Thermostat aus ist.',
    null,
  ),
  'hysteresis': (
    kThermoGroupBehavior,
    'Regelung',
    'Stufenlos öffnet das Ventil fein und hält die Temperatur genau. Sparsam öffnet ganz oder gar nicht, erst 0,5 °C unter dem Ziel.',
    {'comfort': 'Stufenlos', 'eco': 'Sparsam'},
  ),
  'motor_thrust': (
    kThermoGroupBehavior,
    'Motorkraft',
    'Mehr Kraft für schwergängige Ventile, weniger ist leiser und schont die Batterie.',
    {'strong': 'Stark', 'middle': 'Mittel', 'weak': 'Schwach'},
  ),
  'child_lock': (
    kThermoGroupDevice,
    'Kindersicherung',
    'Sperrt die Tasten am Thermostat.',
    null,
  ),
  'display_brightness': (
    kThermoGroupDevice,
    'Display-Helligkeit',
    '',
    {'high': 'Hoch', 'medium': 'Mittel', 'low': 'Niedrig'},
  ),
  'screen_orientation': (
    kThermoGroupDevice,
    'Display-Ausrichtung',
    'Gedreht, wenn das Thermostat kopfüber am Heizkörper sitzt.',
    {'up': 'Normal', 'down': 'Gedreht'},
  ),
  'local_temperature_calibration': (
    kThermoGroupCalibration,
    'Temperatur abgleichen',
    'Das Thermostat misst direkt am Heizkörper. Zeigt es mehr als ein Thermometer im Raum, hier einen negativen Wert einstellen.',
    null,
  ),
};

/// Eigenschaften, die nicht in die Einstellungen gehören, weil die
/// Hauptkarte sie bedient (Betriebsart, Boost) oder der Wochenplan.
const Set<String> kThermoMainProps = {
  'preset',
  'system_mode',
  'current_heating_setpoint',
  'occupied_heating_setpoint',
  'boost_timeset_countdown',
  'identify',
};

const List<String> _kGroupOrder = [
  kThermoGroupTemps,
  kThermoGroupBehavior,
  kThermoGroupDevice,
  kThermoGroupCalibration,
  kThermoGroupMore,
];

/// Einstellungen eines Thermostats, deutsch beschriftet und nach Gruppen
/// geordnet. Wochenplan und Hauptfunktionen fehlen hier, Unbekanntes landet
/// unter „Weitere“ mit seinem Label aus der Integration.
List<(String, List<ZbFeature>)> thermostatSettingGroups(ZbClassified c) {
  final by = <String, List<ZbFeature>>{};
  for (final f in c.settings) {
    if (kThermoMainProps.contains(f.property)) continue;
    if (parseScheduleDay(f.property) != null) continue;
    final spec = _kSpecs[f.property];
    if (spec == null) {
      (by[kThermoGroupMore] ??= []).add(f);
      continue;
    }
    final (group, label, help, values) = spec;
    (by[group] ??= []).add(
      f.relabeled(
        label: label,
        help: help.isEmpty ? null : help,
        valueLabels: values,
      ),
    );
  }
  // Feste Reihenfolge innerhalb der Gruppen wie in [_kSpecs].
  final order = _kSpecs.keys.toList();
  for (final l in by.values) {
    l.sort((a, b) {
      final ia = order.indexOf(a.property);
      final ib = order.indexOf(b.property);
      return (ia < 0 ? 999 : ia).compareTo(ib < 0 ? 999 : ib);
    });
  }
  return [
    for (final g in _kGroupOrder)
      if (by[g]?.isNotEmpty ?? false) (g, by[g]!),
  ];
}

// ---- Wochenplan (TRV602Z) --------------------------------------------------

/// Wochentage in der Reihenfolge Montag bis Sonntag mit Z2M-Namen.
const List<(String, String, String)> kWeekdays = [
  ('monday', 'Montag', 'Mo'),
  ('tuesday', 'Dienstag', 'Di'),
  ('wednesday', 'Mittwoch', 'Mi'),
  ('thursday', 'Donnerstag', 'Do'),
  ('friday', 'Freitag', 'Fr'),
  ('saturday', 'Samstag', 'Sa'),
  ('sunday', 'Sonntag', 'So'),
];

/// Index 0..6 zu `schedule_<tag>`, sonst `null`.
int? parseScheduleDay(String property) {
  if (!property.startsWith('schedule_')) return null;
  final d = property.substring('schedule_'.length);
  for (var i = 0; i < kWeekdays.length; i++) {
    if (kWeekdays[i].$1 == d) return i;
  }
  return null;
}

/// Ein Wechsel im Tagesplan: ab [minute] (seit Mitternacht) gilt [temp].
/// [comfort] ist die Art des Abschnitts (Z2M `P`: 3 Komfort, 2 Eco).
@immutable
class ScheduleSlot {
  const ScheduleSlot(this.minute, this.temp, {this.comfort = true});
  final int minute;
  final double temp;
  final bool comfort;

  String get timeText =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

  ScheduleSlot copyWith({int? minute, double? temp, bool? comfort}) =>
      ScheduleSlot(
        minute ?? this.minute,
        temp ?? this.temp,
        comfort: comfort ?? this.comfort,
      );

  @override
  bool operator ==(Object other) =>
      other is ScheduleSlot &&
      other.minute == minute &&
      other.temp == temp &&
      other.comfort == comfort;

  @override
  int get hashCode => Object.hash(minute, temp, comfort);

  @override
  String toString() => '$timeText/${temp.toStringAsFixed(1)}/$comfort';
}

/// Anzahl der Wechsel pro Tag beim TRV602Z (Z2M verlangt genau 6).
const int kScheduleSlots = 6;
const double kScheduleMinTemp = 5;
const double kScheduleMaxTemp = 30;

/// Liest einen Tagesplan im Z2M-Format `HH:MM/T/P` (mit Leerzeichen
/// getrennt). `null`, wenn der Text nicht passt.
List<ScheduleSlot>? parseSchedule(String? text) {
  if (text == null) return null;
  final parts = text.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty || parts.first.isEmpty) return null;
  final out = <ScheduleSlot>[];
  for (final p in parts) {
    final f = p.split('/');
    if (f.length < 2) return null;
    final hm = f[0].split(':');
    if (hm.length != 2) return null;
    final h = int.tryParse(hm[0]);
    final m = int.tryParse(hm[1]);
    final t = double.tryParse(f[1]);
    if (h == null || m == null || t == null) return null;
    if (h < 0 || h > 24 || m < 0 || m > 59) return null;
    final kind = f.length > 2 ? int.tryParse(f[2]) : 3;
    out.add(ScheduleSlot(h * 60 + m, t, comfort: kind != 2));
  }
  return out;
}

/// Schreibt einen Tagesplan im Z2M-Format.
String formatSchedule(List<ScheduleSlot> slots) => [
  for (final s in slots)
    '${s.timeText}/${s.temp.toStringAsFixed(1)}/${s.comfort ? 3 : 2}',
].join(' ');

/// Fehler im Tagesplan oder `null`, wenn Z2M ihn annimmt.
String? validateSchedule(List<ScheduleSlot> slots) {
  if (slots.length != kScheduleSlots) {
    return 'Ein Tag braucht genau $kScheduleSlots Zeiten.';
  }
  for (var i = 0; i < slots.length; i++) {
    final s = slots[i];
    if (s.minute < 0 || s.minute >= 24 * 60) return 'Ungültige Uhrzeit.';
    if (s.temp < kScheduleMinTemp || s.temp > kScheduleMaxTemp) {
      return 'Temperaturen von 5 bis 30 °C.';
    }
    if (i > 0 && s.minute <= slots[i - 1].minute) {
      return 'Die Zeiten müssen aufsteigen.';
    }
  }
  return null;
}

/// Temperatur im Plan zu einer Uhrzeit (Minute seit Mitternacht). Vor dem
/// ersten Wechsel gilt der letzte des Tages (der Plan läuft über Nacht).
double? scheduleTempAt(List<ScheduleSlot> slots, int minute) {
  if (slots.isEmpty) return null;
  var t = slots.last.temp;
  for (final s in slots) {
    if (s.minute <= minute) t = s.temp;
  }
  return t;
}
