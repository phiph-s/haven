import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';
import 'package:haven_3d/src/sky_view.dart' show lightningFlash;

void main() {
  test('Gewitter: regelmäßig ein kurzer Blitz, sonst dunkel', () {
    var flashes = 0, dark = 0;
    for (var t = 0.0; t < 35; t += 0.02) {
      lightningFlash(t, 1) > 0.5 ? flashes++ : dark++;
    }
    // Etwa zehn Blitze in 35 s, jeder nur Sekundenbruchteile hell.
    expect(flashes, inInclusiveRange(10, 200));
    expect(dark, greaterThan(flashes * 5));
    expect(lightningFlash(3, 0), 0);
  });

  test('Schnee und Gewitter bringen Wolken und dämpfen das Licht', () {
    final clear = SceneSky.at(dayOfYear: 20, hour: 12);
    final snow = SceneSky.at(dayOfYear: 20, hour: 12, snow: 1);
    final storm = SceneSky.at(dayOfYear: 200, hour: 12, storm: 1);
    expect(snow.cover, greaterThan(0.8));
    expect(storm.wetness, greaterThan(0.7));
    expect(snow.light.intensity, lessThan(clear.light.intensity));
    expect(storm.light.intensity, lessThan(0.2));
  });
}
