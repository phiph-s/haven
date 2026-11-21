// Mehrere Geräte an einem Home Assistant: veraltete Stände dürfen neuere
// nicht überschreiben (siehe `data/sync/doc_sync.dart`, Revisionen).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/ha/ha_client.dart';
import 'package:haven/data/ha/ha_repository.dart';
import 'package:haven/data/models/furniture.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/data/sync/app_data.dart';
import 'package:haven/data/sync/doc_sync.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/map/floor_plan_store.dart';

import 'support/fake_ha.dart';
import 'support/live_fixtures.dart';

/// HA mit den geteilten Dokumenten. [revisions] `false`: Integration vor
/// dem Feature `revisions` (speichert ohne Prüfung, keine Revision).
class _Server extends FakeRepository {
  _Server({this.revisions = true}) : super(simulate: false);
  final bool revisions;
  int stores = 0;
  final _plain = <AppDataKind, RemoteDoc>{};

  @override
  bool get appDataRevisions => revisions;

  @override
  Future<RemoteDoc> fetchAppData(AppDataKind kind) async {
    await Future<void>.delayed(Duration.zero);
    if (!revisions) return _plain[kind] ?? RemoteDoc.empty;
    return super.fetchAppData(kind);
  }

  @override
  Future<int?> storeAppData(
    AppDataKind kind,
    Map<String, dynamic> data,
    int updatedAt, {
    int? baseRevision,
  }) async {
    await Future<void>.delayed(Duration.zero);
    stores++;
    if (!revisions) {
      _plain[kind] = RemoteDoc(data: data, updatedAt: updatedAt);
      emitAppData(kind);
      return null;
    }
    return super.storeAppData(
      kind,
      data,
      updatedAt,
      baseRevision: baseRevision,
    );
  }
}

/// Ein Gerät: eigener Abgleich-Zustand, eigener lokaler Stand. Schläft es
/// (App im Hintergrund), verpasst es die Ereignisse.
class _Device {
  _Device(this.name, this.server, {this.local}) {
    sync = DocSync(
      kind: AppDataKind.widgets,
      repo: _Link(this),
      store: state,
      debounce: const Duration(milliseconds: 40),
      readLocal: () => local,
      applyRemote: (d) async {
        local = d;
        return true;
      },
      onError: notes.add,
    );
  }

  final String name;
  final _Server server;
  final state = MemorySyncState();
  final notes = <String>[];
  Map<String, dynamic>? local;
  bool asleep = false;
  late final DocSync sync;

  Future<void> edit(Map<String, dynamic> next) async {
    local = next;
    await sync.changed();
  }
}

/// Leitet an den gemeinsamen [_Server] weiter, Ereignisse nur wach.
class _Link extends FakeRepository {
  _Link(this.device) : super(simulate: false);
  final _Device device;

  @override
  bool get appDataRevisions => device.server.appDataRevisions;
  @override
  Stream<AppDataKind> get appDataChanges =>
      device.server.appDataChanges.where((_) => !device.asleep);
  @override
  Future<RemoteDoc> fetchAppData(AppDataKind kind) =>
      device.server.fetchAppData(kind);
  @override
  Future<int?> storeAppData(
    AppDataKind kind,
    Map<String, dynamic> data,
    int updatedAt, {
    int? baseRevision,
  }) => device.server.storeAppData(
    kind,
    data,
    updatedAt,
    baseRevision: baseRevision,
  );
}

Map<String, dynamic> _doc(List<String> ids, {Map<String, String>? titles}) => {
  'widgets': [
    for (final id in ids)
      {
        'id': id,
        'type': 'power',
        'options': {'title': titles?[id] ?? id},
      },
  ],
  'layout': {'room_order': <String>[]},
};

List<String> _ids(Map<String, dynamic>? d) => [
  for (final w in (d?['widgets'] as List? ?? const [])) '${(w as Map)['id']}',
];

