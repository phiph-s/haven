import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';

void main() {
  test('Sonne aus Azimut und Höhe, gedreht nach Norden des Plans', () {
    // Mittag, Sonne im Süden: Licht fällt nach Norden (Plan oben, -y).
    final noon = sunDirectionOf(180, 45);
    expect(noon.x, closeTo(0, 1e-9));
    expect(noon.y, lessThan(0));
    expect(noon.z, lessThan(0));
    // Morgens im Osten: Licht fällt nach Westen (-x).
    final morning = sunDirectionOf(90, 30);
    expect(morning.x, lessThan(-0.5));
    expect(morning.y.abs(), lessThan(1e-9));
    // Plan gedreht: Norden zeigt nach rechts (90°). Südsonne fällt dann
    // nach rechts (+x).
    final turned = sunDirectionOf(180, 45, north: 90);
    expect(turned.x, greaterThan(0.5));
    expect(turned.y.abs(), lessThan(1e-9));
    // Nachts und flach: mindestens 18° hoch, damit es Licht gibt.
    final night = sunDirectionOf(0, -20);
    final elev = -night.z / night.length;
    expect(elev, closeTo(0.309, 0.01));
  });
}
