import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Netzkarte von Zigbee2MQTT (`bridge/request/networkmap`, type `raw`,
/// `routes` false), wie die Haven-Integration sie mit `haven/zigbee/networkmap`
/// liefert. Parser sind nachsichtig: Fehlendes wird `null` oder leer.
///
/// Vertrag (so liest die App, die Integration kann Z2M-Rohdaten durchreichen):
/// ```
/// haven/zigbee/networkmap {refresh: bool}
///  → {"networkmap": {"nodes": [...], "links": [...]},   // Z2M "value"
///     "timestamp": "2026-11-15T10:00:00Z" | Sekunden | Millisekunden,
///     "running": bool, "started_at": "...", "last_error": "..."}  // ab 0.5.1
/// haven/zigbee/networkmap {refresh: true, background: true}   // ab 0.5.1
///  → {"status": "started" | "running", "started_at": "..."}
/// ```
/// Ende der Hintergrundmessung: HA-Ereignis `haven_networkmap_updated` mit
/// `{ok: true, timestamp}` oder `{ok: false, error}`.
/// `nodes`/`links` dürfen auch direkt auf oberster Ebene oder unter `value`,
/// `data`, `map` stehen. Knoten: `ieeeAddr`, `friendlyName`, `type`,
/// `networkAddress`. Verbindungen: `source`/`target` (`ieeeAddr`),
/// `linkquality`, `depth`, `relationship`, `routes`.

enum ZbNodeKind {
  coordinator,
  router,
  endDevice;

  static ZbNodeKind parse(Object? type) => switch ('$type'.toLowerCase()) {
    'coordinator' => coordinator,
    'router' => router,
    _ => endDevice,
  };
}

/// Beziehung des Nachbarn (`source`) zum meldenden Gerät (`target`), wie in
/// der Zigbee-Neighbor-Table.
abstract final class ZbRelationship {
  /// Der Nachbar ist der Elternknoten des meldenden Geräts.
  static const parent = 0;

  /// Der Nachbar ist ein Kind des meldenden Geräts.
  static const child = 1;
  static const sibling = 2;
  static const none = 3;
  static const previousChild = 4;
}

int? _int(Object? v) =>
    v is num ? v.round() : (v is String ? int.tryParse(v) : null);

String? _ieee(Object? v) {
  if (v is Map) return _ieee(v['ieeeAddr'] ?? v['ieee_address'] ?? v['ieee']);
  final s = v?.toString();
  return s == null || s.isEmpty ? null : s;
}

@immutable
class ZbMeshNode {
  const ZbMeshNode({
    required this.ieee,
    required this.name,
    this.kind = ZbNodeKind.endDevice,
    this.networkAddress,
    this.lqi,
    this.failed = false,
  });

  factory ZbMeshNode.fromJson(Map<String, dynamic> j) {
    final ieee = _ieee(j) ?? '';
    return ZbMeshNode(
      ieee: ieee,
      name: (j['friendlyName'] ?? j['friendly_name'] ?? ieee).toString(),
      kind: ZbNodeKind.parse(j['type']),
      networkAddress: _int(j['networkAddress'] ?? j['network_address']),
      lqi: _int(j['lqi']),
      failed: switch (j['failed']) {
        final List l => l.isNotEmpty,
        final bool b => b,
        _ => false,
      },
    );
  }

  final String ieee;
  final String name;
  final ZbNodeKind kind;
  final int? networkAddress;

  /// Signal zum Elternknoten (0 bis 255), `null` beim Koordinator oder wenn
  /// der Knoten keine Verbindung hat.
  final int? lqi;

  /// Z2M konnte bei der Messung nicht alles von diesem Knoten lesen (`failed`),
  /// er war vermutlich nicht erreichbar.
  final bool failed;

  bool get isCoordinator => kind == ZbNodeKind.coordinator;
  bool get isRouter => kind == ZbNodeKind.router;

  ZbMeshNode withLqi(int? v) => ZbMeshNode(
    ieee: ieee,
    name: name,
    kind: kind,
    networkAddress: networkAddress,
    lqi: v,
    failed: failed,
  );
}

@immutable
class ZbMeshRoute {
  const ZbMeshRoute({this.destination, this.nextHop, this.status});

  factory ZbMeshRoute.fromJson(Map<String, dynamic> j) => ZbMeshRoute(
    destination: _int(j['destinationAddress'] ?? j['destination']),
    nextHop: _int(j['nextHop'] ?? j['next_hop']),
    status: j['status']?.toString(),
  );

  /// Netzwerkadressen.
  final int? destination;
  final int? nextHop;
  final String? status;
}

/// Ein Eintrag der Neighbor-Table von [target] über den Nachbarn [source].
@immutable
class ZbMeshLink {
  const ZbMeshLink({
    required this.source,
    required this.target,
    required this.lqi,
    this.depth = 0,
    this.relationship = ZbRelationship.none,
    this.routes = const [],
  });

  factory ZbMeshLink.fromJson(Map<String, dynamic> j) => ZbMeshLink(
    source: _ieee(j['source']) ?? '',
    target: _ieee(j['target']) ?? '',
    lqi: _int(j['linkquality'] ?? j['lqi']) ?? 0,
    depth: _int(j['depth']) ?? 0,
    relationship: _int(j['relationship']) ?? ZbRelationship.none,
    routes: [
      if (j['routes'] is List)
        for (final r in j['routes'] as List)
          if (r is Map) ZbMeshRoute.fromJson(Map<String, dynamic>.from(r)),
    ],
  );

  final String source;
  final String target;
  final int lqi;

  /// Tiefe des Nachbarn im Baum (Koordinator 0, 15 oder 255: unbekannt).
  final int depth;

  /// Siehe [ZbRelationship]: Beziehung von [source] zu [target].
  final int relationship;
  final List<ZbMeshRoute> routes;
}

/// Eine Kante zum Zeichnen, je Knotenpaar eine (beide Richtungen der
/// Neighbor-Tables zusammengefasst). Baumkanten ([inTree]): [a] ist das Kind,
/// [b] der gewählte Elternknoten, der Pfeil zeigt zu [b]. Alle anderen sind
/// Nachbarschaften ohne Pfeil.
@immutable
class ZbMeshEdge {
  const ZbMeshEdge({
    required this.a,
    required this.b,
    required this.lqi,
    required this.hierarchical,
    this.inTree = false,
    this.depth = 0,
  });

  /// Kind (bzw. eine Seite).
  final String a;

  /// Elternknoten (bzw. andere Seite).
  final String b;

  /// Signal der Verbindung. Melden beide Seiten, ist es der Mittelwert.
  final int lqi;

  /// Z2M meldet die Verbindung als Eltern/Kind (`relationship` 0 oder 1).
  final bool hierarchical;

  /// Diese Kante ist der gewählte Weg des Kindes zum Koordinator.
  final bool inTree;
  final int depth;

  bool touches(String ieee) => a == ieee || b == ieee;
  String get key => '$a>$b';

  ZbMeshEdge _tree(String child, String parent) => ZbMeshEdge(
    a: child,
    b: parent,
    lqi: lqi,
    hierarchical: hierarchical,
    inTree: true,
    depth: depth,
  );
}

/// Zwischenstand je Knotenpaar beim Einlesen.
class _Pair {
  _Pair(this.x, this.y);
  final String x;
  final String y;
  int lqiSum = 0;
  int reports = 0;
  int depth = 0;

  /// Gemeldetes Kind und Eltern (aus `relationship` 0 oder 1).
  String? child;
  String? parent;

  int get lqi => reports == 0 ? 0 : (lqiSum / reports).round();
  String other(String v) => v == x ? y : x;
}

/// Stand der Messung in der Integration (ab 0.5.1), aus der Abfrage ohne
/// `refresh`.
@immutable
class ZbMeasureStatus {
  const ZbMeasureStatus({
    this.running = false,
    this.startedAt,
    this.lastError,
  });

  factory ZbMeasureStatus.fromJson(Map<String, dynamic> j) {
    final err = j['last_error']?.toString().trim();
    return ZbMeasureStatus(
      running: j['running'] == true,
      startedAt: ZbNetworkMap.parseTime(j['started_at']),
      lastError: err == null || err.isEmpty ? null : err,
    );
  }

  static const idle = ZbMeasureStatus();

  final bool running;
  final DateTime? startedAt;
  final String? lastError;
}

/// Antwort auf `refresh: true, background: true`.
@immutable
class ZbMeasureStart {
  const ZbMeasureStart({required this.alreadyRunning, this.startedAt});

  factory ZbMeasureStart.fromJson(Map<String, dynamic> j) => ZbMeasureStart(
    alreadyRunning: j['status'] == 'running',
    startedAt: ZbNetworkMap.parseTime(j['started_at']),
  );

  final bool alreadyRunning;
  final DateTime? startedAt;
}

/// Ereignis `haven_networkmap_updated`.
@immutable
class ZbMeasureResult {
  const ZbMeasureResult({required this.ok, this.error});

  factory ZbMeasureResult.fromJson(Map<String, dynamic> j) {
    final ok = j['ok'] == true;
    final err = j['error']?.toString().trim();
    return ZbMeasureResult(
      ok: ok,
      error: ok
          ? null
          : (err == null || err.isEmpty ? 'Unbekannter Fehler' : err),
    );
  }

  final bool ok;
  final String? error;
}

/// Netzkarte mit Knoten, Verbindungen und Zeitstempel der Messung.
///
/// Z2M-Rohformat: Jeder Router und der Koordinator melden ihre Neighbor-Table.
/// Ein Link ist ein Eintrag darin: `target` ist das meldende Gerät, `source`
/// der Nachbar, `relationship` beschreibt den Nachbarn aus Sicht des
/// meldenden Geräts (0: Nachbar ist sein Elternknoten, 1: Nachbar ist sein
/// Kind, 2: Geschwister, 3: keine, 4: früheres Kind). Endgeräte melden nichts,
/// sie stehen nur als `source` mit `relationship` 1 bei ihrem Elternknoten.
///
/// Elternwahl:
/// - Endgeräte: der gemeldete Elternknoten (bei mehreren der stärkste), sonst
///   der stärkste Router-Nachbar. Endgeräte leiten nie weiter.
/// - Router: kürzester Weg zum Koordinator über Router (Dijkstra), Kosten je
///   Sprung `1 + (255 - lqi) / 85`, gemeldete Eltern/Kind-Kanten etwas
///   billiger. Echte Router haben nach dem Beitritt meist nur Geschwister.
/// - Ohne Weg bleibt der Knoten ohne Eltern (leerer Pfad).
class ZbNetworkMap {
  ZbNetworkMap({
    required List<ZbMeshNode> nodes,
    required this.links,
    this.measuredAt,
    this.status = ZbMeasureStatus.idle,
  }) {
    final byIeee = {for (final n in nodes) n.ieee: n};
    final coordinator = nodes.where((n) => n.isCoordinator).firstOrNull?.ieee;
    _coordinator = coordinator;
    bool routes(String v) => byIeee[v]?.kind != ZbNodeKind.endDevice;

    // 1. Je Knotenpaar zusammenfassen.
    final pairs = <String, _Pair>{};
    String pairKey(String x, String y) =>
        x.compareTo(y) < 0 ? '$x|$y' : '$y|$x';
    for (final l in links) {
      final s = l.source, t = l.target;
      if (s == t || !byIeee.containsKey(s) || !byIeee.containsKey(t)) continue;
      if (l.relationship == ZbRelationship.previousChild) continue;
      final p = pairs.putIfAbsent(
        pairKey(s, t),
        () => s.compareTo(t) < 0 ? _Pair(s, t) : _Pair(t, s),
      );
      p.lqiSum += l.lqi;
      p.reports++;
      if (l.depth > 0 && l.depth < 64) {
        p.depth = math.max(p.depth, l.depth);
      }
      if (p.child == null) {
        if (l.relationship == ZbRelationship.parent) {
          p.child = t;
          p.parent = s;
        } else if (l.relationship == ZbRelationship.child) {
          p.child = s;
          p.parent = t;
        }
      }
    }
    final adj = <String, List<_Pair>>{};
    for (final p in pairs.values) {
      (adj[p.x] ??= []).add(p);
      (adj[p.y] ??= []).add(p);
    }

    // 2. Router: Dijkstra vom Koordinator über Router.
    final parents = <String, _Pair>{};
    final parentId = <String, String>{};
    if (coordinator != null) {
      final dist = <String, double>{coordinator: 0};
      final done = <String>{};
      double cost(_Pair p) {
        final c = 1 + (255 - p.lqi.clamp(0, 255)) / 85;
        return p.child != null ? c * 0.85 : c;
      }

      while (true) {
        String? u;
        var best = double.infinity;
        for (final e in dist.entries) {
          if (done.contains(e.key)) continue;
          if (e.value < best || (e.value == best && e.key.compareTo(u!) < 0)) {
            best = e.value;
            u = e.key;
          }
        }
        if (u == null) break;
        done.add(u);
        for (final p in adj[u] ?? const <_Pair>[]) {
          final v = p.other(u);
          if (!routes(v) || done.contains(v)) continue;
          final d = best + cost(p);
          final old = dist[v];
          if (old == null ||
              d < old - 1e-9 ||
              ((d - old).abs() < 1e-9 && u.compareTo(parentId[v]!) < 0)) {
            dist[v] = d;
            parents[v] = p;
            parentId[v] = u;
          }
        }
      }

      // 3. Endgeräte: gemeldeter Elternknoten vor stärkstem Nachbarn.
      for (final n in nodes) {
        if (routes(n.ieee)) continue;
        _Pair? pick;
        var pickScore = -1;
        for (final p in adj[n.ieee] ?? const <_Pair>[]) {
          final v = p.other(n.ieee);
          if (!routes(v) || !dist.containsKey(v)) continue;
          final reported = p.child == n.ieee && p.parent == v;
          final score = (reported ? 1000 : 0) + p.lqi;
          if (score > pickScore ||
              (score == pickScore && v.compareTo(pick!.other(n.ieee)) < 0)) {
            pickScore = score;
            pick = p;
          }
        }
        if (pick != null) {
          parents[n.ieee] = pick;
          parentId[n.ieee] = pick.other(n.ieee);
        }
      }
    }

    // 4. Kanten: Baumkanten mit Richtung Kind -> Eltern, Rest als Nachbarn.
    final treePairs = <_Pair, String>{
      for (final e in parents.entries) e.value: e.key,
    };
    _parent = {};
    _edges = [];
    for (final p in pairs.values) {
      final child = treePairs[p];
      final base = ZbMeshEdge(
        a: p.child ?? p.x,
        b: p.parent ?? p.y,
        lqi: p.lqi,
        hierarchical: p.child != null,
        depth: p.depth,
      );
      if (child != null) {
        final e = base._tree(child, p.other(child));
        _parent[child] = e;
        _edges.add(e);
      } else {
        _edges.add(base);
      }
    }
    this.nodes = [
      for (final n in nodes)
        n.lqi != null || n.isCoordinator ? n : n.withLqi(_parent[n.ieee]?.lqi),
    ];
    _byIeee = {for (final n in this.nodes) n.ieee: n};
    _tree = [
      for (final e in _edges)
        if (e.inTree) e,
    ];
  }

  factory ZbNetworkMap.fromJson(Map<String, dynamic> j) {
    Map<String, dynamic>? find(Object? v, int depth) {
      if (v is! Map || depth > 4) return null;
      final m = Map<String, dynamic>.from(v);
      if (m['nodes'] is List) return m;
      for (final k in const [
        'networkmap',
        'network_map',
        'map',
        'value',
        'data',
      ]) {
        final r = find(m[k], depth + 1);
        if (r != null) return r;
      }
      return null;
    }

    final body = find(j, 0) ?? const <String, dynamic>{};
    return ZbNetworkMap(
      nodes: [
        for (final n in (body['nodes'] as List? ?? const []))
          if (n is Map) ZbMeshNode.fromJson(Map<String, dynamic>.from(n)),
      ],
      links: [
        for (final l in (body['links'] as List? ?? const []))
          if (l is Map) ZbMeshLink.fromJson(Map<String, dynamic>.from(l)),
      ],
      measuredAt: parseTime(
        j['timestamp'] ??
            j['measured_at'] ??
            j['last_measured'] ??
            j['updated_at'] ??
            body['timestamp'],
      ),
      status: ZbMeasureStatus.fromJson(j),
    );
  }

  static final empty = ZbNetworkMap(nodes: const [], links: const []);

  static DateTime? parseTime(Object? v) {
    if (v is num) {
      final ms = v > 100000000000 ? v.toInt() : (v * 1000).toInt();
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    if (v is String) {
      return DateTime.tryParse(v) ??
          (num.tryParse(v) == null ? null : parseTime(num.parse(v)));
    }
    return null;
  }

  late final List<ZbMeshNode> nodes;
  final List<ZbMeshLink> links;
  final DateTime? measuredAt;

  /// Läuft gerade eine Messung, und wie ging die letzte aus (ab 0.5.1).
  final ZbMeasureStatus status;

  /// Knoten, bei denen Z2M `failed` meldet.
  int get failedCount => nodes.where((n) => n.failed).length;

  late final String? _coordinator;
  late final Map<String, ZbMeshEdge> _parent;
  late final List<ZbMeshEdge> _edges;
  late final List<ZbMeshEdge> _tree;
  late final Map<String, ZbMeshNode> _byIeee;

  bool get isEmpty => nodes.isEmpty;

  /// IEEE des Koordinators oder `null`.
  String? get coordinator => _coordinator;

  /// Alle Kanten zum Zeichnen, je Knotenpaar eine (dedupliziert).
  List<ZbMeshEdge> get edges => _edges;

  /// Nur die Baumkanten: je Knoten die Kante zu seinem Elternknoten.
  List<ZbMeshEdge> get treeEdges => _tree;

  /// Alle Nachbarn eines Knotens (beliebige Beziehung).
  int neighborCount(String ieee) => _edges.where((e) => e.touches(ieee)).length;

  ZbMeshNode? node(String ieee) => _byIeee[ieee];

  /// Kante zum gewählten Elternknoten oder `null`.
  ZbMeshEdge? parentEdge(String ieee) => _parent[ieee];
  String? parentOf(String ieee) => _parent[ieee]?.b;
  int? lqiToParent(String ieee) => _parent[ieee]?.lqi;

  /// Geräte, die über [ieee] am Koordinator hängen.
  List<String> childrenOf(String ieee) => [
    for (final e in _parent.values)
      if (e.b == ieee) e.a,
  ];

  /// Knoten vom [ieee] bis zum Koordinator (beide eingeschlossen). Leer, wenn
  /// es keinen Weg gibt.
  List<String> pathToCoordinator(String ieee) {
    if (!_byIeee.containsKey(ieee) || _coordinator == null) return const [];
    final out = [ieee];
    var cur = ieee;
    while (cur != _coordinator) {
      final p = _parent[cur];
      if (p == null || out.contains(p.b)) return const [];
      out.add(p.b);
      cur = p.b;
    }
    return out;
  }

  /// Kanten des Wegs zum Koordinator.
  List<ZbMeshEdge> pathEdges(String ieee) {
    final p = pathToCoordinator(ieee);
    return [for (var i = 0; i + 1 < p.length; i++) ?_parent[p[i]]];
  }

  /// Routen aus der Routing-Tabelle von [ieee], falls die Messung sie enthält.
  List<ZbMeshRoute> routesOf(String ieee) => [
    for (final l in links)
      if (l.source == ieee) ...l.routes,
  ];
}
