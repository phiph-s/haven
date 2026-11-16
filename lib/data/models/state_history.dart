import 'package:flutter/foundation.dart';

/// Ein Zustandswechsel aus der HA-History.
@immutable
class StateChange {
  const StateChange(this.state, this.at);
  final String state;
  final DateTime at;

  bool get isOn => state == 'on';

  @override
  bool operator ==(Object other) =>
      other is StateChange && other.state == state && other.at == at;

  @override
  int get hashCode => Object.hash(state, at);

  @override
  String toString() => 'StateChange($state, $at)';
}

DateTime? _time(Object? v) {
  if (v is num) {
    return DateTime.fromMillisecondsSinceEpoch((v * 1000).round(), isUtc: true);
  }
  if (v is String) return DateTime.tryParse(v);
  return null;
}

/// Liest die Antwort von `history/history_during_period`: je Entity eine
/// Liste, kompakt (`s`, `lc`, `lu` in Sekunden) oder ausführlich (`state`,
/// `last_changed` als ISO). Gleiche Zustände hintereinander fallen zusammen,
/// das Ergebnis ist nach Zeit sortiert.
Map<String, List<StateChange>> parseStateHistory(Object? raw) {
  final out = <String, List<StateChange>>{};
  if (raw is! Map) return out;
  raw.forEach((id, list) {
    if (list is! List) return;
    final changes = <StateChange>[];
    for (final e in list) {
      if (e is! Map) continue;
      final s = e['s'] ?? e['state'];
      final at =
          _time(e['lc']) ??
          _time(e['lu']) ??
          _time(e['last_changed']) ??
          _time(e['last_updated']);
      if (s == null || at == null) continue;
      changes.add(StateChange('$s', at));
    }
    changes.sort((a, b) => a.at.compareTo(b.at));
    final merged = <StateChange>[];
    for (final c in changes) {
      if (merged.isNotEmpty && merged.last.state == c.state) continue;
      merged.add(c);
    }
    out['$id'] = merged;
  });
  return out;
}

/// Zustand einer Entity zum Zeitpunkt [t] laut [changes] (sortiert), dazu
/// wann er begann. `null`, wenn vor [t] nichts bekannt ist.
StateChange? stateAt(List<StateChange> changes, DateTime t) {
  StateChange? last;
  for (final c in changes) {
    if (c.at.isAfter(t)) break;
    last = c;
  }
  return last;
}
