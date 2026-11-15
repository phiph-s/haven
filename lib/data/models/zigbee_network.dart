import 'package:flutter/foundation.dart';

/// Netzkarte von Zigbee2MQTT (`bridge/request/networkmap`, type `raw`,
/// `routes` false), wie die Haven-Integration sie mit `haven/zigbee/networkmap`
/// liefert. Parser sind nachsichtig: Fehlendes wird `null` oder leer.
///
/// Vertrag (so liest die App, die Integration kann Z2M-Rohdaten durchreichen):
/// ```
/// haven/zigbee/networkmap {refresh: bool}
///  → {"networkmap": {"nodes": [...], "links": [...]},   // Z2M "value"
///     "timestamp": "2026-11-15T10:00:00Z" | Sekunden | Millisekunden}
/// ```
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

/// Beziehung des Ziels zur Quelle (Zigbee-Neighbor-Table).
abstract final class ZbRelationship {
  /// Das Ziel ist der Elternknoten der Quelle.
  static const parent = 0;

  /// Das Ziel ist ein Kind der Quelle.
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
  });

  factory ZbMeshNode.fromJson(Map<String, dynamic> j) {
    final ieee = _ieee(j) ?? '';
    return ZbMeshNode(
      ieee: ieee,
      name: (j['friendlyName'] ?? j['friendly_name'] ?? ieee).toString(),
      kind: ZbNodeKind.parse(j['type']),
      networkAddress: _int(j['networkAddress'] ?? j['network_address']),
      lqi: _int(j['lqi']),
    );
  }

  final String ieee;
  final String name;
  final ZbNodeKind kind;
  final int? networkAddress;

  /// Signal zum Elternknoten (0 bis 255), `null` beim Koordinator oder wenn
  /// der Knoten keine Verbindung hat.
  final int? lqi;

  bool get isCoordinator => kind == ZbNodeKind.coordinator;
  bool get isRouter => kind == ZbNodeKind.router;

  ZbMeshNode withLqi(int? v) => ZbMeshNode(
    ieee: ieee,
    name: name,
    kind: kind,
    networkAddress: networkAddress,
    lqi: v,
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

/// Eine Verbindung aus der Neighbor-Table von [source] über [target].
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

  /// Tiefe der Quelle im Baum (Koordinator 0).
  final int depth;

  /// Siehe [ZbRelationship]: Beziehung von [target] zu [source].
  final int relationship;
  final List<ZbMeshRoute> routes;
}

/// Eine Kante zum Zeichnen. Hierarchisch (`parent != null`): [a] ist das Kind,
/// [b] der Elternknoten, der Pfeil zeigt zu [b]. Sonst Geschwisterverbindung
/// ohne Pfeil.
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
  final int lqi;
  final bool hierarchical;

  /// Diese Kante ist der gewählte Weg des Kindes zum Koordinator.
  final bool inTree;
  final int depth;

  bool touches(String ieee) => a == ieee || b == ieee;
  String get key => '$a>$b';
}

