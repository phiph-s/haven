import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/core/panel/panel_host.dart';
import 'package:haven/core/state/providers.dart';
import 'package:haven/data/storage/settings_store.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('Panel-Modus erkennen', () {
    test('außerhalb des Webs gibt es kein Panel', () {
      expect(detectPanelHost(), isNull);
    });

    test('Zustand aus dem JS-Objekt, tolerant', () {
      final s = PanelState.fromMap({
        'token': 'abc',
        'darkMode': true,
        'origin': 'https://ha.local:8123',
        'version': '0.4.0',
        'narrow': true,
        'language': 'de',
      });
      expect(s.token, 'abc');
      expect(s.darkMode, isTrue);
      expect(s.origin, 'https://ha.local:8123');
      expect(s.narrow, isTrue);
      expect(s.themeMode, ThemeMode.dark);

      final junk = PanelState.fromMap({
        'token': '',
        'darkMode': 'ja',
        'origin': 42,
        'narrow': null,
      });
      expect(junk.token, isNull);
      expect(junk.darkMode, isNull);
      expect(junk.origin, isNull);
      expect(junk.narrow, isFalse);
      expect(junk.themeMode, ThemeMode.system);
      expect(
        PanelState.fromMap(const {'darkMode': false}).themeMode,
        ThemeMode.light,
      );
      expect(
        PanelState.fromMap(const {'token': 'a'}),
        PanelState.fromMap(const {'token': 'a'}),
      );
    });
  });

  test('Theme folgt hass.themes.darkMode, Panel-Modus und Zustand', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore(await SharedPreferences.getInstance());
    final host = StaticPanelHost(const PanelState(darkMode: false));
    final c = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(store),
        panelHostProvider.overrideWithValue(host),
        themeModeProvider.overrideWith(() => PanelThemeModeController(host)),
      ],
    );
    addTearDown(c.dispose);
    expect(c.read(panelModeProvider), isTrue);
    expect(c.read(themeModeProvider), ThemeMode.light);
    final sub = c.listen(panelStateProvider, (_, _) {});
    addTearDown(sub.close);
    host.emit(const PanelState(darkMode: true, narrow: true));
    await Future<void>.delayed(Duration.zero);
    expect(c.read(themeModeProvider), ThemeMode.dark);
    expect(c.read(panelStateProvider)!.narrow, isTrue);
    expect(await host.freshToken(), 'test-token');

    final plain = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(plain.dispose);
    expect(plain.read(panelModeProvider), isFalse);
    expect(plain.read(panelStateProvider), isNull);
  });
}
