import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/data/ha/ha_client.dart';
import 'package:haven/data/ha/ha_zigbee.dart';
import 'package:haven/data/haven_repository.dart';
import 'package:haven/data/models/zigbee_network.dart';
import 'package:haven/features/zigbee/mesh/mesh_providers.dart';
import 'package:haven/features/zigbee/mesh/mesh_scene.dart';
import 'package:haven/features/zigbee/mesh/mesh_screen.dart';

import '../../support/fake_ha.dart';

/// Anonymisierte Netzkarte einer echten Installation (Z2M 2.x, 43 Knoten,
/// 371 Links in beiden Richtungen, `tools/anonymize_live.py`).
Map<String, dynamic> _raw() =>
    jsonDecode(File('test/fixtures/ha/networkmap.json').readAsStringSync())
        as Map<String, dynamic>;

/// Messung hängt, bis der Test sie beendet.
class _SlowRepo extends FakeRepository {
  _SlowRepo() : super(simulate: false);
  Completer<ZbNetworkMap>? pending;

  @override
  Future<ZbNetworkMap> zigbeeNetworkMap({bool refresh = false}) {
    if (!refresh) return Future.value(ZbNetworkMap.empty);
    return (pending = Completer<ZbNetworkMap>()).future;
  }
}

void main() {
  final raw = _raw();
  final map = ZbNetworkMap.fromJson(raw);
  final rawLinks = [
    for (final l in raw['links'] as List) Map<String, dynamic>.from(l as Map),
  ];
  final types = {
    for (final n in raw['nodes'] as List) '${n['ieeeAddr']}': '${n['type']}',
  };
  String src(Map<String, dynamic> l) => '${(l['source'] as Map)['ieeeAddr']}';
  String tgt(Map<String, dynamic> l) => '${(l['target'] as Map)['ieeeAddr']}';

  test('Parser: Knoten, Links, Zeitstempel, Koordinator', () {
    expect(map.nodes, hasLength(43));
    expect(map.links, hasLength(371));
    expect(map.coordinator, isNotNull);
    expect(map.node(map.coordinator!)!.isCoordinator, isTrue);
    expect(map.measuredAt, DateTime.utc(2026, 11, 15, 23, 50, 18));
    final rel = <int, int>{};
    for (final l in map.links) {
      rel[l.relationship] = (rel[l.relationship] ?? 0) + 1;
    }
    expect(rel, {0: 9, 1: 23, 2: 321, 3: 18});
    // `lqi` und `linkquality` stehen beide drin, gelesen wird derselbe Wert.
    expect(map.links.first.lqi, rawLinks.first['linkquality']);
  });

  test('Deduplizierung: je Knotenpaar genau eine Kante', () {
    final pairs = <String>{};
    for (final l in rawLinks) {
      final s = src(l), t = tgt(l);
      if (s == t || !types.containsKey(s) || !types.containsKey(t)) continue;
      pairs.add(s.compareTo(t) < 0 ? '$s|$t' : '$t|$s');
    }
    expect(map.edges, hasLength(pairs.length));
    final seen = <String>{};
    for (final e in map.edges) {
      final k = e.a.compareTo(e.b) < 0 ? '${e.a}|${e.b}' : '${e.b}|${e.a}';
      expect(seen.add(k), isTrue, reason: 'doppelt: $k');
    }
    // Viel weniger Kanten als Links, weil beide Richtungen zusammenfallen.
    expect(map.edges.length, lessThan(map.links.length * 0.6));
  });

  test('Baumkanten: höchstens eine je Knoten, zeigen zum Elternknoten', () {
    final tree = map.treeEdges;
    expect(tree.length, lessThanOrEqualTo(map.nodes.length - 1));
    expect({for (final e in tree) e.a}, hasLength(tree.length));
    for (final e in tree) {
      expect(map.parentOf(e.a), e.b);
      expect(map.node(e.b)!.kind, isNot(ZbNodeKind.endDevice));
    }
    // Standardansicht zeichnet nur den Baum.
    const st = MeshViewState();
    expect(st.filter, MeshFilter.tree);
    final shown = map.edges.where((e) => st.edgeShown(e, const {})).toList();
    expect(shown, hasLength(tree.length));
    expect(shown.length, lessThan(45));
    const all = MeshViewState(filter: MeshFilter.all);
    expect(
      map.edges.where((e) => all.edgeShown(e, const {})),
      hasLength(map.edges.length),
    );
  });

  test('Endgeräte: der gemeldete Elternknoten gewinnt', () {
    // Endgeräte melden nichts, sie stehen als Kind (`relationship` 1) in der
    // Tabelle ihres Elternknotens.
    final reported = <String, String>{};
    for (final l in rawLinks) {
      if (types[src(l)] == 'EndDevice' && l['relationship'] == 1) {
        reported[src(l)] = tgt(l);
      }
    }
    expect(reported, hasLength(18));
    for (final e in reported.entries) {
      expect(map.parentOf(e.key), e.value, reason: e.key);
      expect(map.lqiToParent(e.key), isNotNull);
    }
    // Endgeräte ohne Eintrag (Batterie, schlafend) bleiben ohne Weg.
    final silent = [
      for (final n in map.nodes)
        if (n.kind == ZbNodeKind.endDevice && !reported.containsKey(n.ieee))
          n.ieee,
    ];
    expect(silent, hasLength(4));
    for (final id in silent) {
      expect(map.parentOf(id), isNull);
      expect(map.pathToCoordinator(id), isEmpty);
    }
  });

  test('Router: alle erreichen den Koordinator nur über Router', () {
    final routers = map.nodes.where((n) => n.isRouter).toList();
    expect(routers, hasLength(20));
    for (final r in routers) {
      final p = map.pathToCoordinator(r.ieee);
      expect(p, isNotEmpty, reason: r.name);
      expect(p.last, map.coordinator);
      for (final mid in p.skip(1)) {
        expect(map.node(mid)!.kind, isNot(ZbNodeKind.endDevice));
      }
    }
    // Endgeräte hängen nie an Endgeräten, Pfade enden am Koordinator.
    for (final n in map.nodes) {
      final p = map.pathToCoordinator(n.ieee);
      if (p.isEmpty) continue;
      expect(p.last, map.coordinator);
      expect(p.toSet(), hasLength(p.length), reason: 'Zyklus bei ${n.name}');
    }
  });

  test('Kinder und Nachbarn passen zur Elternwahl', () {
    final c = map.coordinator!;
    final kids = map.childrenOf(c);
    expect(kids, isNotEmpty);
    for (final k in kids) {
      expect(map.parentOf(k), c);
    }
    expect(map.neighborCount(c), greaterThan(kids.length - 1));
  });

  test('Neu messen wartet länger als der normale Timeout', () async {
    // HA antwortet erst nach der Messung. Hier: normaler Timeout 80 ms,
    // Antwort nach 250 ms. Ohne `refresh` kommt der Cache (`null`) sofort.
    final client = HaClient(
      url: 'http://ha.local:8123',
      token: 't',
      requestTimeout: const Duration(milliseconds: 80),
      pingInterval: const Duration(minutes: 5),
      channelFactory: (_) {
        final c = FakeChannel();
        c.server.onMessage = (server, m) {
          void answer(dynamic result) => server.send({
            'id': m['id'],
            'type': 'result',
            'success': true,
            'result': result,
          });
          if (m['type'] == 'haven/zigbee/networkmap' && m['refresh'] == true) {
            Timer(const Duration(milliseconds: 250), () => answer(raw));
          } else {
            answer(null);
          }
        };
        scheduleMicrotask(c.server.greet);
        return c;
      },
    );
    await client.start();
    final zb = HaZigbee(client);
    expect((await zb.networkMap(false)).isEmpty, isTrue);
    final m = await zb.networkMap(true);
    expect(m.nodes, hasLength(43));
    expect(m.links, hasLength(371));
    expect(
      HaZigbee.networkMapRefreshTimeout,
      greaterThanOrEqualTo(const Duration(seconds: 100)),
    );
    await zb.dispose();
    await client.close();
  });

  test('Fehlertexte nach Ursache', () {
    String t(String code) =>
        meshErrorText(HavenException('x', code: code), refresh: true);
    expect(t('timeout'), contains('zu lange'));
    expect(t('bridge_offline'), contains('Zigbee2MQTT ist offline'));
    expect(t('unauthorized'), contains('Administrator'));
    expect(t('busy'), contains('schon eine Messung'));
    expect(t('unknown_command'), contains('Integration'));
    for (final c in ['timeout', 'bridge_offline', 'unauthorized', 'busy']) {
      expect(t(c), isNot(contains('!')));
    }
  });

  test('Fortschritt: steigt, wird nie ganz voll', () {
    final a = MeasureProgress.estimate(const Duration(seconds: 5));
    final b = MeasureProgress.estimate(const Duration(seconds: 30));
    final c = MeasureProgress.estimate(const Duration(seconds: 300));
    expect(a, lessThan(b));
    expect(b, lessThan(c));
    expect(c, lessThanOrEqualTo(0.95));
  });

  test(
    'Abbrechen: kein Fehler, spätes Ergebnis wird still übernommen',
    () async {
      final repo = _SlowRepo();
      final c = ProviderContainer(
        overrides: [
          initialSessionProvider.overrideWithValue(
            Session(SessionMode.fake, repo),
          ),
        ],
      );
      addTearDown(c.dispose);
      final sub = c.listen(zigbeeMeshProvider, (_, _) {});
      addTearDown(sub.close);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(zigbeeMeshProvider).map!.isEmpty, isTrue);

      final f = c.read(zigbeeMeshProvider.notifier).refresh();
      expect(c.read(zigbeeMeshProvider).refreshing, isTrue);
      expect(c.read(zigbeeMeshProvider).refreshStarted, isNotNull);
      c.read(zigbeeMeshProvider.notifier).cancel();
      expect(c.read(zigbeeMeshProvider).refreshing, isFalse);
      expect(c.read(zigbeeMeshProvider).error, isNull);

      repo.pending!.complete(map);
      expect(await f, isNull);
      expect(c.read(zigbeeMeshProvider).map!.nodes, hasLength(43));
      expect(c.read(zigbeeMeshProvider).error, isNull);

      // Fehler nach dem Abbrechen bleiben still.
      final g = c.read(zigbeeMeshProvider.notifier).refresh();
      c.read(zigbeeMeshProvider.notifier).cancel();
      repo.pending!.completeError(HavenException('x', code: 'timeout'));
      expect(await g, isNull);
      expect(c.read(zigbeeMeshProvider).error, isNull);
    },
  );
}