/// Netzkarte mit Knoten, Verbindungen und Zeitstempel der Messung.
class ZbNetworkMap {
  ZbNetworkMap({
    required List<ZbMeshNode> nodes,
    required this.links,
    this.measuredAt,
  }) {
    final byIeee = {for (final n in nodes) n.ieee: n};
    final coordinator = nodes.where((n) => n.isCoordinator).firstOrNull?.ieee;
    _coordinator = coordinator;
    final edgeMap = <String, ZbMeshEdge>{};
    String pair(String x, String y) => x.compareTo(y) < 0 ? '$x|$y' : '$y|$x';
    for (final l in links) {
      if (l.source == l.target ||
          !byIeee.containsKey(l.source) ||
          !byIeee.containsKey(l.target)) {
        continue;
      }
      String? child;
      String? parent;
      switch (l.relationship) {
        case ZbRelationship.parent:
          child = l.source;
          parent = l.target;
        case ZbRelationship.child:
          child = l.target;
          parent = l.source;
        case ZbRelationship.sibling:
          break;
        default:
          continue;
      }
      final k = pair(l.source, l.target);
      final old = edgeMap[k];
      final e = ZbMeshEdge(
        a: child ?? l.source,
        b: parent ?? l.target,
        lqi: l.lqi,
        hierarchical: child != null,
        depth: l.depth,
      );
      if (old == null ||
          (e.hierarchical && !old.hierarchical) ||
          (e.hierarchical == old.hierarchical && e.lqi > old.lqi)) {
        edgeMap[k] = e;
      }
    }

    // Eltern wählen: unter den hierarchischen Kanten die stärkste.
    final parents = <String, ZbMeshEdge>{};
    for (final e in edgeMap.values) {
      if (!e.hierarchical || e.a == coordinator) continue;
      final cur = parents[e.a];
      if (cur == null ||
          e.lqi > cur.lqi ||
          (e.lqi == cur.lqi && e.b.compareTo(cur.b) < 0)) {
        parents[e.a] = e;
      }
    }
    // Hierarchische Eltern, die nicht zum Koordinator führen (Zyklen oder
    // Inseln), werden verworfen und unten über alle Kanten neu gesucht.
    bool reaches(String start) {
      final seen = <String>{};
      var cur = start;
      while (cur != coordinator) {
        if (!seen.add(cur)) return false;
        final p = parents[cur];
        if (p == null) return false;
        cur = p.b;
      }
      return true;
    }

    if (coordinator != null) {
      for (final n in nodes) {
        if (n.ieee != coordinator && !reaches(n.ieee)) parents.remove(n.ieee);
      }
      // Breitensuche über alle Kanten für Knoten ohne Elternweg.
      final adj = <String, List<ZbMeshEdge>>{};
      for (final e in edgeMap.values) {
        (adj[e.a] ??= []).add(e);
        (adj[e.b] ??= []).add(e);
      }
      final done = <String>{
        coordinator,
        for (final n in nodes)
          if (parents.containsKey(n.ieee) && reaches(n.ieee)) n.ieee,
      };
      var frontier = [...done];
      while (frontier.isNotEmpty) {
        final next = <String>[];
        for (final u in frontier) {
          final es = [...?adj[u]]..sort((x, y) => y.lqi.compareTo(x.lqi));
          for (final e in es) {
            final v = e.a == u ? e.b : e.a;
            if (done.contains(v)) continue;
            done.add(v);
            parents[v] = ZbMeshEdge(
              a: v,
              b: u,
              lqi: e.lqi,
              hierarchical: true,
              depth: e.depth,
            );
            next.add(v);
          }
        }
        frontier = next;
      }
    }
    _parent = parents;
    _edges = [
      for (final e in edgeMap.values)
        ZbMeshEdge(
          a: e.a,
          b: e.b,
          lqi: e.lqi,
          hierarchical: e.hierarchical,
          depth: e.depth,
          inTree: e.hierarchical && parents[e.a]?.b == e.b,
        ),
    ];
    // Fallback-Kanten (Breitensuche), die es als eigene Kante nicht gibt.
    final have = {for (final e in _edges) pair(e.a, e.b)};
    for (final p in parents.values) {
      if (!have.contains(pair(p.a, p.b))) {
        _edges.add(
          ZbMeshEdge(
            a: p.a,
            b: p.b,
            lqi: p.lqi,
            hierarchical: true,
            inTree: true,
            depth: p.depth,
          ),
        );
      }
    }
    this.nodes = [
      for (final n in nodes)
        n.lqi != null || n.isCoordinator ? n : n.withLqi(parents[n.ieee]?.lqi),
    ];
    _byIeee = {for (final n in this.nodes) n.ieee: n};
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
      measuredAt: _time(
        j['timestamp'] ??
            j['measured_at'] ??
            j['last_measured'] ??
            j['updated_at'] ??
            body['timestamp'],
      ),
    );
  }

  static final empty = ZbNetworkMap(nodes: const [], links: const []);

  static DateTime? _time(Object? v) {
    if (v is num) {
      final ms = v > 100000000000 ? v.toInt() : (v * 1000).toInt();
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    if (v is String) {
      return DateTime.tryParse(v) ??
          (num.tryParse(v) == null ? null : _time(num.parse(v)));
    }
    return null;
  }

  late final List<ZbMeshNode> nodes;
  final List<ZbMeshLink> links;
  final DateTime? measuredAt;

  late final String? _coordinator;
  late final Map<String, ZbMeshEdge> _parent;
  late final List<ZbMeshEdge> _edges;
  late final Map<String, ZbMeshNode> _byIeee;

  bool get isEmpty => nodes.isEmpty;

  /// IEEE des Koordinators oder `null`.
  String? get coordinator => _coordinator;

  /// Alle Kanten zum Zeichnen, je Knotenpaar eine.
  List<ZbMeshEdge> get edges => _edges;

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
