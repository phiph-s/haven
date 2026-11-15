# Haven · Gestaltungsspezifikation (Entwurf 2)

Gehört zu `entwurf-2.html`. Die Tokens stehen dort als CSS-Variablen am Anfang. Flutter-Namen sind Vorschläge.

## 1. Design-Tokens

### Farben (Oberfläche, neutral)
| Token | Dunkel | Hell | Verwendung |
|---|---|---|---|
| bg | #0D0C12 | #F6F1EA | Seitenhintergrund |
| s1 | #17151F | #FFFFFF | Karten, Kacheln |
| s2 | #211E2B | #EFE8DE | Felder, Regler-Spur, Chips |
| s3 | #2D2939 | #E2D9CB | Schalter-Spur, aktiver Tab |
| tx / tx2 / tx3 | #F5F1FB / #BDB6CB / #968FA5 | #1D1923 / #575063 / #6C6477 | Text primär, sekundär, Hinweise |
| ln / ln2 | weiß 8 % / 14 % | #281932 9 % / 16 % | Haarlinien |
| acc / acc2 / ai | #B9AAFF / #8F7BFF / #17121F | #6A50E8 / #8D77FF / #FFFFFF | Standard-Akzent ohne Licht, `ai` = Schrift auf Akzent |
| ok / warn / bad | #3EE0A6 / #FFC14D / #FF7078 | #12906A / #A96A00 / #D1343F | Status, LQI |

