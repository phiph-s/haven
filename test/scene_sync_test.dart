import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/ha/ha_repository.dart';
import 'package:haven/data/models/room.dart';
import 'package:haven/data/models/scene_check.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/room/widgets/scene_sync_sheet.dart';

/// Antwort von `haven/zigbee/scene_check` wie im Vertrag.
const _checkJson = {
  'group_id': 3,
  'scene_id': 2,
  'name': 'Abend',
  'has_target': true,
  'status': 'differs',
  'members': [
    {
      'entity_id': 'light.a',
      'name': 'Lampe A',
      'expected': {'on': true, 'brightness': 80, 'kelvin': 2700, 'rgb': null},
      'measured': {'on': true, 'brightness': 78, 'kelvin': 2800, 'rgb': null},
      'status': 'ok',
    },
    {
      'entity_id': 'light.b',
      'name': 'Lampe B',
      'expected': {
        'on': true,
        'brightness': 50,
        'kelvin': null,
        'rgb': '#ff0000',
      },
      'measured': {
        'on': false,
        'brightness': null,
        'kelvin': null,
        'rgb': null,
      },
      'status': 'missing',
    },
    {
      'entity_id': 'light.c',
      'name': 'Lampe C',
      'expected': null,
      'measured': null,
      'status': 'unreachable',
    },
  ],
  'measured_look': {
    'colors': ['#ffb070'],
    'brightness': 78,
    'kelvin': 2800,
  },
  'checked_at': '2026-11-19T18:00:00+00:00',
};

