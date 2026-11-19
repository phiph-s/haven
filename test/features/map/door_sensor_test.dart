import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/models/furniture.dart';
import 'package:haven_3d/haven_3d.dart' as h3;

void main() {
  const door = FloorFurniture(
    id: 't',
    kind: 'door',
    x: 3,
    y: 4,
    w: 1.8,
    h: 1.8,
  );

  test('Sensor an Tür: JSON hin und zurück, lösen entfernt das Feld', () {
    expect(door.canHaveSensor, isTrue);
    expect(door.toJson().containsKey('sensor'), isFalse);
    final linked = door.copyWith(sensor: 'binary_sensor.tuer_kontakt');
    expect(linked.toJson()['sensor'], 'binary_sensor.tuer_kontakt');
    expect(FloorFurniture.tryFromJson(linked.toJson()), linked);
    expect(linked.copyWith(clearSensor: true).sensor, isNull);
    expect(linked == door, isFalse);
  });

  test('Türen, Fenster und Kühlschränke lassen sich verknüpfen', () {
    expect(door.copyWith().canHaveSensor, isTrue);
    const fridge = FloorFurniture(
      id: 'k',
      kind: 'fridge',
      x: 1,
      y: 1,
      w: 1.2,
      h: 1.3,
    );
    expect(fridge.canHaveSensor, isTrue);
    const sofa = FloorFurniture(id: 's', kind: 'sofa', x: 1, y: 1, w: 2, h: 1);
    expect(sofa.canHaveSensor, isFalse);
  });

  test('Kühlschrank offen: Tür aufgeklappt, Modell anders als zu', () {
    final closed = h3.buildFurniture('fridge', 0.6, 0.65);
    final open = h3.buildFurniture('fridge', 0.6, 0.65, open: true);
    double maxY(h3.Model3 m) =>
        m.points.map((p) => p.y).reduce((a, b) => a > b ? a : b);
    expect(maxY(closed), closeTo(0.325, 1e-9));
    // Tür steht nach vorn etwa eine Breite heraus.
    expect(maxY(open), greaterThan(0.8));
  });
}
