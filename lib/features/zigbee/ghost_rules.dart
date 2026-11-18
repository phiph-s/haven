/// Geister-Geräte: Zigbee-Geräte, die es nicht mehr gibt oder deren Batterie
/// leer ist, die Z2M aber weiter führt. Reine Regeln ohne Riverpod.
library;

/// Netzgerät (Router, Netzstrom): so lange darf es schweigen.
const Duration kMainsGhostAfter = Duration(hours: 24);

/// Netzgerät, das Z2M als `offline` führt: so lange muss es schon schweigen.
const Duration kMainsOfflineAfter = Duration(hours: 1);

/// Batteriegerät: so lange darf es schweigen, bevor die Batterie verdächtig ist.
const Duration kBatteryQuietAfter = Duration(days: 2);

/// Batteriegerät: ab hier kommt zusätzlich „Entfernen?“.
const Duration kBatteryRemoveAfter = Duration(days: 21);

enum GhostKind {
  /// Netzgerät antwortet nicht mehr.
  unreachable,

  /// Batteriegerät meldet sich nicht mehr.
  silent,
}

/// Ein Geister-Verdacht mit Text und erlaubten Aktionen.
class GhostInfo {
  const GhostInfo({
    required this.kind,
    required this.lastSeen,
    required this.age,
    required this.canRemove,
    required this.text,
  });

  final GhostKind kind;

  /// Zuletzt gesehen, `null` wenn nur die Verfügbarkeit „offline“ meldet.
  final DateTime? lastSeen;

  /// Zeit seit [lastSeen], `null` ohne Zeitstempel.
  final Duration? age;

  /// „Entfernen“ anbieten (Netzgerät immer, Batterie ab [kBatteryRemoveAfter]).
  final bool canRemove;

  /// Überschrift, z. B. „Seit 3 Tagen nicht erreichbar“.
  final String text;

  /// Ganze Tage seit der letzten Meldung.
  int? get days => age?.inDays;
}

String _dauer(Duration d) {
  if (d.inDays >= 1) {
    final n = d.inDays;
    return n == 1 ? '1 Tag' : '$n Tagen';
  }
  final h = d.inHours < 1 ? 1 : d.inHours;
  return '$h Std';
}

/// Prüft ein Gerät. `null`: kein Verdacht, auch wenn keine Quelle für „zuletzt
/// gesehen“ da ist ([lastSeen] `null` und nicht offline).
///
/// [availability] ist die Z2M-Verfügbarkeit (`online`/`offline`/`null`), sie
/// zählt nur bei Netzgeräten. Z2M fragt Netzgeräte regelmäßig ab: `online`
/// heißt erreichbar, auch wenn [lastSeen] alt ist (z. B. nur aus der
/// Netzmessung). Batteriegeräte meldet Z2M erst nach bis zu 25 h als offline,
/// dort entscheidet allein [lastSeen].
GhostInfo? evaluateGhost({
  required bool isBattery,
  required DateTime? lastSeen,
  required String? availability,
  required DateTime now,
}) {
  final age = lastSeen == null ? null : now.difference(lastSeen);
  if (isBattery) {
    if (age == null || age <= kBatteryQuietAfter) return null;
    final remove = age >= kBatteryRemoveAfter;
    return GhostInfo(
      kind: GhostKind.silent,
      lastSeen: lastSeen,
      age: age,
      canRemove: remove,
      text: 'Seit ${_dauer(age)} keine Meldung, Batterie prüfen',
    );
  }
  if (availability == 'online') return null;
  final stale = age != null && age > kMainsGhostAfter;
  final offline =
      availability == 'offline' && (age == null || age > kMainsOfflineAfter);
  if (!stale && !offline) return null;
  return GhostInfo(
    kind: GhostKind.unreachable,
    lastSeen: lastSeen,
    age: age,
    canRemove: true,
    text: age == null
        ? 'Nicht erreichbar'
        : 'Seit ${_dauer(age)} nicht erreichbar',
  );
}

/// Merkzeichen für „Ignorieren“: der `last_seen`-Stempel (Sekunden), bei
/// fehlendem Zeitstempel `none`. Eine neue Meldung ändert ihn.
String ghostStamp(DateTime? lastSeen) =>
    lastSeen == null ? 'none' : '${lastSeen.millisecondsSinceEpoch ~/ 1000}';

/// Ist das Gerät mit diesem Stand ignoriert? [ignored]: IEEE → Stempel.
bool isGhostIgnored(
  Map<String, String> ignored,
  String ieee,
  DateTime? lastSeen,
) => ignored[ieee] == ghostStamp(lastSeen);

/// „zuletzt gesehen am 29.04.“
String ghostSeenOn(DateTime? t) {
  if (t == null) return 'zuletzt gesehen: unbekannt';
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return 'zuletzt gesehen am ${two(l.day)}.${two(l.month)}.';
}
