import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/models/entity_state.dart';
import 'package:haven/data/models/lamp.dart';
import 'package:haven/data/models/widget_config.dart';
import 'package:haven/data/scene_styles.dart';

void main() {
  group('Lamp.fromEntity', () {
    test('an mit Farbe und Helligkeit', () {
      final l = Lamp.fromEntity(
        const EntityState('light.a', 'on', {
          'brightness': 128,
          'rgb_color': [255, 168, 90],
          'color_temp_kelvin': 2732,
          'supported_color_modes': ['color_temp', 'xy'],
          'friendly_name': 'Tischlampe',
        }),
      );
      expect(l.on, isTrue);
      expect(l.brightness, 50);
      expect(l.color, (255, 168, 90));
      expect(l.supportsColor, isTrue);
      expect(l.name, 'Tischlampe');
    });

    test('aus: Helligkeit 0, warmes Weiß als Anzeigefarbe', () {
      final l = Lamp.fromEntity(
        const EntityState('light.a', 'off', {
          'supported_color_modes': ['brightness'],
        }),
      );
      expect(l.on, isFalse);
      expect(l.brightness, 0);
      expect(l.supportsColor, isFalse);
      expect(l.supportsKelvin, isFalse);
    });

    test('nicht erreichbar', () {
      expect(
        Lamp.fromEntity(const EntityState('light.a', 'unavailable')).available,
        isFalse,
      );
    });
  });

  test('Widget-Konfiguration übersteht JSON', () {
    final s = HavenWidgetConfig.encodeList(HavenWidgetConfig.defaults);
    final back = HavenWidgetConfig.decodeList(s);
    expect(back.length, HavenWidgetConfig.defaults.length);
    expect(back[1].type, HavenWidgetType.lowBattery);
    expect(back[1].options['threshold'], 50);
    expect(back[2].type, HavenWidgetType.weather);
    expect(back[2].entityIds, isEmpty);
  });

  test('slugify wie HA', () {
    expect(slugify('ZGKochbereich'), 'zgkochbereich');
    expect(slugify('Nachts/Bewegung'), 'nachts_bewegung');
    expect(slugify('Kochbereich Arbeitslicht 2'), 'kochbereich_arbeitslicht_2');
    expect(slugify('Golden Hour'), 'golden_hour');
  });

  test('bekannte Szenen haben Farben aus dem Entwurf, unbekannte stabile', () {
    expect(sceneStyleFor('Neon Tokyo').colors.first, (255, 46, 147));
    expect(
      sceneStyleFor('Irgendwas').colors,
      sceneStyleFor('Irgendwas').colors,
    );
  });
}
