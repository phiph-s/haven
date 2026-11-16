import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/data/ha/ha_client.dart';
import 'package:haven/data/ha/ha_zigbee.dart';
import 'package:haven/data/haven_repository.dart';
import 'package:haven/data/models/zigbee_network.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/zigbee/mesh/mesh_providers.dart';

import '../../support/fake_ha.dart';

ZbNetworkMap _map({
  int devices = 3,
  bool running = false,
  String? startedAt,
  String? lastError,
  String? timestamp = '2026-11-16T10:00:00+00:00',
  bool failed = false,
}) => ZbNetworkMap.fromJson({
  'nodes': [
    {'ieeeAddr': '0xc', 'friendlyName': 'Coordinator', 'type': 'Coordinator'},
    for (var i = 0; i < devices; i++)
      {
        'ieeeAddr': '0x$i',
        'friendlyName': 'Gerät $i',
        'type': 'Router',
        if (failed && i == 0) 'failed': ['lqi'],
      },
  ],
  'links': const [],
  'timestamp': ?timestamp,
  'running': running,
  'started_at': ?startedAt,
  'last_error': lastError,
});

/// Integration mit (oder ohne) Hintergrundmessung, Antworten steuert der Test.
class _Repo extends FakeRepository {
  _Repo({this.background = true}) : super(simulate: false);
  final bool background;
  ZbNetworkMap current = _map();
  final results = StreamController<ZbMeasureResult>.broadcast();
  int starts = 0;
  int loads = 0;
  Completer<ZbNetworkMap>? legacyPending;
  Object? startError;
  bool startRunning = false;

  @override
  bool get zigbeeBackgroundMeasure => background;

  @override
  Stream<ZbMeasureResult> get zigbeeMeasureResults => results.stream;

  @override
  Future<ZbMeasureStart> zigbeeStartNetworkMeasure() async {
    starts++;
    if (startError != null) throw startError!;
    return ZbMeasureStart(
      alreadyRunning: startRunning,
      startedAt: DateTime.utc(2026, 11, 16, 11),
    );
  }

  @override
  Future<ZbNetworkMap> zigbeeNetworkMap({bool refresh = false}) {
    if (refresh) return (legacyPending = Completer<ZbNetworkMap>()).future;
    loads++;
    return Future.value(current);
  }
}

