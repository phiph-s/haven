import 'dart:convert';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/data/ha/ha_client.dart';
import 'package:haven/data/ha/ha_repository.dart';
import 'package:haven/data/haven_repository.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/data/models/room.dart';
import 'package:haven/data/models/widget_config.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/data/sync/app_data.dart';
import 'package:haven/data/sync/doc_sync.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/map/floor_plan_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_ha.dart';
import 'support/live_fixtures.dart';

/// Zählt Speichervorgänge und kann sie ablehnen.
class _CountingRepo extends FakeRepository {
  _CountingRepo() : super(simulate: false);
  final stores = <(AppDataKind, Map<String, dynamic>, int)>[];
  String? failWith;

  @override
  Future<void> storeAppData(
    AppDataKind kind,
    Map<String, dynamic> data,
    int updatedAt,
  ) async {
    if (failWith != null) throw HavenException('nein', code: failWith);
    stores.add((kind, data, updatedAt));
    await super.storeAppData(kind, data, updatedAt);
  }
}

class _MemoryPlans implements FloorPlanRepository {
  _MemoryPlans([this.plan]);
  HavenFloorPlan? plan;
  @override
  Future<HavenFloorPlan?> load() async => plan;
  @override
  Future<void> save(HavenFloorPlan p) async => plan = p;
  @override
  Future<void> clear() async => plan = null;
}

