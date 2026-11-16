import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/ha/ha_client.dart';
import 'package:haven/data/ha/ha_repository.dart';
import 'package:haven/data/haven_repository.dart';
import 'package:haven/data/models/entity_state.dart';
import 'package:haven/data/models/snapshot.dart';

import 'support/fake_ha.dart';

HaClient _client(
  List<FakeChannel> channels, {
  void Function(FakeChannel)? onOpen,
}) => HaClient(
  url: 'http://ha.local:8123',
  token: 'geheim',
  minBackoff: const Duration(milliseconds: 10),
  maxBackoff: const Duration(milliseconds: 40),
  pingInterval: const Duration(minutes: 5),
  channelFactory: (uri) {
    final c = FakeChannel();
    channels.add(c);
    scheduleMicrotask(() {
      onOpen?.call(c);
      c.server.greet();
    });
    return c;
  },
);

Future<void> _until(bool Function() cond) async {
  for (var i = 0; i < 200 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(cond(), isTrue, reason: 'Bedingung nicht erreicht');
}

void main() {
  group('websocketUri', () {
    test('http, https, ohne Schema, mit Pfad', () {
      expect(
        HaClient.websocketUri('http://ha.local:8123').toString(),
        'ws://ha.local:8123/api/websocket',
      );
      expect(
        HaClient.websocketUri('https://ha.example.org').toString(),
        'wss://ha.example.org/api/websocket',
      );
      expect(
        HaClient.websocketUri('ha.local:8123/').toString(),
        'ws://ha.local:8123/api/websocket',
      );
      expect(
        HaClient.websocketUri('https://x.org/ha/').toString(),
        'wss://x.org/ha/api/websocket',
      );
      expect(
        HaClient.websocketUri('ws://x:1/api/websocket').toString(),
        'ws://x:1/api/websocket',
      );
    });
  });

  group('HaClient', () {
    test('Auth, Request-IDs und Antworten', () async {
      final channels = <FakeChannel>[];
      final c = _client(channels);
      await c.start();
      expect(c.isConnected, isTrue);
      expect(channels.single.server.received.first, {
        'type': 'auth',
        'access_token': 'geheim',
      });

      final f1 = c.send({'type': 'get_states'});
      final f2 = c.send({'type': 'haven/info'});
      await Future<void>.delayed(Duration.zero);
      final sent = channels.single.server.received
          .where((m) => m['type'] != 'auth')
          .toList();
      expect(sent.map((m) => m['id']), [1, 2]);
      channels.single.server.send({
        'id': 2,
        'type': 'result',
        'success': true,
        'result': {'loaded': true},
      });
      channels.single.server.send({
        'id': 1,
        'type': 'result',
        'success': true,
        'result': [],
      });
      expect(await f2, {'loaded': true});
      expect(await f1, isEmpty);
      await c.close();
    });

    test('Fehlerantwort wird zu HaError mit Code', () async {
      final channels = <FakeChannel>[];
      final c = _client(channels);
      await c.start();
      final f = c.send({'type': 'haven/rooms'});
      channels.single.server.send({
        'id': 1,
        'type': 'result',
        'success': false,
        'error': {'code': 'not_found', 'message': 'Haven nicht geladen'},
      });
      await expectLater(
        f,
        throwsA(isA<HaError>().having((e) => e.code, 'code', 'not_found')),
      );
      await c.close();
    });

    test('abgelehnter Token: kein Reconnect, Status authFailed', () async {
      final channels = <FakeChannel>[];
      final c = _client(channels, onOpen: (ch) => ch.server.accept = false);
      await expectLater(
        c.start(),
        throwsA(
          isA<HavenException>().having((e) => e.code, 'code', 'auth_invalid'),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(c.status, ConnectionStatus.authFailed);
      expect(channels, hasLength(1));
      await c.close();
    });

    test('Abo bekommt Ereignisse und überlebt den Reconnect', () async {
      final channels = <FakeChannel>[];
      final c = _client(channels);
      await c.start();
      final events = <dynamic>[];
      await Future.wait([
        c.subscribe({
          'type': 'subscribe_events',
          'event_type': 'state_changed',
        }, events.add),
        Future<void>.microtask(() {
          final sub = channels.single.server.received.last;
          channels.single.server.send({
            'id': sub['id'],
            'type': 'result',
            'success': true,
            'result': null,
          });
        }),
      ]);
      final sub = channels.single.server.received.last;
      channels.single.server.send({
        'id': sub['id'],
        'type': 'event',
        'event': {'n': 1},
      });
      await _until(() => events.length == 1);

      // Server bricht weg: der Client verbindet neu und abonniert erneut.
      final reconnected = c.onConnected.first;
      channels.single.server.close();
      // Zweiter Kanal: nach dem Auth kommt das erneute Abo.
      await _until(() => channels.length == 2);
      await _until(
        () => channels[1].server.received.any(
          (m) => m['type'] == 'subscribe_events',
        ),
      );
      final again = channels[1].server.received.lastWhere(
        (m) => m['type'] == 'subscribe_events',
      );
      channels[1].server.send({
        'id': again['id'],
        'type': 'result',
        'success': true,
        'result': null,
      });
      await reconnected;
      channels[1].server.send({
        'id': again['id'],
        'type': 'event',
        'event': {'n': 2},
      });
      await _until(() => events.length == 2);
      expect(events.last, {'n': 2});
      await c.close();
    });

    test('Senden ohne Verbindung scheitert sofort', () async {
      final c = HaClient(url: 'x', token: 't');
      await expectLater(
        c.send({'type': 'ping'}),
        throwsA(isA<HavenException>()),
      );
      await c.close();
    });
  });

  group('HaRepository', () {
    test('baut Räume aus haven/rooms und Gruppen', () {
      final entities = {
        'scene.zgsalon_0_golden_hour': const EntityState(
          'scene.zgsalon_0_golden_hour',
          'unknown',
        ),
        'sensor.drehknopf_salon_1_battery': const EntityState(
          'sensor.drehknopf_salon_1_battery',
          '100',
        ),
      };
      final rooms = HaRepository.roomsFromHaven(
        {
          'rooms': [
            {
              'area_id': 'salon',
              'name': 'Salon',
              'lights': ['light.a', 'light.b'],
              'climate': {
                'temperature': ['sensor.t'],
                'humidity': ['sensor.h'],
              },
              'group': {'id': 1, 'friendly_name': 'ZGSalon', 'match': 'exact'},
            },
            {
              'area_id': 'bad',
              'name': 'Bad',
              'lights': <String>[],
              'climate': {},
              'group': null,
            },
          ],
        },
        {
          'groups': [
            {
              'id': 1,
              'friendly_name': 'ZGSalon',
              'members': [
                {
                  'ieee': '0x1',
                  'friendly_name': 'Drehknopf Salon 1',
                  'device_type': 'knob',
                },
                {
                  'ieee': '0x2',
                  'friendly_name': 'Lampe',
                  'device_type': 'light',
                },
              ],
              'scenes': [
                {'id': 0, 'name': 'Golden Hour'},
                {'id': 9, 'name': 'Gibt es nicht'},
              ],
            },
          ],
        },
        entities,
      );
      expect(rooms, hasLength(2));
      final wz = rooms.first;
      expect(wz.lightIds, ['light.a', 'light.b']);
      expect(wz.temperatureId, 'sensor.t');
      expect(wz.scenes.map((s) => s.entityId), ['scene.zgsalon_0_golden_hour']);
      expect(
        wz.knobs.single.batteryEntityId,
        'sensor.drehknopf_salon_1_battery',
      );
      expect(rooms.last.scenes, isEmpty);
    });

    test('lädt Zustände, ruft Dienste und folgt state_changed', () async {
      final channels = <FakeChannel>[];
      // Mini-Server: antwortet auf Befehle.
      void respond(FakeServer server, Map<String, dynamic> m) {
        dynamic result;
        var ok = true;
        switch (m['type']) {
          case 'get_states':
            result = [
              {
                'entity_id': 'light.a',
                'state': 'off',
                'attributes': {
                  'supported_color_modes': ['brightness'],
                  'friendly_name': 'A',
                },
              },
            ];
          case 'haven/rooms':
            result = {
              'rooms': [
                {
                  'area_id': 'r',
                  'name': 'R',
                  'lights': ['light.a'],
                  'climate': {},
                  'group': null,
                },
              ],
            };
          case 'haven/zigbee/groups':
            result = {'groups': []};
          case 'call_service':
          case 'subscribe_events':
            result = null;
          default:
            ok = false;
        }
        server.send({
          'id': m['id'],
          'type': 'result',
          'success': ok,
          'result': result,
          if (!ok) 'error': {'code': 'unknown_command', 'message': 'x'},
        });
      }

      final client = _client(
        channels,
        onOpen: (ch) => ch.server.onMessage = respond,
      );
      final repo = HaRepository(url: 'x', token: 'y', client: client);

      await repo.start();
      await _until(() => repo.snapshot.rooms.isNotEmpty);
      expect(repo.snapshot.status, ConnectionStatus.connected);
      expect(repo.snapshot.lamp('light.a')!.on, isFalse);

      await repo.setLights(['light.a'], on: true, brightness: 50);
      expect(repo.snapshot.lamp('light.a')!.on, isTrue, reason: 'optimistisch');
      await _until(
        () => channels.first.server.received.any(
          (m) => m['type'] == 'call_service',
        ),
      );
      final call = channels.first.server.received.firstWhere(
        (m) => m['type'] == 'call_service',
      );
      expect(call['domain'], 'light');
      expect(call['service'], 'turn_on');
      expect(call['service_data'], {'brightness_pct': 50});
      expect(call['target'], {
        'entity_id': ['light.a'],
      });

      final sub = channels.first.server.received.firstWhere(
        (m) => m['type'] == 'subscribe_events',
      );
      channels.first.server.send({
        'id': sub['id'],
        'type': 'event',
        'event': {
          'event_type': 'state_changed',
          'data': {
            'entity_id': 'light.a',
            'new_state': {
              'entity_id': 'light.a',
              'state': 'off',
              'attributes': {'friendly_name': 'A'},
            },
          },
        },
      });
      await _until(() => repo.snapshot.lamp('light.a')?.on == false);
      await repo.dispose();
    });
  });

  test(
    'Token-Quelle (Panel): frisches Token bei jedem Verbindungsaufbau',
    () async {
      final channels = <FakeChannel>[];
      var n = 0;
      final client = HaClient(
        url: 'http://ha.local:8123',
        token: 'alt',
        tokenProvider: () async => 'frisch${++n}',
        minBackoff: const Duration(milliseconds: 10),
        maxBackoff: const Duration(milliseconds: 40),
        pingInterval: const Duration(minutes: 5),
        channelFactory: (uri) {
          final c = FakeChannel();
          channels.add(c);
          scheduleMicrotask(c.server.greet);
          return c;
        },
      );
      await client.start();
      expect(channels.single.server.received.first['access_token'], 'frisch1');
      channels.single.server.close();
      await _until(() => channels.length == 2 && client.isConnected);
      expect(channels.last.server.received.first['access_token'], 'frisch2');
      await client.close();
    },
  );

  test('Token-Quelle: abgelehntes Token wird zweimal neu geholt', () async {
    final channels = <FakeChannel>[];
    final client = HaClient(
      url: 'http://ha.local:8123',
      token: 'alt',
      tokenProvider: () async => 'x',
      minBackoff: const Duration(milliseconds: 5),
      maxBackoff: const Duration(milliseconds: 10),
      pingInterval: const Duration(minutes: 5),
      channelFactory: (uri) {
        final c = FakeChannel();
        c.server.accept = channels.isNotEmpty;
        channels.add(c);
        scheduleMicrotask(c.server.greet);
        return c;
      },
    );
    await client.start();
    expect(channels.length, 2, reason: 'zweiter Versuch mit neuem Token');
    expect(client.isConnected, isTrue);
    await client.close();
  });
}