ProviderContainer _container(_Repo repo, {Duration? poll}) {
  final c = ProviderContainer(
    overrides: [
      initialSessionProvider.overrideWithValue(Session(SessionMode.fake, repo)),
      meshPollIntervalProvider.overrideWithValue(
        poll ?? const Duration(hours: 1),
      ),
    ],
  );
  addTearDown(c.dispose);
  c.listen(zigbeeMeshProvider, (_, _) {});
  return c;
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  test('Parsing: running, started_at, last_error, failed je Knoten', () {
    final m = _map(
      running: true,
      startedAt: '2026-11-16T10:30:00+00:00',
      lastError: ' Gerät Lampe nicht erreichbar ',
      failed: true,
    );
    expect(m.status.running, isTrue);
    expect(m.status.startedAt, DateTime.utc(2026, 11, 16, 10, 30));
    expect(m.status.lastError, 'Gerät Lampe nicht erreichbar');
    expect(m.nodes.where((n) => n.failed).map((n) => n.name), ['Gerät 0']);
    expect(m.failedCount, 1);
    // Alte Integration: keine neuen Felder.
    final old = ZbNetworkMap.fromJson({
      'nodes': [
        {'ieeeAddr': '0x1', 'type': 'Router', 'failed': []},
      ],
      'links': [],
    });
    expect(old.status.running, isFalse);
    expect(old.status.lastError, isNull);
    expect(old.failedCount, 0);
    expect(ZbMeasureStatus.fromJson(const {'last_error': ''}).lastError, isNull);
  });

  test('Parsing: Start-Antwort und Ereignis', () {
    final s = ZbMeasureStart.fromJson(const {
      'status': 'running',
      'started_at': '2026-11-16T11:00:00+00:00',
    });
    expect(s.alreadyRunning, isTrue);
    expect(s.startedAt, DateTime.utc(2026, 11, 16, 11));
    expect(
      ZbMeasureStart.fromJson(const {'status': 'started'}).alreadyRunning,
      isFalse,
    );
    expect(
      ZbMeasureResult.fromJson(const {'ok': true, 'timestamp': 'x'}).ok,
      isTrue,
    );
    final e = ZbMeasureResult.fromJson(const {'ok': false, 'error': 'kaputt'});
    expect(e.ok, isFalse);
    expect(e.error, 'kaputt');
    expect(ZbMeasureResult.fromJson(const {'ok': false}).error, isNotNull);
  });

  test('Texte: Uhr, Stand, Meldung', () {
    expect(meshElapsedLabel(const Duration(seconds: 80)), '1:20');
    expect(meshElapsedLabel(const Duration(seconds: 5)), '0:05');
    expect(meshElapsedLabel(const Duration(seconds: 3723)), '1:02:03');
    expect(meshElapsedLabel(const Duration(seconds: -4)), '0:00');
    expect(meshDoneText(_map(devices: 43)), 'Netz gemessen, 43 Geräte');
    expect(meshDoneText(_map(devices: 1)), 'Netz gemessen, 1 Gerät');
    final now = DateTime(2026, 11, 16, 15);
    expect(
      meshStandLabel(DateTime(2026, 11, 16, 9, 5), now),
      'Stand von heute 09:05',
    );
    expect(
      meshStandLabel(DateTime(2026, 11, 15, 9, 5), now),
      'Stand von 15.11. 09:05',
    );
    expect(meshFailedText('x'), 'Messung fehlgeschlagen. x');
    for (final t in [meshDoneText(_map()), meshFailedText('x')]) {
      expect(t, isNot(contains('!')));
    }
  });

  test('Gestartet: Messung läuft, App bleibt bedienbar, Ereignis beendet', () async {
    final repo = _Repo();
    final c = _container(repo);
    await _settle();
    expect(c.read(zigbeeMeshProvider).loaded, isTrue);
    expect(c.read(zigbeeMeshProvider).refreshing, isFalse);

    expect(await c.read(zigbeeMeshProvider.notifier).refresh(), isNull);
    var d = c.read(zigbeeMeshProvider);
    expect(repo.starts, 1);
    expect(d.refreshing, isTrue);
    expect(d.legacy, isFalse);
    expect(d.refreshStarted, isNotNull);

    // Fertig: Ereignis, dann neu laden und melden.
    repo.current = _map(devices: 5, timestamp: '2026-11-16T11:05:00+00:00');
    repo.results.add(const ZbMeasureResult(ok: true));
    await _settle();
    d = c.read(zigbeeMeshProvider);
    expect(d.refreshing, isFalse);
    expect(d.map!.nodes, hasLength(6));
    expect(d.notice, 'Netz gemessen, 5 Geräte');
    expect(d.error, isNull);
  });

  test('Läuft schon: Öffnen zeigt die Messung sofort, Beginn aus der Integration', () async {
    final repo = _Repo()
      ..current = _map(running: true, startedAt: '2026-11-16T10:58:40+00:00');
    final c = _container(repo);
    await _settle();
    final d = c.read(zigbeeMeshProvider);
    expect(d.refreshing, isTrue);
    expect(d.refreshStarted, DateTime.utc(2026, 11, 16, 10, 58, 40));
    expect(d.map!.nodes, isNotEmpty); // alter Cache bleibt sichtbar
    expect(d.legacy, isFalse);
    // Zweiter Start ist wirkungslos.
    expect(await c.read(zigbeeMeshProvider.notifier).refresh(), isNull);
    expect(repo.starts, 0);
  });

  test('Läuft schon (Start meldet running): übernimmt started_at', () async {
    final repo = _Repo()..startRunning = true;
    final c = _container(repo);
    await _settle();
    await c.read(zigbeeMeshProvider.notifier).refresh();
    expect(
      c.read(zigbeeMeshProvider).refreshStarted,
      DateTime.utc(2026, 11, 16, 11),
    );
  });

  test('Rückfall: Abfrage alle 15 s erkennt das Ende ohne Ereignis', () async {
    final repo = _Repo();
    final c = _container(repo, poll: const Duration(milliseconds: 30));
    await _settle();
    await c.read(zigbeeMeshProvider.notifier).refresh();
    // Noch läuft sie.
    repo.current = _map(running: true, startedAt: '2026-11-16T11:00:00+00:00');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(c.read(zigbeeMeshProvider).refreshing, isTrue);
    repo.current = _map(devices: 7);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final d = c.read(zigbeeMeshProvider);
    expect(d.refreshing, isFalse);
    expect(d.notice, 'Netz gemessen, 7 Geräte');
    final loads = repo.loads;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(repo.loads, loads, reason: 'Abfragen enden mit der Messung');
  });

  test('Fehler per Ereignis: Text der Integration, alter Cache bleibt', () async {
    final repo = _Repo();
    final c = _container(repo);
    await _settle();
    await c.read(zigbeeMeshProvider.notifier).refresh();
    repo.results.add(
      const ZbMeasureResult(ok: false, error: 'Gerät Lampe 1 nicht erreichbar'),
    );
    await _settle();
    final d = c.read(zigbeeMeshProvider);
    expect(d.refreshing, isFalse);
    expect(d.error, contains('Gerät Lampe 1 nicht erreichbar'));
    expect(d.map!.nodes, hasLength(4));
    expect(d.map!.measuredAt, isNotNull);
    expect(d.notice, isNull);
  });

  test('Fehler beim Öffnen: last_error der Integration', () async {
    final repo = _Repo()..current = _map(lastError: 'Keine Antwort');
    final c = _container(repo);
    await _settle();
    final d = c.read(zigbeeMeshProvider);
    expect(d.refreshing, isFalse);
    expect(d.error, contains('Keine Antwort'));
    expect(d.map!.nodes, hasLength(4));
  });

  test('Start schlägt fehl (z. B. Z2M offline)', () async {
    final repo = _Repo()
      ..startError = HavenException('x', code: 'bridge_offline');
    final c = _container(repo);
    await _settle();
    final msg = await c.read(zigbeeMeshProvider.notifier).refresh();
    expect(msg, contains('offline'));
    expect(c.read(zigbeeMeshProvider).refreshing, isFalse);
  });

  test('Ereignis ohne laufende Messung: nur still neu laden', () async {
    final repo = _Repo();
    final c = _container(repo);
    await _settle();
    repo.current = _map(devices: 9);
    repo.results.add(const ZbMeasureResult(ok: true));
    await _settle();
    final d = c.read(zigbeeMeshProvider);
    expect(d.map!.nodes, hasLength(10));
    expect(d.notice, isNull);
  });

  test('Alte Integration: blockierend, Hinweis, Abbrechen möglich', () async {
    final repo = _Repo(background: false);
    final c = _container(repo);
    await _settle();
    final f = c.read(zigbeeMeshProvider.notifier).refresh();
    var d = c.read(zigbeeMeshProvider);
    expect(d.refreshing, isTrue);
    expect(d.legacy, isTrue);
    expect(repo.starts, 0);

    repo.legacyPending!.complete(_map(devices: 2));
    expect(await f, isNull);
    d = c.read(zigbeeMeshProvider);
    expect(d.refreshing, isFalse);
    expect(d.map!.nodes, hasLength(3));

    final g = c.read(zigbeeMeshProvider.notifier).refresh();
    repo.legacyPending!.completeError(HavenException('x', code: 'timeout'));
    final msg = await g;
    expect(msg, contains(meshLegacyHint));
    expect(c.read(zigbeeMeshProvider).error, contains(meshLegacyHint));
  });

  test('Neue Integration: Zeitüberschreitung nennt keinen Update-Hinweis', () {
    final t = meshErrorText(HavenException('x', code: 'timeout'), refresh: true);
    expect(t, isNot(contains(meshLegacyHint)));
  });

  test('HaZigbee: Start sendet refresh + background, Antwort sofort', () async {
    final client = HaClient(
      url: 'http://ha.local:8123',
      token: 't',
      requestTimeout: const Duration(milliseconds: 200),
      pingInterval: const Duration(minutes: 5),
      channelFactory: (_) {
        final c = FakeChannel();
        c.server.onMessage = (server, m) => server.send({
          'id': m['id'],
          'type': 'result',
          'success': true,
          'result': {
            'status': 'started',
            'started_at': '2026-11-16T11:00:00+00:00',
          },
        });
        scheduleMicrotask(c.server.greet);
        return c;
      },
    );
    await client.start();
    final zb = HaZigbee(client);
    final s = await zb.startMeasure();
    expect(s.alreadyRunning, isFalse);
    expect(s.startedAt, DateTime.utc(2026, 11, 16, 11));
    await zb.dispose();
    await client.close();
  });
}
