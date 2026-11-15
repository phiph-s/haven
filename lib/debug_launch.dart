import 'package:material_ui/material_ui.dart';

/// Startzustände für Screenshots im Web, z. B.
/// `?theme=dark&screen=room&room=salon&preset=party`.
///
/// Mit `--dart-define=HAVEN_FAKE=true` startet die App ohne Onboarding mit der
/// erfundenen Beispielwohnung aus `lib/dev/`, ein Aufruf mit `screen=` zusätzlich
/// ohne Zeitgeber (stabile Bilder). Ohne das Flag gibt es nur die Theme- und
/// Routenvorgabe, die Sitzung bleibt unberührt.
///
/// Parameter: `theme` (light, dark, system), `screen` (home, room, sheet, map,
/// zigbee, automations, settings, onboarding), `room` (Raum-ID),
/// `preset` (party: Neon Tokyo im Salon, Chill im Ruheraum).
/// `screen=floorplan_editor` öffnet den Grundriss-Editor, dort wählt `room`
/// den markierten Raum und `preset=devices` den Modus „Geräte setzen“.
/// `screen=zigbee_mesh` zeigt den Netz-Graphen, `select=<ieee>` (bzw. `ieee=`)
/// wählt einen Knoten.
class LaunchOverrides {
  const LaunchOverrides({
    this.theme,
    this.screen,
    this.room = 'salon',
    this.preset,
    this.ieee,
  });

  factory LaunchOverrides.fromUri(Uri uri) {
    final q = uri.queryParameters;
    return LaunchOverrides(
      theme: switch (q['theme']) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        'system' => ThemeMode.system,
        _ => null,
      },
      screen: q['screen'],
      room: q['room'] ?? 'salon',
      preset: q['preset'],
      ieee: q['ieee'] ?? q['select'],
    );
  }

  static const none = LaunchOverrides();

  final ThemeMode? theme;
  final String? screen;
  final String room;
  final String? preset;

  /// Zigbee-Gerät für `screen=zigbee_device&ieee=0x...`.
  final String? ieee;

  /// Es gibt etwas zu überschreiben.
  bool get active => screen != null || theme != null || preset != null;

  String? get location => switch (screen) {
    'home' => '/home',
    'room' => '/room/$room',
    'sheet' => '/room/$room?sheet=1',
    'map' => '/map',
    'floorplan_editor' =>
      '/map/editor?mode=${preset == 'devices' ? 'devices' : 'rooms'}&sel=$room',
    'zigbee' => '/zigbee',
    'zigbee_device' => '/zigbee/device/${ieee ?? '0x00124b0000000009'}',
    'zigbee_pair' => '/zigbee/pair',
    'zigbee_mesh' =>
      '/zigbee/mesh${ieee == null ? '' : '?select=${Uri.encodeQueryComponent(ieee!)}'}',
    'automations' => '/automations',
    'settings' => '/settings',
    'onboarding' => '/onboarding',
    _ => null,
  };
}
