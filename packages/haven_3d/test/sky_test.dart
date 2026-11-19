import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';

void main() {
  test('Sonnenstand: Mittag im Süden, im Sommer höher als im Winter', () {
    final summer = sunPosition(dayOfYear: 172, hour: 12, latitude: 49);
    final winter = sunPosition(dayOfYear: 355, hour: 12, latitude: 49);
    expect(summer.azimuth, closeTo(180, 1));
    expect(summer.elevation, closeTo(64.4, 1));
    expect(winter.elevation, closeTo(17.6, 1));
    // Morgens im Osten, abends im Westen, nachts unter dem Horizont.
    expect(
      sunPosition(dayOfYear: 80, hour: 7, latitude: 49).azimuth,
      inInclusiveRange(80, 120),
    );
    expect(
      sunPosition(dayOfYear: 80, hour: 17, latitude: 49).azimuth,
      inInclusiveRange(240, 280),
    );
    expect(
      sunPosition(dayOfYear: 80, hour: 0, latitude: 49).elevation,
      lessThan(-30),
    );
  });

  test('Mond: Vollmond steht um Mitternacht im Süden, voll beleuchtet', () {
    final full = moonPosition(dayOfYear: 355, hour: 0, phase: 0.5);
    expect(full.azimuth, closeTo(180, 1));
    expect(full.elevation, greaterThan(50));
    expect(moonIlluminationOf(0.5), closeTo(1, 1e-9));
    expect(moonIlluminationOf(0), closeTo(0, 1e-9));
  });

  test('Licht: Tag hell, Nacht mit Mond schwach und kühl, Wolken dämpfen', () {
    final noon = SceneSky.at(dayOfYear: 172, hour: 12).light;
    final night = SceneSky.at(dayOfYear: 355, hour: 0, moonPhase: 0.5).light;
    final dark = SceneSky.at(dayOfYear: 355, hour: 0, moonPhase: 0).light;
    final cloudy = SceneSky.at(dayOfYear: 172, hour: 12, cloud: 1).light;
    expect(noon.night, isFalse);
    expect(noon.intensity, greaterThan(0.9));
    expect(night.night, isTrue);
    expect(night.intensity, inExclusiveRange(0.01, 0.1));
    expect(dark.intensity, lessThan(0.001));
    expect(night.ambient, lessThan(noon.ambient));
    expect(cloudy.intensity, lessThan(noon.intensity * 0.3));
    expect(cloudy.softness, greaterThan(noon.softness));
    // Licht fällt nach unten.
    expect(noon.direction.z, lessThan(0));
  });
}
