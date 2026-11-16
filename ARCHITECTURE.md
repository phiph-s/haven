# Haven App: Architektur

Android zuerst (`de.phiph.haven`), Web nur zum Prüfen per Screenshot. State mit Riverpod 3, Routing mit go_router. Handgeschriebene Modelle, kein Codegen. Material kommt aus `package:material_ui` (Flutter 3.50), nicht aus `flutter/material.dart`.

## Ordner
```
lib/
  main.dart, app.dart        Start, Sitzung aus den Einstellungen, MaterialApp.router
  debug_launch.dart          ?theme=&screen=&room=&preset= für Screenshots (Screenshots, nur mit `HAVEN_FAKE=true`)
  core/
    theme/                   tokens.dart (HavenColors hell/dunkel als ThemeExtension, HavenRadii, HavenSpace,
                             HavenText, HavenMotion), theme.dart
    light/                   color_math.dart (Kelvin, HSL, uiColor, Kontrast, Mischung), room_palette.dart
                             (computePalette -> RoomPalette, lerp). Reine Dart-Logik, getestet.
    widgets/                 MeshGlow/AnimatedPalette, AccentScope, HavenSwitch, PressScale, HavenCard,
                             HavenButton, HavenSegmented, ScreenHeader/PlaceholderScreen, SectionHeader,
                             haven_sheet.dart (Sheets von unten, siehe „Sheets“), ...
    state/providers.dart     Sitzung, Snapshot, abgeleitete Provider, Theme-Modus, Widget-Liste
    router/router.dart       Routen, Redirect ins Onboarding, Raum-Übergang
  data/
    haven_repository.dart    Interface HavenRepository
    models/                  EntityState, Lamp, Room, RoomScene, RoomControl, HavenSnapshot, HavenWidgetConfig
    room_view.dart           RoomView, HouseView (mit ==, für gezieltes Neubauen)
    ha/                      HaClient (WebSocket), HaRepository
    storage/                 SettingsStore (SharedPreferences), TokenStore (Secure Storage)
    sync/                    app_data.dart (geteilte Dokumente, Abgleichregel), doc_sync.dart (DocSync)
  features/
    onboarding/ shell/ home/ room/ settings/     fertig (room ohne Drehregler, die stehen in der Geräteansicht)
    map/                                         Karte und Grundriss-Editor (fertig)
    zigbee/ automations/                         Platzhalter, werden von Folge-Agents gebaut
    updates/                                     App-Update und HA-Updates (siehe Abschnitt „Updates“)
  dev/                       Entwicklungsdaten, nur mit --dart-define=HAVEN_FAKE=true (siehe Abschnitt „Entwicklungsdaten“)
```

## Datenfluss
`Session` (Modus none/ha/fake plus Repository) -> `snapshotProvider` (hält den letzten `HavenSnapshot`) -> abgeleitete Provider (`roomsProvider`, `roomViewProvider(id)`, `houseViewProvider`, `entityProvider(id)`). Die Oberfläche liest nur Provider und ruft `ref.read(repositoryProvider)` für Aktionen. Aktionen wirken sofort (optimistisch), der Snapshot meldet danach den echten Zustand.

`HavenSnapshot`: `status` (connecting, connected, reconnecting, authFailed, offline), `entities` (alle HA-Entities als `EntityState`), `rooms`, `activeScenes`, `integrationMissing`.

Raumfarbe: `RoomView.palette(dark:)` bzw. `HouseView.palette(dark:)` ruft `computePalette` (hell und dunkel getrennt). `MeshGlow` und `AccentScope` lerpen bei Änderungen (800 ms, `RoomPalette.lerp`). Bildschirme, die zu einem Raum oder zum Haus gehören, stecken in `AccentScope(palette: ...)`, dann färben sich Schalter, Regler, Navigation und Primärknöpfe.

## Entwicklungsdaten (`lib/dev/`)
Für Screenshots und die Arbeit ohne Home Assistant gibt es `FakeRepository` mit einer erfundenen Beispielwohnung. Sie ist nur mit `--dart-define=HAVEN_FAKE=true` aktiv. `kHavenFake` (`dev/fake_flag.dart`) ist eine `const bool.fromEnvironment`, `main.dart` baut den Fake-Zweig nur dahinter, deshalb entfernt der Compiler im Release-Build `lib/dev/` per Tree-Shaking. Es gibt keine Assets.
- `fake_data.dart`: Konstanten `kFakeInventory` (5 Räume, 20 Zigbee-Geräte mit ihren HA-Entities, 2 Z2M-Gruppen mit Szenen, Wetter und 7 Automationen) und `kFakeZigbee` (die Geräte in der Form von `haven/zigbee/devices` samt `classified`). Die Geräte sind echte Zigbee2MQTT-Modelle mit ihren echten Exposes, Namen, Räume und IEEE-Adressen (`0x00124b00000000NN`) sind erfunden.
- `fake_rooms.dart`: baut die `Room`-Objekte. Jedes Gerät und jede Gruppe nennt seinen Raum selbst (`room`). Szenenfarben kommen aus `data/scene_styles.dart`.
- `fake_repository.dart`: simuliert Lampen (Farbe, Helligkeit, Szenen, Ausnahmen), Schalter, Automationen und leicht schwankende Messwerte. Mit `simulate: false` laufen keine Timer (Tests). Rohbefehle `haven/info`, `haven/rooms`, `haven/zigbee/devices`, `haven/zigbee/groups` beantwortet es aus den Konstanten.
- `fake_zigbee.dart`: Zigbee im Speicher (Einstellungen, Umbenennen, Anlernen simuliert, feste Netzkarte `buildFakeNetworkMap`).
- `fake_floor_plan.dart`: `kFakeFloorPlan`, der Beispielgrundriss. Er gilt über `HavenRepository.sampleFloorPlan`, solange kein Grundriss gespeichert ist.
- Screenshots: `lib/debug_launch.dart` liest `?theme=&screen=&room=&preset=` aus der URL (`flutter build web --dart-define=HAVEN_FAKE=true`). `screen=` startet den Fake ohne Zeitgeber.

