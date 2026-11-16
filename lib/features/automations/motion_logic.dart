import 'dart:math' as math;

import '../../data/models/haven_automation.dart';

/// Reine Logik des Bewegungslicht-Assistenten: Texte, Validierung, Werte.

const kMotionSteps = [
  'Raum',
  'Melder',
  'Wann aktiv',
  'Licht',
  'Nachlauf',
  'Live-Test',
  'Speichern',
];

/// `18:30` als Minuten seit Mitternacht, sonst `null`.
int? parseHhmm(String s) {
  final m = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$').firstMatch(s);
  return m == null ? null : int.parse(m[1]!) * 60 + int.parse(m[2]!);
}

String formatHhmm(int minutes) {
  final m = minutes % 1440;
  return '${(m ~/ 60).toString().padLeft(2, '0')}:'
      '${(m % 60).toString().padLeft(2, '0')}';
}

/// „18:00 bis 07:00“, über Mitternacht mit Hinweis.
String windowLabel(String from, String to) => '$from bis $to';

bool windowCrossesMidnight(String from, String to) {
  final a = parseHhmm(from), b = parseHhmm(to);
  return a != null && b != null && a > b;
}

String sunEventLabel(String event) =>
    event == 'sunset' ? 'Sonnenuntergang' : 'Sonnenaufgang';

/// „Sonnenuntergang“, „30 min nach Sonnenaufgang“, „15 min vor Sonnenuntergang“.
String sunEdgeLabel(SunEdge e) {
  if (e.offset == 0) return sunEventLabel(e.event);
  final rel = e.offset > 0 ? 'nach' : 'vor';
  return '${e.offset.abs()} min $rel ${sunEventLabel(e.event)}';
}

/// „Von Sonnenuntergang bis 1 h nach Sonnenaufgang“ o. ä. in einem Satz.
String sunWindowLabel(SunWindow w) {
  final from = w.from == null ? null : sunEdgeLabel(w.from!);
  final until = w.until == null ? null : sunEdgeLabel(w.until!);
  if (from != null && until != null) return '$from bis $until';
  if (from != null) return 'Ab $from';
  return 'Bis $until';
}

/// 45 → „45 s“, 90 → „1,5 min“, 120 → „2 min“, 3600 → „1 h“.
String delayLabel(int seconds) {
  if (seconds < 60) return '$seconds s';
  if (seconds % 3600 == 0) return '${seconds ~/ 3600} h';
  if (seconds % 60 == 0) return '${seconds ~/ 60} min';
  final min = seconds / 60;
  return '${min.toStringAsFixed(1).replaceAll('.', ',')} min';
}

