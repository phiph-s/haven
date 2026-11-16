import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/dev/fake_data.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/dev/fake_zigbee.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/data/models/zigbee.dart';
import 'package:haven/data/models/zigbee_network.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/features/zigbee/mesh/mesh_graph.dart';
import 'package:haven/features/zigbee/mesh/mesh_scene.dart';
import 'package:haven/features/zigbee/zigbee_model.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<ZbDevice> _devs = [];

List<ZbDevice> _devices() => _devs;

Map<String, List<String>> _entityIds() {
  final byName = {
    for (final d in kFakeInventory['z2m_devices'] as List)
      d['friendly_name'] as String: (d['entities'] as Map).keys
          .cast<String>()
          .toList(),
  };
  return {
    for (final d in _devices()) d.ieee: byName[d.friendlyName] ?? const [],
  };
}

Map<String, dynamic> _raw() => {
  'timestamp': 1763200000,
  'networkmap': {
    'nodes': [
      {
        'ieeeAddr': '0xc0',
        'friendlyName': 'Coordinator',
        'type': 'Coordinator',
        'networkAddress': 0,
      },
      {
        'ieeeAddr': '0xr1',
        'friendlyName': 'Flur',
        'type': 'Router',
        'networkAddress': 10,
      },
      {
        'ieeeAddr': '0xr2',
        'friendlyName': 'Bad',
        'type': 'Router',
        'networkAddress': 11,
      },
      {
        'ieeeAddr': '0xe1',
        'friendlyName': 'Sensor',
        'type': 'EndDevice',
        'networkAddress': 12,
      },
      {
        'ieeeAddr': '0xe2',
        'friendlyName': 'Insel',
        'type': 'EndDevice',
        'networkAddress': 13,
      },
    ],
    // Z2M-Rohformat: `target` meldet seine Neighbor-Table, `source` ist der
    // Nachbar, `relationship` beschreibt den Nachbarn (0 Eltern, 1 Kind,
    // 2 Geschwister).
    'links': [
      // Tabelle des Koordinators: Flur ist sein Kind.
      {
        'source': {'ieeeAddr': '0xr1', 'networkAddress': 10},
        'target': {'ieeeAddr': '0xc0', 'networkAddress': 0},
        'linkquality': 200,
        'depth': 1,
        'relationship': 1,
        'routes': [
          {'destinationAddress': 12, 'nextHop': 11, 'status': 'ACTIVE'},
        ],
      },
      // Tabelle des Flurs: der Koordinator ist sein Elternknoten.
      {
        'source': {'ieeeAddr': '0xc0'},
        'target': {'ieeeAddr': '0xr1'},
        'linkquality': 205,
        'depth': 0,
        'relationship': 0,
      },
      // Bad hängt nur über die Tabelle des Flurs (Kind).
      {
        'source': {'ieeeAddr': '0xr2'},
        'target': {'ieeeAddr': '0xr1'},
        'linkquality': 120,
        'depth': 2,
        'relationship': 1,
      },
      // Sensor: zwei mögliche Eltern, der stärkere gewinnt.
      {
        'source': {'ieeeAddr': '0xe1'},
        'target': {'ieeeAddr': '0xr1'},
        'linkquality': 90,
        'depth': 2,
        'relationship': 1,
      },
      {
        'source': {'ieeeAddr': '0xe1'},
        'target': {'ieeeAddr': '0xr2'},
        'linkquality': 170,
        'depth': 3,
        'relationship': 1,
      },
      // Insel: nur Geschwister-Verbindung zum Bad.
      {
        'source': {'ieeeAddr': '0xe2'},
        'target': {'ieeeAddr': '0xr2'},
        'linkquality': 60,
        'depth': 3,
        'relationship': 2,
      },
    ],
  },
};