## HA-Anbindung
`HaClient`: Auth per Long-Lived-Token, Request-IDs mit Futures, Abos überleben Reconnects, Backoff 1 bis 30 s, Ping alle 25 s. `HaRepository`: lädt `get_states`, abonniert `state_changed` und die drei `*_registry_updated`-Ereignisse (Räume neu laden, 400 ms gebündelt), holt Räume über `haven/rooms`, Gruppen/Szenen über `haven/zigbee/groups` und Ausnahmen über `haven/prefs/get`. Nach `zigbeeSetArea`, `zigbeeRename` und `zigbeeRemove` lädt es die Räume sofort neu (`reloadRooms`). Lichtbefehle werden pro Ziel auf 120 ms gedrosselt. Getestet gegen Fake-Kanäle mit anonymisierten Antworten einer echten HA-Installation (`test/ha_live_fixtures_test.dart`, Fixtures unter `test/fixtures/ha/`: Namen, Räume, Entity-IDs und IEEE-Adressen sind ersetzt, die Struktur ist echt), nicht gegen ein laufendes HA.

## Schnittstellen für Folge-Agents (Karte, Zigbee, Abläufe)
1. **Screen ersetzen:** `features/map/map_screen.dart` (`MapScreen`), `features/zigbee/zigbee_screen.dart` (`ZigbeeScreen`), `features/automations/automations_screen.dart` (`AutomationsScreen`). Der Name der Klasse bleibt, der Router muss nicht angefasst werden. Der Inhalt liegt schon in `SafeArea` und hinter der schwebenden Navigation: unten `HavenSpace.navClearance` (120) Platz lassen. Kopf mit `ScreenHeader(... actions: [SettingsButton()])`.
2. **Unterseiten:** `map_routes.dart`, `zigbee_routes.dart`, `automations_routes.dart` exportieren je `List<RouteBase>`, die der Router unter dem Tab einhängt (Pfade relativ, z. B. `GoRoute(path: 'editor', ...)` gibt `/map/editor`). Vollbildseiten ohne Navigation: `parentNavigatorKey: rootNavigatorKey` (aus `core/router/router.dart`).
3. **Daten:** `ref.watch(snapshotProvider)` für Entities und Räume. Neue abgeleitete Provider in dein Feature legen, nicht in `core/state`. Rohbefehle: `ref.read(repositoryProvider).command('haven/zigbee/devices')`, `command('haven/zigbee/device', {'ieee': ...})`. Dienste: `callService(domain, service, entityId:, data:)`. Für `haven/subscribe_zigbee` fehlt noch ein Stream im Interface: `HavenRepository.subscribe(type)` ergänzen (HaClient hat `subscribe` bereits, das Fake müsste Ereignisse simulieren).
4. **Farbe und Stil:** `context.hv` (Tokens), `HavenText`, `HavenRadii`, `HavenSpace`, `HavenMotion`. Lichtfarbe: `computePalette`, `uiColor`, `onColorFor`, `kelvinToRgb`. Glow: `MeshGlow`. Immer beide Modi prüfen. Bewegungsreduzierung: `context.reduceMotion` und `context.motion(duration)`.
5. **Persistenz:** Lokales in `SettingsStore`. Was alle Geräte sehen sollen, über `DocSync` als geteiltes Dokument in HA (siehe „Geteilte Daten“). Den `HavenFloorPlan` gibt es seit der Karten-Etappe (`data/models/floor_plan.dart`), siehe „Karte / FloorPlanView“.
6. **Tests:** `test/app_test.dart` zeigt, wie die App mit der Fake-Sitzung gepumpt wird (`initialSessionProvider`, `settingsStoreProvider`, `MemoryTokenStore`).

