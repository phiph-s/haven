# Haven

*English: Haven is a smart-home app for Android (Flutter) that talks to Home Assistant and Zigbee2MQTT. It shows your rooms as light-coloured scenes, controls lights and scenes, manages Zigbee devices and draws a floor plan with the Zigbee mesh. It needs the companion integration [haven-ha](https://github.com/phiph-s/haven-ha) (installable through HACS). The UI is in German. Install the APK from the GitHub releases, connect with your Home Assistant URL and a long-lived access token of an administrator.*

Haven ist eine Smart-Home-App für Home Assistant und Zigbee2MQTT. Das Licht in einem Raum färbt die ganze Oberfläche. Die App zeigt Räume, Lampen und Szenen, verwaltet Zigbee-Geräte (Einstellungen, Umbenennen, Raum, Anlernen), zeichnet einen Grundriss mit Lichtkegeln und das Zigbee-Funknetz und listet die Abläufe (Automationen). Die Oberfläche ist deutsch.

> Screenshots folgen. (Platzhalter: `docs/screenshots/`)

## Installation

1. **Integration:** Die Home-Assistant-Integration [`haven-ha`](https://github.com/phiph-s/haven-ha) per HACS als benutzerdefiniertes Repository installieren (HACS, Menü, Benutzerdefinierte Repositories, Kategorie Integration) und in Home Assistant hinzufügen. Voraussetzung sind die MQTT-Integration und Zigbee2MQTT 2.x.
2. **App:** Die APK `haven-<version>.apk` aus den [GitHub-Releases](https://github.com/phiph-s/haven/releases) laden und auf dem Android-Gerät installieren (Installation aus unbekannten Quellen erlauben).

## Mit Home Assistant verbinden

Beim ersten Start fragt die App nach Adresse und Token.

- **Adresse:** die URL von Home Assistant, z. B. `http://homeassistant.local:8123`.
- **Token:** ein Long-Lived Access Token. In Home Assistant unter Profil, Sicherheit, „Langlebige Zugriffstoken“ erstellen. Das Konto sollte Administrator sein, sonst sind schreibende Funktionen (Geräte ändern, Grundriss, Einstellungen) gesperrt.

Der Token liegt verschlüsselt im Android-Keystore auf dem Gerät. Klartext-HTTP ist für Adressen im lokalen Netz erlaubt.

## Updates

**Die App selbst:** Haven fragt beim Start höchstens alle 6 Stunden die GitHub-Releases ab (`phiph-s/haven`, nur das neueste fertige Release, keine Vorabversionen). Gibt es eine neuere Version, erscheint auf der Übersicht eine Karte, die du schließen kannst (sie kommt erst mit der nächsten Version wieder). In den Einstellungen, Abschnitt „Updates“, stehen die Versionshinweise und der Knopf „Herunterladen und installieren“, dort suchst du auch von Hand. Haven lädt die APK in den App-Cache und übergibt sie dem Android-Installer. Beim ersten Mal fragt Android nach der Erlaubnis „Unbekannte Apps installieren“, Haven führt dich in die passende Einstellung. Das Update muss mit demselben Schlüssel signiert sein wie die installierte App. Auf Web und anderen Plattformen zeigt Haven nur die neue Version mit Link zur Release-Seite.

**Home Assistant:** Unter Einstellungen, „Updates in Home Assistant“, stehen alle `update.*`-Entities, gruppiert nach Home Assistant (Core, OS, Supervisor), Add-ons, Integrationen (HACS), Geräte (Firmware) und Haven. Du kannst Versionshinweise lesen, aktualisieren (auf Wunsch mit Backup vorher), überspringen oder alles auf einmal aktualisieren. Core, OS und Supervisor sind bei „Alle aktualisieren“ ausgenommen, weil Home Assistant dabei neu startet. Das bestätigst du einzeln, Haven verbindet sich danach von selbst wieder. Ist die Integration nicht über HACS installiert, erscheint ihr Update hier nicht. Haven weist darauf hin und zeigt, wenn `haven-ha` eine neuere Version hat.

## Entwicklung

```
flutter pub get
flutter analyze
flutter test
```

Ohne Home Assistant startet die App mit einer erfundenen Beispielwohnung (`lib/dev/`):

```
flutter run --dart-define=HAVEN_FAKE=true
```

Das Flag ist eine Compile-Zeit-Konstante, ohne sie enthält ein Release-Build keine dieser Daten. Für Screenshots im Browser:

```
flutter build web --dart-define=HAVEN_FAKE=true
# dann z. B. index.html?theme=dark&screen=room&room=salon&preset=party
```

Parameter stehen in `lib/debug_launch.dart`. Ab 1000 px Breite zeigt die App das Desktop-Layout (Seitenleiste, Spalten, Raum als Seitenpanel), darunter das Handy-Layout.

**Als Seitenleisten-Eintrag in Home Assistant:** `tool/build_ha_panel.sh` baut die Web-Fassung (`flutter build web --release --no-web-resources-cdn --base-href /haven_static/<version>/`), entfernt Überflüssiges (nur eine CanvasKit, keine Source-Maps, kein Service Worker) und kopiert sie nach `../integration/custom_components/haven/frontend/` (anderer Ort mit `--out`). Die Version kommt aus der `manifest.json` der Integration und muss dazu passen, nach jedem Versionssprung also neu bauen. Größe etwa 13 MB (CanvasKit 7 MB, App 4 MB, Lizenztexte 1,4 MB). Zum Testen ohne HA: `tool/build_ha_panel.sh --fake --out /tmp/x/haven_static/0.3.0`, `/tmp/x` per `python3 -m http.server` ausliefern und `/haven_static/0.3.0/?screen=home` öffnen. Aufbau und Konventionen: [ARCHITECTURE.md](ARCHITECTURE.md). Gestaltung und Entwürfe: [docs/design/](docs/design/spec.md). Android-Builds laufen auf einem Rechner mit Android SDK, Java 21 und Flutter (stable).

## Release

1. Version in `pubspec.yaml` anheben (`version: x.y.z+n`), committen.
2. Tag setzen und pushen: `git tag vX.Y.Z && git push origin vX.Y.Z`.
3. Der Workflow `release.yml` baut die signierte APK (`--build-name` aus dem Tag, `--build-number` aus der Lauf-Nummer) und legt ein GitHub-Release mit `haven-X.Y.Z.apk` und generierten Release Notes an.

Dafür müssen im Repository diese Secrets hinterlegt sein (Settings, Secrets and variables, Actions):

| Secret | Inhalt |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Keystore (`.jks`), Base64-codiert, z. B. `base64 -w0 haven.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | Passwort des Keystores |
| `ANDROID_KEY_ALIAS` | Alias des Schlüssels |
| `ANDROID_KEY_PASSWORD` | Passwort des Schlüssels |

Fehlt eines davon, bricht der Workflow mit einer Meldung ab.

Lokal signieren: `android/key.properties` mit `storeFile`, `storePassword`, `keyAlias`, `keyPassword` anlegen (steht in `.gitignore`), oder die Umgebungsvariablen `HAVEN_KEYSTORE`, `HAVEN_KEYSTORE_PASSWORD`, `HAVEN_KEY_ALIAS`, `HAVEN_KEY_PASSWORD` setzen. Ohne beides signiert der Release-Build mit dem Debug-Schlüssel und gibt eine Warnung aus.

## Lizenz

MIT, siehe [LICENSE](LICENSE). Copyright phiph-s.