/// `1:20` für 80 s.
String countdown(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Lux-Schwelle logarithmisch auf 0..100 (5 lx bis 1000 lx) für den Regler.
int luxToPercent(double lux) {
  final v = lux.clamp(5, 1000);
  return ((_log10(v.toDouble()) - _log10(5)) / (_log10(1000) - _log10(5)) * 100)
      .round()
      .clamp(0, 100);
}

double percentToLux(int pct) {
  final x = _log10(5) + pct / 100 * (_log10(1000) - _log10(5));
  final raw = _pow10(x);
  // Runde Werte statt 37,2 lx
  final step = raw < 20 ? 1 : (raw < 100 ? 5 : (raw < 400 ? 10 : 50));
  return (raw / step).round() * step.toDouble();
}

double _log10(double v) => math.log(v) / math.ln10;
double _pow10(double x) => math.pow(10, x).toDouble();

String luxLabel(double lux) => '${lux.round()} lx';

/// Sichtbarer Text zum Zustand auf der Karte, z. B. „Licht vom Melder, aus in 1:20“.
String motionStatusLine(MotionStatus? s, DateTime now, {bool enabled = true}) {
  if (!enabled) return 'Ausgeschaltet';
  if (s == null) return 'Bereit';
  switch (s.phase) {
    case MotionPhase.motion:
      final off = s.offAt;
      if (s.occupied || off == null) {
        return 'Licht vom Melder, Bewegung erkannt';
      }
      return 'Licht vom Melder, aus in ${countdown(off.difference(now))}';
    case MotionPhase.warn:
      final off = s.offAt;
      return off == null
          ? 'Dimmt, gleich aus'
          : 'Dimmt, aus in ${countdown(off.difference(now))}';
    case MotionPhase.manual:
      final off = s.offAt;
      return off == null
          ? 'Manuell übernommen'
          : 'Manuell übernommen, aus in ${countdown(off.difference(now))}';
    case MotionPhase.inactive:
      return 'Inaktiv (${inactiveReason(s.inactive)})';
    case MotionPhase.idle:
      return 'Bereit';
  }
}

String inactiveReason(String? reason) => switch (reason) {
  'lux' => 'zu hell',
  'time' => 'außerhalb des Zeitfensters',
  'sun' => 'Sonne',
  _ => 'Bedingung nicht erfüllt',
};

/// Kurzfassung der Bedingungen für Zusammenfassung und Karte.
List<String> conditionLines(MotionOptions o) => [
  if (o.windows.isNotEmpty)
    o.windows.map((w) => windowLabel(w.from, w.to)).join(', '),
  if (o.sun != null) sunWindowLabel(o.sun!),
  if (o.luxBelow != null) 'unter ${luxLabel(o.luxBelow!)}',
];

String lightLabel(
  MotionLight l,
  List<GroupScene> scenes, [
  String? entityName,
]) {
  if (l.isScene) {
    if (l.sceneEntity != null) return 'Szene ${entityName ?? l.sceneEntity}';
    final s = scenes.where((s) => s.id == l.scene).firstOrNull;
    return 'Szene ${s?.name ?? 'wählen'}';
  }
  final ct = l.colorTemp == null ? '' : ', ${l.colorTemp} K';
  return '${l.percent} %$ct';
}

/// Fehler je Schritt (0 Raum, 1 Melder, 2 Wann, 3 Licht, 4 Nachlauf).
/// Leer = speicherbar.
Map<int, String> validateMotionDraft(
  HavenAutomation draft,
  HavenAutomations all, {
  Map<String, String> deviceNames = const {},
}) {
  final errors = <int, String>{};
  final room = all.rooms[draft.roomAreaId];
  if (draft.roomAreaId.isEmpty) {
    errors[0] = 'Wähl einen Raum';
  } else if (room != null && !room.hasLights) {
    errors[0] = '${room.name} hat keine Lichter, die Haven steuern kann';
  }
  if (draft.devices.isEmpty) {
    errors[1] = 'Wähl mindestens einen Melder';
  } else if (draft.enabled) {
    for (final d in draft.devices) {
      final owner = all.ownerOf(d, exceptId: draft.id, type: kMotionType);
      if (owner != null) {
        errors[1] = '${deviceNames[d] ?? d} meldet schon für ${owner.name}';
        break;
      }
    }
  }
  final o = draft.motion ?? const MotionOptions();
  for (final w in o.windows) {
    if (parseHhmm(w.from) == null || parseHhmm(w.to) == null) {
      errors[2] = 'Zeitfenster: Uhrzeit prüfen';
    }
  }
  final scenes = room?.scenes ?? const <GroupScene>[];
  String? lightError(MotionLight l, String prefix) {
    if (!l.isScene) return null;
    if (l.sceneEntity != null) return null;
    if (room != null && room.group == null) {
      return '$prefix: Z2M-Szenen brauchen eine Gruppe im Raum, wähl eine HA-Szene';
    }
    return scenes.any((s) => s.id == l.scene) ? null : '$prefix: Szene wählen';
  }

  final e = lightError(o.light, 'Licht');
  if (e != null) errors[3] = e;
  final night = o.night;
  if (night != null) {
    final ne = lightError(night.light, 'Nachtlicht');
    if (ne != null) errors[3] ??= ne;
    if (parseHhmm(night.from) == null || parseHhmm(night.to) == null) {
      errors[3] ??= 'Nachtlicht: Uhrzeit prüfen';
    }
  }
  if (o.delay < 5) errors[4] = 'Der Nachlauf ist zu kurz';
  return errors;
}
