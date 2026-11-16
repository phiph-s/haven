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
  const RemoteDoc({this.data, this.updatedAt});
  static const empty = RemoteDoc();

  final Map<String, dynamic>? data;
  final int? updatedAt;

  bool get isEmpty => data == null;
}

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
/// - Server != [baseStamp]: lokal ungespeichert ist ein Konflikt (Server
///   gewinnt), sonst Server übernehmen.
SyncAction decideSync({
  required bool hasLocal,
  required bool localDirty,
  required int? baseStamp,
  required RemoteDoc remote,
}) {
  if (remote.isEmpty) return hasLocal ? SyncAction.upload : SyncAction.none;
  if (!hasLocal || baseStamp == null) return SyncAction.takeRemote;
  if (remote.updatedAt == baseStamp) {
    return localDirty ? SyncAction.upload : SyncAction.none;
  }
  return localDirty ? SyncAction.conflict : SyncAction.takeRemote;
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
