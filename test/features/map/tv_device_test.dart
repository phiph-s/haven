import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/features/map/map_3d.dart';
import 'package:haven/features/map/placement_3d.dart';
import 'package:haven_3d/haven_3d.dart' as h3;

/// Ausdehnung eines Modells (min, max).
(h3.V3, h3.V3) _bounds(h3.Model3 m) {
  var lo = const h3.V3(1e9, 1e9, 1e9), hi = const h3.V3(-1e9, -1e9, -1e9);
  for (final p in m.points) {
    lo = h3.V3(
      p.x < lo.x ? p.x : lo.x,
      p.y < lo.y ? p.y : lo.y,
      p.z < lo.z ? p.z : lo.z,
    );
    hi = h3.V3(
      p.x > hi.x ? p.x : hi.x,
      p.y > hi.y ? p.y : hi.y,
      p.z > hi.z ? p.z : hi.z,
    );
  }
  return (lo, hi);
}

void main() {
  final tv = h3.deviceSpec('tv');

  group('Fernseher', () {
    test('Größe in Zoll: Standard 55″, begrenzt auf 24–98″', () {
      final s = tv.sizing!;
      expect(s.standard, 55);
      expect(s.clamp(null), 55);
      expect(s.clamp(10), 24);
      expect(s.clamp(120), 98);
      expect(s.clamp(double.nan), 55);
      // Bildbreite 16:9 aus der Diagonale und zurück.
      expect(h3.tvWidthOf(55), closeTo(1.218, 0.002));
      expect(h3.tvInchesOf(h3.tvWidthOf(65)), closeTo(65, 1e-9));
    });

    test('Breite folgt der Größe, zu große Werte werden begrenzt', () {
      double width(double? inch) {
        final (lo, hi) = _bounds(tv.model(h3.DeviceMount.stand, inch));
        return hi.x - lo.x;
      }

      expect(width(32), lessThan(width(55)));
      expect(width(55), lessThan(width(85)));
      expect(width(200), closeTo(width(98), 1e-9));
      expect(width(null), closeTo(width(55), 1e-9));
    });

    test('Montage: aufgestellt (drehbar, Bild nach +y) oder an der Wand', () {
      expect(tv.mounts, [h3.DeviceMount.stand, h3.DeviceMount.wall]);
      expect(tv.mountOf(null), h3.DeviceMount.stand);
      expect(tv.mountOf(h3.DeviceMount.ceiling), h3.DeviceMount.stand);
      expect(tv.canRotate(h3.DeviceMount.stand), isTrue);
      expect(tv.canRotate(h3.DeviceMount.wall), isFalse);
      expect(tv.isWall(h3.DeviceMount.wall), isTrue);
      expect(tv.heightFor(h3.DeviceMount.wall), 0.95);
      expect(tv.heightFor(h3.DeviceMount.stand), 0.5);
      // Aufgestellt: Bildschirm vorn (+y); an der Wand: Rückseite auf y = 0,
      // Bild nach -y in den Raum.
      final stand = tv.model(h3.DeviceMount.stand);
      final screen = stand.faces.where((f) => f.zone == 'screen');
      expect(
        screen.map((f) => f.centroid.y).reduce((a, b) => a + b),
        greaterThan(0),
      );
      final (wlo, whi) = _bounds(tv.model(h3.DeviceMount.wall));
      expect(whi.y, closeTo(0, 1e-9));
      expect(wlo.y, lessThan(-0.04));
      expect(wlo.z, closeTo(0, 1e-9));
    });

    test('Farbzonen Gehäuse und Bildschirm', () {
      expect(tv.zones.map((z) => z.id), ['housing', 'screen']);
      final zones = {for (final f in tv.model().faces) f.zone};
      expect(zones, {'housing', 'screen'});
    });

    test('Platzierung: Größe und Farben im JSON und in der Szene', () {
      const p = FloorPlacement(
        entityId: 'media_player.tv_salon',
        x: 4,
        y: 2,
        model: 'tv',
        mount: 'wall',
        size: 65.04,
        colors: {'housing': Color(0xFFF2EFE8)},
      );
      final j = jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>;
      expect(j['size'], 65.0);
      expect(j['colors'], {'housing': '#F2EFE8'});
      final back = FloorPlacement.fromJson(j);
      expect(back.size, 65.0);
      expect(back.colors['housing'], const Color(0xFFF2EFE8));
      expect(back.withColor('housing', null).colors, isEmpty);
      // Ohne Größe und Farben bleibt das JSON wie bisher.
      const plain = FloorPlacement(entityId: 'light.a', x: 1, y: 1);
      expect(plain.toJson().containsKey('size'), isFalse);
      expect(plain.toJson().containsKey('colors'), isFalse);
      final scene = sceneOfPlan(HavenFloorPlan(placements: [back]));
      final m = scene.markers.single;
      expect(m.size, 65.0);
      expect(m.colors['housing'], const Color(0xFFF2EFE8));
      expect(m.mount, h3.DeviceMount.wall);
    });

    test('Fernseher erkannt am Namen des Media-Players', () {
      String model(String id) => defaultDeviceModel(FloorKind.media, id);
      expect(model('media_player.tv_salon'), 'tv');
      expect(model('media_player.fernseher'), 'tv');
      expect(model('media_player.wohnzimmer_android_tv'), 'tv');
      expect(model('media_player.kueche'), 'speaker');
      expect(model('media_player.tvheadend_box'), 'speaker');
    });
  });

  group('Katalog und Wand', () {
    test('Wandmöbel rücken an die Wand, Hängendes hängt', () {
      for (final k in [
        'wall_cabinet',
        'mirror',
        'mirror_cabinet',
        'washbasin',
        'sideboard',
        'dresser',
        'bookcase',
        'coat_rack',
        'washing_machine',
        'dishwasher',
      ]) {
        expect(hugsWall(k), isTrue, reason: k);
      }
      for (final k in ['coffee_table', 'plant', 'rug', 'side_table', 'neu']) {
        expect(hugsWall(k), isFalse, reason: k);
      }
      // App-Katalog und 3D-Katalog sind sich einig.
      for (final t in kFurnitureCatalog) {
        final spec = h3.kFurnitureModels[t.id];
        expect(spec, isNotNull, reason: t.id);
        expect(spec!.wallHung, t.wallHung, reason: t.id);
        if (t.wallHung) expect(spec.elevation, greaterThan(0), reason: t.id);
        expect(spec.zones, isNotEmpty, reason: t.id);
      }
    });
  });
}