Hell ist nicht invertiert: warmes Papier (#F6F1EA) statt Grau, weiße Karten mit weichen warmen Schatten, Statusfarben dunkler gezogen (Kontrast mindestens 4,5:1 auf s1).
Ohne leuchtende Lampe ist die App fast einfarbig. Farbe kommt nur vom Licht, Standardakzent ist ein zurückhaltendes Violett.

### Radien, Abstände, Typo
- Radien: s 12, m 18, l 26 (Kacheln, Karten), xl 34 (Sheets, Regler). Schalter und Chips sind Pillen.
- Abstände: 4, 8, 12, 16, 24. Seitenrand 20.
- Typo (Systemschrift, Rounded wo vorhanden): Display 38/800, Titel 34/800, Section 21/800, Headline 18/800, Body 15/400, Label 13,5/700, Caption 12/500. Zahlen groß (Prozent 64/800, Leistung 34/800).

### Motion
| Token | Wert |
|---|---|
| spring | cubic-bezier(.34,1.45,.5,1), leichtes Überschwingen |
| out | cubic-bezier(.2,.8,.2,1) |
| d1 / d2 / d3 / d4 | 150 / 280 / 520 / 800 ms |

## 2. Lichtfarbe wird Oberflächenfarbe

Eingang je Lampe: `on`, `brightness` 0..100, `rgb_color` (bei Farbmodus) oder `color_temp_kelvin`.

1. **Lampenfarbe c.** Farbmodus: `rgb_color` direkt. Weißmodus: Kelvin nach RGB (Näherung nach Tanner Helland, 1000..40000 K). HA liefert für beide `rgb_color`, es wird bevorzugt.
2. **UI-Farbe `ui(c)`** (Lesbarkeit). Nach HSL wandeln und klemmen:
   - Sättigung S: unter 0,25 wird `S*1,8` (weiche Weißtöne bleiben leicht getönt), sonst `clamp(S, .45, .95)`.
   - Helligkeit L: dunkel `clamp(L, .52, .70)`, hell `clamp(L, .50, .62)`.
   So bleibt Kontrast zu Text erhalten, ein sehr dunkles Blau (Kino) wird sichtbar, ein fast weißes Licht blendet im Hellmodus nicht.
3. **Mischung je Raum.** Eingeschaltete Lampen nach Helligkeit sortieren, dann drei Farben:
   - primär: hellste Lampe,
   - sekundär: erste Lampe mit Farbton mehr als 40 Grad entfernt, sonst zweite, sonst primär,
   - Mix: gewichteter quadratischer Mittelwert der UI-Farben mit Gewicht `Helligkeit + 10` (Mittelung im quasi-linearen Raum vermeidet Schlammfarben).
   Aus Raum-Farben und Hausfarben (alle Lampen) entsteht ein **Mesh**: drei Radialverläufe (primär oben links, sekundär rechts, Mix unten) mit Alpha .95/.85/.8.
4. **Intensität.** Deckkraft der Glow-Ebene `(.3 + .7 * hellsteLampe/100) * Stärke * Modusfaktor`. Modusfaktor Kachel: dunkel .95, hell .7. Stärke ist in Einstellungen einstellbar. Licht aus: Deckkraft 0, die Kachel bleibt neutral.
5. **Schrift auf Farbflächen** (`onC`). Relative Luminanz L der Fläche, Kontrast zu Weiß `1,05/(L+.05)` gegen Kontrast zu Tinte `(L+.05)/.057`, die bessere Seite gewinnt. Gilt für Szenenkarten, Icon-Kreise, Lampenpunkte. Text auf Kacheln liegt immer auf neutraler Fläche mit schwachem Glow und nutzt tx.
6. **Akzent.** `--acc` und `--acc2` pro Bildschirm: Zuhause mit Hausfarbe, Raum mit Raumfarbe, sonst Standard. `--ai` per `onC`. Schalter, Tab-Symbol, Primärbutton übernehmen das.
7. **Animation des Farbwechsels.** Jede Glow-Fläche hat zwei Ebenen. Neue Farbe in die verdeckte Ebene schreiben, dann Cross-Fade (opacity, 800 ms). Es wird nie `background` animiert.
8. **Szenen.** Jede Szene hat drei Karten-Farben, Helligkeit und optional Kelvin. Beim Anwenden bekommt Lampe i die Farbe `palette[i mod 3]` (Weißszene: Kelvin), `scene.only` begrenzt auf Lampen (Lichtleiste).

## 3. Komponenten und Flutter-Gegenstücke

| Komponente | Verhalten | Flutter (Vorschlag) |
|---|---|---|
| Glow / MeshGlow | zwei Ebenen, Cross-Fade, Deckkraft = Helligkeit | `AnimatedOpacity` plus `Stack` mit `RadialGradient`, Mesh alternativ Shader (`FragmentProgram`) |
| RoomTile | Tippen schaltet, Halten oder Pfeil öffnet, Press-Scale | `GestureDetector` (onTap, onLongPress), `AnimatedScale` mit `Curves.easeOutBack` |
| Shared-Element-Übergang | Kachel wird Raumansicht (FLIP) | `Hero` mit `createRectTween`, oder Paket `animations` (`OpenContainer`) |
| Toggle (haptisch) | Daumen weitet beim Drücken, Federweg | `AnimatedAlign`, `HapticFeedback.selectionClick`, Federn per `SpringSimulation` |
| BrightnessSlider (vertikal, horizontal) | Drag, Füllung per Skalierung, Raster bei 10 % haptisch | `GestureDetector` mit `onVerticalDragUpdate`, `CustomPainter` oder `ClipRRect` plus `FractionallySizedBox` |
| SceneCard | Verlauf, Häkchen, aktiv angehoben | `AnimatedContainer`, `LinearGradient`, `Material` |
| LampRow | Farbpunkt, Name, Schalter | `ListTile` angepasst |
| BottomSheet | Spring-In, Ziehen zum Schließen | `showModalBottomSheet` mit `DraggableScrollableSheet` |
| ColorWheel | Farbton = Winkel, Sättigung = Radius | Paket `flutter_colorpicker`, oder `CustomPainter` mit `SweepGradient` plus `RadialGradient` |
| KelvinSlider | 2000..6535 K Verlauf | `Slider` mit eigenem `SliderTrackShape` |
| RotaryDial | Drehregler 270 Grad, Ticks | `CustomPainter`, `GestureDetector` onPanUpdate, `atan2` |
| SegmentedControl | Daumen gleitet | `CupertinoSlidingSegmentedControl` oder `AnimatedAlign` |
| FloorPlan (Karte, Editor) | Raster, Räume, Marker, Lichtkegel | `CustomPainter` für Räume und Kegel, `Stack` mit `Positioned` für Marker, `InteractiveViewer` zum Zoomen |
| MeshGraph | Cluster je Raum, Kanten mit LQI | `CustomPainter` mit Kraftlayout (statisch vorberechnet), Tipp per `hitTest` |
| PairWizard | Radar, Gefunden, Name und Raum | `Stepper`-ähnlich mit `AnimatedSwitcher`, Radar per `AnimationController` |
| ProblemRow | Grund, Aktion, Raus-Animation | `Dismissible` oder `AnimatedList` |
| DeviceHero | Inline-SVG, Zustandsring | Paket `flutter_svg` oder `CustomPainter` |
| AutomationRow | Schalter, Jetzt-Taste, zuletzt | `ListTile`, `FilledButton.tonal` |
| Toast | Spring von oben | `ScaffoldMessenger`, eigenes `Overlay` |
| BottomNav | schwebende Pille, Blase gleitet | `NavigationBar` mit eigener Indicator-Form |
| Theme | Hell, Dunkel, System | `ThemeMode`, `ThemeExtension` für Haven-Tokens (`HavenColors`, `HavenMotion`) |

Zustand: Riverpod oder Bloc. Lampen, Räume, Plan als unveränderliche Modelle (`freezed`), Räume leiten Mix und Akzent per Selector ab.

## 4. Motion-Regeln
- Nur `transform` und `opacity` animieren. Farbwechsel per Cross-Fade, Füllstände per Skalierung, Positionen per Translation.
- Federn (spring) für alles, was eine Hand bewegt: Schalter, Kacheln, Sheets, Marker. Ausblenden und Schließen mit `out`, kürzer als Einblenden (360 gegen 560 ms).
- Press: Skalierung .95 bis .88 beim Drücken, Rückkehr mit Feder.
- Zwischen Tabs: Überblenden mit 14 px Versatz, 480 ms. Push-Seiten kommen von rechts, die darunter schiebt um 24 % zurück und dimmt.
- Raumöffnung: Hintergrundfläche skaliert von der Kachel zum Vollbild (elliptischer Radius gegen Verzerrung), Inhalt blendet verzögert ein, Rückweg spiegelt.
- Ziehen folgt dem Finger ohne Verzögerung (keine Transition während `drg`), erst beim Loslassen federt es.
- Haptik: `selectionClick` bei Schalter, jeder 10. Prozentstufe, Szene.
- `prefers-reduced-motion` (Flutter: `MediaQuery.disableAnimations`): Dauer 0, keine Endlosanimationen, Farbwechsel bleiben als harter Wechsel.

## 5. Datenmodell Grundriss

Ein Raster aus Zellen, eine Zelle ist ungefähr 0,5 m. Räume sind achsenparallele Rechtecke in ganzen Zellen, ohne Überlappung, mindestens 3 mal 3. Entities liegen relativ zum Raum (0..1), damit sie beim Verschieben oder Skalieren des Raums mitwandern.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "HavenFloorPlan",
  "type": "object",
  "required": ["version", "grid", "rooms", "placements"],
  "properties": {
    "version": { "const": 1 },
    "grid": {
      "type": "object",
      "required": ["cols", "rows", "cellMeters"],
      "properties": {
        "cols": { "type": "integer", "minimum": 4 },
        "rows": { "type": "integer", "minimum": 4 },
        "cellMeters": { "type": "number", "default": 0.5 }
      }
    },
    "rooms": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["id", "name", "x", "y", "w", "h"],
        "properties": {
          "id": { "type": "string" },
          "name": { "type": "string" },
          "areaId": { "type": ["string", "null"], "description": "HA-Bereich, optional" },
          "x": { "type": "integer", "minimum": 0 },
          "y": { "type": "integer", "minimum": 0 },
          "w": { "type": "integer", "minimum": 3 },
          "h": { "type": "integer", "minimum": 3 }
        }
      }
    },
    "placements": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["entityId", "roomId", "rx", "ry"],
        "properties": {
          "entityId": { "type": "string", "description": "HA entity_id, z. B. light.tischlampe_salon" },
          "roomId": { "type": "string" },
          "rx": { "type": "number", "minimum": 0, "maximum": 1 },
          "ry": { "type": "number", "minimum": 0, "maximum": 1 },
          "kind": { "enum": ["light", "temperature", "switch", "presence"], "description": "Darstellung, sonst aus Domain abgeleitet" }
        }
      }
    }
  }
}
```

Regeln: Beim Ablegen außerhalb aller Räume wird die Platzierung entfernt (Entity kehrt in den Pool zurück). Beim Zeichnen, Verschieben und Skalieren rastet alles am Raster ein, überlappende Ergebnisse werden verworfen. Ein Raum mit `areaId` öffnet beim Tippen die Raumansicht. Lichtkegel: Radius ungefähr 0,95 mal kurze Raumseite, Deckkraft `.35 + .65 * Helligkeit`, geclippt auf den Raum.

Speicherort später: Haven-Integration in HA (`.storage`), pro Haus ein Dokument.

## 5a. Zigbee-Graph auf dem Grundriss (Vorgabe, 2026-11-15)
Der Mesh-Graph nutzt **dieselbe Kartenansicht** wie die normale Karte, kein eigenes, handplatziertes Layout.
- Knoten = Zigbee-Geräte an ihrer Grundriss-Position. Die Position eines Geräts ist die Platzierung einer seiner Entities (zuerst die Hauptentity, z. B. das Licht). Geräte ohne Platzierung, aber mit Raum liegen in der Raummitte, mehrere davon im kleinen Kreis darum, damit sie sich nicht überdecken. Geräte ohne Raum stehen in einem Bereich „Ohne Raum“ neben dem Grundriss.
- Die Koordinatorposition ist frei setzbar, wie eine Entity, z. B. dort, wo der Stick steht.
- Kanten = Verbindungen aus der Z2M-Netzkarte (`bridge/request/networkmap`, raw) mit Richtung (Pfeil zum Elternknoten bzw. Router) und LQI als Beschriftung. Schwache Verbindungen werden hervorgehoben.
- **In der Graph-Ansicht liegen die Räume weiter auseinander** (z. B. ein fester Spalt von 1 bis 2 Zellen zwischen allen Räumen, Räume behalten ihre Größe). So bleibt Platz für Pfeile und Beschriftungen zwischen den Räumen. Der Wechsel Karte ↔ Graph animiert die Räume auseinander und zurück.
- Router (Netzstrom) und Endgeräte (Batterie) unterscheiden sich in der Form, Lampen behalten ihre Lichtfarbe.

## 6. Offen
- Hero-Übergang und Federn sind im Prototyp per Web Animations gebaut. Das Gefühl auf echten Geräten ist nicht geprüft.
- LQI, Zuordnung zu Räumen, letzte Auslösezeit der Abläufe und Stromverlauf sind Beispielwerte, das Inventar enthält sie nicht.
- Mesh-Layout ist im Entwurf 2 noch handplatziert. Abgelöst durch 5a (Graph auf dem Grundriss).
- Farbwerte der Szenen sind erfunden (nur Namen sind echt), Haven schreibt später echte Szenendefinitionen.