## Karte / FloorPlanView
Dateien: `data/models/floor_plan.dart` (Modell), `features/map/` (`floor_plan_view.dart`, `floor_plan_store.dart`, `map_screen.dart`, `map_painters.dart`, `map_markers.dart`, `map_data.dart`, `floor_editor_screen.dart`, `floor_editor_ops.dart`, `floor_assign_sheet.dart`, `map_routes.dart`). Route `/map/editor` (Vollbild, `mapEditorPath`), Karte und Einstellungen führen dorthin.

**Modell `HavenFloorPlan`** (unveränderlich, JSON nach Spec 5, `encode/decode`): `grid`, `rooms` (`FloorRoom` x, y, w, h in Zellen, `areaId`), `placements` (`FloorPlacement` entityId, roomId, rx, ry), `coordinator` (`PlanPoint`). `validate()` / `roomProblem(room)` prüfen Überlappung (gemeinsame Kante ist erlaubt), Mindestgröße 3 x 3 und Raster. Änderungen: `withRoom`, `withoutRoom` (nimmt Platzierungen mit), `withPlacement`, `withoutPlacement`, `withCoordinator`. Positionen in Zellen: `entityPosition(id, gap:)`, `coordinatorPosition(gap:)`, `cellOf(PlanPoint, layoutRects:)`. Geräte: `devicePoints([FloorDevice(id, entityIds, roomId:)])` liefert `PlanPoint` je Gerät: erst die Platzierung einer Entity (Reihenfolge der Liste), sonst Raummitte (`roomId` darf Plan-Raum-ID oder Bereichs-ID sein), mehrere unplatzierte im Kreis (Radius max(1, 0,22 n) Zellen, höchstens 30 % der kurzen Seite). Geräte ohne Platzierung und Raum fehlen im Ergebnis (Zigbee: „Ohne Raum“). `layout(gap: n)` liefert Raumrechtecke in Zellen: jede neue linke bzw. obere Kante rückt um n weiter, Größen bleiben, jedes Nachbarpaar hat mindestens n Abstand, Bruchwerte sind stetig. `kFakeFloorPlan` (`dev/fake_floor_plan.dart`) ist der Beispielgrundriss der Entwicklungsdaten, einige Geräte bleiben bewusst im Editor-Pool.

**Speichern:** `floorPlanProvider` (`AsyncNotifier<HavenFloorPlan?>`, `.notifier.save(plan)`, `.reset()`). `null` = kein Grundriss, in den Entwicklungsdaten gilt ohne gespeicherten Stand das Beispiel (`HavenRepository.sampleFloorPlan`). Quelle der Wahrheit ist HA (`haven/floorplan/get|set`), `FloorPlanRepository` (`LocalFloorPlanRepository`, Schlüssel `floor_plan_v1`) ist nur der lokale Cache. Abgleich über `DocSync`, siehe „Geteilte Daten“.

**`FloorPlanView`** (zentrale Schnittstelle für den Zigbee-Graph):
- `FloorPlanView(plan:, gap: 0, reserveGap: 2, nodes: [FloorNode(id:, point: PlanPoint)], nodeBuilder: (ctx, node) => Widget, overlayPainter:, underlayPainter:, roomStyle:, roomSubtitle:, onRoomTap:, onNodeTap:, interactive: true, fill:)`.
- `gap` ist animierbar: Wechsel 0 zu 2 fährt die Raumrechtecke in `gapDuration` (560 ms, `gapCurve`) auseinander. Knoten wandern per `Transform.translate` mit, ihre Widgets werden dabei nicht neu gebaut. `reserveGap` reserviert die Höhe für den größten Abstand, damit die Fläche nicht springt. Die Fläche passt den Plan in die Größe ein (der Maßstab sinkt mit wachsendem Abstand).
- `FloorOverlayPainter` (abstrakt: `paint(canvas, size, FloorGeometry)`, `shouldRepaint`, optional `repaint`) bekommt in jedem Frame die animierten Pixelrechtecke `geometry.rooms[roomId]`, die Knotenmitten `geometry.nodes[nodeId]`, `scale`, `gap`, dazu `pointToPx(PlanPoint)`. Kanten und Pfeile liegen im Overlay, Knoten-Widgets darüber. Der Koordinator ist ein normaler `FloorNode(id: 'coordinator', point: plan.coordinator!)`.
- Schichten: Raster (optional), Räume, `underlayPainter` (Karte: Lichtkegel), Raumnamen, `overlayPainter`, Knoten. Zoom und Pan per `InteractiveViewer` (1 bis 4 fach), Tippen auf Raum (`onRoomTap`) und Knoten (`onNodeTap`).
- Der Graph blendet die Karten-Marker nicht automatisch ein: Er übergibt eigene `nodes` und `nodeBuilder`.

**Karte (Tab):** Räume als weich gerundete Flächen, Lampen als Marker und Lichtkegel (`MapLightPainter`: `computePalette` für den Raumton, `uiColor` je Lampe, Radius ca. 0,6 mal kurze Seite, Deckkraft `.35 + .65 * Helligkeit`, auf den Raum geclippt). Temperatur und Feuchte stehen unter dem Raumnamen. Tippen auf eine Lampe schaltet sie (`Haptics.tick`), auf einen Raum öffnet die Raumansicht (nur wenn der Raum Lampen hat). Die Karte hängt an `mapLightsProvider(plan)` mit Wertgleichheit, sie baut nur bei Änderung platzierter Lampen oder Raumwerte neu.

