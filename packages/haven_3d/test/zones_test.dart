import 'package:flutter_test/flutter_test.dart';
import 'package:haven_3d/haven_3d.dart';
import 'package:haven_3d/src/gpu_scene.dart' show roomChannels;

SceneRoom _rect(String id, double x0, double x1, {Set<int> open = const {}}) =>
    SceneRoom(
      id: id,
      outline: [Offset(x0, 0), Offset(x1, 0), Offset(x1, 4), Offset(x0, 4)],
      openEdges: open,
    );

void main() {
  test('Offene Wand verbindet zwei Räume zu einer Lichtzone', () {
    final scene = Scene(
      rooms: [
        _rect('a', 0, 4, open: {1}),
        _rect('b', 4, 8),
        _rect('c', 8, 12),
      ],
    );
    final z = scene.lightZones;
    expect(z['a'], z['b']);
    expect(z['c'], isNot(z['a']));
    // Gleiche Zone, gleiches Licht-Bit; der Nachbar c hat ein anderes.
    final ch = roomChannels(scene.rooms, z);
    expect(ch['a'], ch['b']);
    expect(ch['c'], isNot(ch['a']));
  });

  test('Tür auf der gemeinsamen Wand verbindet, Tür weit weg nicht', () {
    // Tür: Wandlinie an der Unterkante (lokal y = d/2), um 90° gedreht
    // liegt sie senkrecht auf x = 4.
    SceneObject door(String id, Offset c) => SceneObject.furniture(
      id: id,
      kind: 'door',
      center: c,
      w: 0.9,
      d: 0.9,
      rotation: 270,
    );
    final scene = Scene(
      rooms: [_rect('a', 0, 4), _rect('b', 4, 8), _rect('c', 8, 12)],
      objects: [
        door('t1', const Offset(3.55, 2)),
        door('t2', const Offset(6, 2)),
      ],
    );
    final z = scene.lightZones;
    expect(z['a'], z['b']);
    expect(z['c'], isNot(z['b']));
    // Echtzeitlicht teilt sich nur über offene Wände, nicht durch Türen.
    expect(scene.openZones['a'], isNot(scene.openZones['b']));
  });
}
