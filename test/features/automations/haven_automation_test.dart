import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/ha/ha_automations.dart';
import 'package:haven/data/ha/ha_client.dart';
import 'package:haven/data/models/haven_automation.dart';
import 'package:haven/features/automations/automation_logic.dart';
import 'package:haven/features/automations/knob_live_test.dart';
import 'package:haven/features/automations/knob_logic.dart';

import '../../support/fake_ha.dart';

/// Antwort von `haven/automations/list` wie im README der Integration.
const _list = {
  'automations': [
    {
      'id': 'a1',
      'type': 'room_knob',
      'name': 'Drehregler Salon',
      'enabled': true,
      'room_area_id': 'salon',
      'devices': ['0x16'],
      'options': {
        'gestures': {
          'rotate': {'action': 'brightness'},
          'single': {'action': 'toggle'},
          'double': {'action': 'next_scene'},
          'hold': {'action': 'scene', 'scene': 2},
        },
        'scenes': [3, 0],
        'on_action': 'scene',
        'on_scene': 1,
        'step': 20,
        'transition': 0.5,
        'min_brightness': 10,
        'off_at_min': true,
        'zukunft': 'bleibt',
      },
      'last_triggered': {'at': '2026-11-16T10:00:00+00:00', 'action': 'double'},
    },
    {
      'id': 'a2',
      'name': 'Aus',
      'enabled': false,
      'room_area_id': 'diele',
      'devices': ['0x08'],
    },
  ],
  'rooms': {
    'salon': {
      'name': 'Salon',
      'group': 'ZGSalon',
      'scenes': [
        {'id': 0, 'name': 'Golden Hour'},
        {'id': 1, 'name': 'Neon Tokyo'},
        {'id': 2, 'name': 'Nordlicht'},
        {'id': 3, 'name': 'Kinoabend'},
      ],
      'lights': ['light.a'],
      'has_lights': true,
    },
    'diele': {
      'name': 'Diele',
      'group': null,
      'scenes': [],
      'lights': [],
      'has_lights': false,
    },
  },
  'device_automations': {
    '0x16': ['automation.drehknopf_salon'],
  },
  'running': true,
};

AutomationItem _ha(String id, String name, {bool on = true, String? room}) =>
    AutomationItem(entityId: id, name: name, on: on, room: room);

