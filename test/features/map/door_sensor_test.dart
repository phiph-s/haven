import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/models/furniture.dart';

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

  test('Nur Türen und Fenster lassen sich verknüpfen', () {
    expect(door.copyWith().canHaveSensor, isTrue);
    const sofa = FloorFurniture(id: 's', kind: 'sofa', x: 1, y: 1, w: 2, h: 1);
    expect(sofa.canHaveSensor, isFalse);
  });
}
