import 'dart:async';

import 'package:flutter/foundation.dart';

import '../haven_repository.dart';

/// Geteilte App-Dokumente in Home Assistant (Integration `haven`, `.storage`).
///
/// - `floorplan`: Grundriss (`haven/floorplan/get|set`)
/// - `widgets`: Widgets der Übersicht plus Layout, z. B. die Reihenfolge der
///   Räume (`haven/widgets/get|set`, `layout` ab Integration 0.3.0)
/// - `prefs`: ausgenommene Lichter (`haven/prefs/get|set`, läuft im
///   Repository selbst)
///
/// Der Server ist die Quelle der Wahrheit, lokal liegt ein Cache für den
/// schnellen Start und für offline. Jede Fassung trägt `updatedAt`
/// (Millisekunden seit 1970, UTC). Ab 0.3.0 feuert die Integration nach jedem
/// `set` das HA-Ereignis `haven_data_updated` mit `{kind}`, dann laden die
/// anderen Geräte neu.
enum AppDataKind {
  floorplan,
  widgets,
  prefs;

  static AppDataKind? parse(Object? v) {
    for (final k in values) {
      if (k.name == v) return k;
    }
    return null;
  }
}

/// Stand auf dem Server. [data] `null`: Dort wurde noch nie gespeichert.
@immutable
class RemoteDoc {
  const RemoteDoc({this.data, this.updatedAt, this.revision});
  static const empty = RemoteDoc();

  final Map<String, dynamic>? data;
  final int? updatedAt;

  /// Revision, die der Server vergibt (Integration mit Feature `revisions`).
  /// `null`: ältere Integration ohne Revisionen.
  final int? revision;

  bool get isEmpty => data == null;
}

/// Revision aus einer Antwort, `null` wenn keine (ältere Integration).
int? parseRevision(Object? v) => v is int && v >= 0 ? v : null;

/// Die Integration hat ein `set` abgelehnt, weil inzwischen ein anderes Gerät
/// gespeichert hat (`base_revision` veraltet, Fehlercode `conflict`).
bool isConflictError(Object e) => e is HavenException && e.code == 'conflict';

/// Zeitstempel aus dem Dokument: Millisekunden, Sekunden oder ISO-Text.
int? parseStamp(Object? v) {
  if (v is num) {
    final n = v.toInt();
    return n > 100000000000 ? n : n * 1000;
  }
  if (v is String) {
    final n = num.tryParse(v);
    if (n != null) return parseStamp(n);
    return DateTime.tryParse(v)?.millisecondsSinceEpoch;
  }
  return null;
}

/// Was beim Abgleich zu tun ist.
enum SyncAction {
  /// Nichts, beide Seiten sind gleich (oder beide leer).
  none,

  /// Den Server-Stand übernehmen und lokal ablegen.
  takeRemote,

  /// Den lokalen Stand hochladen (Migration oder Änderung von offline).
  upload,

  /// Lokal ungespeichert, aber der Server hat sich seitdem geändert (anderes
  /// Gerät). Der Server gilt, die lokale Änderung wird verworfen.
  conflict,
}

/// Abgleich zwischen lokalem Cache und Server.
///
/// Verglichen werden keine Uhrzeiten (die Geräte gehen verschieden), sondern
/// der Stand, auf dem die lokale Fassung beruht: [baseStamp] ist der zuletzt
/// vom Server übernommene oder erfolgreich gespeicherte `updated_at`.
///
/// - Server leer, lokal etwas: hochladen (erste Migration).
/// - Kein lokaler Stand: Server übernehmen.
/// - Kein [baseStamp] (Installation vor 0.6.1, nie abgeglichen): Der Server
///   gilt, auch bei lokalen Änderungen.
/// - Server == [baseStamp]: lokal ungespeichert hochladen, sonst nichts.
/// - Server != [baseStamp]: lokal ungespeichert ist ein Konflikt (wird
///   zusammengeführt, siehe [mergeDocs]), sonst Server übernehmen.
///
/// Kennen beide Seiten eine Revision ([baseRevision], [RemoteDoc.revision],
/// Integration mit `revisions`), zählt sie statt des Stempels: Sie vergibt
/// nur der Server, ältere Apps ohne Stempel ändern sie trotzdem.
SyncAction decideSync({
  required bool hasLocal,
  required bool localDirty,
  required int? baseStamp,
  required RemoteDoc remote,
  int? baseRevision,
}) {
  if (remote.isEmpty) return hasLocal ? SyncAction.upload : SyncAction.none;
  if (!hasLocal) return SyncAction.takeRemote;
  final bool same;
  if (baseRevision != null && remote.revision != null) {
    same = remote.revision == baseRevision;
  } else if (baseStamp != null) {
    same = remote.updatedAt == baseStamp;
  } else {
    return SyncAction.takeRemote;
  }
  if (same) return localDirty ? SyncAction.upload : SyncAction.none;
  return localDirty ? SyncAction.conflict : SyncAction.takeRemote;
}