**Editor:** Modus „Räume zeichnen“ (im Leeren ziehen legt an, danach Bottom Sheet zur Zuordnung; Ecken und Kanten ziehen ändert die Größe, Raum ziehen verschiebt; alles rastet ein, ungültige Ergebnisse werden nicht übernommen und angezeigt) und „Geräte setzen“ (Pool `buildDevicePool` pro Gerät, siehe unten; Halten und ziehen; Ablegen außerhalb eines Raums gibt die Platzierung frei). Rückgängig hat einen Stapel (40). Jeder Schritt wird sofort gespeichert. Haptik bei jedem Rasterschritt und beim Überfahren eines Raums.

## Zigbee-Netzgraph (Spec 5a)
Dateien: `data/models/zigbee_network.dart` (Modell), `features/zigbee/mesh/` (`mesh_scene.dart`, `mesh_painter.dart`, `mesh_graph.dart`, `mesh_screen.dart`, `mesh_providers.dart`), Miniatur in `widgets/mesh_card.dart`. Route `/zigbee/mesh` (`zigbeeMeshPath`, optional `?select=<ieee>`), Vollbild unter `zigbeeRoutes`.

- **Vertrag:** `ZigbeeApi.zigbeeNetworkMap({refresh})` ruft `haven/zigbee/networkmap` `{refresh: bool}` und liest das Z2M-Raw-Ergebnis (`nodes`, `links` unter `networkmap`, `value`, `data` oder oben) plus `timestamp` (ISO, Sekunden oder Millisekunden). Ohne `refresh` kommt sofort der Cache der Integration (`null` ohne Cache, dann eine leere Karte). Mit `refresh` antwortet die Integration erst nach der Messung (bei 43 Knoten 60 bis 90 s), deshalb sendet `HaZigbee` diesen Befehl mit eigenem Timeout (`networkMapRefreshTimeout`, 120 s) statt der 15 s von `HaClient`. Gegen eine echte Antwort geprüft: anonymisiert in `test/fixtures/ha/networkmap.json` (43 Knoten, 371 Links), Tests in `test/features/zigbee/networkmap_fixture_test.dart`.
- **Z2M-Rohformat:** Jeder Router und der Koordinator melden ihre Neighbor-Table. `target` ist das meldende Gerät, `source` der Nachbar, `relationship` beschreibt den Nachbarn aus Sicht von `target` (0 Eltern, 1 Kind, 2 Geschwister, 3 keine, 4 früheres Kind, wird ignoriert). Endgeräte melden nichts, sie stehen als `source` mit 1 bei ihrem Elternknoten. Jede Router-Router-Verbindung steht zweimal drin. Im echten Netz sind Router fast nur Geschwister (321 von 371 Links), `depth` 15 und 255 heißen unbekannt.
- **`ZbNetworkMap`:** `nodes` (`ZbMeshNode`: IEEE, Typ, `lqi` zum Elternknoten), `links` (roh), `edges` (je Knotenpaar genau eine Kante, beide Richtungen zusammengefasst, LQI gemittelt), `treeEdges` (nur die Kante jedes Knotens zu seinem Elternknoten, `inTree`, Richtung Kind zu Eltern), `parentOf`, `lqiToParent`, `childrenOf`, `neighborCount`, `pathToCoordinator` / `pathEdges`. Elternwahl: Endgeräte nehmen den gemeldeten Elternknoten (bei mehreren den stärksten), sonst den stärksten Router-Nachbarn, Endgeräte leiten nie weiter. Router bekommen den kürzesten Weg zum Koordinator über Router (Dijkstra, Kosten je Sprung `1 + (255 - lqi) / 85`, gemeldete Eltern/Kind-Kanten 15 % billiger). Ohne Weg bleibt der Pfad leer (im echten Netz 4 schlafende Endgeräte ohne Eintrag).
- **Filter:** `MeshFilter.tree` („Wege“, Standard: nur `treeEdges`, je Gerät eine Kante), `all` („Alle Verbindungen“: dazu jede Nachbarschaft dünn und leise ohne Pfeil, LQI-Zahlen nur am gewählten Knoten), `weak` und `routers` filtern die Baumkanten. Die Miniatur zeigt immer den Baum.
- **Neu messen:** `MeshNotifier.refresh` setzt `refreshing` und `refreshStarted`, `MeasureProgress` zeigt einen geschätzten Fortschritt (`1 - e^(-t/28)`, höchstens 95 %), den Text „Messung läuft, das kann bis zu einer Minute dauern“ und „Abbrechen“. `cancel()` beendet nur das Warten, ein spätes Ergebnis wird still übernommen, späte Fehler bleiben still. `meshErrorText` trennt die Ursachen (`timeout`, `bridge_offline`, `mqtt_error`, `unauthorized`, `busy`, `disconnected`, alte Integration).
- **Szene (`buildMeshScene`):** Gerätepositionen über `HavenFloorPlan.devicePoints` (Entity-Platzierung, sonst Raummitte im Kreis). Geräte ohne Raum liegen im zusätzlichen Raum `kNoRoomId` („Ohne Raum“) unter dem Grundriss, er gehört nur zur Szene und wird nie gespeichert. Ohne gespeicherten Grundriss entsteht ein Raster aus den Räumen der Geräte (8 x 8 Zellen) und die Ansicht zeigt den Hinweis zum Zeichnen. Koordinator: `plan.coordinator`, sonst der Raum mit den meisten direkten Geräten. „Koordinator platzieren“ zieht den Knoten und speichert per `floorPlanProvider.notifier.save(plan.withCoordinator(...))` (nur mit gespeichertem Grundriss, dabei ist Zoom aus).
- **Zeichnen:** Eine `FloorPlanView` mit `gap` 2 (Vollbild: Start bei 0 und nach dem ersten Bild auf 2, die Räume fahren auseinander), Kanten in einem `MeshEdgePainter` (`overlayPainter`, quadratische Bézierkurven, Pfeil zum Eltern, Farbe nach `LqiLevel` mit `ok`/`warn`/`bad`, Kanten im Raum dezent, zwischen Räumen kräftiger). LQI-Zahlen nur an schwachen Kanten, an Kanten des gewählten Knotens, des Pfads und bei höchstens 12 sichtbaren Kanten. Auswahl und Filter stehen in einem `ValueNotifier<MeshViewState>` (`repaint` des Painters, Knoten hören per `ValueListenableBuilder`), ein Tippen baut den Bildschirm nicht neu. Das Info-Sheet ist ein Panel über dem Graphen, damit der Pfad sichtbar bleibt.
- **Fake:** `buildFakeNetworkMap` (in `dev/fake_zigbee.dart`) baut die feste Topologie aus Grundriss und Gerätelagen, ohne Zufall, im selben Rohformat wie Z2M: Kinder in der Tabelle der Eltern, Router melden ihre Eltern nur zur Hälfte (sonst Geschwister), dazu Geschwister zwischen allen Routern in Reichweite, damit „Alle Verbindungen“ etwas zeigt. Die absichtlich schwachen Geräte bekommen keinen besseren Umweg. Das Fake setzt `linkquality` der Geräte aus der Topologie. Es lädt nichts aus `test/`.
- **Miniatur:** `ZigbeeMeshCard` zeigt denselben Graphen als `MeshGraph(mini: true)` ohne Interaktion und Beschriftung, Tippen öffnet das Vollbild. Ohne Netzkarte (lädt, Befehl fehlt) bleibt die Skizze.
- `lib/features/map/**` wurde nicht geändert, `FloorPlanView` reichte aus.

