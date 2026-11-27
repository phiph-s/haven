import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/dev/fake_data.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/room/room_group.dart';
import 'package:haven/features/room/widgets/scene_editor.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<FakeRepository> _pump(
  WidgetTester tester,
  String location, {
  Map<String, dynamic> inventory = kFakeInventory,
}) async {
  tester.view.physicalSize = const Size(412 * 2.625, 915 * 2.625);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final store = SettingsStore(await SharedPreferences.getInstance());
  late FakeRepository repo;
  await tester.runAsync(() async {
    repo = FakeRepository(
      simulate: false,
      localPrefs: store,
      inventory: inventory,
    );
    await repo.start();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
          initialSessionProvider.overrideWithValue(
            Session(SessionMode.fake, repo),
          ),
        ],
        child: HavenApp(initialLocation: location),
      ),
    );
  });
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  test('Lampen eines Raums nach Funk getrennt', () async {
    final repo = FakeRepository(simulate: false);
    await repo.start();
    addTearDown(repo.dispose);
    final s = repo.snapshot;
    final diele = roomLampsByRadio(s, s.room('diele')!);
    // Die Stehleuchte in der Diele läuft über Matter.
    expect(diele.other, contains('light.stehleuchte_diele'));
    expect(diele.zigbee, isNot(contains('light.stehleuchte_diele')));
    final wasch = s.room('waschraum')!;
    expect(wasch.zigbeeGroupId, isNull);
    expect(canCreateGroupFor(repo, s, wasch), isTrue);
    expect(canCreateGroupFor(repo, s, s.room('salon')!), isFalse);
  });

  testWidgets('Raum ohne Gruppe: anlegen, danach Szenen speichern', (
    tester,
  ) async {
    final repo = await _pump(tester, '/home/room/waschraum');
    final create = find.byKey(const ValueKey('room-group-create'));
    await tester.ensureVisible(create);
    expect(find.byType(SceneAddCard), findsNothing);
    await tester.tap(create);
    await tester.pumpAndSettle();
    expect(repo.snapshot.room('waschraum')!.zigbeeGroupId, isNotNull);
    expect(repo.canEditScenes('waschraum'), isTrue);
    expect(find.byKey(const ValueKey('room-group-card')), findsNothing);
    expect(find.byType(SceneAddCard), findsOneWidget);
    expect(find.textContaining('angelegt'), findsOneWidget);
    // Eine Szene lässt sich jetzt speichern.
    final n = await repo.storeScene('waschraum', name: 'Abend');
    expect(repo.snapshot.room('waschraum')!.scenes.map((s) => s.number), [n]);
  });

  testWidgets('Einstellungen: alle fehlenden Gruppen auf einmal', (
    tester,
  ) async {
    final repo = await _pump(tester, '/settings');
    await tester.tap(find.text('Räume verwalten'));
    await tester.pumpAndSettle();
    final create = find.byKey(const ValueKey('missing-room-groups-create'));
    await tester.ensureVisible(create);
    await tester.tap(create);
    await tester.pumpAndSettle();
    expect(repo.snapshot.room('waschraum')!.zigbeeGroupId, isNotNull);
    expect(find.byKey(const ValueKey('missing-room-groups')), findsNothing);
  });

  testWidgets('Szene speichern: Lampe außerhalb der Gruppe ist vorgewählt', (
    tester,
  ) async {
    final repo = await _pump(tester, '/home/room/ruheraum');
    await tester.tap(find.byType(SceneSaveChip));
    await tester.pumpAndSettle();
    expect(find.text('Weitere Geräte'), findsOneWidget);
    final row = find.byKey(
      const ValueKey('scene-device-light.leselampe_ruheraum'),
    );
    await tester.ensureVisible(row);
    expect(row, findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Kino');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Speichern').last);
    await tester.tap(find.text('Speichern').last);
    await tester.pumpAndSettle();
    final kino = repo.snapshot
        .room('ruheraum')!
        .scenes
        .firstWhere((s) => s.name == 'Kino');
    expect(kino.devices, ['light.leselampe_ruheraum']);
  });

  testWidgets('Lampe fehlt in der Gruppe: Karte nimmt sie auf', (tester) async {
    // Ruheraum-Gruppe ohne „Lampe Ruhebett“
    final inventory = {
      ...kFakeInventory,
      'z2m_groups': [
        for (final g in kFakeInventory['z2m_groups'] as List)
          if ((g as Map<String, dynamic>)['room'] == 'ruheraum')
            <String, dynamic>{
              ...g,
              'members': [
                for (final m in g['members'] as List)
                  if (m != 'Lampe Ruhebett') m,
              ],
            }
          else
            g,
      ],
    };
    final repo = await _pump(
      tester,
      '/home/room/ruheraum',
      inventory: inventory,
    );
    final room = repo.snapshot.room('ruheraum')!;
    expect(room.groupMissingLightIds, hasLength(1));
    expect(room.sceneLightIds, containsAll(room.groupMissingLightIds));
    expect(canCompleteGroupFor(repo, repo.snapshot.room('salon')!), isFalse);
    final add = find.byKey(const ValueKey('group-missing-add'));
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    expect(find.text('1 Lampe fehlt in der Zigbee-Gruppe'), findsOneWidget);
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(repo.snapshot.room('ruheraum')!.groupMissingLightIds, isEmpty);
    expect(find.byKey(const ValueKey('group-missing-card')), findsNothing);
    expect(find.textContaining('aufgenommen'), findsOneWidget);
  });
}