// ---- Zusammenführen ---------------------------------------------------------

/// Ergebnis von [mergeDocs]: das zusammengeführte Dokument und die Zahl der
/// Stellen, die beide Seiten verschieden geändert haben (dort gilt lokal).
typedef MergeResult = ({Map<String, dynamic> doc, int overlaps});

/// Dreiwege-Zusammenführung eines geteilten Dokuments: [base] ist der
/// Server-Stand, auf dem die lokale Fassung beruht, [local] die Fassung hier,
/// [remote] der neue Server-Stand (anderes Gerät).
///
/// - Objekte: je Schlüssel.
/// - Listen von Objekten mit eindeutiger `id` bzw. `entityId` (Räume,
///   Platzierungen, Möbel, Widgets): je Eintrag. Neu Hinzugefügtes beider
///   Seiten bleibt, gelöscht wird nur, was die andere Seite nicht geändert
///   hat. Die Reihenfolge kommt von der Seite, die umsortiert hat.
/// - Alles andere (Zahlen, Texte, Punktlisten) als Ganzes: Hat nur eine Seite
///   geändert, gilt sie. Haben beide verschieden geändert, gilt lokal (die
///   Änderung hier wird auf den neuen Stand gelegt) und [MergeResult.overlaps]
///   zählt mit.
MergeResult mergeDocs(
  Map<String, dynamic> base,
  Map<String, dynamic> local,
  Map<String, dynamic> remote,
) {
  final m = _Merger();
  final doc = m.merge(base, local, remote);
  return (doc: Map<String, dynamic>.from(doc as Map), overlaps: m.overlaps);
}

/// Gleichheit von JSON-Werten (Reihenfolge der Schlüssel egal, `1 == 1.0`).
class _DeepEq {
  const _DeepEq();
  bool equals(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a is num && b is num) return a == b;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if (!b.containsKey(k) || !equals(a[k], b[k])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!equals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }
}

/// Gleicher JSON-Inhalt?
bool sameDoc(Object? a, Object? b) => const _DeepEq().equals(a, b);

class _Merger {
  int overlaps = 0;

  static const _eq = _DeepEq();

  Object? merge(Object? base, Object? local, Object? remote) {
    if (_eq.equals(local, remote)) return local;
    if (_eq.equals(local, base)) return remote;
    if (_eq.equals(remote, base)) return local;
    if (local is Map && remote is Map) {
      return _mergeMap(base is Map ? base : const {}, local, remote);
    }
    if (local is List && remote is List) {
      final key = _idKey(local, remote, base is List ? base : const []);
      if (key != null) {
        return _mergeList(key, base is List ? base : const [], local, remote);
      }
    }
    overlaps++;
    return local;
  }

  Map<String, dynamic> _mergeMap(Map base, Map local, Map remote) {
    final out = <String, dynamic>{};
    for (final k in {...remote.keys, ...local.keys}) {
      final inL = local.containsKey(k), inR = remote.containsKey(k);
      final inB = base.containsKey(k);
      if (inL && inR) {
        out['$k'] = merge(base[k], local[k], remote[k]);
      } else if (inL) {
        // Remote hat den Schlüssel gelöscht: bleibt, wenn lokal geändert.
        if (!inB || !_eq.equals(local[k], base[k])) out['$k'] = local[k];
      } else {
        if (!inB || !_eq.equals(remote[k], base[k])) out['$k'] = remote[k];
      }
    }
    return out;
  }

  /// `id` oder `entityId`, wenn jede Liste nur Objekte mit eindeutigem
  /// Schlüssel enthält.
  static String? _idKey(List local, List remote, List base) {
    for (final key in const ['id', 'entityId']) {
      bool ok(List l) {
        final seen = <Object?>{};
        for (final e in l) {
          if (e is! Map || e[key] is! String || !seen.add(e[key])) return false;
        }
        return true;
      }

      if ((local.isNotEmpty || remote.isNotEmpty) &&
          ok(local) &&
          ok(remote) &&
          ok(base)) {
        return key;
      }
    }
    return null;
  }

