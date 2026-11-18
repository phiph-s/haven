import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/features/map/map_3d.dart';
import 'package:haven_3d/haven_3d.dart' as h3;

void main() {
  test('Bauform und Höhe: JSON hin und zurück, ohne Angabe kein Feld', () {
    const p = FloorPlacement(entityId: 'light.decke', x: 3, y: 4);
    expect(p.toJson().containsKey('model'), isFalse);
    expect(p.toJson().containsKey('height'), isFalse);
    final q = p.copyWith(model: 'pendant', height: 2.1);
    expect(FloorPlacement.fromJson(q.toJson()), q);
    expect(q.copyWith(clearModel: true, clearHeight: true), p);
  });

  test('Standard-Bauform je Art, Lampen nur mit Lampen-Bauformen', () {
    expect(defaultDeviceModel(FloorKind.light, 'light.x'), 'ceiling');
    expect(defaultDeviceModel(FloorKind.temperature, 'climate.trv'), 'trv');
    expect(defaultDeviceModel(FloorKind.temperature, 'sensor.t'), 'sensor');
    expect(deviceModelsFor(FloorKind.light).every((d) => d.isLamp), isTrue);
    expect(deviceModelsFor(FloorKind.remote).any((d) => d.isLamp), isFalse);
  });

  test('Marker sitzt an der Lichtquelle bzw. über dem Gerät', () {
    const pendant = FloorPlacement(
      entityId: 'light.p',
      x: 1,
      y: 1,
      model: 'pendant',
    );
    final spec = h3.deviceSpec('pendant');
    expect(markerHeightOf(pendant), spec.height + spec.lamp!.lightZ);
    final low = pendant.copyWith(height: 2.0);
    expect(markerHeightOf(low), 2.0 + spec.lamp!.lightZ);
  });
}