## Änderungen nach dem ersten Test (2026-11-15)
**Lichtgruppen** (`data/models/light_groups.dart`): `isLightGroup` erkennt HA-Gruppen (`entity_id`-Liste), Z2M-Gruppen (`group_entities`), Hue-Gruppen und Namen von Z2M-Gruppen. `Room.lightIds` enthält nie Gruppen, sie stehen in `Room.lightGroupIds`. `Room.groupEntityId` ist die HA-Entity der Z2M-Raumgruppe (aus `group_entity` der Integration 0.2.0, sonst über den Namen). `lightCallTargets` (`data/light_targets.dart`) ersetzt beim Schalten die Mitglieder durch die Gruppe, aber nur, wenn jedes Mitglied eine gesteuerte Lampe genau dieses Raums ist.

**Lichtsteuerung:** `HavenSnapshot.excludedLights` und `controlledLightIds(room)`. `lampsOf` liefert nur gesteuerte Lampen, `excludedLampsOf` die ausgenommenen. Raum an/aus, Helligkeit, „Alles aus“ und Szenen (Fake) nutzen nur gesteuerte Lampen. `HavenRepository.setLightExcluded` speichert über `haven/prefs/set` (`prefsShared`) oder lokal in `LocalPrefs` (`SettingsStore`, Entwicklungsdaten, Integration 0.1.0). Oberfläche: `features/room/widgets/light_control_list.dart` (Liste in den Einstellungen, Zeile im Lampen-Sheet, im Zigbee-Licht und im Raum als Hinweis „n Lichter nicht in der Lichtsteuerung“).

**Grundriss pro Gerät** (`features/map/device_pool.dart`): `buildDevicePool(snapshot, zigbeeDevices, plan)` liefert zwei Abschnitte, „Zigbee-Geräte“ (aus `haven/zigbee/devices` mit `ha_entities`, Hauptentity je `device_type`) und „Weitere Geräte“ (aus `rooms[].devices` der Integration 0.2.0, nur Lichter, Schalter, Klima, Medien, Melder; ohne 0.2.0 die Lampen und Klimasensoren der Räume einzeln). Platziert wird die Hauptentity mit `kind` und additivem `deviceId`. `HavenFloorPlan.migrateDevices` stellt alte Pläne beim Öffnen des Editors um (eine Platzierung je Gerät, die der Hauptentity gewinnt). `quickGrid` setzt „Schnell platzieren“ in ein Raster in der Raummitte. Neue `FloorKind`: `remote`, `contact`, `media`, `device`.