void main() {
  group('Modell', () {
    test('liest die Liste der Integration', () {
      final all = HavenAutomations.fromJson(_list);
      final a = all.byId('a1')!;
      expect(a.name, 'Drehregler Salon');
      expect(
        a.options.binding(KnobGesture.hold),
        const GestureBinding(GestureAction.scene, scene: 2),
      );
      expect(a.options.scenes, [3, 0]);
      expect(a.options.onScene, 1);
      expect(a.options.step, 20);
      expect(a.options.transition, 0.5);
      expect(a.options.offAtMin, isTrue);
      expect(a.lastTriggered!.action, 'double');
      expect(all.rooms['salon']!.scenes.length, 4);
      expect(all.rooms['diele']!.hasLights, isFalse);
      expect(all.deviceAutomations['0x16'], ['automation.drehknopf_salon']);
      // Standardwerte, wenn Optionen fehlen
      final b = all.byId('a2')!;
      expect(b.enabled, isFalse);
      expect(b.options, const KnobOptions());
      expect(
        b.options.binding(KnobGesture.rotate).action,
        GestureAction.brightness,
      );
    });

    test('toJson hält unbekannte Optionen und lässt last_triggered weg', () {
      final a = HavenAutomations.fromJson(_list).byId('a1')!;
      final j = a.toJson();
      expect(j.containsKey('last_triggered'), isFalse);
      expect(j['options']['zukunft'], 'bleibt');
      expect(j['options']['on_action'], 'scene');
      expect(j['options']['gestures']['hold'], {'action': 'scene', 'scene': 2});
      final again = HavenAutomation.fromJson(j);
      expect(again.copyWith(lastTriggered: a.lastTriggered), a);
      // Neu: ohne id
      expect(
        const HavenAutomation(
          name: 'x',
          roomAreaId: 'r',
        ).toJson().containsKey('id'),
        isFalse,
      );
    });

    test('ownerOf beachtet nur aktive', () {
      final all = HavenAutomations.fromJson(_list);
      expect(all.ownerOf('0x16')!.id, 'a1');
      expect(all.ownerOf('0x16', exceptId: 'a1'), isNull);
      expect(all.ownerOf('0x08'), isNull);
    });

    test('Normalisierung im event- und command-Modus', () {
      expect(normalizeKnobAction({'action': 'rotate_left'}), 'rotate_left');
      expect(
        normalizeKnobAction({
          'action': 'brightness_step_up',
          'action_step_size': 13,
        }),
        'rotate_right',
      );
      expect(normalizeKnobAction({'action': 'toggle'}), 'single');
      expect(normalizeKnobAction({'action': ''}), isNull);
      expect(normalizeKnobAction({'action': 'hue_move'}), isNull);
      expect(normalizeKnobAction({'battery': 3}), isNull);
      expect(gestureOf('rotate_right'), KnobGesture.rotate);
    });

    test('Auslöse-Ereignis', () {
      final t = AutomationTrigger.fromEvent({
        'event_type': 'haven_automation_triggered',
        'data': {
          'id': 'a1',
          'action': 'single',
          'room': 'salon',
          'source': 'test',
          'at': '2026-11-16T10:00:00+00:00',
        },
      })!;
      expect(t.id, 'a1');
      expect(t.source, 'test');
      expect(
        AutomationTrigger.fromEvent({
          'data': {'id': 3},
        }),
        isNull,
      );
    });
  });

  group('Editor-Validierung', () {
    final all = HavenAutomations.fromJson(_list);
    const base = HavenAutomation(
      name: 'Neu',
      roomAreaId: 'salon',
      devices: ['0x99'],
    );

    test('gültig', () {
      expect(validateKnobDraft(base, all), isEmpty);
    });

    test('Raum fehlt oder ohne Lichter', () {
      expect(
        validateKnobDraft(base.copyWith(roomAreaId: ''), all)[0],
        'Wähl einen Raum',
      );
      expect(
        validateKnobDraft(base.copyWith(roomAreaId: 'diele'), all)[0],
        contains('keine Lichter'),
      );
    });

    test('Gerät fehlt oder ist belegt', () {
      expect(validateKnobDraft(base.copyWith(devices: []), all)[1], isNotNull);
      final taken = validateKnobDraft(
        base.copyWith(devices: ['0x16']),
        all,
        deviceNames: {'0x16': 'Drehknopf Salon 1'},
      );
      expect(taken[1], 'Drehknopf Salon 1 steuert schon Drehregler Salon');
      // ausgeschaltet darf es doppelt sein
      expect(
        validateKnobDraft(
          base.copyWith(devices: ['0x16'], enabled: false),
          all,
        ),
        isEmpty,
      );
    });

    test('Szene bei Halten und beim Einschalten', () {
      final noScene = base.copyWith(
        options: base.options.withBinding(
          KnobGesture.hold,
          const GestureBinding(GestureAction.scene),
        ),
      );
      expect(validateKnobDraft(noScene, all)[2], 'Halten: Szene wählen');
      final emptyCycle = base.copyWith(
        options: base.options.copyWith(scenes: []),
      );
      expect(
        validateKnobDraft(emptyCycle, all)[3],
        'Wähl mindestens eine Szene',
      );
      final badOn = base.copyWith(options: base.options.copyWith(onScene: 42));
      expect(
        validateKnobDraft(badOn, all)[3],
        'Beim Einschalten: Szene wählen',
      );
    });

    test('Szenen-Reihenfolge', () {
      final scenes = all.rooms['salon']!.scenes;
      final o = orderedScenes(scenes, [3, 1]);
      expect(
        [for (final (s, on) in o) '${s.id}$on'],
        ['3true', '1true', '0false', '2false'],
      );
      expect(orderedScenes(scenes, null).every((e) => e.$2), isTrue);
      expect(stepPercent(35), 14);
      expect(stepFromPercent(14), 36);
    });
  });

  group('HA-Konflikte', () {
    final items = [
      _ha('automation.drehknopf_salon', 'Drehknopf Salon: Einfach'),
      _ha(
        'automation.knopf_ruheraum',
        'Knopf schaltet Ruheraum',
        room: 'Ruheraum',
      ),
      _ha('automation.licht', 'Salon Licht bei Bewegung', room: 'Salon'),
      _ha('automation.alt', 'Drehregler Salon alt', on: false),
    ];

    test('über Device-Trigger und am Namen', () {
      final c = findHaConflicts(
        devices: ['0x16'],
        roomName: 'Salon',
        deviceNames: {'0x16': 'Drehknopf Salon 1'},
        deviceAutomations: {
          '0x16': ['automation.drehknopf_salon'],
        },
        haAutomations: items,
      );
      expect(
        [for (final x in c) x.item.entityId],
        ['automation.drehknopf_salon'],
      );
      expect(c.single.byDevice, isTrue);
    });

    test('ohne Device-IDs am Namen, ausgeschaltete zählen nicht', () {
      final c = findHaConflicts(
        devices: ['0x08'],
        roomName: 'Ruheraum',
        deviceNames: {'0x08': 'Knopf Ruheraum'},
        deviceAutomations: const {},
        haAutomations: items,
      );
      expect(
        [for (final x in c) x.item.entityId],
        ['automation.knopf_ruheraum'],
      );
      expect(c.single.byDevice, isFalse);
    });
  });

  group('Live-Log', () {
    test('Gerätemeldung und Auslösung werden ein Eintrag', () {
      final log = LiveGestureLog();
      final t0 = DateTime(2026, 11, 16, 10);
      expect(log.addDevice('rotate_right', '0x16', t0), isTrue);
      expect(
        log.addDevice(
          'rotate_right',
          '0x16',
          t0.add(const Duration(milliseconds: 100)),
        ),
        isFalse,
      );
      expect(
        log.addTrigger(
          AutomationTrigger(
            id: 'a1',
            action: 'rotate_right',
            device: '0x16',
            at: t0.add(const Duration(milliseconds: 200)),
          ),
        ),
        isFalse,
      );
      expect(log.items.single.executed, isTrue);
      // Test-Auslösung ist immer ein eigener Eintrag
      expect(
        log.addTrigger(
          AutomationTrigger(
            id: 'a1',
            action: 'rotate_right',
            source: 'test',
            at: t0,
          ),
        ),
        isTrue,
      );
      expect(log.items.first.test, isTrue);
      for (var i = 0; i < 20; i++) {
        log.addDevice('single', '0x16', t0.add(Duration(seconds: i + 2)));
      }
      expect(log.items.length, 8);
    });
  });

  group('HaAutomations', () {
    test('list, set, test und Ereignis gegen eine HA-Gegenstelle', () async {
      final channels = <FakeChannel>[];
      final client = HaClient(
        url: 'http://ha.local:8123',
        token: 'geheim',
        pingInterval: const Duration(minutes: 5),
        channelFactory: (uri) {
          final c = FakeChannel();
          channels.add(c);
          c.server.onMessage = (s, m) {
            final id = m['id'];
            switch (m['type']) {
              case 'haven/automations/list':
                s.send({
                  'id': id,
                  'type': 'result',
                  'success': true,
                  'result': _list,
                });
              case 'haven/automations/set':
                final a = Map<String, dynamic>.from(m['automation'] as Map);
                s.send({
                  'id': id,
                  'type': 'result',
                  'success': true,
                  'result': {
                    'ok': true,
                    'automation': {...a, 'id': 'neu'},
                  },
                });
              case 'subscribe_events':
                s.send({
                  'id': id,
                  'type': 'result',
                  'success': true,
                  'result': null,
                });
                scheduleMicrotask(
                  () => s.send({
                    'id': id,
                    'type': 'event',
                    'event': {
                      'event_type': 'haven_automation_triggered',
                      'data': {
                        'id': 'neu',
                        'action': 'double',
                        'room': 'salon',
                      },
                    },
                  }),
                );
              default:
                s.send({
                  'id': id,
                  'type': 'result',
                  'success': true,
                  'result': {'ok': true},
                });
            }
          };
          scheduleMicrotask(c.server.greet);
          return c;
        },
      );
      await client.start();
      final auto = HaAutomations(client);
      final all = await auto.list();
      expect(all.automations.length, 2);
      final saved = await auto.save(
        const HavenAutomation(
          name: 'X',
          roomAreaId: 'salon',
          devices: ['0x99'],
        ),
      );
      expect(saved.id, 'neu');
      final sent = channels.first.server.received.firstWhere(
        (m) => m['type'] == 'haven/automations/set',
      );
      expect((sent['automation'] as Map).containsKey('id'), isFalse);
      final trig = auto.triggers.first;
      expect((await trig).action, 'double');
      await auto.test('neu', 'hold');
      final t = channels.first.server.received.lastWhere(
        (m) => m['type'] == 'haven/automations/test',
      );
      expect(t['action'], 'hold');
      // `id` ist bei HA die Nummer der Nachricht, die ID muss anders heißen.
      expect(t['automation_id'], 'neu');
      await auto.delete('neu');
      final d = channels.first.server.received.lastWhere(
        (m) => m['type'] == 'haven/automations/delete',
      );
      expect(d['automation_id'], 'neu');
      await auto.dispose();
      await client.close();
    });
  });
}
