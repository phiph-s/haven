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
}

/// Abgleich zwischen lokalem Cache und Server. Neuere Fassung gewinnt.
///
/// - Server leer, lokal etwas: hochladen (erste Migration nach dem Update
///   oder Gerät mit altem lokalen Stand).
/// - Lokal ungespeicherte Änderung ([localDirty]) und neuer als der Server:
///   hochladen.
/// - Sonst gilt der Server, außer er ist genau der lokale Stand.
SyncAction decideSync({
  required bool hasLocal,
  required bool localDirty,
  required int? localStamp,
  required RemoteDoc remote,
}) {
  if (remote.isEmpty) return hasLocal ? SyncAction.upload : SyncAction.none;
  if (!hasLocal) return SyncAction.takeRemote;
  final r = remote.updatedAt;
  final l = localStamp;
  // Gleicher Stempel: dieselbe Fassung (z. B. das Echo des eigenen Speicherns).
  if (r != null && r == l) return SyncAction.none;
  if (localDirty && (r == null || (l ?? 0) > r)) return SyncAction.upload;
  // Auch wenn lokal ein jüngerer, schon hochgeladener Stand liegt (Server
  // wiederhergestellt): Der Server bleibt die Wahrheit.
  return SyncAction.takeRemote;
}

/// Speicherfehler, verständlich formuliert. `null`: kein Hinweis nötig
/// (z. B. offline, es wird später nachgeholt).
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
      'Home Assistant konnte $what gerade nicht speichern. Haven versucht es später noch einmal.',
  };
}