**Raum öffnen:** siehe „Sheets“ (seit 0.4.0, vorher Container-Transform aus der Kachel).

**Motion** (`HavenMotion`): d1 120, d2 200, d3 300, d4 450 ms (Farbe), Raum 340/280, Unterseiten 300/250, Tabs 240. Die Kurve `spring` schwingt nur noch etwa 3 % über, die Feder (`springDesc`) hat einen Dämpfungsgrad von etwa 0,85. `AccentScope` lerpt 300 ms, weil währenddessen der ganze Teilbaum neu baut. Glows lerpen länger, die malen nur.

**Edge-to-edge:** Android `MainActivity` setzt `setDecorFitsSystemWindows(false)` (darunter die alten Flags), durchsichtige Leisten unter API 35, keinen Kontrastschleier, Cutout `always` bzw. `shortEdges`. `styles.xml` (hell und dunkel) setzt durchsichtige Leisten und den Haven-Hintergrund als Fensterfarbe. Flutter: `SystemUiMode.edgeToEdge` in `main`, je Route `SystemBars` (`AnnotatedRegion`, Symbolhelligkeit nach Theme). `AppShell` hat kein `SafeArea` mehr: Der Router legt Tabs in `SafeArea(bottom: false)`, Zuhause lässt seinen Glow hinter der Statusleiste weiterlaufen. Sheets nutzen `useSafeArea: false` und polstern innen.

**Zustände:** Skeletons (`core/widgets/skeleton.dart`) statt Spinner in Zuhause (erste Verbindung), Zigbee-Liste, Gerät und Netzkarte. Ziehen zum Aktualisieren gibt es in Zuhause und Zigbee (`HavenRepository.refresh`). Hinweise für „unterbrochen“, „nicht erreichbar“ und „Token abgelehnt“, die beiden letzten führen in die Einstellungen. Räume ohne Lampen zeigen „Keine Lampen“.

### Profile-Build: worauf achten
`flutter run --profile` (Handy per USB, auf dem Desktop), dann DevTools, Performance:
- Raum-Sheet öffnen, ziehen und schließen: Kein Frame über 16 ms (bei 120 Hz über 8 ms). Pro Frame nur die Verschiebung des Sheets, der Schleier und die Skalierung der Hülle (`SheetBackdrop`, ein Clip mit Antialiasing). Kein `saveLayer`, kein `BackdropFilter`.
- Helligkeitsregler ziehen: Im UI-Thread baut nur der Regler. „Track widget rebuilds“: `RoomScreen` und `_RoomBody` bauen höchstens bei jeder neuen Zustandsmeldung neu, nicht pro Frame.
- Farbe im Lampen-Sheet ändern: `AccentScope` baut den Raum für etwa 300 ms pro Frame neu. Wenn das ruckelt, steht es zuerst hier.
- Tabwechsel: Nur der aktive Tab blendet, die anderen sind Offstage ohne Ticker.
- Netzgraph: Zoomen und Auswählen dürfen keine Neubauten auslösen (Painter mit `repaint`).
- Prüfen mit `--profile` und Impeller (Standard). Debug-Builds sind deutlich langsamer und taugen nicht zum Urteilen.

## Sheets (`core/widgets/haven_sheet.dart`, seit 0.4.0)
Alles, was von unten kommt, ist eine `HavenSheetRoute` (`PopupRoute`): der Raum (`HavenSheetPage`, go_router), Lampenfarbe, Gerät, Auswahl- und Einstellungs-Sheets (`showHavenModalSheet`, ersetzt `showModalBottomSheet`, nimmt Theme und Akzentfarbe des Aufrufers mit).
- **Bewegung:** Der Wert der Route ist der sichtbare Anteil (0 zu, 1 offen). Öffnen und Schließen laufen über `createSimulation` als Feder (`SheetMotion.open`: Steifigkeit 300, Dämpfungsgrad 0,9, etwa 300 ms; `close`: kritisch gedämpft, mit der Geschwindigkeit des Wischs). Keine Kurve, deshalb folgt das Sheet beim Ziehen exakt dem Finger. Pro Frame ändert sich nur eine `FractionalTranslation`, das Sheet liegt in einer `RepaintBoundary`.
- **Ziehen:** Am Griff (`SheetGrabber`) und bei `fit`-Sheets überall. Loslassen (`sheetShouldClose`): schneller als 700 dp/s nach unten schließt, nach oben öffnet, sonst schließt es unter der Hälfte und federt darüber zurück. Haptik beim Schließen.
- **Scrollen:** `SheetScrollController` (über `HavenSheetScope.scrollController`) erzeugt eine eigene `ScrollPosition`: Am oberen Ende übernimmt das Sheet das Ziehen nach unten, bei nicht ganz offenem Sheet auch das Ziehen nach oben, der Rest scrollt weiter. Das Prinzip wie bei `DraggableScrollableSheet`, nur dass das Sheet eine Route ist. Die Raumliste und die `SingleChildScrollView` der Sheets hängen daran.
- **Raum:** Route `/home/room/:id` (`Routes.room`, Root-Navigator, unter Zuhause eingehängt, damit ein Deep Link Zuhause dahinter hat). `/room/:id` leitet um, auch aus der Karte. Groß: 92 % der Höhe, oben mindestens Statusleiste plus 10 dp. Hintergrund `RoomPageBackdrop` (Raumfarbe als Glow) mit Radius `xl` und Haarlinie. `scalesBackground`: `sheetBackdropDepth` treibt `SheetBackdrop` um die Hülle, die App rückt um 6 % zurück und rundet die Ecken (Baum bleibt gleich, bei 0 ohne Clip), dazu ein Schleier mit 40 %. Android-Zurück und Tippen auf den Schleier schließen. Statusleiste bleibt durchsichtig (`SystemBars`).
- **Screenshots:** `?screen=room&extent=0.5` öffnet halb gezogen (nur Entwicklungsdaten).
- Ein mittlerer Rastpunkt fehlt bewusst: Er widerspricht „langsam über die Hälfte schließt“.

