import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/data/models/room.dart';
import 'package:haven/data/models/widget_config.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/home/widgets/room_row.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  test('Altes Layout wird zu Kopf, Hinweisen, Szenen, Räumen und Karten', () {
    const rooms = [
      Room(id: 'a', name: 'A', lightIds: []),
      Room(id: 'b', name: 'B', lightIds: []),
    ];
    final legacy = HavenWidgetConfig.defaults;
    expect(isLegacyHome(legacy), isTrue);
    final home = effectiveHome(legacy, rooms);
    expect(home.map((w) => w.type).take(5), [
      HavenWidgetType.header,
      HavenWidgetType.notices,
      HavenWidgetType.scenes,
      HavenWidgetType.room,
      HavenWidgetType.room,
    ]);
    expect(home.skip(5).map((w) => w.id), legacy.map((w) => w.id));
    // Neu gespeichert: gelöschte Räume fallen weg, sonst bleibt alles.
    final saved = [...home, HavenWidgetConfig.forRoom('weg')];
    expect(isLegacyHome(saved), isFalse);
    expect(
      effectiveHome(saved, rooms).map((w) => w.roomId),
      isNot(contains('weg')),
    );
  });

  testWidgets('Neue Räume: hinzufügen oder nicht mehr fragen', (tester) async {
    tester.view.physicalSize = const Size(412 * 2.625, 1400 * 2.625);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    // Gespeichert: nur Kopf und der Salon.
    SharedPreferences.setMockInitialValues({
      'home_widgets': HavenWidgetConfig.encodeList([
        const HavenWidgetConfig(id: 'header', type: HavenWidgetType.header),
        HavenWidgetConfig.forRoom('salon'),
      ]),
    });
    final store = SettingsStore(await SharedPreferences.getInstance());
    late FakeRepository repo;
    await tester.runAsync(() async {
      repo = FakeRepository(simulate: false);
      await repo.start();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
          initialSessionProvider.overrideWithValue(
            Session(SessionMode.fake, repo),
          ),
        ],
        child: const HavenApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RoomRow), findsOneWidget);
    expect(find.text('Neuer Raum: Ruheraum'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find
            .ancestor(
              of: find.text('Neuer Raum: Ruheraum'),
              matching: find.byType(Row),
            )
            .first,
        matching: find.text('Hinzufügen'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Neuer Raum: Ruheraum'), findsNothing);
    expect(find.byType(RoomRow), findsNWidgets(2));
    await tester.tap(
      find.descendant(
        of: find
            .ancestor(
              of: find.text('Neuer Raum: Kochbereich'),
              matching: find.byType(Row),
            )
            .first,
        matching: find.text('Nein'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Neuer Raum: Kochbereich'), findsNothing);
    expect(store.hiddenRooms, contains('kochbereich'));
  });
}
