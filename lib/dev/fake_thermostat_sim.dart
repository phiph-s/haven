import '../data/models/entity_state.dart';

/// Simulation der Fake-Thermostate (TRV602Z-Verhalten, vereinfacht). Reine
/// Funktionen auf dem Z2M-Zustand, das `FakeRepository` ruft sie auf.

/// Folgewerte eines Schreibbefehls: Die Betriebsart (`preset`) setzt
/// `system_mode` und, bei Komfort, Eco, Frostschutz und Zeitplan, den
/// Sollwert wie das Gerät.
Map<String, dynamic> thermostatDerived(
  Map<String, dynamic> state,
  Map<String, dynamic> values,
  DateTime now,
) {
  final out = <String, dynamic>{};
  final preset = values['preset'];
  if (preset is String) {
    out['system_mode'] = switch (preset) {
      'off' => 'off',
      'on' => 'heat',
      _ => 'auto',
    };
    final sp = switch (preset) {
      'comfort' => state['comfort_temperature'],
      'eco' => state['eco_temperature'],
      'antifrost' => state['holiday_temperature'],
      'auto' => _scheduleNow(state, now),
      _ => null,
    };
    if (sp is num) out['current_heating_setpoint'] = sp.toDouble();
    if (preset == 'off') {
      out['running_state'] = 'idle';
      out['position'] = 0;
    }
  }
  final boost = values['boost_timeset_countdown'];
  if (boost is num && boost > 0 && state['preset'] != 'off') {
    out['running_state'] = 'heat';
    out['position'] = 100;
  }
  return out;
}

double? _scheduleNow(Map<String, dynamic> state, DateTime now) {
  const days = [
    'monday',
    'tuesday',
    'wednesday',
    'thursday',
    'friday',
    'saturday',
    'sunday',
  ];
  final text = state['schedule_${days[now.weekday - 1]}'];
  if (text is! String) return null;
  final minute = now.hour * 60 + now.minute;
  double? t;
  double? last;
  for (final p in text.split(' ')) {
    final f = p.split('/');
    if (f.length < 2) continue;
    final hm = f[0].split(':');
    final m = int.parse(hm[0]) * 60 + int.parse(hm[1]);
    final v = double.tryParse(f[1]);
    last = v;
    if (m <= minute) t = v;
  }
  return t ?? last;
}

/// Ein Takt (4 s): Raumtemperatur läuft Richtung Sollwert, das Ventil folgt,
/// der Boost zählt herunter (eine Minute je 15 Takte). Gibt nur Änderungen
/// zurück.
Map<String, dynamic> thermostatStep(Map<String, dynamic> s, int tick) {
  final out = <String, dynamic>{};
  final cur = (s['local_temperature'] as num?)?.toDouble() ?? 19;
  final sp = (s['current_heating_setpoint'] as num?)?.toDouble() ?? 20;
  final off = s['preset'] == 'off';
  final windowOpen = s['window'] == 'OPEN';
  var boost = (s['boost_timeset_countdown'] as num?)?.toInt() ?? 0;
  if (boost > 0 && tick % 15 == 0) {
    boost--;
    out['boost_timeset_countdown'] = boost;
  }
  final heat = !off && !windowOpen && (boost > 0 || cur < sp - 0.2);
  final next = heat ? cur + 0.06 : (cur > 17 ? cur - 0.02 : cur);
  final pos = !heat
      ? 0
      : boost > 0
      ? 100
      : ((sp - cur) * 40).clamp(15, 90).round();
  final r = (next * 10).round() / 10;
  if (r != cur) out['local_temperature'] = r;
  if (pos != s['position']) out['position'] = pos;
  final rs = heat ? 'heat' : 'idle';
  if (rs != s['running_state']) out['running_state'] = rs;
  return out;
}

/// HA-Entities eines Thermostats nach dem Z2M-Zustand (Climate-Entity,
/// Messwert, Ventil, Fenster, Schalter, Zahlen).
Map<String, EntityState> thermostatEntities(
  String slug,
  Map<String, dynamic> s,
  Map<String, EntityState> current,
) {
  final out = <String, EntityState>{};
  void put(String id, String state, [Map<String, dynamic>? attrs]) {
    final e = current[id];
    if (e == null) return;
    out[id] = EntityState(id, state, {...e.attributes, ...?attrs});
  }

  String onOff(dynamic v) =>
      (v == 'ON' || v == 'LOCK' || v == 'OPEN' || v == true) ? 'on' : 'off';

  put('climate.$slug', '${s['system_mode'] ?? 'unknown'}', {
    'current_temperature': s['local_temperature'],
    'temperature': s['current_heating_setpoint'],
    'preset_mode': s['preset'] ?? 'none',
    'hvac_action': switch (s['running_state']) {
      'heat' => 'heating',
      'idle' => s['preset'] == 'off' ? 'off' : 'idle',
      _ => null,
    },
  });
  put('sensor.${slug}_local_temperature', '${s['local_temperature']}');
  put('sensor.${slug}_position', '${s['position'] ?? 0}');
  put('sensor.${slug}_battery', '${s['battery'] ?? 'unknown'}');
  put('binary_sensor.${slug}_window', onOff(s['window']));
  for (final k in const [
    'child_lock',
    'window_detection',
    'frost_protection',
  ]) {
    put('switch.${slug}_$k', onOff(s[k]));
  }
  for (final k in const [
    'comfort_temperature',
    'eco_temperature',
    'holiday_temperature',
    'min_temperature',
    'max_temperature',
    'local_temperature_calibration',
    'boost_timeset_countdown',
  ]) {
    if (s[k] != null) put('number.${slug}_$k', '${s[k]}');
  }
  for (final k in const [
    'display_brightness',
    'screen_orientation',
    'hysteresis',
    'motor_thrust',
  ]) {
    if (s[k] != null) put('select.${slug}_$k', '${s[k]}');
  }
  for (final e in s.entries) {
    if (e.key.startsWith('schedule_') && e.value is String) {
      put('text.${slug}_${e.key}', e.value as String);
    }
  }
  return out;
}