## Geteilte Daten (`data/sync/`, seit 0.4.0)
Grundriss (`floorplan`) und Übersicht (`widgets`: Widgets plus `layout.room_order`) liegen in HA, lokal nur als Cache für den schnellen Start und für offline. Ausgenommene Lichter (`prefs`) laufen weiter im Repository (`haven/prefs/*`, beim Verbinden und nach dem Ereignis neu geladen).
- **Schnittstelle:** `HavenRepository.fetchAppData(kind)` → `RemoteDoc(data, updatedAt)`, `storeAppData(kind, data, updatedAt)`, `appDataChanges` (Ereignis `haven_data_updated` der Integration 0.3.0, plus alle Arten nach jedem Verbinden). `HaRepository` liest `features` aus `haven/info`: mit `data_events` (0.3.0) gehen `updated_at` und `layout` mit, bei 0.2.0 nicht (die alten Schemas lehnen unbekannte Felder ab), dann steckt der Stempel nur im Plan (`plan.updatedAt`) und die Reihenfolge der Räume bleibt lokal. `BaseRepository` hält die Dokumente für die Entwicklungsdaten im Speicher.
- **`DocSync`:** startet mit dem lokalen Stand und gleicht dann ab (`decideSync`): Server leer und lokal etwas Eigenes: hochladen (Migration). Gleicher Stempel: nichts (Echo). Lokal ungespeichert und neuer: hochladen. Sonst gilt der Server. Jede lokale Änderung bekommt einen streng steigenden Stempel (ms) und geht 800 ms nach der letzten an HA (Entwicklungsdaten sofort). Solange ein Speichern aussteht, wird nichts übernommen. Stempel und „ungespeichert“ liegen im `SettingsStore` (`sync_<kind>_at`, `sync_<kind>_dirty`).
- **Fehler:** offline oder Timeout: bleibt offen, beim nächsten Verbinden wird hochgeladen. `unauthorized` (kein Admin) und `invalid_format`: Hinweis über `syncNoticeProvider` (Meldung oben, gleicher Text höchstens einmal pro Minute), danach gilt beim nächsten Abgleich wieder der Server. Lesen geht ohne Admin.
- **Nicht-Admins:** HA erlaubt `subscribe_events` ohne Admin nur für eine feste Liste von Ereignissen. Dann fehlt der Live-Abgleich, die App gleicht beim Verbinden und beim Ziehen zum Aktualisieren ab.
- **Reihenfolge der Räume:** `homeLayoutProvider` (`HomeLayout`: `widgets`, `roomOrder`), `orderedRoomsProvider` (`sortRooms`: bekannte nach Liste, neue Räume ans Ende). Im Bearbeiten-Modus der Übersicht werden die Kacheln zu einer Liste (`_RoomOrderList`), langes Drücken oder der Griff zieht. `widgetsProvider` ist eine Sicht auf `homeLayoutProvider`.

## Updates (App und Home Assistant)
Dateien: `features/updates/` (`app_release.dart`, `app_installer.dart`, `app_update_provider.dart`, `app_update_widgets.dart`, `ha_updates_provider.dart`, `updates_screen.dart`, `update_widgets.dart`), `data/models/ha_update.dart`, `core/widgets/simple_markdown.dart`, Entwicklungsdaten in `dev/fake_updates.dart`. Route `/settings/updates` (`Routes.updates`), Screenshot mit `?screen=updates`.

