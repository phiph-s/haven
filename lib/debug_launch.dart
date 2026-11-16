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
/// zigbee, automations, settings, updates, onboarding), `room` (Raum-ID),
/// `preset` (party: Neon Tokyo im Salon, Chill im Ruheraum).
/// `screen=floorplan_editor` öffnet den Grundriss-Editor, dort wählt `room`
/// den markierten Raum und `preset=devices` den Modus „Geräte setzen“.
/// `screen=zigbee_mesh` zeigt den Netz-Graphen, `select=<ieee>` (bzw. `ieee=`)
/// wählt einen Knoten, `filter=all` zeigt alle Verbindungen.
/// `screen=room&extent=0.5` öffnet das Raum-Sheet halb gezogen.
/// `screen=map&layer=temperature` wählt die Kartenart (`light`,
/// `temperature`, `humidity`, `presence`, `network`, `battery`),
/// `menu=1` klappt die Auswahl der Kartenarten auf, `t=-20` stellt den
/// Zeitstrahl der Bewegung auf vor 20 min.
/// `screen=floorplan_editor&drag=<Entity>` zeigt das Ziehen-Label.
class LaunchOverrides {
  const LaunchOverrides({
    this.theme,
    this.screen,
    this.room = 'salon',
    this.preset,
    this.ieee,
    this.extent,
    this.filter,
    this.layer,
    this.menu = false,
    this.drag,
    this.time,
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
      extent: q['extent'],
      filter: q['filter'],
      layer: q['layer'],
      menu: q['menu'] == '1',
      drag: q['drag'],
      time: q['t'],
    );
  }

  static const none = LaunchOverrides();

  final ThemeMode? theme;
  final String? screen;
  final String room;
  final String? preset;

  /// Zigbee-Gerät für `screen=zigbee_device&ieee=0x...`.
  final String? ieee;

  /// Raum-Sheet halb gezogen (`0.5`), nur für Screenshots.
  final String? extent;

  /// Filter des Netz-Graphen (`tree`, `all`, `weak`, `routers`).
  final String? filter;

  /// Kartenart (`MapLayer.name`).
  final String? layer;

  /// Auswahl der Kartenarten aufgeklappt (Screenshot).
  final bool menu;

  /// Entity, deren Ziehen-Label der Editor zeigt (Screenshot).
  final String? drag;

  /// Zeitstrahl der Bewegung in Minuten (z. B. `-20`).
  final String? time;

  /// Es gibt etwas zu überschreiben.
  bool get active => screen != null || theme != null || preset != null;

  String? get location => switch (screen) {
    'home' => '/home',
    'room' => '/room/$room${extent == null ? '' : '?extent=$extent'}',
    'sheet' => '/room/$room?sheet=1',
    'map' => Uri(
      path: '/map',
      queryParameters: !menu && time == null
          ? null
          : {if (menu) 'menu': '1', 't': ?time},
    ).toString(),
    'floorplan_editor' =>
      '/map/editor?mode=${preset == 'devices' ? 'devices' : 'rooms'}&sel=$room'
          '${drag == null ? '' : '&drag=$drag'}',
    'zigbee' => '/zigbee',
    'zigbee_device' => '/zigbee/device/${ieee ?? '0x00124b0000000009'}',
    'zigbee_pair' => '/zigbee/pair',
    'zigbee_mesh' => Uri(
      path: '/zigbee/mesh',
      queryParameters: ieee == null && filter == null
          ? null
          : {'select': ?ieee, 'filter': ?filter},
    ).toString(),
    'automations' => '/automations',
    'settings' => '/settings',
    'updates' => '/settings/updates',
    'onboarding' => '/onboarding',
    _ => null,
  };
}
