import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/core/theme/tokens.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/features/map/furniture_ops.dart';
import 'package:haven/features/map/furniture_painter.dart';

const _grid = FloorGrid(cols: 20, rows: 20);

FloorFurniture _sofa({double rot = 0}) => FloorFurniture(
  id: 's',
  kind: 'sofa',
  x: 5,
  y: 5,
  w: 4,
  h: 2,
  rotation: rot,
);

void _near(Offset a, Offset b) {
  expect((a - b).distance, lessThan(1e-6), reason: '$a != $b');
}

void main() {
  group('Bibliothek', () {
    test('25 Elemente, eindeutige Kennungen, alle Gruppen', () {
      expect(kFurnitureCatalog.length, 25);
      expect(kFurnitureCatalog.map((t) => t.id).toSet().length, 25);
      for (final c in FurnitureCategory.values) {
        expect(kFurnitureCatalog.where((t) => t.category == c), isNotEmpty);
      }
      for (final t in kFurnitureCatalog) {
        expect(t.w, greaterThan(0));
        expect(t.h, greaterThan(0));
        expect(t.name, isNot(contains('!')));
      }
      expect(furnitureType('door')!.layer, 2);
      expect(furnitureType('rug')!.layer, 0);
      expect(furnitureType('gibt_es_nicht'), isNull);
    });

    test('jede Form lässt sich zeichnen, auch unbekannte', () {
      final rec = PictureRecorder();
      final canvas = Canvas(rec);
      final ink = FurnitureInk.map(HavenColors.dark);
      for (final t in kFurnitureCatalog) {
        paintFurnitureShape(canvas, t.id, Size(t.w * 20, t.h * 20), ink);
        paintFurnitureShape(canvas, t.id, const Size(2, 2), ink);
      }
      paintFurnitureShape(canvas, 'neu', const Size(40, 40), ink);
      rec.endRecording().dispose();
    });
  });

  group('Modell und JSON', () {
    test('Rundreise', () {
      final f = _sofa(rot: 30);
      final j = jsonDecode(jsonEncode(f.toJson())) as Map<String, dynamic>;
      expect(j, {
        'id': 's',
        'kind': 'sofa',
        'x': 5,
        'y': 5,
        'w': 4,
        'h': 2,
        'rotation': 30,
      });
      expect(FloorFurniture.tryFromJson(j), f);
    });

    test('liest tolerant, kaputte Einträge fallen weg', () {
      expect(FloorFurniture.tryFromJson(null), isNull);
      expect(FloorFurniture.tryFromJson({'id': 'a', 'kind': 'sofa'}), isNull);
      expect(
        FloorFurniture.tryFromJson({
          'id': 'a',
          'kind': 'sofa',
          'x': 1,
          'y': 2,
          'w': 'breit',
          'h': 1,
        }),
        isNull,
      );
      final f = FloorFurniture.tryFromJson({
        'id': 'a',
        'kind': 'zukunft',
        'x': 1,
        'y': 2,
        'w': 0,
        'h': 1,
        'rotation': -90,
      })!;
      expect(f.kind, 'zukunft', reason: 'unbekannte Art bleibt erhalten');
      expect(f.w, kFurnitureMinSide);
      expect(f.rotation, 270);
    });

    test(
      'Grundriss: optionales Feld, immer geschrieben, alt bleibt lesbar',
      () {
        final plan = HavenFloorPlan(
          rooms: [FloorRoom.rect(id: 'a', name: 'A', x: 1, y: 1, w: 6, h: 6)],
        );
        final json = plan.toJson();
        expect(json['version'], 2, reason: 'Schema bleibt 2');
        expect(json['furniture'], isEmpty);

        final old = Map<String, dynamic>.from(json)..remove('furniture');
        expect(HavenFloorPlan.fromJson(old).furniture, isEmpty);

        final withF = plan.withFurniture(_sofa());
        final back = HavenFloorPlan.decode(withF.encode());
        expect(back.furniture, [_sofa()]);
        expect(back, withF);
        expect(back == plan, isFalse, reason: 'Möbel zählen für ==');

        final broken = Map<String, dynamic>.from(withF.toJson())
          ..['furniture'] = [
            {'id': 'x'},
            _sofa().toJson(),
            _sofa().toJson(),
            'Müll',
          ];
        expect(HavenFloorPlan.fromJson(broken).furniture, [_sofa()]);
      },
    );

    test('Beispielgrundriss hat Möbel und bleibt gültig', () {
      expect(kFakeFloorPlan.furniture.length, greaterThan(20));
      expect(kFakeFloorPlan.validate(), isEmpty);
      for (final f in kFakeFloorPlan.furniture) {
        expect(f.type, isNotNull, reason: f.kind);
      }
    });
  });

  group('Geometrie', () {
    test('Ecken, Rechteck und Treffer bei 90°', () {
      final f = _sofa(rot: 90);
      final b = f.bounds;
      expect(b.left, closeTo(4, 1e-9));
      expect(b.right, closeTo(6, 1e-9));
      expect(b.top, closeTo(3, 1e-9));
      expect(b.bottom, closeTo(7, 1e-9));
      // Oben links (lokal) liegt nach 90° oben rechts.
      _near(f.corners.first, const Offset(6, 3));
      expect(f.contains(const Offset(5, 3.2)), isTrue);
      expect(f.contains(const Offset(6.6, 5)), isFalse);
      expect(f.contains(const Offset(6.1, 5), tolerance: 0.2), isTrue);
      _near(
        f.toLocal(f.toWorld(const Offset(1.3, -0.4))),
        const Offset(1.3, -0.4),
      );
    });

    test('Treffer: Teppich liegt unten, Tür oben', () {
      final rug = FloorFurniture(id: 'r', kind: 'rug', x: 5, y: 5, w: 8, h: 8);
      final table = FloorFurniture(
        id: 't',
        kind: 'coffee_table',
        x: 5,
        y: 5,
        w: 2,
        h: 1,
      );
      // Teppich zuletzt eingefügt: trotzdem gewinnt der Tisch.
      expect(furnitureAt([table, rug], const Offset(5, 5))!.id, 't');
      expect(furnitureAt([table, rug], const Offset(8, 8))!.id, 'r');
      expect(furnitureAt([table, rug], const Offset(15, 15)), isNull);
      expect(furnitureInPaintOrder([table, rug]).first.id, 'r');
    });
  });

  group('Editor-Operationen', () {
    test('Einsetzen rastet auf halbe Zellen', () {
      final f = placeFurniture(
        furnitureType('armchair')!,
        const Offset(3.37, 4.12),
        _grid,
        id: 'a',
      );
      final b = f.bounds;
      expect((b.left * 2) % 1, closeTo(0, 1e-9));
      expect((b.top * 2) % 1, closeTo(0, 1e-9));
      expect(f.w, 1.8);
    });

    test('Verschieben: Halbraster, frei, im Raster gehalten', () {
      final f = _sofa();
      final m = moveFurniture(f, const Offset(1.3, 0.2), _grid);
      expect(m.x, 6.5);
      expect(m.y, 5);
      final free = moveFurniture(f, const Offset(1.3, 0.2), _grid, snap: false);
      expect(free.x, closeTo(6.3, 1e-9));
      expect(free.y, closeTo(5.2, 1e-9));
      final out = moveFurniture(f, const Offset(100, -100), _grid, snap: false);
      expect(out.x, 20);
      expect(out.y, 0);
    });

    test('Skalieren hält die gegenüberliegende Kante', () {
      final f = _sofa();
      // Rechte Kante (x = 7) nach x = 8,2: Halbraster gibt Breite 5.
      final r = resizeFurniture(
        f,
        const FurnitureHandle(1, 0),
        const Offset(8.2, 9),
      );
      expect(r.w, 5);
      expect(r.h, 2, reason: 'Tiefe bleibt');
      expect(r.x - r.w / 2, closeTo(3, 1e-9), reason: 'linke Kante bleibt');
      // Ecke unten links frei, nicht unter die Mindestgröße.
      final c = resizeFurniture(
        f,
        const FurnitureHandle(-1, 1),
        const Offset(6.95, 4.05),
        snap: false,
      );
      expect(c.w, kFurnitureMinSide);
      expect(c.h, kFurnitureMinSide);
      expect(c.x + c.w / 2, closeTo(7, 1e-9));
      expect(c.y - c.h / 2, closeTo(4, 1e-9));
    });

    test('Skalieren eines gedrehten Möbels', () {
      final f = _sofa(rot: 90);
      // Lokal rechts (+x) zeigt nach 90° nach unten (+y). Untere Kante bei 7.
      final r = resizeFurniture(
        f,
        const FurnitureHandle(1, 0),
        const Offset(5, 8),
      );
      expect(r.w, 5);
      expect(r.x, closeTo(5, 1e-9));
      expect(r.y - r.w / 2, closeTo(3, 1e-9), reason: 'obere Kante bleibt');
    });

    test('Drehen: 15°-Schritte, frei, um 90°', () {
      final f = _sofa();
      // Zeiger rechts von der Mitte: Griff zeigt nach rechts, 90°.
      expect(rotateFurnitureTo(f, const Offset(9, 5)).rotation, 90);
      // 50° sind gerastet 45°.
      final p = Offset(5 + 3 * 0.766, 5 - 3 * 0.643);
      expect(rotateFurnitureTo(f, p).rotation, 45);
      expect(rotateFurnitureTo(f, p, snap: false).rotation, closeTo(50, 0.05));
      expect(rotateFurnitureBy(_sofa(rot: 300), 90).rotation, 30);
      expect(rotateFurnitureBy(f, -15).rotation, 345);
    });

    test('Duplizieren versetzt und vergibt eine neue ID', () {
      final d = duplicateFurniture(_sofa(), _grid, id: 'n');
      expect(d.id, 'n');
      expect(d.center, const Offset(6, 6));
      expect(d.kind, 'sofa');
      expect(newFurnitureId(), isNot(newFurnitureId()));
    });

    test('Griffe: Lage, Treffer, Mausform', () {
      final f = _sofa();
      Offset px(Offset c) => c * 30;
      final pts = furnitureHandlePoints(f, px, rotateGap: 20);
      expect(pts.length, 9, reason: '4 Ecken, 4 Kanten, Drehen');
      final rot = pts.firstWhere((p) => p.$1.isRotate).$2;
      _near(rot, const Offset(150, 100));
      expect(
        furnitureHandleAt(pts, const Offset(211, 181)),
        const FurnitureHandle(1, 1),
      );
      expect(furnitureHandleAt(pts, const Offset(150, 102))!.isRotate, isTrue);
      expect(furnitureHandleAt(pts, const Offset(160, 150)), isNull);
      // Kleines Möbel: keine Kanten-Griffe.
      final small = furnitureHandlePoints(
        FloorFurniture(id: 'p', kind: 'plant', x: 1, y: 1, w: 1, h: 1),
        (c) => c * 10,
      );
      expect(small.length, 5);

      expect(
        resizeAxisOf(const FurnitureHandle(1, 0), 0),
        ResizeAxis.horizontal,
      );
      expect(
        resizeAxisOf(const FurnitureHandle(1, 0), 90),
        ResizeAxis.vertical,
      );
      expect(
        resizeAxisOf(const FurnitureHandle(1, 1), 0),
        ResizeAxis.diagonalDown,
      );
      expect(
        resizeAxisOf(const FurnitureHandle(1, 1), 90),
        ResizeAxis.diagonalUp,
      );
    });

    test('Raum verschieben nimmt Möbel mit, Raum löschen entfernt sie', () {
      final plan = HavenFloorPlan(
        grid: _grid,
        rooms: [FloorRoom.rect(id: 'a', name: 'A', x: 2, y: 2, w: 6, h: 6)],
        furniture: [
          _sofa(),
          FloorFurniture(id: 'o', kind: 'plant', x: 15, y: 15, w: 1, h: 1),
        ],
      );
      final moved = plan.withRoomMoved('a', 2, 1);
      expect(moved.furnitureById('s')!.center, const Offset(7, 6));
      expect(moved.furnitureById('o')!.center, const Offset(15, 15));
      final gone = plan.withoutRoom('a');
      expect(gone.furniture.map((f) => f.id), ['o']);
      expect(plan.locationOfFurniture(_sofa()), 'a');
      expect(plan.withoutFurniture('s').furniture.length, 1);
      expect(
        plan.withFurniture(_sofa().copyWith(x: 6)).furnitureById('s')!.x,
        6,
      );
    });

    test('Maße als Text', () {
      expect(furnitureSizeText(_sofa(), 0.5), '2 × 1 m');
      expect(
        furnitureSizeText(_sofa().copyWith(w: 3.6, h: 4.25), 0.5),
        '1,8 × 2,13 m',
      );
    });
  });
}
