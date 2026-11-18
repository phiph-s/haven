import 'package:flutter_test/flutter_test.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/features/map/floor_editor_ops.dart';

void main() {
  final room = FloorRoom.rect(id: 'a', name: 'A', x: 0, y: 0, w: 8, h: 6);

  test('Offene Wände: JSON hin und zurück, ohne offene kein Feld', () {
    expect(room.toJson().containsKey('open'), isFalse);
    final r = setEdgeOpen(room, 1, true);
    expect(r.toJson()['open'], [1]);
    final back = FloorRoom.fromJson(r.toJson());
    expect(back.isOpen(1), isTrue);
    expect(back, r);
    expect(setEdgeOpen(r, 1, false).open, isEmpty);
  });

  test('Ecke einfügen teilt eine offene Kante, Nummern rücken weiter', () {
    final r = setEdgeOpen(setEdgeOpen(room, 1, true), 2, true);
    final next = insertVertex(r, 1)!;
    expect(next.points, hasLength(5));
    // Kante 1 wird 1 und 2 (beide offen), alte 2 wird 3.
    expect(next.open, {1, 2, 3});
  });

  test('Ecke entfernen: offen nur, wenn beide Nachbarkanten offen waren', () {
    final r = insertVertex(setEdgeOpen(room, 0, true), 0)!; // 0 und 1 offen
    expect(r.open, {0, 1});
    expect(removeVertex(r, 1)!.open, {0});
    final mixed = setEdgeOpen(r, 1, false);
    expect(removeVertex(mixed, 1)!.open, isEmpty);
  });

  test(
    'Vereinfachen behält die Ecke zwischen offener und geschlossener Wand',
    () {
      final r = setEdgeOpen(insertVertex(room, 0)!, 0, true); // nur 0 offen
      expect(simplifyRoom(r).points, hasLength(5));
      final both = setEdgeOpen(r, 1, true);
      final s = simplifyRoom(both);
      expect(s.points, hasLength(4));
      expect(s.open, {0});
    },
  );

  test('Gemeinsame Wand: Kante des Nachbarn auf derselben Linie', () {
    final b = FloorRoom.rect(id: 'b', name: 'B', x: 8, y: 2, w: 4, h: 6);
    // Kante 1 von A: (8,0)–(8,6); B hat (8,8)–(8,2) als Kante 3.
    final shared = sharedEdges(room, 1, [room, b]);
    expect(shared, {
      'b': [3],
    });
    // Kante 0 von A (oben) berührt B nicht.
    expect(sharedEdges(room, 0, [room, b]), isEmpty);
  });
}