  List<Object?> _mergeList(String key, List base, List local, List remote) {
    Map<Object?, Map> byId(List l) => {for (final e in l) (e as Map)[key]: e};
    final b = byId(base), l = byId(local), r = byId(remote);
    final kept = <Object?, Object?>{};
    for (final id in {...r.keys, ...l.keys}) {
      final bi = b[id], li = l[id], ri = r[id];
      if (li != null && ri != null) {
        kept[id] = merge(bi, li, ri);
      } else if (li != null) {
        // Fehlt remote: neu hier, oder remote gelöscht (bleibt nur, wenn hier
        // geändert).
        if (bi == null || !_eq.equals(li, bi)) kept[id] = li;
      } else if (ri != null) {
        if (bi == null || !_eq.equals(ri, bi)) kept[id] = ri;
      }
    }
    // Reihenfolge: Hat lokal umsortiert (gemeinsame Einträge in anderer
    // Reihenfolge als in base), gilt die lokale, sonst die des Servers.
    List<Object?> ids(Map m) => [...m.keys];
    final common = {...b.keys}.intersection({...l.keys});
    final localMoved = !_eq.equals(
      [
        for (final id in ids(l))
          if (common.contains(id)) id,
      ],
      [
        for (final id in ids(b))
          if (common.contains(id)) id,
      ],
    );
    final lead = localMoved ? ids(l) : ids(r);
    final other = localMoved ? ids(r) : ids(l);
    final order = [
      for (final id in lead)
        if (kept.containsKey(id)) id,
    ];
    // Einträge nur der anderen Seite: hinter ihren Vorgänger auf jener Seite,
    // nach dort schon neu Hinzugefügtem der führenden Seite.
    final otherSet = {...other};
    for (var i = 0; i < other.length; i++) {
      final id = other[i];
      if (order.contains(id) || !kept.containsKey(id)) continue;
      var at = 0;
      for (var j = i - 1; j >= 0; j--) {
        final p = order.indexOf(other[j]);
        if (p >= 0) {
          at = p + 1;
          break;
        }
      }
      while (at < order.length &&
          !otherSet.contains(order[at]) &&
          !b.containsKey(order[at])) {
        at++;
      }
      order.insert(at, id);
    }
    return [for (final id in order) kept[id]];
  }
}

/// Hinweis nach einem Konflikt (Server gewinnt).
String syncConflictText(AppDataKind kind) {
  final what = switch (kind) {
    AppDataKind.floorplan => 'Der Grundriss',
    AppDataKind.widgets => 'Die Übersicht',
    AppDataKind.prefs => 'Die Lichtsteuerung',
  };
  return '$what wurde auf einem anderen Gerät geändert, die Fassung aus Home Assistant gilt.';
}

/// Hinweis nach dem Zusammenführen, wenn beide Geräte dieselbe Stelle
/// geändert haben (dort gilt die Änderung hier).
String syncMergedText(AppDataKind kind) {
  final what = switch (kind) {
    AppDataKind.floorplan => 'Der Grundriss',
    AppDataKind.widgets => 'Die Übersicht',
    AppDataKind.prefs => 'Die Lichtsteuerung',
  };
  return '$what wurde gleichzeitig auf einem anderen Gerät geändert. Beide Änderungen sind übernommen, wo sie sich überschneiden, gilt deine.';
}

/// Fehler, bei denen das Gerät nur gerade nicht durchkommt: Die Änderung
/// bleibt offen und wird später hochgeladen.
bool isOfflineError(Object e) =>
    e is TimeoutException ||
    (e is HavenException && (e.code == 'disconnected' || e.code == 'timeout'));

/// Speicherfehler, verständlich formuliert. `null`: kein Hinweis nötig
/// (z. B. offline, es wird später nachgeholt). Alles außer `unauthorized`,
/// `invalid_format` und Offline gilt als Konflikt: Der Server gewinnt.
String? syncErrorText(Object e, AppDataKind kind) {
  final code = e is HavenException ? e.code : null;
  final what = switch (kind) {
    AppDataKind.floorplan => 'den Grundriss',
    AppDataKind.widgets => 'die Übersicht',
    AppDataKind.prefs => 'die Lichtsteuerung',
  };
  return switch (code) {
    'unauthorized' =>
      'Nur ein Administrator in Home Assistant kann $what für alle Geräte speichern. Deine Änderung gilt nur hier, bis Haven wieder abgleicht.',
    'invalid_format' =>
      'Home Assistant hat $what nicht angenommen. Deine Änderung gilt nur auf diesem Gerät.',
    'disconnected' || 'timeout' => null,
    'unknown_command' || 'not_found' => null,
    _ =>
      'Home Assistant konnte $what nicht speichern (${code ?? 'Fehler'}: ${e is HavenException ? e.message : e}). Die Fassung aus Home Assistant gilt.',
  };
}
