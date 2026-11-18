# haven_3d

3D-Ansicht für den Haven-Grundriss auf [flutter_scene](https://pub.dev/packages/flutter_scene).
Die Kamera ist orthographisch. Von oben sieht alles aus wie die 2D-Karte.
Kippt man die Kamera, bekommen Wände, Möbel und Geräte ihre Höhe.

- **Tiefenpuffer:** Verdeckung stimmt immer, auch bei verschachtelten Möbeln.
- **Licht:**
  - Umgebungslicht.
  - Ein Hauptlicht mit weichen Schatten.
  - Eingeschaltete Lampen werden zu Punktlichtern.
  - Jede Lampe leuchtet nur in ihrem Raum. Dafür nutzt flutter_scene Lichtkanäle: Benachbarte Räume bekommen verschiedene Bits (`roomChannels`). Das geht mit beliebig vielen Lampen. Echtzeit-Schatten rechnet flutter_scene nur für vier Punktlichter (`kMaxPointShadows`). Deshalb ist das Lampenlicht auf Böden und Möbel-Oberseiten gebaken (`lightbake.dart`).
    - Je Lampe und Fläche entsteht eine Textur mit weichen Schatten, berechnet mit Strahlen gegen die Möbel des Raums. Das dauert etwa 20 ms pro Boden und Lampe.
    - Zur Laufzeit werden die Texturen der eingeschalteten Lampen mit Farbe und Helligkeit zur Emissive-Textur der Fläche summiert. An, aus und Farbwechsel brauchen kein neues Baking.
    - Wände und Möbelseiten bekommen Echtzeitlicht ohne Schatten. Gebakene Flächen liegen im Lichtkanal `kBakedChannel`, den nur die Sonne erreicht.
- **Nur echte Kanten:** Knicke und offene Ränder, aber keine Linien auf ebenen Flächen. Das gilt auch für Möbel aus mehreren Teilen (`featureEdges`). Die Kanten bleiben beim Zoomen gleich breit.
- **Modelle nur angedeutet:** meist ein Quader. Merkmale wie Kissen, Kochfeld oder Fugen sind Detaillinien (`ModelBuilder.line`, `rectLines`, `ellipseLines`). Kanten und Linien gibt es nur in der Draufsicht: Beim Kippen blenden sie weich aus, schräg trägt die Schattierung. Schwarze Flächen gibt es nicht, `Mat.dark` ist ein mittleres Grau.
- **Wie die 2D-Karte:** Räume sind um einen halben Spalt eingerückt und haben runde Ecken (`SceneStyle.roomGap`, `roomRadius`). Alle Linien haben eine Farbe, Standard 2,5 px.
- **Flache und aufgestellte Räume:** `Scene3DView.raisedRooms` legt fest, welche Räume in 3D stehen, die übrigen liegen flach wie die 2D-Karte.
  - Flache Räume behalten ihre Linien auch schräg.
  - Lampen bleiben auf Deckenhöhe und beleuchten flache Räume von oben.
  - Unsichtbare Stellvertreter in voller Höhe werfen weiter die Schatten.
  - Beim Wechsel streckt sich der Raum vom Boden nach oben.
- **Durchsichtiger Hintergrund:** Ein Verlauf dahinter scheint durch. Wände und Böden sind halb durchsichtig.
- **Overlays:** Gerätepunkte sind normale Flutter-Widgets über der Szene. Ihre Position kommt aus derselben Projektion (`OrbitCamera.project`).

## Plattformen

| Plattform | Voraussetzung |
|---|---|
| Web | nichts, eigenes WebGL2-Backend von flutter_scene |
| Linux | `fl_dart_project_set_enable_flutter_gpu(project, TRUE)` im Runner (siehe `example/linux`) |
| Android | `<meta-data android:name="io.flutter.embedding.android.EnableFlutterGPU" android:value="true" />` im `<application>` |

Der eingebaute Browser der Claude-App hat kein WebGL. Dort bleibt die Szene leer, und nur die Overlays sind zu sehen.

## Aufbau

| Datei | Inhalt |
|---|---|
| `model.dart` | `V3`, `Face3`, `Model3` und der `ModelBuilder` mit Quader, Prisma, Loft, Zylinder, Kegel und Platte |
| `furniture/` | ein Modell je Möbel-Kennung der App, mit Standardhöhe und Abstand zum Boden |
| `scene.dart` | `SceneRoom` (Umriss → Wände), `SceneObject`, `SceneMarker` mit `LampState` und `Scene` |
| `camera.dart` | `OrbitCamera` mit `yaw`, `pitch`, `scale` und `pan`, dazu `project`, `fit` und `lerp` |
| `edges.dart` | echte Kanten eines Modells |
| `triangulate.dart` | Ohrenschneiden, auch für L-förmige Flächen |
| `picking.dart` | Treffertest ohne GPU: Gerät vor Möbel vor Raum |
| `style.dart` | `SceneStyle.light()` und `.dark()`: Farben, Deckkraft, Licht |
| `gpu_scene.dart` | Umwandlung in flutter_scene-Knoten; pro Bild nur Sichtbarkeit, Kantenbreite und Auswahl |
| `view.dart` | `Scene3DView` mit Gesten, `SceneController` (`show`, `setLamp`) und Overlays |

Koordinaten sind in Metern. `x` zeigt nach Osten, `y` nach Süden (wie im Plan), `z` nach oben.
Für flutter_scene wird gedreht: (x, z, −y).

## Karten-Funktionen für die App

- **Eine Karte für die ganze App:** Der `SceneController` hält die aufgebaute Szene samt Baking und die Kamera. Ein `Scene3DView` an anderer Stelle mit demselben Controller übernimmt beides ohne Neuaufbau. Es sollte immer nur ein `Scene3DView` gleichzeitig am Controller hängen.
- **Kartenarten:** Licht ist das gebakene Lampenlicht. Heatmaps (`SceneHeatmap`, Skalen in `HeatRamps` für Temperatur und Luftfeuchte) färben die Böden je Raum aus den eigenen Messpunkten, wie in der 2D-Karte. Die übrigen Arten (Bewegung, Funknetz, Batterie) laufen über die Marker-Widgets (`markerBuilder`).
- **Raumauswahl:** `selectedRoomId` umrandet den Raum in Akzentfarbe, in jeder Neigung sichtbar.
- **Fokus mit Zurück:** `controller.focus(markerId:/objectId:/roomId:, insets:, pitch:)` fährt hin und passt den Raum in den Bereich ohne `insets` ein, etwa das obere Drittel über einem Panel. `controller.back()` fährt zur Kamera davor zurück. Welche Räume dabei aufgestellt sind, steuert die App über `raisedRooms`.
- **Fenster** zeigen ihren Aufgehwinkel zur Raumseite. Die Szene dreht sie dafür bei Bedarf um 180° (`FurnitureSpec.facesRoom`).

## Leistung

- **Rendern nur bei Bewegung:** `Scene3DView` rendert nur, solange sich Kamera, Animation, Auswahl, Stil oder Lampen ändern, danach noch 0,9 s zum Nachladen. Eine stehende Karte kostet keine Bilder.
- **Qualitätsstufen:** `SceneQuality.low`, `medium` und `high` über `Scene3DView.quality`. Die Tabelle steht in `quality.dart`. Die Stufen drehen an Pixeldichte, MSAA oder FXAA, Bildrate, Sonnenschatten, Echtzeit-Lampenlicht und dem Raster des Bakings.
- **Messen:** `showStats: true` blendet oben links Bilder pro Sekunde, die CPU-Zeit von flutter_scene und die Raster-Zeit von Flutter ein. Aussagekräftig ist das nur im Profil- oder Release-Build.
- **Perspektive:** `SceneController.setPerspective(true)` blendet auf 40° Öffnungswinkel über. Der Maßstab auf Höhe des Ziels bleibt gleich.

## Tests

    flutter test                                   # ohne GPU: Kamera, Wände, Kanten, Treffer, Katalog
    flutter test --enable-flutter-gpu --enable-impeller test_gpu/render_test.dart
                                                   # rendert ohne Fenster nach build/gpu/*.png
    flutter test --enable-flutter-gpu --enable-impeller test_gpu/preview_test.dart --plain-name sofa
                                                   # ein Möbelstück aus vier Richtungen: build/preview/sofa.png

## Demo

    cd example && flutter run -d linux   # oder -d chrome
