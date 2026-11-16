import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart' show MockClient;

import '../data/models/entity_state.dart';
import '../features/updates/app_installer.dart';

/// Erfundene `update.*`-Entities für Screenshots und Tests. Namen, Versionen
/// und Links sind frei erfunden.
List<EntityState> buildFakeUpdateEntities() => [
  const EntityState('update.home_assistant_core_update', 'on', {
    'friendly_name': 'Home Assistant Core Update',
    'title': 'Home Assistant Core',
    'installed_version': '2026.11.1',
    'latest_version': '2026.11.2',
    'release_summary': 'Kleine Korrekturen und neue Übersetzungen.',
    'release_url': 'https://example.org/core/2026.11.2',
    'in_progress': false,
    'auto_update': false,
    'skipped_version': null,
    'entity_picture': 'https://brands.home-assistant.io/homeassistant/icon.png',
    'supported_features': 1 | 2 | 4 | 8 | 16,
  }),
  const EntityState('update.mqtt_broker_update', 'on', {
    'friendly_name': 'MQTT-Broker Update',
    'title': 'MQTT-Broker',
    'installed_version': '6.4.1',
    'latest_version': '6.5.0',
    'release_summary': null,
    'release_url': 'https://example.org/addons/mqtt-broker/changelog',
    'in_progress': true,
    'update_percentage': 42,
    'auto_update': false,
    'entity_picture': '/api/hassio/addons/mqtt_broker/icon',
    'supported_features': 1 | 4 | 8 | 16,
  }),
  const EntityState('update.sonnenstand_update', 'on', {
    'friendly_name': 'Sonnenstand Update',
    'title': 'Sonnenstand',
    'installed_version': '1.2.0',
    'latest_version': '1.3.0',
    'release_summary': 'Neue Sensoren für Dämmerung und Mondphase.',
    'release_url': 'https://github.com/example/sonnenstand/releases/tag/v1.3.0',
    'in_progress': false,
    'auto_update': false,
    'entity_picture': 'https://brands.home-assistant.io/sonnenstand/icon.png',
    'supported_features': 1 | 16,
  }),
  const EntityState('update.dimmer_flur_firmware', 'on', {
    'friendly_name': 'Dimmer Flur Firmware',
    'title': 'Firmware',
    'device_class': 'firmware',
    'installed_version': '2.3.0',
    'latest_version': '2.4.1',
    'release_summary': 'Stabilere Verbindung, behebt gelegentliches Flackern.',
    'in_progress': false,
    'auto_update': false,
    'supported_features': 1 | 4,
  }),
  const EntityState('update.haven_update', 'on', {
    'friendly_name': 'Haven Update',
    'title': 'Haven',
    'installed_version': '0.2.0',
    'latest_version': '0.3.0',
    'release_summary': 'Updates der App und von Home Assistant in Haven.',
    'release_url': 'https://github.com/phiph-s/haven-ha/releases/tag/v0.3.0',
    'in_progress': false,
    'auto_update': false,
    'entity_picture': 'https://brands.home-assistant.io/haven/icon.png',
    'supported_features': 1 | 16,
  }),
];

/// Versionshinweise der erfundenen Updates (Markdown).
const Map<String, String> kFakeReleaseNotes = {
  'update.home_assistant_core_update': '## Änderungen\n\n- Neue Übersetzungen für den Zeitplan\n- Korrektur für **Szenen**, die beim Start doppelt liefen\n- Schnellerer Start der Datenbank\n\nMehr dazu in den `Versionshinweisen` auf der Webseite.',
  'update.mqtt_broker_update': '## 6.5.0\n\n- Neue Option `retain_limit`\n- Sicherheitskorrekturen\n\n1. Broker neu starten\n2. Verbindungen prüfen',
  'update.sonnenstand_update': '## Neu\n\n- Sensor für **Mondphase**\n- Dämmerung bürgerlich, nautisch und astronomisch\n\n## Korrekturen\n\n- Zeitzonen mit Sommerzeit',
  'update.haven_update': '## Haven 0.3.0\n\n- Updates in der App\n- Neue Befehle für die Integration\n\nDie App prüft beim Start auf neue Versionen.',
};

/// Release-Antworten der GitHub-API für die Entwicklungsdaten, damit die
/// Update-Karte der App sichtbar ist. Die Version liegt über der der App.
http.Client buildFakeReleaseClient({
  String appVersion = '0.6.0',
  int apkSize = 48000000,
}) => MockClient((req) async {
  final repo = req.url.pathSegments.length > 2
      ? '${req.url.pathSegments[1]}/${req.url.pathSegments[2]}'
      : '';
  final isApp = repo == 'phiph-s/haven';
  final v = isApp ? appVersion : '0.3.0';
  final tag = 'v$v';
  final body = {
    'tag_name': tag,
    'name': isApp ? 'Haven $v' : 'Haven Integration $v',
    'draft': false,
    'prerelease': false,
    'html_url': 'https://github.com/$repo/releases/tag/$tag',
    'body': isApp
        ? '## Neu\n\n- Schnellere **Raumansicht**\n- Neue Szenenfarben im Salon\n- Der Netzgraph zeigt Verbindungen genauer\n\n## Korrekturen\n\n- Die Helligkeit springt beim Ziehen nicht mehr zurück\n- Der `Alles aus`-Knopf beachtet Ausnahmen'
        : '## Neu\n\n- Befehle für Updates',
    'assets': isApp
        ? [
            {
              'name': 'haven-$v.apk',
              'size': apkSize,
              'browser_download_url':
                  'https://github.com/$repo/releases/download/$tag/haven-$v.apk',
            },
          ]
        : const [],
  };
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
});

/// Installer für Screenshots und Tests: tut so, als wäre es Android, ohne
/// etwas zu laden oder zu installieren.
class FakeAppInstaller implements AppInstaller {
  FakeAppInstaller({this.allowed = true, this.dir = '/tmp'});
  bool allowed;
  final String dir;
  final List<String> installed = [];
  int settingsOpened = 0;

  @override
  bool get supported => true;
  @override
  Future<String> cacheDir() async => dir;
  @override
  Future<bool> canInstall() async => allowed;
  @override
  Future<void> openInstallSettings() async => settingsOpened++;
  @override
  Future<void> install(String path) async => installed.add(path);
}
