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
/// `screen=map&layer=temperature` wählt die Kartenart (`combo`, `lamps`,
/// `temperature`, `humidity`, `presence`, `network`, `battery`),
/// `t=-20` stellt den Zeitstrahl der Bewegung auf vor 20 min.
/// `screen=map&layer=temperature&tap=<Entity>` tippt nach dem Start einen
/// Knoten an, `tap=room:<Raum-ID>` einen Raum (öffnet das Info-Sheet).
/// `screen=floorplan_editor&drag=<Entity>` zeigt das Ziehen-Label.
/// `screen=floorplan_editor&preset=furniture` öffnet „Einrichten“,
/// `fsel=<Möbel-ID>` wählt ein Möbelstück (z. B. `sofa`).
/// `screen=zigbee&ieee=<IEEE>` wählt am Desktop ein Gerät (Master-Detail).
/// `screen=map&inspect=<Raum>` wählt am Desktop einen Raum im Inspektor.
/// `screen=automations_ha` zeigt die HA-Automationen, `screen=automation_new`
/// den Drehregler-Assistenten (`room=`, `preset=<Schritt 0..6>`),
/// `screen=automation_edit` das Dashboard einer Beispiel-Automation
/// (`ieee=<ID>`, `preset=<Abschnitt 0..4>` öffnet dessen Sheet, `5` den
/// Live-Test, ohne `preset` nur das Dashboard), beide mit Beispielgesten im
/// Live-Test. `screen=motion_new&room=waschraum&preset=<Schritt 0..6>` ist der
/// Bewegungslicht-Assistent, `screen=motion_edit&preset=<Abschnitt>` das
/// Dashboard von `demo-waschraum`. `screen=heating&room=salon` öffnet die
/// Einrichtung der Heizungsregelung.
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
    this.drag,
    this.time,
    this.furniture,
    this.inspect,
    this.tap,
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
      drag: q['drag'],
      time: q['t'],
      furniture: q['fsel'],
      inspect: q['inspect'],
      tap: q['tap'],
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

  /// Entity, deren Ziehen-Label der Editor zeigt (Screenshot).
  final String? drag;

  /// Zeitstrahl der Bewegung in Minuten (z. B. `-20`).
  final String? time;

  /// Gewähltes Möbelstück im Editor (Screenshot).
  final String? furniture;

  /// Raum im Inspektor der Desktop-Karte (Screenshot).
  final String? inspect;

  /// Knoten (`<Entity>`) oder Raum (`room:<ID>`), der nach dem Start der Karte
  /// angetippt wird (Screenshot).
  final String? tap;

  /// Es gibt etwas zu überschreiben.
  bool get active => screen != null || theme != null || preset != null;

  String? get location => switch (screen) {
    'home' => '/home',
    'room' => '/room/$room${extent == null ? '' : '?extent=$extent'}',
    'sheet' => '/room/$room?sheet=1',
    'map' => Uri(
      path: '/map',
      queryParameters: time == null && inspect == null && tap == null
          ? null
          : {'t': ?time, 'inspect': ?inspect, 'tap': ?tap},
    ).toString(),
    'floorplan_editor' =>
      '/map/editor?mode=${switch (preset) {
            'devices' => 'devices',
            'furniture' => 'furniture',
            _ => 'rooms',
          }}&sel=$room'
          '${drag == null ? '' : '&drag=$drag'}'
          '${furniture == null ? '' : '&fsel=$furniture'}',
    'zigbee' => ieee == null ? '/zigbee' : '/zigbee?select=$ieee',
    'zigbee_device' => '/zigbee/device/${ieee ?? '0x00124b0000000009'}',
    'zigbee_pair' => '/zigbee/pair',
    'zigbee_mesh' => Uri(
      path: '/zigbee/mesh',
      queryParameters: ieee == null && filter == null
          ? null
          : {'select': ?ieee, 'filter': ?filter},
    ).toString(),
    'automations' => '/automations',
    'automations_ha' => '/automations/home-assistant',
    'automation_new' =>
      '/automations/knob/new?room=$room&step=${preset ?? 0}&demo=1',
    'automation_edit' =>
      '/automations/knob/${ieee ?? 'demo-salon'}?step=${preset ?? 6}&demo=1',
    'motion_new' =>
      '/automations/motion/new?room=$room&step=${preset ?? 0}&demo=1',
    'motion_edit' =>
      '/automations/motion/${ieee ?? 'demo-waschraum'}?step=${preset ?? 6}&demo=1',
    'heating' => '/heating/$room',
    'settings' => '/settings',
    'updates' => '/settings/updates',
    'onboarding' => '/onboarding',
    _ => null,
  };
}
