import 'package:flutter_test/flutter_test.dart';
import 'package:haven/core/widgets/simple_markdown.dart';
import 'package:haven/data/models/entity_state.dart';
import 'package:haven/data/models/ha_update.dart';
import 'package:haven/dev/fake_updates.dart';

EntityState _u(String id, Map<String, dynamic> a, {String state = 'on'}) =>
    EntityState(id, state, {'friendly_name': id, ...a});

void main() {
  group('Feature-Bits', () {
    test('lesen alle fünf Bits', () {
      HaUpdate f(int n) =>
          HaUpdate.fromEntity(_u('update.x', {'supported_features': n}));
      expect(f(0).canInstall, isFalse);
      final all = f(31);
      expect(all.canInstall, isTrue);
      expect(all.canPickVersion, isTrue);
      expect(all.hasProgress, isTrue);
      expect(all.canBackup, isTrue);
      expect(all.hasReleaseNotes, isTrue);
      final some = f(1 | 16);
      expect(some.canInstall && some.hasReleaseNotes, isTrue);
      expect(
        some.canBackup || some.hasProgress || some.canPickVersion,
        isFalse,
      );
      expect(f(8).canBackup, isTrue);
      expect(f(4).hasProgress, isTrue);
      expect(f(2).canPickVersion, isTrue);
    });

    test('Attribute defensiv gelesen', () {
      final u = HaUpdate.fromEntity(
        _u('update.x', {
          'installed_version': '1',
          'latest_version': null,
          'release_summary': '  ',
          'in_progress': true,
          'update_percentage': 140,
        }),
      );
      expect(u.latest, isNull);
      expect(u.summary, isNull);
      expect(u.inProgress, isTrue);
      expect(u.percentage, 100);
      expect(u.features, 0);
      // Manche Quellen melden in_progress als Zahl.
      final n = HaUpdate.fromEntity(_u('update.y', {'in_progress': 30}));
      expect(n.inProgress, isTrue);
      expect(n.percentage, 30);
      expect(
        HaUpdate.fromEntity(_u('update.z', {'in_progress': false})).inProgress,
        isFalse,
      );
    });
  });

  group('Gruppierung', () {
    UpdateGroup g(String id, [Map<String, dynamic> a = const {}]) =>
        HaUpdate.fromEntity(_u(id, a)).group;

    test('Core, OS, Supervisor', () {
      expect(g('update.home_assistant_core_update'), UpdateGroup.homeAssistant);
      expect(
        g('update.home_assistant_operating_system_update'),
        UpdateGroup.homeAssistant,
      );
      expect(
        g('update.home_assistant_supervisor_update'),
        UpdateGroup.homeAssistant,
      );
      expect(
        g('update.irgendwas', {'title': 'Home Assistant Core'}),
        UpdateGroup.homeAssistant,
      );
      expect(
        HaUpdate.fromEntity(
          _u('update.home_assistant_core_update', {}),
        ).restartsHa,
        isTrue,
      );
    });

    test('Add-ons über das Symbol', () {
      expect(
        g('update.studio_code_server_update', {
          'entity_picture': '/api/hassio/addons/a0d7b954_vscode/icon',
        }),
        UpdateGroup.addons,
      );
    });

    test('Add-ons ohne Symbol über das Backup-Merkmal', () {
      // Supervisor-Add-ons melden supported_features 29 (mit Backup),
      // HACS-Einträge 23 (ohne Backup).
      expect(
        g('update.eigenes_addon_update', {'supported_features': 29}),
        UpdateGroup.addons,
      );
      expect(
        g('update.eine_karte_update', {'supported_features': 23}),
        UpdateGroup.integrations,
      );
    });

    test('Geräte-Firmware', () {
      expect(
        g('update.lampe', {'device_class': 'firmware'}),
        UpdateGroup.devices,
      );
      expect(g('update.lampe_firmware'), UpdateGroup.devices);
      expect(g('update.x', {'title': 'Firmware'}), UpdateGroup.devices);
    });

    test('HACS und Unbekanntes landen bei den Integrationen', () {
      expect(
        g('update.sonnenstand_update', {
          'release_url':
              'https://github.com/example/sonnenstand/releases/tag/v1',
          'entity_picture': 'https://brands.home-assistant.io/x/icon.png',
        }),
        UpdateGroup.integrations,
      );
      expect(g('update.mystery'), UpdateGroup.integrations);
    });

    test('Haven hat Vorrang, Geräte namens Haven nicht', () {
      expect(g('update.haven_update', {'title': 'Haven'}), UpdateGroup.haven);
      expect(
        g('update.x', {
          'release_url': 'https://github.com/phiph-s/haven-ha/releases/tag/v1',
        }),
        UpdateGroup.haven,
      );
      expect(
        g('update.haven_lampe', {'device_class': 'firmware'}),
        UpdateGroup.devices,
      );
      expect(g('update.havenwood_thermostat_update'), isNot(UpdateGroup.haven));
    });
  });

  group('HaUpdates', () {
    final entities = [
      ...buildFakeUpdateEntities(),
      _u('update.aktuell', {'supported_features': 1}, state: 'off'),
      _u('update.sensor.x', {}, state: 'on'),
      const EntityState('light.x', 'on'),
    ];

    test('nur anstehende Updates, nach Gruppe sortiert', () {
      final u = HaUpdates.fromEntities(entities);
      expect(u.items.any((e) => e.entityId == 'update.aktuell'), isFalse);
      expect(u.items.any((e) => e.entityId == 'light.x'), isFalse);
      final order = u.items.map((e) => e.group.index).toList();
      expect(order, [...order]..sort());
      expect(u.byGroup.keys, containsAll(UpdateGroup.values));
      expect(
        u.byGroup[UpdateGroup.haven]!.single.entityId,
        'update.haven_update',
      );
    });

    test(
      'Alle aktualisieren lässt Core, Laufendes und Nicht-Installierbares aus',
      () {
        final u = HaUpdates.fromEntities(entities);
        final ids = u.bulkTargets.map((e) => e.entityId).toSet();
        expect(ids, {
          'update.sonnenstand_update',
          'update.dimmer_flur_firmware',
          'update.haven_update',
        });
        expect(u.anyRunning, isTrue);
      },
    );

    test('Gleichheit für gezieltes Neubauen', () {
      expect(
        HaUpdates.fromEntities(entities),
        HaUpdates.fromEntities(entities),
      );
      expect(
        HaUpdates.fromEntities(entities),
        isNot(HaUpdates.fromEntities(entities.take(2))),
      );
    });
  });

  group('Markdown', () {
    test('Blöcke', () {
      final b = parseMarkdown(
        '# Titel\n\nErste Zeile\nzweite Zeile\n\n- eins\n  - unter\n1. nummer\n\n```\ncode\n```\n---',
      );
      expect(b[0], isA<MdHeading>());
      expect((b[1] as MdParagraph).text, 'Erste Zeile zweite Zeile');
      expect((b[2] as MdBullet).marker, '•');
      expect((b[3] as MdBullet).indent, 1);
      expect((b[4] as MdBullet).marker, '1.');
      expect((b[5] as MdCode).text, 'code');
      expect(b.length, 6);
    });
  });
}