Future<void> until(bool Function() cond) async {
  for (var i = 0; i < 200 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(cond(), isTrue);
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

Future<SettingsStore> _store([Map<String, Object> init = const {}]) async {
  SharedPreferences.setMockInitialValues(init);
  return SettingsStore(await SharedPreferences.getInstance());
}

void main() {
  group('decideSync', () {
    const remote = RemoteDoc(data: {'x': 1}, updatedAt: 200);
    SyncAction decide({
      bool hasLocal = true,
      bool dirty = false,
      int? base,
      RemoteDoc r = remote,
    }) => decideSync(
      hasLocal: hasLocal,
      localDirty: dirty,
      baseStamp: base,
      remote: r,
    );

    test('Server leer: lokal hochladen (Migration) oder nichts', () {
      expect(decide(r: RemoteDoc.empty), SyncAction.upload);
      expect(decide(hasLocal: false, r: RemoteDoc.empty), SyncAction.none);
    });
    test('Server == baseStamp: dirty lädt hoch, sonst nichts', () {
      expect(decide(dirty: true, base: 200), SyncAction.upload);
      expect(decide(base: 200), SyncAction.none);
    });
    test('Server != baseStamp: dirty ist Konflikt, sonst Übernahme', () {
      expect(decide(dirty: true, base: 100), SyncAction.conflict);
      // Auch wenn die lokale Uhr "später" geht: Uhrzeiten zählen nicht.
      expect(decide(dirty: true, base: 999), SyncAction.conflict);
      expect(decide(base: 100), SyncAction.takeRemote);
    });
    test('Ohne baseStamp (alte Installation): Server gilt', () {
      expect(decide(dirty: true), SyncAction.takeRemote);
      expect(decide(), SyncAction.takeRemote);
    });
    test('Neues Gerät ohne eigenen Stand: Server', () {
      expect(decide(hasLocal: false), SyncAction.takeRemote);
    });
    test('Stempel: Millisekunden, Sekunden, ISO', () {
      expect(parseStamp(1763200000000), 1763200000000);
      expect(parseStamp(1763200000), 1763200000000);
      expect(parseStamp('1763200000000'), 1763200000000);
      expect(
        parseStamp('2026-11-15T10:00:00Z'),
        DateTime.utc(2026, 11, 15, 10).millisecondsSinceEpoch,
      );
      expect(parseStamp(null), isNull);
    });
    test('Fehlertexte nach Ursache', () {
      final e = HavenException('x', code: 'unauthorized');
      expect(
        syncErrorText(e, AppDataKind.floorplan),
        contains('Administrator'),
      );
      expect(
        syncErrorText(
          HavenException('x', code: 'disconnected'),
          AppDataKind.widgets,
        ),
        isNull,
      );
    });
  });

  group('DocSync', () {
    late _CountingRepo repo;
    late SettingsStore store;
    Map<String, dynamic>? local;
    final errors = <String>[];
    late DocSync sync;

    setUp(() async {
      repo = _CountingRepo();
      store = await _store();
      local = null;
      errors.clear();
      sync = DocSync(
        kind: AppDataKind.widgets,
        repo: repo,
        store: store,
        debounce: const Duration(milliseconds: 40),
        readLocal: () => local,
        applyRemote: (d) async {
          local = d;
          return true;
        },
        onError: errors.add,
      );
    });
    tearDown(() => sync.dispose());

    test('Migration: Server leer, lokal da: wird hochgeladen', () async {
      local = {'widgets': <dynamic>[], 'layout': null};
      sync.start();
      await _settle();
      expect(repo.stores, hasLength(1));
      expect((await repo.fetchAppData(AppDataKind.widgets)).isEmpty, isFalse);
    });

    test(
      'Entprellt: viele Änderungen, ein Speichern mit dem letzten Stand',
      () async {
        sync.start();
        await _settle();
        for (var i = 0; i < 5; i++) {
          local = {'n': i};
          await sync.changed();
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(repo.stores, isEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(repo.stores, hasLength(1));
        expect(repo.stores.single.$2, {'n': 4});
        expect(sync.dirty, isFalse);
      },
    );

    test(
      'Anderes Gerät speichert: Ereignis, neuer Stand wird übernommen',
      () async {
        local = {'n': 1};
        await store.setSync('widgets', stamp: 100, dirty: false);
        await repo.storeAppData(AppDataKind.widgets, {'n': 1}, 100);
        sync.start();
        await _settle();
        // Das zweite Gerät schreibt direkt in HA, das Ereignis kommt.
        await repo.storeAppData(AppDataKind.widgets, {'n': 2}, 500);
        await _settle();
        expect(local, {'n': 2});
        expect(sync.stamp, 500);
      },
    );

    test('Ohne Admin-Rechte: Hinweis, kein Endlosversuch', () async {
      repo.failWith = 'unauthorized';
      sync.start();
      await _settle();
      local = {'n': 1};
      await sync.changed();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(errors.single, contains('Administrator'));
      expect(sync.dirty, isFalse);
    });

    test(
      'Offline: bleibt offen und wird beim nächsten Abgleich hochgeladen',
      () async {
        await repo.storeAppData(AppDataKind.widgets, {'n': 0}, 1);
        await store.setSync('widgets', stamp: 1, dirty: false, base: 1);
        local = {'n': 0};
        repo.failWith = 'disconnected';
        sync.start();
        await _settle();
        local = {'n': 7};
        await sync.changed();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(errors, isEmpty);
        expect(sync.dirty, isTrue);
        repo.failWith = null;
        await sync.pull();
        // Server unverändert (== baseStamp) und lokal offen: hoch.
        expect(repo.stores.last.$2, {'n': 7});
      },
    );
    test(
      'Offline-Fehler (disconnected, timeout) bleiben dirty, still',
      () async {
        sync.start();
        await _settle();
        for (final code in ['disconnected', 'timeout']) {
          repo.failWith = code;
          local = {'n': 1};
          await sync.changed();
          await sync.flush();
          expect(sync.dirty, isTrue, reason: code);
          expect(errors, isEmpty, reason: code);
        }
      },
    );

    test('Anderer Fehler: Code und Text sichtbar, Server gilt', () async {
      await repo.storeAppData(AppDataKind.widgets, {'n': 'server'}, 500);
      await store.setSync('widgets', stamp: 500, dirty: false, base: 500);
      local = {'n': 'server'};
      sync.start();
      await _settle();
      repo.failWith = 'home_assistant_error';
      local = {'n': 'lokal'};
      await sync.changed();
      await sync.flush();
      await _settle();
      expect(errors.single, contains('home_assistant_error'));
      expect(errors.single, contains('nein'));
      expect(sync.dirty, isFalse);
      expect(local, {'n': 'server'});
      expect(sync.info.value.state, SyncState.error);
      expect(sync.info.value.lastError, contains('home_assistant_error'));
      // Und es gibt keinen Endlosversuch beim nächsten Abgleich.
      repo.failWith = null;
      final before = repo.stores.length;
      await sync.pull();
      expect(repo.stores.length, before);
    });

    test('Erfolgreiches Speichern merkt den Stand als Basis', () async {
      sync.start();
      await _settle();
      local = {'n': 1};
      await sync.changed();
      await sync.flush();
      expect(sync.dirty, isFalse);
      expect(sync.baseStamp, sync.stamp);
      expect(sync.baseStamp, repo.stores.last.$3);
    });

    test('Konflikt: Server gewinnt, Hinweis, lokale Änderung weg', () async {
      await repo.storeAppData(AppDataKind.widgets, {'n': 'server'}, 500);
      local = {'n': 'lokal'};
      // Die lokale Uhr geht vor: Stempel nach der Server-Zeit, dirty.
      await store.setSync('widgets', stamp: 9000, dirty: true, base: 100);
      sync.start();
      await _settle();
      expect(local, {'n': 'server'});
      expect(errors.single, contains('anderen Gerät'));
      expect(repo.stores.length, 1); // nur die Vorbereitung oben
      expect(sync.dirty, isFalse);
      expect(sync.baseStamp, 500);
    });

    test('„Stand übernehmen“ verwirft die lokale Fassung', () async {
      await repo.storeAppData(AppDataKind.widgets, {'n': 'server'}, 500);
      local = {'n': 'lokal'};
      await store.setSync('widgets', stamp: 600, dirty: true, base: 500);
      final msg = await sync.takeRemoteNow();
      expect(msg, contains('übernommen'));
      expect(local, {'n': 'server'});
      expect(sync.dirty, isFalse);
      expect(sync.baseStamp, 500);
    });
  });

  group('Grundriss und Übersicht über Provider', () {
    Future<(ProviderContainer, _CountingRepo, SettingsStore)> make({
      HavenFloorPlan? localPlan,
      Map<String, Object> prefs = const {},
    }) async {
      final store = await _store(prefs);
      final repo = _CountingRepo();
      await repo.start();
      final c = ProviderContainer(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          initialSessionProvider.overrideWithValue(
            Session(SessionMode.fake, repo),
          ),
          floorPlanRepositoryProvider.overrideWithValue(
            _MemoryPlans(localPlan),
          ),
        ],
      );
      addTearDown(c.dispose);
      return (c, repo, store);
    }

    test('lokaler Grundriss wandert nach HA, wenn dort keiner liegt', () async {
      final (c, repo, _) = await make(localPlan: kFakeFloorPlan);
      final sub = c.listen(floorPlanProvider, (_, _) {});
      addTearDown(sub.close);
      await c.read(floorPlanProvider.future);
      await _settle();
      final remote = await repo.fetchAppData(AppDataKind.floorplan);
      expect(remote.isEmpty, isFalse);
      expect(
        HavenFloorPlan.fromJson(
          Map<String, dynamic>.from(remote.data!['plan'] as Map),
        ).rooms,
        hasLength(kFakeFloorPlan.rooms.length),
      );
    });

    test('Grundriss aus HA gewinnt auf einem neuen Gerät', () async {
      final (c, repo, _) = await make();
      final small = kFakeFloorPlan.withoutRoom(kFakeFloorPlan.rooms.first.id);
      await repo.storeAppData(AppDataKind.floorplan, {
        'plan': small.toJson(),
      }, 1000);
      final sub = c.listen(floorPlanProvider, (_, _) {});
      addTearDown(sub.close);
      await c.read(floorPlanProvider.future);
      await _settle();
      expect(
        c.read(floorPlanProvider).value!.rooms,
        hasLength(kFakeFloorPlan.rooms.length - 1),
      );
      // Speichern geht wieder nach HA.
      await c.read(floorPlanProvider.notifier).save(kFakeFloorPlan);
      await _settle();
      expect(repo.stores.last.$1, AppDataKind.floorplan);
    });

    test('Laden und Migration lösen kein Speichern aus', () async {
      final v1 = HavenFloorPlan.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(
                jsonEncode({
                  'version': 1,
                  'grid': {'cols': 20, 'rows': 26, 'cellMeters': 0.5},
                  'rooms': [
                    {
                      'id': 'wz',
                      'name': 'Wohnen',
                      'x': 0,
                      'y': 0,
                      'w': 10,
                      'h': 8,
                    },
                  ],
                  'placements': <dynamic>[],
                }),
              )
              as Map,
        ),
      );
      expect(v1.migratedFrom, 1);
      final (c, repo, store) = await make(localPlan: v1);
      await repo.storeAppData(AppDataKind.floorplan, {
        'plan': v1.toJson(),
      }, 1000);
      await store.setSync('floorplan', stamp: 1000, dirty: false, base: 1000);
      final before = repo.stores.length;
      final sub = c.listen(floorPlanProvider, (_, _) {});
      addTearDown(sub.close);
      await c.read(floorPlanProvider.future);
      await _settle();
      expect(repo.stores.length, before);
      expect(store.syncDirty('floorplan'), isFalse);
      // Speichern desselben Plans ist keine Änderung.
      await c.read(floorPlanProvider.notifier).save(v1);
      await _settle();
      expect(repo.stores.length, before);
      expect(store.syncDirty('floorplan'), isFalse);
    });

    test('Übersicht: unveränderte Reihenfolge speichert nicht', () async {
      final (c, repo, store) = await make();
      final sub = c.listen(homeLayoutProvider, (_, _) {});
      addTearDown(sub.close);
      await _settle();
      final n = repo.stores.length;
      c.read(homeLayoutProvider.notifier).setRoomOrder(const []);
      await _settle();
      expect(repo.stores.length, n);
      expect(store.syncDirty('widgets'), isFalse);
    });

    test(
      'Handy mit altem Cache und dirty-Stempel nach Server-Zeit bekommt die Möbel',
      () async {
        final old = kFakeFloorPlan.copyWith(furniture: const []);
        expect(old.furniture, isEmpty);
        expect(kFakeFloorPlan.furniture, isNotEmpty);
        final (c, repo, store) = await make(localPlan: old);
        // Server: Plan mit Möbeln aus dem Panel, 11:18.
        await repo.storeAppData(AppDataKind.floorplan, {
          'plan': kFakeFloorPlan.toJson(),
        }, 1794827886440);
        // Handy: lokal "geändert" nach 11:18 (Migration der alten Version),
        // nie mit dem Server abgeglichen (kein baseStamp).
        await store.setSync(
          'floorplan',
          stamp: 1794827886440 + 3600000,
          dirty: true,
        );
        final before = repo.stores.length;
        final sub = c.listen(floorPlanProvider, (_, _) {});
        addTearDown(sub.close);
        await c.read(floorPlanProvider.future);
        await _settle();
        expect(
          c.read(floorPlanProvider).value!.furniture,
          hasLength(kFakeFloorPlan.furniture.length),
        );
        expect(repo.stores.length, before, reason: 'nichts hochgeladen');
        expect(store.syncDirty('floorplan'), isFalse);
        expect(store.syncBase('floorplan'), 1794827886440);
        final info = c.read(syncRegistryProvider).docs[AppDataKind.floorplan]!;
        expect(info.info.value.state, SyncState.current);
        expect(info.info.value.remoteSummary, contains('Möbel'));
      },
    );

    test(
      'Reihenfolge der Räume: sortiert, synchron, neue Räume ans Ende',
      () async {
        final (c, repo, store) = await make();
        final sub = c.listen(homeLayoutProvider, (_, _) {});
        addTearDown(sub.close);
        await _settle();
        c.read(homeLayoutProvider.notifier).setRoomOrder([
          'waschraum',
          'salon',
        ]);
        await _settle();
        expect(store.roomOrder, ['waschraum', 'salon']);
        final doc = await repo.fetchAppData(AppDataKind.widgets);
        expect((doc.data!['layout'] as Map)['room_order'], [
          'waschraum',
          'salon',
        ]);
        final rooms = c.read(orderedRoomsProvider).map((r) => r.id).toList();
        expect(rooms.take(2), ['waschraum', 'salon']);
        expect(rooms.length, c.read(roomsProvider).length);

        // Ein anderes Gerät stellt um.
        await repo.storeAppData(AppDataKind.widgets, {
          'widgets': [
            for (final w in HavenWidgetConfig.defaults.take(1)) w.toJson(),
          ],
          'layout': {
            'room_order': ['kochbereich'],
          },
        }, DateTime.now().millisecondsSinceEpoch + 10000);
        await _settle();
        expect(c.read(homeLayoutProvider).roomOrder, ['kochbereich']);
        expect(c.read(homeLayoutProvider).widgets, hasLength(1));
        // Altes Format: Kopf, Hinweise, Szenen und Räume kommen dazu.
        expect(c.read(widgetsProvider).where((w) => !w.isMain), hasLength(1));
        expect(c.read(orderedRoomsProvider).first.id, 'kochbereich');
      },
    );

    test('sortRooms', () {
      const rooms = [
        Room(id: 'a', name: 'A', lightIds: []),
        Room(id: 'b', name: 'B', lightIds: []),
        Room(id: 'c', name: 'C', lightIds: []),
      ];
      expect(sortRooms(rooms, const []).map((r) => r.id), ['a', 'b', 'c']);
      expect(sortRooms(rooms, const ['c', 'x', 'a']).map((r) => r.id), [
        'c',
        'a',
        'b',
      ]);
    });
  });

  group('HaRepository: Befehle und Ereignis', () {
    Future<(HaRepository, LiveHa)> start({bool v3 = true}) async {
      final live = LiveHa();
      if (v3) {
        live.answers['haven/info'] = (_) => {
          ...Map<String, dynamic>.from(liveJson('info') as Map),
          'version': '0.3.0',
          'features': ['light_groups', 'room_devices', 'prefs', 'data_events'],
        };
      }
      Map<String, dynamic>? plan;
      Object? planAt;
      live.answers['haven/floorplan/get'] = (_) => {
        'plan': plan,
        'updated_at': planAt,
      };
      live.answers['haven/floorplan/set'] = (m) {
        plan = Map<String, dynamic>.from(m['plan'] as Map);
        planAt = m['updated_at'];
        return {'ok': true};
      };
      live.answers['haven/widgets/get'] = (_) => {'widgets': null};
      live.answers['haven/widgets/set'] = (_) => {'ok': true};
      final client = HaClient(
        url: 'http://ha.local:8123',
        token: 't',
        pingInterval: const Duration(minutes: 5),
        channelFactory: (_) {
          final c = FakeChannel();
          live.channels.add(c);
          c.server.onMessage = live.respond;
          scheduleMicrotask(c.server.greet);
          return c;
        },
      );
      final repo = HaRepository(url: 'x', token: 'y', client: client);
      await repo.start();
      await until(() => repo.snapshot.rooms.isNotEmpty);
      return (repo, live);
    }

    test('0.3.0: Stempel und Layout werden mitgeschickt', () async {
      final (repo, live) = await start();
      expect(live.subscriptions, contains('haven_data_updated'));
      await repo.storeAppData(AppDataKind.floorplan, {
        'plan': kFakeFloorPlan.toJson(),
      }, 1763200001234);
      final set = live.received.lastWhere(
        (m) => m['type'] == 'haven/floorplan/set',
      );
      expect(set['updated_at'], 1763200001234);
      expect((set['plan'] as Map)['updatedAt'], 1763200001234);
      final got = await repo.fetchAppData(AppDataKind.floorplan);
      expect(got.updatedAt, 1763200001234);
      await repo.storeAppData(AppDataKind.widgets, {
        'widgets': <dynamic>[],
        'layout': {
          'room_order': ['a'],
        },
      }, 99);
      final w = live.received.lastWhere(
        (m) => m['type'] == 'haven/widgets/set',
      );
      expect(w['layout'], {
        'room_order': ['a'],
      });
      expect(w['updated_at'], 99);
      expect((await repo.fetchAppData(AppDataKind.widgets)).isEmpty, isTrue);
      await repo.dispose();
    });

    test('0.2.0: keine unbekannten Felder, Stempel steckt im Plan', () async {
      final (repo, live) = await start(v3: false);
      await repo.storeAppData(AppDataKind.widgets, {
        'widgets': <dynamic>[],
        'layout': {'room_order': <String>[]},
      }, 99);
      final w = live.received.lastWhere(
        (m) => m['type'] == 'haven/widgets/set',
      );
      expect(w.containsKey('layout'), isFalse);
      expect(w.containsKey('updated_at'), isFalse);
      await repo.storeAppData(AppDataKind.floorplan, {
        'plan': kFakeFloorPlan.toJson(),
      }, 1763200000055);
      final f = live.received.lastWhere(
        (m) => m['type'] == 'haven/floorplan/set',
      );
      expect(f.containsKey('updated_at'), isFalse);
      // Ohne updated_at liest die App den Stempel aus dem Plan.
      expect(
        (await repo.fetchAppData(AppDataKind.floorplan)).updatedAt,
        1763200000055,
      );
      await repo.dispose();
    });

    test('haven_data_updated meldet die Art, Prefs laden neu', () async {
      final (repo, live) = await start();
      final kinds = <AppDataKind>[];
      final sub = repo.appDataChanges.listen(kinds.add);
      live.fire('haven_data_updated', {'kind': 'floorplan'});
      live.prefs = {
        'excluded_lights': ['light.lampe_salon'],
      };
      live.fire('haven_data_updated', {'kind': 'prefs'});
      await until(() => repo.snapshot.excludedLights.isNotEmpty);
      expect(kinds, [AppDataKind.floorplan, AppDataKind.prefs]);
      expect(repo.snapshot.excludedLights, {'light.lampe_salon'});
      await sub.cancel();
      await repo.dispose();
    });

    test('Speichern ohne Admin: Fehlercode kommt an', () async {
      final (repo, live) = await start();
      live.answers['haven/floorplan/set'] = (_) => const HaFail('unauthorized');
      await expectLater(
        repo.storeAppData(AppDataKind.floorplan, {
          'plan': <String, dynamic>{},
        }, 1),
        throwsA(
          isA<HavenException>().having((e) => e.code, 'code', 'unauthorized'),
        ),
      );
      await repo.dispose();
    });
  });
}
