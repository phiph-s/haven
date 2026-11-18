import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';
import 'package:haven_3d/src/gpu_scene.dart' show roomChannels;

void main() {
  test('Benachbarte Räume bekommen verschiedene Lichtkanäle', () {
    final scene = sampleScene();
    final ch = roomChannels(scene.rooms);
    expect(ch.keys, unorderedEquals([for (final r in scene.rooms) r.id]));
    // Arbeitszimmer grenzt an Schlafzimmer, Flur und Bad.
    for (final n in ['schlafen', 'flur', 'bad']) {
      expect(ch['arbeiten'], isNot(ch[n]), reason: n);
    }
    expect(ch['wohnen'], isNot(ch['kueche']));
    expect(ch['wohnen'], isNot(ch['flur']));
    for (final bit in ch.values) {
      expect(bit & (bit - 1), 0, reason: 'genau ein Bit');
      expect(bit, lessThan(0x80));
    }
  });

  test('Kanten: Weltbreite, aber nie unter der Mindestbreite in Pixeln', () {
    final s = SceneStyle.light();
    // Weit herausgezoomt (10 px/m): Mindestbreite greift, 1,3 px.
    expect(s.edgeWidthAt(10) * 10, closeTo(s.edgeWidth, 1e-9));
    // Nah dran (400 px/m): Weltbreite, also breiter als die Mindestbreite.
    expect(s.edgeWidthAt(400) * 400, greaterThan(s.edgeWidth));
    expect(s.edgeWidthAt(400), s.edgeWorldWidth);
  });
}