**App-Update:**
- `app_release.dart` ist reine Logik: `SemVer` (0.10.0 > 0.9.1, `-pre` unter der fertigen Version), `parseRelease` (Entwurf, Pre-Release und Tags ohne Version fallen weg, Asset `haven-<version>.apk`, sonst die einzige andere APK, nur https), `isCheckDue` (6 Stunden), `ReleaseChecker` über `package:http` (im Test `MockClient`).
- `AppUpdateController` (`appUpdateProvider`): prüft beim Start über `HomeScreen.initState` (`checkIfDue`) und manuell (`check`). Letzte Prüfung, weggewischte Version und das gefundene Release liegen im `SettingsStore` (`update_last_check`, `update_dismissed`, `update_latest_release`). Download mit Fortschritt in den App-Cache, Größe wird gegen das Asset geprüft, eine fertige Datei wird wiederverwendet.
- Installation: `AppInstaller` (`AndroidAppInstaller` ruft den `MethodChannel` `de.phiph.haven/installer` aus `MainActivity.kt`: `cacheDir`, `canInstall`, `openInstallSettings`, `install`). `install` nimmt nur Dateien aus dem App-Cache, baut per `FileProvider` (`${applicationId}.fileprovider`, `res/xml/provider_paths.xml`) die URI und startet `ACTION_VIEW`. Das Manifest hat `REQUEST_INSTALL_PACKAGES`. Fehlt die Erlaubnis, zeigt die Karte eine Erklärung und `Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES` mit `package:`-URI. Ohne Android (`supported == false`) öffnet der Knopf die Release-Seite (`url_launcher`).
- Versionen kommen aus `package_info_plus` (`main` überschreibt `appVersionProvider`), ohne Treffer gilt `kFallbackAppVersion`.

**HA-Updates:** `HaUpdate.fromEntity` liest die Attribute defensiv, `UpdateFeature` hält die Bits (INSTALL 1, SPECIFIC_VERSION 2, PROGRESS 4, BACKUP 8, RELEASE_NOTES 16). `classifyUpdate` ordnet nach `entity_id`, Titel, Symbol und `release_url` zu: Haven vor Core/OS/Supervisor-IDs vor Add-ons (`/api/hassio/addons/` im Bild) vor Firmware vor Rest (Integrationen). `HaUpdates` (mit `==`) hält die anstehenden (`state == on` oder laufend), `bulkTargets` schließt Core, OS, Supervisor und Laufendes aus. `UpdatesController` ruft `update.install` (mit `backup: true` nur bei Bit 8), `update.skip`, `update/release_notes` (nur bei Bit 16). Fortschritt kommt aus `in_progress` und `update_percentage` der normalen Zustands-Events. `timeout` und `disconnected` bei `update.install` gelten nicht als Fehler. Nach Core, OS oder Supervisor zeigt der Screen „Home Assistant startet neu“, solange die Verbindung weg ist, der vorhandene Reconnect holt sie zurück. `integrationInfoProvider` liest `haven/info.version` und das neueste Release von `phiph-s/haven-ha`, die Hinweiskarte gibt es nur, wenn keine Haven-Entity existiert.
- Fake: fünf erfundene Entities, `update.install` simuliert Fortschritt (mit Zeitgebern), `buildFakeReleaseClient` liefert erfundene GitHub-Releases (App 0.4.0), `FakeAppInstaller` für Screenshots mit Installationsknopf. In `main.dart` nur hinter `kHavenFake`.

## Konventionen
- Nur `Transform` und `Opacity` animieren, Glows in `RepaintBoundary`, Radialverlauf statt `BackdropFilter`. Regler und Drehregler zeichnen per `CustomPainter` mit `repaint:`-Listenable (kein Neubau pro Frame).
- Zielgrößen mindestens 48 dp (sichtbar darf kleiner sein).
- Texte deutsch, Du, knapp, keine Ausrufezeichen.
- Neue Webdienste und Secrets: nichts im Repo. Der Token liegt nur im Secure Storage.

## Offen
- Raum-Sheet (Feder, Ziehen, Zusammenspiel mit dem Scrollen, Zurück-Geste): nur in Widget-Tests und im Web geprüft, auf dem Gerät noch nicht.
- Geteilte Daten mit echtem HA (Integration 0.3.0, Ereignis `haven_data_updated`) ungeprüft. Ohne Admin-Token fehlt der Live-Abgleich (HA-Allowlist für `subscribe_events`).
- „Netz neu messen“ mit 120 s Timeout gegen echtes HA noch nicht wiederholt (die Antwort selbst ist live geprüft).
- Predictive Back (Android 14+, `enableOnBackInvokedCallback`) ist aus, weil die verschachtelten go_router-Navigatoren damit nicht geprüft sind. Zurück per Geste und Taste funktioniert normal.
- Z2M-Szenen schalten alle Gruppenmitglieder, auch ausgenommene Lichter, wenn sie in der Gruppe stecken.
- OAuth-Login über HA statt Token (TODO in `onboarding_screen.dart` und `ha_client.dart`).
- Manifest hat INTERNET und erlaubt Klartext-HTTP für LAN-Adressen.
- Raum-Szenen in HA: Szenenfarben sind erfunden, `scene.turn_on` ruft die Z2M-Gruppenszene auf.
