// Der Grundriss-Editor hält eine eigene Fassung des Plans. Speichert ein
// anderes Gerät, während er offen ist, darf seine nächste Änderung dessen
// Stand nicht zurückschreiben.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/app.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/data/models/floor_plan.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/data/sync/app_data.dart';
import 'package:haven/dev/fake_floor_plan.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/map/floor_plan_store.dart';
import 'package:haven/features/map/furniture_library.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryPlans implements FloorPlanRepository {
  _MemoryPlans([this.plan]);
  HavenFloorPlan? plan;
  @override
  Future<HavenFloorPlan?> load() async => plan;
  @override
  Future<void> save(HavenFloorPlan p) async => plan = p;
  @override
  Future<void> clear() async => plan = null;
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  testWidgets('Editor offen, anderes Gerät benennt einen Raum um: die nächste '
      'Änderung hier behält den neuen Namen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore(await SharedPreferences.getInstance());
    late FakeRepository server;
    await tester.runAsync(() async {
      server = FakeRepository(simulate: false);
      await server.start();
    });
    tester.view.physicalSize = const Size(412, 915) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final cache = _MemoryPlans(kFakeFloorPlan);
    final container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(store),
        tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
        initialSessionProvider.overrideWithValue(
          Session(SessionMode.fake, server),
        ),
        floorPlanRepositoryProvider.overrideWithValue(cache),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: HavenApp(
          initialLocation: '/map/editor?mode=furniture&view=2d&sel=salon',
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Der lokale Plan ist nach HA gewandert.
    final first = await server.fetchAppData(AppDataKind.floorplan);
    expect(first.isEmpty, isFalse);

    // Anderes Gerät: Salon heißt jetzt Wohnzimmer.
    final plan = Map<String, dynamic>.from(first.data!['plan'] as Map);
    plan['rooms'] = [
      for (final r in plan['rooms'] as List)
        (r as Map)['id'] == 'salon' ? {...r, 'name': 'Wohnzimmer'} : r,
    ];
    await server.storeAppData(AppDataKind.floorplan, {
      'plan': plan,
    }, first.updatedAt! + 1000);
    await tester.pumpAndSettle();
    expect(
      container.read(floorPlanProvider).value!.room('salon')!.name,
      'Wohnzimmer',
    );

    // Hier im noch offenen Editor: ein Sofa dazu.
    final before = kFakeFloorPlan.furniture.length;
    await tester.tap(
      find.byWidgetPredicate((w) => w is LibraryTile && w.type.id == 'sofa'),
    );
    await tester.pumpAndSettle();

    expect(cache.plan!.furniture.length, before + 1);
    expect(cache.plan!.room('salon')!.name, 'Wohnzimmer');
    final last = await server.fetchAppData(AppDataKind.floorplan);
    final saved = HavenFloorPlan.fromJson(
      Map<String, dynamic>.from(last.data!['plan'] as Map),
    );
    expect(saved.room('salon')!.name, 'Wohnzimmer');
    expect(saved.furniture.length, before + 1);
  });
}