void main() {
  group('LampState', () {
    test('liest und schreibt das JSON des Vertrags', () {
      final s = LampState.fromJson({
        'on': true,
        'brightness': 40,
        'kelvin': null,
        'rgb': '#00ff80',
      })!;
      expect(s.on, isTrue);
      expect(s.brightness, 40);
      expect(s.rgb, (0, 255, 128));
      expect(s.toJson(), {
        'on': true,
        'brightness': 40,
        'kelvin': null,
        'rgb': '#00ff80',
      });
      expect(LampState.fromJson({'on': false, 'brightness': 3}), LampState.off);
      expect(LampState.off.toJson()['brightness'], isNull);
      expect(LampState.fromJson(null), isNull);
      expect(LampState.fromJson({'brightness': 3}), isNull);
    });

    test('Vergleich mit den Grenzen des Abgleichs', () {
      const a = LampState(on: true, brightness: 50, rgb: (200, 100, 0));
      expect(
        a.matches(
          const LampState(on: true, brightness: 58, rgb: (230, 70, 30)),
        ),
        isTrue,
      );
      expect(
        a.matches(
          const LampState(on: true, brightness: 59, rgb: (200, 100, 0)),
        ),
        isFalse,
      );
      expect(
        a.matches(
          const LampState(on: true, brightness: 50, rgb: (200, 141, 0)),
        ),
        isFalse,
      );
      expect(a.matches(LampState.off), isFalse);
      const w = LampState(on: true, brightness: 50, kelvin: 2700);
      expect(
        w.matches(const LampState(on: true, brightness: 50, kelvin: 3000)),
        isTrue,
      );
      expect(
        w.matches(const LampState(on: true, brightness: 50, kelvin: 3100)),
        isFalse,
      );
      expect(LampState.off.matches(LampState.off), isTrue);
    });
  });

  group('SceneCheck', () {
    test('liest die Antwort von scene_check', () {
      final c = SceneCheck.fromJson(_checkJson);
      expect((c.groupId, c.sceneId, c.name), (3, 2, 'Abend'));
      expect(c.hasTarget, isTrue);
      expect(c.status, SceneCheckStatus.differs);
      expect(c.members, hasLength(3));
      expect(c.members[0].status, SceneLampStatus.ok);
      expect(c.members[0].expected!.kelvin, 2700);
      expect(c.members[1].status, SceneLampStatus.missing);
      expect(c.members[1].measured, LampState.off);
      expect(c.members[2].status, SceneLampStatus.unreachable);
      expect(c.members[2].expected, isNull);
      expect(c.members[2].measured, isNull);
      expect(c.measuredLook!.brightness, 78);
      expect(c.measuredLook!.kelvin, 2800);
      expect(c.checkedAt, DateTime.utc(2026, 11, 19, 18));
      // Fehlende Lampe wiegt schwerer als eine nicht erreichbare.
      expect(c.outcome, SceneCheckOutcome.missing);
      expect(sceneOutcomeLabel(c), 'Lampe fehlt');
      expect(sceneOutcomeDetail(c), 'Lampe B kennt die Szene nicht');
    });

    test('toJson und zurück ergibt dasselbe', () {
      final c = SceneCheck.fromJson(_checkJson);
      final again = SceneCheck.fromJson(c.toJson());
      expect(again.toJson(), c.toJson());
    });

    test('Urteile: ohne Soll, nur Helligkeit, übernommen', () {
      final noTarget = SceneCheck.fromJson({
        ..._checkJson,
        'has_target': false,
        'status': 'unknown',
        'members': [
          {
            'entity_id': 'light.a',
            'name': 'Lampe A',
            'expected': null,
            'measured': {'on': true, 'brightness': 50},
            'status': 'ok',
          },
        ],
      });
      expect(noTarget.outcome, SceneCheckOutcome.noTarget);
      expect(sceneOutcomeLabel(noTarget), 'Ohne Soll');

      final dim = SceneCheck.fromJson({
        ..._checkJson,
        'members': [
          {
            'entity_id': 'light.a',
            'name': 'Lampe A',
            'expected': {'on': true, 'brightness': 80, 'kelvin': 2700},
            'measured': {'on': true, 'brightness': 30, 'kelvin': 2700},
            'status': 'differs',
          },
        ],
      });
      expect(sceneOutcomeLabel(dim), 'Helligkeit weicht ab');

      final adopted = SceneCheck.fromJson(_checkJson).adopted();
      expect(adopted.members[1].status, SceneLampStatus.ok);
      expect(adopted.members[1].expected, LampState.off);
      // Ohne Messung bleibt die Lampe, wie sie war.
      expect(adopted.outcome, SceneCheckOutcome.unreachable);
    });
  });

  group('Gruppenliste', () {
    test('sync und checked_at je Szene, ohne Angabe unknown', () {
      final rooms = HaRepository.roomsFromHaven(
        {
          'rooms': [
            {
              'area_id': 'raum',
              'name': 'Raum',
              'lights': <String>[],
              'climate': {},
              'group': {'id': 4, 'friendly_name': 'ZGRaum'},
            },
          ],
        },
        {
          'groups': [
            {
              'id': 4,
              'friendly_name': 'ZGRaum',
              'members': [],
              'scenes': [
                {'id': 0, 'name': 'Hell', 'look': null},
                {
                  'id': 1,
                  'name': 'Rot',
                  'look': null,
                  'sync': 'stale',
                  'checked_at': null,
                },
                {
                  'id': 2,
                  'name': 'Blau',
                  'look': null,
                  'sync': 'differs',
                  'checked_at': '2026-11-19T08:30:00+00:00',
                },
                {'id': 3, 'name': 'Grün', 'look': null, 'sync': 'ok'},
              ],
            },
          ],
        },
        const {},
        sceneCommands: true,
      );
      final s = rooms.single.scenes;
      expect(
        [for (final x in s) x.sync],
        [SceneSync.unknown, SceneSync.stale, SceneSync.differs, SceneSync.ok],
      );
      expect(s[1].checkedAt, isNull);
      expect(s[2].checkedAt, DateTime.utc(2026, 11, 19, 8, 30));
      expect([for (final x in s) x.needsSync], [false, true, true, false]);
      expect(sceneSyncDetail(s[3]), 'Noch nicht geprüft');
    });
  });

  group('FakeRepository', () {
    late FakeRepository repo;
    setUp(() async {
      repo = FakeRepository(simulate: false);
      await repo.start();
    });
    tearDown(() => repo.dispose());

    Room salon() => repo.snapshot.room('salon')!;
    RoomScene scene(int n) => salon().scenes.firstWhere((s) => s.number == n);

    test('eine Szene mit fehlender Lampe, eine mit anderer Farbe', () async {
      expect(repo.canSyncScenes, isTrue);
      final outcomes = <String, SceneCheckOutcome>{};
      for (final s in salon().scenes) {
        final c = await repo.checkScene('salon', s.number!);
        outcomes[s.name] = c.outcome;
      }
      expect(
        outcomes.values.where((o) => o == SceneCheckOutcome.missing),
        hasLength(1),
      );
      expect(
        outcomes.values.where((o) => o == SceneCheckOutcome.differs),
        hasLength(1),
      );
      expect(
        outcomes.values.where((o) => o == SceneCheckOutcome.ok),
        hasLength(salon().scenes.length - 2),
      );
      final missing = salon().scenes.firstWhere(
        (s) => outcomes[s.name] == SceneCheckOutcome.missing,
      );
      final differs = salon().scenes.firstWhere(
        (s) => outcomes[s.name] == SceneCheckOutcome.differs,
      );
      // Die Lampe kam später in die Gruppe: neu abgleichen.
      expect(missing.sync, SceneSync.stale);
      expect(differs.sync, SceneSync.differs);
      expect(differs.checkedAt, isNotNull);
      expect(
        salon().scenes
            .where(
              (s) => s.number != missing.number && s.number != differs.number,
            )
            .every((s) => s.sync == SceneSync.ok),
        isTrue,
      );

      // Abgleichen bringt die fehlende Lampe in die Szene.
      final fixed = await repo.repairScene('salon', missing.number!);
      expect(fixed.outcome, SceneCheckOutcome.ok);
      expect(scene(missing.number!).sync, SceneSync.ok);

      // Übernehmen macht die andere Farbe zum Soll und zur Kartenfarbe.
      await repo.adoptScene('salon', differs.number!);
      expect(scene(differs.number!).sync, SceneSync.ok);
      expect(scene(differs.number!).stored, isTrue);
      final again = await repo.checkScene('salon', differs.number!);
      expect(again.outcome, SceneCheckOutcome.ok);
    });

    test('Messen lässt das Licht, wie es war', () async {
      final before = {
        for (final id in salon().lightIds) id: repo.snapshot.lamp(id)!.on,
      };
      for (final s in salon().scenes) {
        await repo.checkScene('salon', s.number!);
      }
      expect({
        for (final id in salon().lightIds) id: repo.snapshot.lamp(id)!.on,
      }, before);
    });

    test('Speichern merkt sich das Soll', () async {
      final id = await repo.storeScene('salon', name: 'Neu');
      expect(scene(id).sync, SceneSync.ok);
      expect(scene(id).checkedAt, isNull);
      final c = await repo.checkScene('salon', id);
      expect(c.hasTarget, isTrue);
      expect(c.outcome, SceneCheckOutcome.ok);
      expect(scene(id).checkedAt, isNotNull);
    });
  });
}
