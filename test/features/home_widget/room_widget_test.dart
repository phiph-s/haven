import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/core/theme/theme.dart';
import 'package:haven/data/models/entity_state.dart';
import 'package:haven/data/models/room.dart';
import 'package:haven/data/models/snapshot.dart';
import 'package:haven/data/room_view.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:haven/dev/fake_repository.dart';
import 'package:haven/features/home_widget/room_widget_bridge.dart';
import 'package:haven/features/home_widget/room_widget_config_screen.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('Einstellung: Lampen, Thermometer und Bilder des Raums', () {
    const room = Room(
      id: 'salon',
      name: 'Salon',
      lightIds: ['light.a', 'light.b'],
      temperatureId: 'sensor.salon_t',
    );
    final snap = HavenSnapshot(
      rooms: const [room],
      entities: {
        for (final e in [
          const EntityState('light.a', 'on', {'brightness': 128}),
          const EntityState('light.b', 'off'),
          const EntityState('image.k_hell', '2026-11-19', {
            'room': 'r1',
            'theme': 'light',
          }),
          const EntityState('image.k_dunkel', '2026-11-19', {
            'room': 'r1',
            'theme': 'dark',
          }),
          const EntityState('image.anderer', '2026-11-19', {
            'room': 'r2',
            'theme': 'dark',
          }),
        ])
          e.entityId: e,
      },
    );
    final view = RoomView.from(snap, room);
    final cfg = roomWidgetConfig(snap, view, 'r1');
    expect(cfg['room'], 'salon');
    expect(cfg['name'], 'Salon');
    expect(cfg['lights'], ['light.a', 'light.b']);
    expect(cfg['temp'], 'sensor.salon_t');
    expect(cfg['image'], {'light': 'image.k_hell', 'dark': 'image.k_dunkel'});
    // Ohne Plan-Raum (keine Bilder): nur Licht und Temperatur.
    expect(roomWidgetConfig(snap, view, null)['image'], isEmpty);
  });

  test('Vergleich unabhängig von der Reihenfolge der Schlüssel', () {
    expect(
      canonicalJson({
        'b': 1,
        'a': {
          'y': 2,
          'x': [1, 2],
        },
      }),
      canonicalJson({
        'a': {
          'x': [1, 2],
          'y': 2,
        },
        'b': 1,
      }),
    );
    expect(canonicalJson({'a': 1}), isNot(canonicalJson({'a': 2})));
  });

  testWidgets('Einrichten: Raum wählen speichert und schließt', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('de.phiph.haven/room_widget'),
      (c) async {
        calls.add(c);
        return null;
      },
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
    SharedPreferences.setMockInitialValues({'ha_url': 'http://ha.local:8123'});
    final store = SettingsStore(await SharedPreferences.getInstance());
    final tokens = MemoryTokenStore();
    await tokens.write('geheim');
    late FakeRepository repo;
    await tester.runAsync(() async {
      repo = FakeRepository(simulate: false);
      await repo.start();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          tokenStoreProvider.overrideWithValue(tokens),
          // Wie angemeldet: Modus HA, Daten aus der Attrappe.
          initialSessionProvider.overrideWithValue(
            Session(SessionMode.ha, repo),
          ),
        ],
        child: MaterialApp(
          theme: havenDarkTheme,
          home: const RoomWidgetConfigScreen(widgetId: 7),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Raum fürs Widget'), findsOneWidget);
    await tester.tap(find.text('Salon'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    final methods = [for (final c in calls) c.method];
    expect(
      methods,
      containsAllInOrder(['setCredentials', 'saveWidget', 'finishConfigure']),
    );
    final cred = calls.firstWhere((c) => c.method == 'setCredentials');
    expect(cred.arguments, {'url': 'http://ha.local:8123', 'token': 'geheim'});
    final save = calls.firstWhere((c) => c.method == 'saveWidget');
    expect((save.arguments as Map)['id'], 7);
    final cfg = jsonDecode((save.arguments as Map)['config'] as String) as Map;
    expect(cfg['name'], 'Salon');
    expect(cfg['lights'], isNotEmpty);
  });
}
