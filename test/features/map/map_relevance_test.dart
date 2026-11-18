import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/models/entity_state.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/features/map/map_relevance.dart';

void main() {
  FloorPlacement at(String id) => FloorPlacement(entityId: id, x: 0, y: 0);
  final states = {
    'light.an': const EntityState('light.an', 'on'),
    'light.aus': const EntityState('light.aus', 'off'),
    'climate.heizt': const EntityState('climate.heizt', 'heat', {
      'hvac_action': 'heating',
    }),
    'climate.ruht': const EntityState('climate.ruht', 'heat', {
      'hvac_action': 'idle',
    }),
    'binary_sensor.fenster': const EntityState('binary_sensor.fenster', 'on'),
    'binary_sensor.zu': const EntityState('binary_sensor.zu', 'off'),
    'switch.ofen': const EntityState('switch.ofen', 'on'),
    'switch.radio': const EntityState('switch.radio', 'on'),
    'switch.lader': const EntityState('switch.lader', 'on'),
    'switch.lampe': const EntityState('switch.lampe', 'on'),
    'sensor.knopf': const EntityState('sensor.knopf', '20'),
  };
  const watts = {
    'switch.ofen': 1800.0,
    'switch.radio': 12.0,
    'switch.lader': 40.0,
    'switch.lampe': 9.0,
  };

  test('Kombi zeigt nur, was gerade los ist', () {
    final shown = relevantDevices(
      [for (final id in states.keys) at(id)],
      entity: (id) => states[id],
      power: (id) => watts[id],
      battery: (id) => id == 'sensor.knopf' ? 8 : null,
    );
    expect(shown, {
      'light.an',
      'climate.heizt',
      'binary_sensor.fenster',
      'switch.ofen', // über 100 W
      'switch.lader', // über dem 1,5-Fachen des Medians (12 W)
      'sensor.knopf', // Batterie fast leer
    });
  });
}
