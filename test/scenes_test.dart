import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/ha/ha_repository.dart';
import 'package:haven/data/haven_repository.dart';
import 'package:haven/data/models/entity_state.dart';
import 'package:haven/data/models/lamp.dart';
import 'package:haven/data/models/room.dart';
import 'package:haven/data/scene_look.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/room/widgets/scene_editor.dart';

Lamp _lamp(bool on, int bri, (int, int, int) rgb, {int? kelvin}) => Lamp(
  entityId: 'light.x',
  name: 'x',
  on: on,
  brightness: on ? bri : 0,
  color: rgb,
  kelvin: kelvin,
);

RoomScene _scene(String name, int n) => RoomScene(
  id: name.toLowerCase(),
  name: name,
  colors: const [(1, 1, 1), (1, 1, 1), (1, 1, 1)],
  brightness: 50,
  groupId: 1,
  number: n,
);

void main() {
  group('sceneLookOf', () {
    test('alles aus', () {
      final look = sceneLookOf([_lamp(false, 0, (255, 0, 0))]);
      expect(look.allOff, isTrue);
      expect(look.colors, [sceneOffColor]);
    });

    test('Farben der hellsten Lampen zuerst, fast gleiche einmal', () {
      final look = sceneLookOf([
        _lamp(true, 30, (0, 0, 255)),
        _lamp(true, 90, (255, 0, 0)),
        _lamp(true, 80, (250, 4, 2)),
        _lamp(false, 0, (0, 255, 0)),
      ]);
      expect(look.colors, [(255, 0, 0), (0, 0, 255)]);
      expect(look.brightness, 67);
      expect(look.kelvin, isNull);
      expect(look.cardColors, [(255, 0, 0), (0, 0, 255), (255, 0, 0)]);
    });

    test('Weißlicht: mittlere Farbtemperatur auf 100 K gerundet', () {
      final look = sceneLookOf([
        _lamp(true, 50, (255, 200, 150), kelvin: 2700),
        _lamp(true, 50, (255, 220, 190), kelvin: 3100),
      ]);
      expect(look.kelvin, 2900);
    });

    test('JSON hin und zurück, Unsinn wird null', () {
      const look = SceneLook(colors: [(255, 170, 0)], brightness: 40);
      final back = SceneLook.fromJson(look.toJson())!;
      expect(back.colors, look.colors);
      expect(back.brightness, 40);
      expect(
        SceneLook.fromJson({
          'colors': ['rot'],
          'brightness': 4,
        }),
        isNull,
      );
      expect(SceneLook.fromJson(null), isNull);
    });
  });

  group('Namen', () {
    final scenes = [_scene('Kinoabend', 0), _scene('Lesen', 1)];

    test('sceneNamed findet unabhängig von Schreibweise und Leerzeichen', () {
      expect(sceneNamed(scenes, '  kinoABEND ')?.number, 0);
      expect(sceneNamed(scenes, 'Kino'), isNull);
      expect(sceneNamed(scenes, '   '), isNull);
    });

    test('Vorschläge ohne vergebene Namen', () {
      final s = sceneNameSuggestions(scenes);
      expect(s, hasLength(4));
      expect(s, isNot(contains('Lesen')));
    });

    test('Fehlertexte', () {
      expect(
        sceneErrorText(HavenException('x', code: 'unauthorized')),
        contains('Admin'),
      );
      expect(sceneErrorText(HavenException('Gibt es schon')), 'Gibt es schon');
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

    test('neue Szene speichert das aktuelle Licht und wird aktiv', () async {
      expect(repo.canEditScenes('salon'), isTrue);
      final before = salon().scenes.length;
      await repo.setLights(salon().lightIds, on: true, rgb: (255, 0, 0));
      final id = await repo.storeScene('salon', name: 'Rot');
      final scene = salon().scenes.firstWhere((s) => s.number == id);
      expect(salon().scenes, hasLength(before + 1));
      expect(scene.name, 'Rot');
      expect(scene.stored, isTrue);
      expect(scene.colors.first, (255, 0, 0));
      expect(repo.snapshot.activeScenes['salon'], scene.id);
      // Andere Farbe, dann die Szene: das gespeicherte Rot kommt zurück.
      await repo.setLights(salon().lightIds, rgb: (0, 0, 255));
      await repo.applyScene('salon', scene.id);
      expect(repo.snapshot.lamp(salon().lightIds.first)!.color, (255, 0, 0));
    });

    test(
      'vergebener Name wird abgelehnt, Überschreiben behält die ID',
      () async {
        final first = salon().scenes.first;
        expect(
          () => repo.storeScene('salon', name: first.name.toUpperCase()),
          throwsA(
            isA<HavenException>().having((e) => e.code, 'code', 'name_taken'),
          ),
        );
        final count = salon().scenes.length;
        final id = await repo.storeScene('salon', number: first.number);
        expect(id, first.number);
        expect(salon().scenes, hasLength(count));
        expect(
          salon().scenes.firstWhere((s) => s.number == id).name,
          first.name,
        );
      },
    );

    test('Zusatzgeräte: speichern, herausnehmen', () async {
      Room ruheraum() => repo.snapshot.room('ruheraum')!;
      // Die Matter-Leselampe ist in keiner Zigbee-Gruppe.
      expect(ruheraum().sceneLightIds, ['light.leselampe_ruheraum']);
      expect(repo.canSceneDevices, isTrue);
      final id = await repo.storeScene(
        'ruheraum',
        name: 'Abend',
        devices: ['light.leselampe_ruheraum'],
      );
      RoomScene scene() => ruheraum().scenes.firstWhere((s) => s.number == id);
      expect(scene().devices, ['light.leselampe_ruheraum']);
      await repo.setSceneDevices('ruheraum', id, const []);
      expect(scene().devices, isEmpty);
    });

    test('umbenennen und löschen', () async {
      final s = salon().scenes.first;
      await repo.renameScene('salon', s.number!, 'Neu');
      expect(
        salon().scenes.firstWhere((x) => x.number == s.number).name,
        'Neu',
      );
      await repo.removeScene('salon', s.number!);
      expect(salon().scenes.where((x) => x.number == s.number), isEmpty);
    });
  });

  group('HaRepository.roomsFromHaven', () {
    final rooms = {
      'rooms': [
        {
          'area_id': 'salon',
          'name': 'Salon',
          'lights': <String>[],
          'climate': {},
          'group': {'id': 4, 'friendly_name': 'ZGSalon', 'match': 'exact'},
        },
      ],
    };
    final groups = {
      'groups': [
        {
          'id': 4,
          'friendly_name': 'ZGSalon',
          'members': [],
          'scenes': [
            {'id': 0, 'name': 'Hell', 'look': null},
            {
              'id': 2,
              'name': 'Rot',
              'look': {
                'colors': ['#ff0000'],
                'brightness': 30,
                'kelvin': null,
              },
            },
          ],
        },
      ],
    };
    final entities = {
      'scene.zgsalon_0_hell': const EntityState('scene.zgsalon_0_hell', 'x'),
    };

    test('ohne Feature nur Szenen mit HA-Entity', () {
      final r = HaRepository.roomsFromHaven(rooms, groups, entities).single;
      expect(r.zigbeeGroupId, 4);
      expect(r.scenes.map((s) => s.name), ['Hell']);
      expect(r.scenes.single.editable, isFalse);
    });

    test('mit Feature scenes alle Szenen, echte Farben aus look', () {
      final r = HaRepository.roomsFromHaven(
        rooms,
        groups,
        entities,
        sceneCommands: true,
      ).single;
      expect(r.scenes.map((s) => s.name), ['Hell', 'Rot']);
      final rot = r.scenes.last;
      expect(rot.editable, isTrue);
      expect((rot.groupId, rot.number), (4, 2));
      expect(rot.stored, isTrue);
      expect(rot.colors, [(255, 0, 0), (255, 0, 0), (255, 0, 0)]);
      expect(rot.brightness, 30);
      expect(rot.entityId, isNull);
      expect(r.scenes.first.stored, isFalse);
    });

    test('mit room_scenes: Zusatzgeräte und Szenen ohne Gruppe', () {
      final withDevices = {
        'groups': [
          {
            ...(groups['groups'] as List).first as Map<String, dynamic>,
            'scenes': [
              {
                'id': 0,
                'name': 'Hell',
                'look': null,
                'devices': [
                  {'entity_id': 'light.matter', 'on': true},
                ],
              },
            ],
          },
        ],
      };
      final all = {
        'rooms': [
          {
            ...(rooms['rooms'] as List).first as Map<String, dynamic>,
            'lights': ['light.matter'],
            'outside_lights': ['light.matter'],
            'switches': ['switch.steckdose'],
          },
          {
            'area_id': 'bad',
            'name': 'Bad',
            'lights': ['light.wlan'],
            'outside_lights': ['light.wlan'],
            'climate': {},
            'group': null,
            'scenes': [
              {
                'id': 3,
                'name': 'Nacht',
                'look': {
                  'colors': ['#ff8800'],
                  'brightness': 10,
                  'kelvin': null,
                },
                'devices': [
                  {'entity_id': 'light.wlan', 'on': true, 'brightness': 10},
                ],
              },
            ],
          },
        ],
      };
      final rs = HaRepository.roomsFromHaven(
        all,
        withDevices,
        entities,
        sceneCommands: true,
        roomScenes: true,
      );
      final salon = rs.firstWhere((r) => r.id == 'salon');
      expect(salon.scenes.single.devices, ['light.matter']);
      expect(salon.sceneLightIds, ['light.matter']);
      expect(salon.switchIds, ['switch.steckdose']);
      final bad = rs.firstWhere((r) => r.id == 'bad');
      final nacht = bad.scenes.single;
      expect((nacht.own, nacht.number, nacht.editable), (true, 3, true));
      expect(nacht.zigbee, isFalse);
      expect(nacht.devices, ['light.wlan']);
      expect(nacht.brightness, 10);
      // Ohne Feature keine eigenen Szenen
      final old = HaRepository.roomsFromHaven(
        all,
        withDevices,
        entities,
        sceneCommands: true,
      );
      expect(old.firstWhere((r) => r.id == 'bad').scenes, isEmpty);
    });
  });
}
