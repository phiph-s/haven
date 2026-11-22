import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/core/theme/theme.dart';
import 'package:haven/data/ha/ha_client.dart';
import 'package:haven/data/ha/ha_render.dart';
import 'package:haven/data/haven_repository.dart';
import 'package:haven/data/render_api.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/features/map/map_render.dart';
import 'package:haven_3d/haven_3d.dart' as h3;
import 'package:material_ui/material_ui.dart';

import '../../support/fake_ha.dart';

void main() {
  group('Perspektiven und Schlüssel', () {
    test('Übersicht 2D, 3D und je Raum eine Aufnahme', () {
      final views = mapLayerViews(kFakeFloorPlan);
      final rooms = kFakeFloorPlan.rooms.where((r) => !r.detached).toList();
      expect(views, hasLength(2 + rooms.length));
      expect(views[0].flat, isTrue);
      expect(views[1].pitch, greaterThan(0.5));
      for (var i = 0; i < rooms.length; i++) {
        expect(views[2 + i].roomId, rooms[i].id);
        expect(views[2 + i].name, rooms[i].name);
        expect(views[2 + i].id, matches(RegExp(r'^[A-Za-z0-9_\-]+$')));
      }
    });

    test('Schlüssel folgt Plan und Perspektiven', () {
      final plan = kFakeFloorPlan;
      final views = mapLayerViews(plan);
      final key = mapRenderKey(plan, views);
      expect(mapRenderKey(plan, mapLayerViews(plan)), key);
      final moved = plan.copyWith(
        placements: [
          for (final p in plan.placements)
            p == plan.placements.first ? p.copyWith(x: p.x + 1) : p,
        ],
      );
      expect(mapRenderKey(moved, views), isNot(key));
      expect(mapRenderKey(plan, views.take(2).toList()), isNot(key));
      expect(key, matches(RegExp(r'^[0-9a-f-]+$')));
    });

    test('Schlüssel gleich in Web und nativ (ganze Kommazahlen)', () {
      // Im Web (JavaScript) schreibt jsonEncode 4.0 als „4“: dieselben Daten
      // mit ganzen Zahlen statt Kommazahlen müssen denselben Text ergeben.
      Object? asWeb(Object? v) => switch (v) {
        final double d when d == d.truncateToDouble() => d.toInt(),
        final Map<dynamic, dynamic> m => {
          for (final e in m.entries) e.key: asWeb(e.value),
        },
        final List<dynamic> l => [for (final x in l) asWeb(x)],
        _ => v,
      };
      final plan = kFakeFloorPlan.toJson();
      expect(jsonEncode(plan), isNot(jsonEncode(asWeb(plan))));
      expect(
        jsonEncode(canonicalJson(plan)),
        jsonEncode(canonicalJson(asWeb(plan))),
      );
      expect(canonicalJson({'a': 1.5, 'b': 2.0, 'c': -0.0}), {
        'a': 1.5,
        'b': 2,
        'c': 0,
      });
    });
  });

  group('Bilder aktuell trotz verschiedener App-Versionen', () {
    test('Bereich, Geräte-ID und Zeitstempel ändern den Schlüssel nicht', () {
      final plan = kFakeFloorPlan;
      final views = mapLayerViews(plan);
      final key = mapRenderKey(plan, views);
      final relinked = plan.copyWith(
        rooms: [
          for (final r in plan.rooms) r.copyWith(areaId: 'anders_${r.id}'),
        ],
        placements: [
          for (final p in plan.placements) p.copyWith(deviceId: 'x'),
        ],
      );
      expect(mapRenderKey(relinked, views), key);
      final stamped = HavenFloorPlan.fromJson({
        ...plan.toJson(),
        'updatedAt': 1234,
      });
      expect(mapRenderKey(stamped, views), key);
    });

    test(
      'Schlüssel alter Versionen gelten als aktuell, fremde Pläne nicht',
      () {
        final plan = kFakeFloorPlan;
        final views = mapLayerViews(plan);
        final accepted = acceptedRenderKeys(plan, views);
        // Bis 0.9.30 (nativ): Plan samt Bereichen, Kommazahlen wie `1.0`.
        String legacy(Object? doc) =>
            '${h3.kLayerFormat}-${fnvForTest(utf8.encode(jsonEncode(doc)))}';
        final doc = {
          'format': h3.kLayerFormat,
          'look': h3.kLayerLook,
          'plan': plan.toJson(),
          'views': [for (final v in views) v.toJson()],
        };
        expect(accepted, contains(legacy(doc)));
        // 0.9.31 und 0.9.32: wie heute im Web, aber mit Bereichen.
        expect(accepted, contains(legacy(canonicalJson(doc))));
        expect(accepted, contains(mapRenderKey(plan, views)));
        final moved = plan.copyWith(
          placements: [
            for (final p in plan.placements)
              p == plan.placements.first ? p.copyWith(x: p.x + 1) : p,
          ],
        );
        expect(
          accepted.intersection(acceptedRenderKeys(moved, views)),
          isEmpty,
        );
      },
    );
  });

  group('Upload in Stücken', () {
    Future<(HaClient, FakeServer)> connect(
      void Function(FakeServer s, Map<String, dynamic> m) onMessage,
    ) async {
      late FakeServer server;
      final c = HaClient(
        url: 'http://ha.local:8123',
        token: 'test',
        pingInterval: const Duration(minutes: 5),
        channelFactory: (uri) {
          final ch = FakeChannel();
          server = ch.server..onMessage = onMessage;
          scheduleMicrotask(server.greet);
          return ch;
        },
      );
      await c.start();
      return (c, server);
    }

    test('begin, Stücke mit Versatz, commit; Inhalt kommt ganz an', () async {
      final got = <String, BytesBuilder>{};
      final types = <String>[];
      final (client, server) = await connect((s, m) {
        types.add(m['type'] as String);
        final res = switch (m['type']) {
          'haven/render/begin' => {'upload': 'u1'},
          'haven/render/chunk' => () {
            final b = got.putIfAbsent(m['path'] as String, BytesBuilder.new);
            expect(m['offset'], b.length);
            b.add(base64Decode(m['data'] as String));
            return {'size': b.length};
          }(),
          _ => {'ok': true},
        };
        s.send({
          'id': m['id'],
          'type': 'result',
          'success': true,
          'result': res,
        });
      });
      final big = Uint8List.fromList(
        List.generate(HaRender.chunkSize * 2 + 17, (i) => i % 251),
      );
      final small = Uint8List.fromList(utf8.encode('{"format":1}'));
      final sent = <int>[];
      await HaRender(client).upload('k1', [
        (path: 'a_dark/meta.json', bytes: small),
        (path: 'a_dark/base.png', bytes: big),
      ], onProgress: (s, _) => sent.add(s));
      expect(types.first, 'haven/render/begin');
      expect(types.last, 'haven/render/commit');
      expect(types.where((t) => t == 'haven/render/chunk'), hasLength(4));
      expect(got['a_dark/base.png']!.toBytes(), big);
      expect(got['a_dark/meta.json']!.toBytes(), small);
      expect(sent.last, big.length + small.length);
      expect(
        server.received.any(
          (m) => m['type'] == 'haven/render/begin' && m['key'] == 'k1',
        ),
        isTrue,
      );
      await client.close();
    });

    test('Fehler beim Hochladen bricht den Upload in HA ab', () async {
      final types = <String>[];
      final (client, _) = await connect((s, m) {
        types.add(m['type'] as String);
        if (m['type'] == 'haven/render/chunk') {
          s.send({
            'id': m['id'],
            'type': 'result',
            'success': false,
            'error': {'code': 'invalid_format', 'message': 'kaputt'},
          });
          return;
        }
        s.send({
          'id': m['id'],
          'type': 'result',
          'success': true,
          'result': {'upload': 'u1'},
        });
      });
      await expectLater(
        HaRender(
          client,
        ).upload('k', [(path: 'a/base.png', bytes: Uint8List(3))]),
        throwsA(isA<HavenException>()),
      );
      expect(types.last, 'haven/render/abort');
      await client.close();
    });

    test('Status ohne numpy/Pillow gilt als nicht unterstützt', () async {
      final (client, _) = await connect((s, m) {
        s.send({
          'id': m['id'],
          'type': 'result',
          'success': true,
          'result': {'available': false, 'key': null, 'sets': {}},
        });
      });
      expect(await HaRender(client).status(), isNull);
      await client.close();
    });
  });

  testWidgets('Ladedialog zeigt Fortschritt, Raum und „Später“', (
    tester,
  ) async {
    final key = GlobalKey<MapRenderDialogState>();
    final job = MapRenderJob(FakeRepository(simulate: false), kFakeFloorPlan);
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: havenDarkTheme,
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async => result = await showDialog<bool>(
                context: context,
                builder: (_) =>
                    MapRenderDialog(key: key, job: job, autoStart: false),
              ),
              child: const Text('los'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('los'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Bilder für Widgets'), findsOneWidget);
    final room = kFakeFloorPlan.rooms.first;
    key.currentState!.show((
      phase: MapRenderPhase.render,
      fraction: 0.4,
      roomId: room.id,
    ));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('${room.name} wird beleuchtet …'), findsOneWidget);
    expect(find.text('40 %'), findsOneWidget);
    key.currentState!.show((
      phase: MapRenderPhase.upload,
      fraction: 0.9,
      roomId: null,
    ));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Wird zu Home Assistant gebracht …'), findsOneWidget);
    await tester.tap(find.text('Später'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 1));
    expect(result, isFalse);
    expect(find.text('Bilder für Widgets'), findsNothing);
  });

  test('Entwicklungsdaten nehmen Bilder im Speicher an', () async {
    final repo = FakeRepository(simulate: false);
    expect((await repo.renderStatus())!.key, isNull);
    await repo.uploadRenders('k', [
      (path: 'x_dark/base.png', bytes: Uint8List(4)),
    ]);
    final s = (await repo.renderStatus())!;
    expect(s.key, 'k');
    expect(s.sets, {'x_dark'});
    await expectLater(
      repo.uploadRenders('k2', [
        (path: 'x/base.png', bytes: Uint8List(1)),
      ], cancelled: () => true),
      throwsA(isA<RenderUploadCancelled>()),
    );
  });
}