String? _title(Map<String, dynamic>? d, String id) {
  for (final w in (d?['widgets'] as List? ?? const [])) {
    if ((w as Map)['id'] == id) return (w['options'] as Map)['title'] as String;
  }
  return null;
}

Future<void> until(bool Function() cond) async {
  for (var i = 0; i < 200 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(cond(), isTrue);
}

Future<void> _settle([int ms = 200]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

Future<Map<String, dynamic>?> _onServer(_Server s) async =>
    (await s.fetchAppData(AppDataKind.widgets)).data;

void main() {
  group('Zwei Geräte, ein Home Assistant', () {
    late _Server server;
    late _Device desktop;
    late _Device phone;

    Future<void> startBoth({bool revisions = true}) async {
      server = _Server(revisions: revisions);
      desktop = _Device('Desktop', server, local: _doc(['a']));
      phone = _Device('Telefon', server);
      desktop.sync.start();
      await _settle();
      phone.sync.start();
      await _settle();
      expect(_ids(phone.local), ['a']);
    }

    tearDown(() {
      desktop.sync.dispose();
      phone.sync.dispose();
    });

    test('Laden und Abgleichen speichern nichts ohne Änderung', () async {
      await startBoth();
      expect(server.stores, 1); // nur die erste Migration des Desktops
      await desktop.sync.pull();
      await phone.sync.pull();
      await _settle();
      expect(server.stores, 1);
      expect(desktop.sync.dirty || phone.sync.dirty, isFalse);
    });

    test('Telefon im Hintergrund verpasst das Speichern des Desktops: sein alter '
        'Stand wird abgelehnt und zusammengeführt', () async {
      await startBoth();
      phone.asleep = true;
      await desktop.edit(_doc(['a', 'b'], titles: {'a': 'Desktop'}));
      await _settle();
      expect(_ids(await _onServer(server)), ['a', 'b']);
      // Telefon wacht auf und ändert seinen (alten) Stand, bevor es abgleicht.
      phone.asleep = false;
      await phone.edit(_doc(['a', 'c']));
      await _settle(400);
      final s = await _onServer(server);
      expect(_ids(s), ['a', 'b', 'c']);
      expect(_title(s, 'a'), 'Desktop', reason: 'Titel des Desktops bleibt');
      expect(_ids(phone.local), ['a', 'b', 'c']);
      expect(_ids(desktop.local), ['a', 'b', 'c']);
      expect(phone.sync.dirty, isFalse);
      expect(phone.notes, isEmpty, reason: 'ohne Überschneidung kein Hinweis');
    });

    test('Uhr des Telefons geht weit vor: zählt nicht', () async {
      await startBoth();
      phone.asleep = true;
      await desktop.edit(_doc(['a', 'b']));
      await _settle();
      phone.asleep = false;
      // Stempel weit in der Zukunft, wie bei einer falsch gehenden Uhr.
      await phone.state.setSync('widgets', stamp: 1 << 50, dirty: false);
      await phone.edit(_doc(['a', 'c']));
      await _settle(400);
      expect(_ids(await _onServer(server)), ['a', 'b', 'c']);
    });

    test('Speichern des anderen Geräts während der Entprellung geht nicht verloren', () async {
      await startBoth();
      await desktop.edit(_doc(['a', 'x']));
      // Desktop wartet noch (40 ms), da speichert das Telefon.
      await phone.edit(_doc(['a', 'p']));
      await phone.sync.flush();
      await _settle(400);
      final s = await _onServer(server);
      expect(_ids(s)..sort(), ['a', 'p', 'x']);
      expect(_ids(desktop.local)..sort(), ['a', 'p', 'x']);
      expect(_ids(phone.local)..sort(), ['a', 'p', 'x']);
    });

    test('Beide ändern dieselbe Stelle: lokal gilt, mit Hinweis', () async {
      await startBoth();
      phone.asleep = true;
      await desktop.edit(_doc(['a'], titles: {'a': 'Desktop'}));
      await _settle();
      phone.asleep = false;
      await phone.edit(_doc(['a'], titles: {'a': 'Telefon'}));
      await _settle(400);
      expect(_title(await _onServer(server), 'a'), 'Telefon');
      expect(phone.notes.single, contains('gleichzeitig'));
    });

    test(
      'Ältere Integration ohne Revisionen: App prüft vorher selbst',
      () async {
        await startBoth(revisions: false);
        phone.asleep = true;
        await desktop.edit(_doc(['a', 'b']));
        await _settle();
        phone.asleep = false;
        await phone.edit(_doc(['a', 'c']));
        await _settle(400);
        expect(_ids(await _onServer(server)), ['a', 'b', 'c']);
      },
    );

    test('Alte App ohne base_revision speichert: neuere erkennen es an der '
        'Revision', () async {
      await startBoth();
      // Wie eine App vor dieser Version: gleicher Stempel, keine Revision.
      final before = await server.fetchAppData(AppDataKind.widgets);
      await server.storeAppData(
        AppDataKind.widgets,
        _doc(['a', 'alt']),
        before.updatedAt!,
      );
      await _settle();
      expect(_ids(desktop.local), ['a', 'alt']);
      expect(_ids(phone.local), ['a', 'alt']);
    });

    test('Ausstehende Änderung beim Abbau: bleibt offen, kein ungeprüftes '
        'Hochladen', () async {
      await startBoth();
      await desktop.edit(_doc(['a', 'z']));
      final stores = server.stores;
      desktop.sync.dispose();
      await _settle();
      expect(server.stores, stores);
      expect(desktop.state.syncDirty('widgets'), isTrue);
    });
  });

  group('mergeDocs', () {
    test('Listen je id: hinzufügen, löschen, ändern', () {
      final base = _doc(['a', 'b', 'c']);
      final local = _doc(['a', 'c', 'l'], titles: {'c': 'C lokal'});
      final remote = _doc(['a', 'b', 'c', 'r'], titles: {'a': 'A remote'});
      final m = mergeDocs(base, local, remote);
      // Neues von dort zuerst, dann das von hier.
      expect(_ids(m.doc), ['a', 'c', 'r', 'l']);
      expect(_title(m.doc, 'a'), 'A remote');
      expect(_title(m.doc, 'c'), 'C lokal');
      expect(m.overlaps, 0);
    });

    test('Gelöscht hier, remote geändert: bleibt (keine Daten weg)', () {
      final m = mergeDocs(
        _doc(['a', 'b']),
        _doc(['a']),
        _doc(['a', 'b'], titles: {'b': 'neu'}),
      );
      expect(_ids(m.doc), ['a', 'b']);
      expect(_title(m.doc, 'b'), 'neu');
    });

    test('Umsortieren hier, neues Element remote: beides', () {
      final m = mergeDocs(
        _doc(['a', 'b', 'c']),
        _doc(['c', 'b', 'a']),
        _doc(['a', 'b', 'c', 'd']),
      );
      // d folgt wie dort auf c, die Reihenfolge von hier bleibt.
      expect(_ids(m.doc), ['c', 'd', 'b', 'a']);
    });

    test('Überschneidung zählt, lokal gilt', () {
      final m = mergeDocs({'x': 1, 'y': 1}, {'x': 2, 'y': 1}, {'x': 3, 'y': 5});
      expect(m.doc, {'x': 2, 'y': 5});
      expect(m.overlaps, 1);
    });

    test('Grundriss: Raum umbenannt dort, Möbel hier dazu', () {
      final base = kFakeFloorPlan;
      final remote = base.withRoom(
        base.room('salon')!.copyWith(name: 'Wohnzimmer'),
      );
      final local = base.withFurniture(
        const FloorFurniture(id: 'neu', kind: 'sofa', x: 4, y: 4, w: 2, h: 1),
      );
      final merged = rebasePlan(base, local, remote);
      expect(merged.room('salon')!.name, 'Wohnzimmer');
      expect(merged.furnitureById('neu'), isNotNull);
      expect(merged.furniture.length, base.furniture.length + 1);
    });
  });

  group('HaRepository mit Revisionen', () {
    Future<(HaRepository, LiveHa)> start({bool revisions = true}) async {
      final live = LiveHa();
      live.answers['haven/info'] = (_) => {
        ...Map<String, dynamic>.from(liveJson('info') as Map),
        'features': [
          'light_groups',
          'room_devices',
          'prefs',
          'data_events',
          if (revisions) 'revisions',
        ],
      };
      var prefsRev = 4;
      live.answers['haven/prefs/get'] = (_) => {
        'prefs': live.prefs,
        'revision': prefsRev,
      };
      live.answers['haven/prefs/set'] = (m) {
        if (m.containsKey('base_revision') && m['base_revision'] != prefsRev) {
          return const HaFail('conflict');
        }
        live.prefs = Map<String, dynamic>.from(m['prefs'] as Map);
        prefsRev++;
        return {'ok': true, 'prefs': live.prefs, 'revision': prefsRev};
      };
      live.answers['haven/widgets/get'] = (_) => {
        'widgets': <dynamic>[],
        'layout': null,
        'updated_at': 5,
        'revision': 7,
      };
      live.answers['haven/widgets/set'] = (m) => {'ok': true, 'revision': 8};
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

    test('base_revision geht mit, neue Revision kommt zurück', () async {
      final (repo, live) = await start();
      expect(repo.appDataRevisions, isTrue);
      final got = await repo.fetchAppData(AppDataKind.widgets);
      expect(got.revision, 7);
      final rev = await repo.storeAppData(
        AppDataKind.widgets,
        {'widgets': <dynamic>[], 'layout': null},
        9,
        baseRevision: 7,
      );
      expect(rev, 8);
      final set = live.received.lastWhere(
        (m) => m['type'] == 'haven/widgets/set',
      );
      expect(set['base_revision'], 7);
      await repo.dispose();
    });

    test(
      'Ältere Integration: kein base_revision (Schema lehnt es ab)',
      () async {
        final (repo, live) = await start(revisions: false);
        expect(repo.appDataRevisions, isFalse);
        await repo.storeAppData(
          AppDataKind.widgets,
          {'widgets': <dynamic>[], 'layout': null},
          9,
          baseRevision: 7,
        );
        final set = live.received.lastWhere(
          (m) => m['type'] == 'haven/widgets/set',
        );
        expect(set.containsKey('base_revision'), isFalse);
        await repo.dispose();
      },
    );

    test('Prefs: anderes Gerät hat inzwischen gesperrt, Ausnahme hier wird '
        'neu angewendet statt die Sperre zu löschen', () async {
      final (repo, live) = await start();
      // Anderes Gerät speichert eine Sperre, das Ereignis fehlt hier.
      live.answers['haven/prefs/set']!({
        'prefs': {
          'excluded_lights': <String>[],
          'locked': ['switch.kaffee'],
        },
      });
      await repo.setLightExcluded('light.lampe_salon', true);
      expect(live.prefs['locked'], ['switch.kaffee']);
      expect(live.prefs['excluded_lights'], ['light.lampe_salon']);
      final sets = live.received
          .where((m) => m['type'] == 'haven/prefs/set')
          .toList();
      expect(sets.length, 2); // abgelehnt, dann mit Revision 5
      expect(sets.last['base_revision'], 5);
      await repo.dispose();
    });

    test('Zurück aus dem Hintergrund: Dokumente gleichen neu ab', () async {
      final (repo, _) = await start();
      final kinds = <AppDataKind>[];
      final sub = repo.appDataChanges.listen(kinds.add);
      repo.nudgeConnection();
      await until(() => kinds.length >= 2);
      expect(kinds, containsAll([AppDataKind.floorplan, AppDataKind.widgets]));
      await sub.cancel();
      await repo.dispose();
    });
  });
}
