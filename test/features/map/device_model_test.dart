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

  mountTests();
}

void mountTests() {
  test('Montage: JSON hin und zurück, Standard ohne Feld', () {
    const p = FloorPlacement(entityId: 'light.spot', x: 1, y: 1, model: 'spot');
    expect(p.toJson().containsKey('mount'), isFalse);
    expect(deviceMountOf(p), h3.DeviceMount.ceiling);
    final up = p.copyWith(mount: 'up');
    expect(FloorPlacement.fromJson(up.toJson()), up);
    expect(deviceMountOf(up), h3.DeviceMount.up);
    expect(up.copyWith(clearMount: true), p);
  });

  test('Spot nach oben: Kegel zeigt nach oben, steht auf dem Boden', () {
    final spot = h3.deviceSpec('spot');
    expect(spot.lightAxis(h3.DeviceMount.up).z, closeTo(1, 1e-9));
    expect(spot.heightFor(h3.DeviceMount.up), 0);
    // Modell liegt über dem Montagepunkt statt darunter.
    final pts = spot.model(h3.DeviceMount.up).points;
    expect(pts.every((v) => v.z >= -1e-9), isTrue);
  });

  test('Deckenleuchte an der Wand: Licht in den Raum (-y)', () {
    final c = h3.deviceSpec('ceiling');
    final axis = c.lightAxis(h3.DeviceMount.wall);
    expect(axis.y, closeTo(-1, 1e-9));
    expect(axis.z, closeTo(0, 1e-9));
    expect(c.isWall(h3.DeviceMount.wall), isTrue);
    expect(c.isWall(h3.DeviceMount.ceiling), isFalse);
    // Modell ragt in den Raum, nicht in die Wand.
    final pts = c.model(h3.DeviceMount.wall).points;
    expect(pts.every((v) => v.y <= 1e-9), isTrue);
  });

  test('Lightbar: Lampe, steht standardmäßig und strahlt nach oben', () {
    final bar = h3.deviceSpec('lightbar');
    expect(bar.id, 'lightbar');
    expect(bar.isLamp, isTrue);
    expect(bar.mountOf(null), h3.DeviceMount.up);
    expect(
      deviceModelsFor(FloorKind.light).map((d) => d.id),
      contains('lightbar'),
    );
  });

  test('Bewegungsmelder: Decke oder Wand, alte Wand-Bauform wird Montage', () {
    const legacy = FloorPlacement(
      entityId: 'binary_sensor.m',
      x: 1,
      y: 1,
      model: 'motion_wall',
    );
    expect(deviceModelOf(legacy), 'motion');
    expect(deviceMountOf(legacy), h3.DeviceMount.wall);
    expect(
      deviceModelsFor(FloorKind.presence).map((d) => d.id),
      isNot(contains('motion_wall')),
    );
    expect(h3.deviceSpec('motion').mounts, contains(h3.DeviceMount.wall));
  });
}