void main() {
  setUpAll(() async {
    _devs = await FakeZigbee(
      inventory: kFakeInventory,
      zigbee: kFakeZigbee,
    ).devices();
  });

  group('Networkmap parsen', () {
    final map = ZbNetworkMap.fromJson(_raw());

    test('Knoten, Typen, Zeitstempel', () {
      expect(map.nodes, hasLength(5));
      expect(map.coordinator, '0xc0');
      expect(map.node('0xr1')!.kind, ZbNodeKind.router);
      expect(map.node('0xe1')!.kind, ZbNodeKind.endDevice);
      expect(map.node('0xr1')!.networkAddress, 10);
      expect(
        map.measuredAt,
        DateTime.fromMillisecondsSinceEpoch(1763200000000),
      );
      expect(map.links, hasLength(6));
      expect(map.links.first.routes.single.nextHop, 11);
      expect(map.routesOf('0xr1'), hasLength(1));
    });

    test('Kanten: Kind zu Eltern, Hin und Rück fallen zusammen', () {
      final e = map.edges.where((e) => e.touches('0xr1') && e.touches('0xc0'));
      expect(e, hasLength(1));
      expect(e.single.a, '0xr1');
      expect(e.single.b, '0xc0');
      expect(e.single.hierarchical, isTrue);
      expect(map.parentOf('0xr2'), '0xr1');
      expect(map.lqiToParent('0xr2'), 120);
    });

    test('stärkster Elternknoten gewinnt, LQI am Knoten', () {
      expect(map.parentOf('0xe1'), '0xr2');
      expect(map.node('0xe1')!.lqi, 170);
      expect(map.childrenOf('0xr2'), contains('0xe1'));
      expect(map.node('0xc0')!.lqi, isNull);
    });

    test('Wrapper der Bridge und verschachtelte Formen', () {
      final w = ZbNetworkMap.fromJson({
        'data': {
          'type': 'raw',
          'routes': false,
          'value': (_raw()['networkmap']),
        },
        'status': 'ok',
        'timestamp': '2026-11-15T10:00:00Z',
      });
      expect(w.nodes, hasLength(5));
      expect(w.measuredAt, DateTime.utc(2026, 11, 15, 10));
      expect(ZbNetworkMap.fromJson(const {}).isEmpty, isTrue);
    });
  });

  group('Pfadsuche', () {
    final map = ZbNetworkMap.fromJson(_raw());

    test('Pfad bis zum Koordinator', () {
      expect(map.pathToCoordinator('0xe1'), ['0xe1', '0xr2', '0xr1', '0xc0']);
      expect(map.pathToCoordinator('0xc0'), ['0xc0']);
      expect(map.pathEdges('0xe1').map((e) => e.key), [
        '0xe1>0xr2',
        '0xr2>0xr1',
        '0xr1>0xc0',
      ]);
    });

    test('nur Geschwisterverbindung: stärkster Router-Nachbar', () {
      expect(map.parentOf('0xe2'), '0xr2');
      expect(map.pathToCoordinator('0xe2').last, '0xc0');
    });

    test('Zyklen und Inseln liefern keinen Pfad, ohne zu hängen', () {
      final m = ZbNetworkMap(
        nodes: const [
          ZbMeshNode(ieee: 'c', name: 'c', kind: ZbNodeKind.coordinator),
          ZbMeshNode(ieee: 'a', name: 'a', kind: ZbNodeKind.router),
          ZbMeshNode(ieee: 'b', name: 'b', kind: ZbNodeKind.router),
          ZbMeshNode(ieee: 'x', name: 'x'),
        ],
        links: const [
          ZbMeshLink(source: 'a', target: 'b', lqi: 100, relationship: 0),
          ZbMeshLink(source: 'b', target: 'a', lqi: 100, relationship: 0),
        ],
      );
      expect(m.pathToCoordinator('a'), isEmpty);
      expect(m.pathToCoordinator('x'), isEmpty);
      expect(m.pathToCoordinator('unbekannt'), isEmpty);
    });
  });

  group('Fake-Topologie', () {
    test('deterministisch', () {
      final a = buildFakeNetworkMap(_devices(), entityIds: _entityIds());
      final b = buildFakeNetworkMap(_devices(), entityIds: _entityIds());
      String sig(ZbNetworkMap m) => [
        for (final l in m.links)
          '${l.source}>${l.target}:${l.lqi}:${l.depth}:${l.relationship}',
      ].join(',');
      expect(sig(a), sig(b));
      expect(a.nodes.map((n) => n.ieee), b.nodes.map((n) => n.ieee));
    });

    test('jedes Gerät hat einen Pfad zum Koordinator', () {
      final devs = _devices();
      final m = buildFakeNetworkMap(devs, entityIds: _entityIds());
      expect(m.nodes, hasLength(devs.length + 1));
      for (final d in devs) {
        final p = m.pathToCoordinator(d.ieee);
        expect(p, isNotEmpty, reason: d.friendlyName);
        expect(p.first, d.ieee);
        expect(p.last, m.coordinator);
        // Pfad läuft nur über Router.
        for (final mid in p.skip(1).take(p.length - 2)) {
          expect(m.node(mid)!.isRouter, isTrue, reason: d.friendlyName);
        }
        expect(m.node(d.ieee)!.lqi, isNotNull);
      }
    });

    test('Endgeräte hängen im selben Raum, schwache Verbindungen sind da', () {
      final devs = _devices();
      final m = buildFakeNetworkMap(devs, entityIds: _entityIds());
      final byName = {for (final d in devs) d.friendlyName: d};
      int q(String n) => m.lqiToParent(byName[n]!.ieee)!;
      expect(q('Lüfter Waschraum'), 58);
      expect(q('Sensor Terrasse'), 71);
      final weak = [
        for (final d in devs)
          if (m.lqiToParent(d.ieee)! < kWeakLqi) d.friendlyName,
      ];
      expect(weak, unorderedEquals(['Lüfter Waschraum', 'Sensor Terrasse']));
      // Mittlere und gute Werte kommen vor.
      final all = [for (final d in devs) m.lqiToParent(d.ieee)!];
      expect(all.any((v) => v >= kGoodLqi), isTrue);
      expect(all.any((v) => v >= kWeakLqi && v < kGoodLqi), isTrue);
      // Das Endgerät Präsenz Waschraum hängt an einem Router im selben Raum.
      final plan = kFakeFloorPlan;
      final ents = _entityIds();
      final pts = plan.devicePoints([
        for (final d in devs)
          FloorDevice(d.ieee, ents[d.ieee]!, roomId: d.areaId),
      ]);
      final kid = byName['Präsenz Waschraum']!;
      final parent = m.parentOf(kid.ieee)!;
      expect(pts[parent]!.roomId, pts[kid.ieee]!.roomId);
    });
  });

  group('Szene', () {
    test('ohne Grundriss: Raster aus den Räumen, Geräte ohne Raum separat', () {
      final devs = _devices();
      final map = buildFakeNetworkMap(devs, entityIds: _entityIds());
      final views = [for (final d in devs) ZbDeviceView.build(d)];
      final s = buildMeshScene(map: map, views: views);
      expect(s.autoLayout, isTrue);
      expect(s.plan.rooms.where((r) => r.id != kNoRoomId), isNotEmpty);
      expect(s.hasNoRoom, isTrue);
      // Jeder Knoten hat einen Punkt, der Koordinator auch.
      for (final n in map.nodes) {
        expect(s.points[n.ieee], isNotNull, reason: n.name);
        expect(s.plan.room(s.points[n.ieee]!.roomId), isNotNull);
      }
    });

    test('mit Grundriss: Koordinator aus dem Plan', () {
      final devs = _devices();
      final map = buildFakeNetworkMap(devs, entityIds: _entityIds());
      final views = [for (final d in devs) ZbDeviceView.build(d)];
      final s = buildMeshScene(map: map, views: views, plan: kFakeFloorPlan);
      expect(s.autoLayout, isFalse);
      expect(s.points[map.coordinator!], kFakeFloorPlan.coordinator);
      final moved = s.withCoordinator(const PlanPoint('bad', 0.5, 0.5));
      expect(moved.points[map.coordinator!]!.roomId, 'bad');
    });
  });

  group('Graph-Ansicht', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    });

    testWidgets('rendert mit Beispieldaten, Antippen öffnet das Sheet', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore(await SharedPreferences.getInstance());
      tester.view.physicalSize = const Size(412 * 2.625, 915 * 2.625);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      late Widget app;
      await tester.runAsync(() async {
        final repo = FakeRepository(simulate: false);
        await repo.start();
        app = ProviderScope(
          overrides: [
            settingsStoreProvider.overrideWithValue(store),
            tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
            initialSessionProvider.overrideWithValue(
              Session(SessionMode.fake, repo),
            ),
          ],
          child: const HavenApp(initialLocation: '/zigbee/mesh'),
        );
      });
      await tester.pumpWidget(app);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.text('Funknetz'), findsOneWidget);
      expect(find.text('Netz neu messen'), findsOneWidget);
      expect(find.text('Wege'), findsOneWidget);
      expect(find.text('Alle Verbindungen'), findsOneWidget);
      expect(find.text('Schwache'), findsOneWidget);
      expect(find.textContaining('gemessen vor'), findsOneWidget);
      expect(find.byType(MeshGraph), findsOneWidget);
      expect(find.byType(MeshNodeDot), findsNWidgets(21));

      final target = find.byWidgetPredicate(
        (w) => w is MeshNodeDot && w.info.name == 'Kochbereich Arbeitslicht 1',
      );
      expect(target, findsOneWidget);
      await tester.tap(target);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Gerät öffnen'), findsOneWidget);
      expect(find.text('Signal zum Elternknoten'), findsOneWidget);
      expect(find.text('Elternknoten'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
