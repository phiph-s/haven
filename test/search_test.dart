import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/room/room_screen.dart';
import 'package:haven/features/search/search_index.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

SearchItem _item(
  String title, {
  String? sub,
  SearchKind kind = SearchKind.device,
}) => SearchItem(
  kind: kind,
  title: title,
  subtitle: sub,
  icon: Icons.circle,
  open: (_, _) {},
);

Future<Widget> _app() async {
  SharedPreferences.setMockInitialValues({});
  final store = SettingsStore(await SharedPreferences.getInstance());
  final repo = FakeRepository(simulate: false);
  await repo.start();
  return ProviderScope(
    overrides: [
      settingsStoreProvider.overrideWithValue(store),
      tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
      initialSessionProvider.overrideWithValue(Session(SessionMode.fake, repo)),
    ],
    child: const HavenApp(),
  );
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  test('Umlaute und Schreibweisen treffen sich', () {
    expect(foldSearch('Küche'), foldSearch('kueche'));
    expect(foldSearch('Küche'), foldSearch('kuche'));
    expect(foldSearch('Groß_Lampe'), 'gross lampe');
  });

  test('Titel vor Untertitel, alle Wörter müssen passen', () {
    final index = [
      _item('Temperatur Bad', sub: '21,3 °C'),
      _item('Stehlampe', sub: 'Wohnzimmer · Temperatur egal'),
      _item('Bad', kind: SearchKind.room),
    ];
    final r = searchItems(index, 'temp');
    expect(r.first.title, 'Temperatur Bad');
    expect(r.map((i) => i.title), contains('Stehlampe'));
    expect(searchItems(index, 'bad 21').single.title, 'Temperatur Bad');
    expect(searchItems(index, 'bad').first.title, 'Bad');
    expect(searchItems(index, 'xyz'), isEmpty);
  });

  testWidgets('Suche: Raum finden und mit Enter öffnen', (tester) async {
    tester.view.physicalSize = const Size(412 * 2.625, 900 * 2.625);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async => tester.pumpWidget(await _app()));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Suchen').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('search-field')), 'salon');
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Raum Salon'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.byType(RoomScreen), findsOneWidget);
  });

  testWidgets('Suche: Werte finden (Sensoren)', (tester) async {
    tester.view.physicalSize = const Size(412 * 2.625, 900 * 2.625);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async => tester.pumpWidget(await _app()));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Suchen').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('search-field')),
      'temperatur',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('°C'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-field')), findsNothing);
  });
}
