import 'dart:math' as math;

import '../../data/models/haven_automation.dart';
import '../../data/models/state_history.dart';

/// Reine Rechenlogik für die kompakten Info-Sheets der Karte (Verlauf,
/// Kennzahlen, Hinweise). Ohne Widgets, damit sie sich testen lässt.

/// Ein Messwert zu einem Zeitpunkt.
class SeriesPoint {
  const SeriesPoint(this.at, this.value);
  final DateTime at;
  final double value;
}

/// Messwerte aus der History: nicht numerische Zustände („unavailable“)
/// fallen weg, das Ergebnis ist nach Zeit sortiert.
List<SeriesPoint> numericSeries(List<StateChange> changes) {
  final out = <SeriesPoint>[];
  for (final c in changes) {
    final v = double.tryParse(c.state);
    if (v != null && v.isFinite) out.add(SeriesPoint(c.at, v));
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return out;
}

/// Kennzahlen eines Verlaufs.
class SeriesStats {
  const SeriesStats({required this.min, required this.max, required this.last});
  final double min;
  final double max;
  final double last;
}

SeriesStats? seriesStats(List<SeriesPoint> s) {
  if (s.isEmpty) return null;
  var lo = s.first.value;
  var hi = s.first.value;
  for (final p in s) {
    lo = math.min(lo, p.value);
    hi = math.max(hi, p.value);
  }
  return SeriesStats(min: lo, max: hi, last: s.last.value);
}

/// Verlauf als [buckets] gleichmäßige Werte zwischen [start] und [end]
/// (Treppenfunktion: der letzte bekannte Wert gilt weiter). Vor dem ersten
/// Messwert ist der Wert `null`.
List<double?> resampleSeries(
  List<SeriesPoint> s,
  DateTime start,
  DateTime end,
  int buckets,
) {
  final span = end.difference(start).inMilliseconds;
  final out = <double?>[];
  var i = 0;
  double? cur;
  for (var b = 0; b < buckets; b++) {
    final t = buckets == 1
        ? end
        : start.add(Duration(milliseconds: (span * b / (buckets - 1)).round()));
    while (i < s.length && !s[i].at.isAfter(t)) {
      cur = s[i].value;
      i++;
    }
    out.add(cur);
  }
  return out;
}

/// Mittelwert mehrerer gleich langer Verläufe, je Stelle über die Werte,
/// die es gibt. Eine Stelle ganz ohne Wert bleibt `null`.
List<double?> meanSeries(List<List<double?>> all) {
  if (all.isEmpty) return const [];
  final n = all.map((l) => l.length).reduce(math.min);
  return [
    for (var i = 0; i < n; i++)
      () {
        final v = [
          for (final l in all)
            if (l[i] != null) l[i]!,
        ];
        return v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
      }(),
  ];
}

/// Mittelwert, kleinster und größter Wert einer Liste, `null` bei leerer Liste.
({double mean, double min, double max})? spreadOf(List<double> v) {
  if (v.isEmpty) return null;
  return (
    mean: v.reduce((a, b) => a + b) / v.length,
    min: v.reduce(math.min),
    max: v.reduce(math.max),
  );
}

/// Ab dieser Luftfeuchte (in %) kommt der Lüften-Hinweis.
const double kVentAbove = 60;

bool needsVenting(double? humidity) =>
    humidity != null && humidity > kVentAbove;

/// Unter diesem Stand gilt eine Batterie als schwach.
const double kBatteryLow = 20;

/// Wie lange ein Gerät schweigen darf, bevor die Batterie verdächtig ist.
const Duration kSilentLimit = Duration(days: 2);

/// „Batterie prüfen“: unter 20 % oder seit über 2 Tagen nichts gemeldet.
bool batteryNeedsCheck(double? level, DateTime? lastSeen, DateTime now) {
  if (level != null && level < kBatteryLow) return true;
  return lastSeen != null && now.difference(lastSeen) > kSilentLimit;
}

/// Eine Phase mit Bewegung: von [from] bis [to] (`null` = läuft noch).
class MotionSpan {
  const MotionSpan(this.from, this.to);
  final DateTime from;
  final DateTime? to;

  bool get running => to == null;
}

/// Phasen mit Bewegung in den letzten [window] vor [now], aus der History
/// eines Melders. Eine Phase, die vor dem Fenster begann, startet am
/// Fensteranfang. Neueste zuerst.
List<MotionSpan> motionSpans(
  List<StateChange> history,
  DateTime now, {
  Duration window = const Duration(minutes: 60),
}) {
  final start = now.subtract(window);
  final out = <MotionSpan>[];
  DateTime? from;
  for (final c in history) {
    if (c.at.isAfter(now)) break;
    if (c.isOn) {
      from ??= c.at;
    } else if (from != null) {
      if (c.at.isAfter(start)) {
        out.add(MotionSpan(from.isBefore(start) ? start : from, c.at));
      }
      from = null;
    }
  }
  if (from != null) {
    out.add(MotionSpan(from.isBefore(start) ? start : from, null));
  }
  return out.reversed.toList();
}

/// Kurztext zu einer Phase: „vor 12 min, 3 min lang“, laufend „seit 2 min“.
String motionSpanText(MotionSpan s, DateTime now) {
  String len(Duration d) {
    if (d.inSeconds < 60) return '${math.max(d.inSeconds, 1)} s';
    return '${d.inMinutes} min';
  }

  final ago = now.difference(s.from);
  if (s.to == null) {
    return ago.inSeconds < 60 ? 'jetzt' : 'seit ${ago.inMinutes} min';
  }
  final when = ago.inSeconds < 60 ? 'gerade eben' : 'vor ${ago.inMinutes} min';
  return '$when, ${len(s.to!.difference(s.from))} lang';
}

/// Haven-Bewegungslicht (`room_motion`) für einen Raum: Treffer über die
/// Bereichs-ID des Raums. [areaIds] sind alle Kennungen, unter denen der
/// Raum bekannt ist (Bereich, Raum-ID).
HavenAutomation? motionAutomationFor(
  HavenAutomations? automations,
  Iterable<String?> areaIds,
) {
  if (automations == null) return null;
  final ids = {
    for (final a in areaIds)
      if (a != null && a.isNotEmpty) a,
  };
  for (final a in automations.automations) {
    if (a.isMotion && ids.contains(a.roomAreaId)) return a;
  }
  return null;
}

/// Zuletzt gemeldet: „gerade eben“, „vor 3 min“, „vor 2 h“, „vor 4 d“.
String lastSeenText(DateTime? at, DateTime now) {
  if (at == null) return 'unbekannt';
  final d = now.difference(at);
  if (d.inSeconds < 60) return 'gerade eben';
  if (d.inMinutes < 60) return 'vor ${d.inMinutes} min';
  if (d.inHours < 24) return 'vor ${d.inHours} h';
  return 'vor ${d.inDays} d';
}

/// Gerätename ohne angehängte Eigenschaft („Sensor Terrasse Temperatur“).
String shortDeviceName(String n) {
  for (final s in [
    ' Temperatur',
    ' Luftfeuchtigkeit',
    ' Belegung',
    ' Batterie',
    ' Tür',
    ' Beleuchtungsstärke',
    ' Leistung',
  ]) {
    if (n.endsWith(s)) return n.substring(0, n.length - s.length);
  }
  return n;
}

/// Aktive Haven-Knob-Automation, in der das Gerät (IEEE) steckt.
HavenAutomation? knobAutomationFor(HavenAutomations? automations, String ieee) {
  if (automations == null) return null;
  for (final a in automations.automations) {
    if (a.type == 'room_knob' && a.enabled && a.devices.contains(ieee)) {
      return a;
    }
  }
  return null;
}
