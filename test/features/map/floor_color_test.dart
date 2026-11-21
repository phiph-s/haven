import 'package:flutter_test/flutter_test.dart';
import 'package:haven/core/theme/theme.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/features/map/furniture_colors.dart';
import 'package:haven/features/map/map_3d.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final room = FloorRoom.rect(id: 'a', name: 'A', x: 0, y: 0, w: 8, h: 6);
  const oak = Color(0xFFC49A6C);

  test('Bodenfarbe: JSON hin und zurück, ohne Farbe kein Feld', () {
    expect(room.toJson().containsKey('floorColor'), isFalse);
    final r = room.copyWith(floorColor: oak);
    expect(r.toJson()['floorColor'], oak.toARGB32());
    final back = FloorRoom.fromJson(r.toJson());
    expect(back.floorColor?.toARGB32(), oak.toARGB32());
    expect(back, r);
    expect(back == room, isFalse);
    expect(r.copyWith(clearFloorColor: true).floorColor, isNull);
    expect(r.copyWith(name: 'B').floorColor, oak, reason: 'bleibt erhalten');
  });

  test('3D-Szene bekommt die Bodenfarbe', () {
    final plan = HavenFloorPlan(rooms: [room.copyWith(floorColor: oak)]);
    expect(sceneOfPlan(plan).rooms.single.floorColor, oak);
    expect(
      sceneOfPlan(HavenFloorPlan(rooms: [room])).rooms.single.floorColor,
      isNull,
    );
  });

  testWidgets('Farbwahl: Palette und Standard', (tester) async {
    Color? picked = oak;
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: havenDarkTheme,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, set) => FloorColorPicker(
              color: picked,
              onChanged: (c) => set(() {
                picked = c;
                calls++;
              }),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('floor-color-Schiefer')));
    await tester.pump();
    expect(picked, kFloorPalette.firstWhere((p) => p.name == 'Schiefer').color);
    await tester.tap(find.byKey(const ValueKey('floor-color-standard')));
    await tester.pump();
    expect(picked, isNull);
    expect(calls, 2);
  });
}
