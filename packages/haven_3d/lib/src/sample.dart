import 'dart:ui' show Color, Offset;

import 'scene.dart';

/// Beispielwohnung (frei erfunden) für Demo und Tests: sechs Räume, alle
/// Möbel des Katalogs, ein paar Geräte. Maße in Metern.
Scene sampleScene() {
  List<Offset> rect(double l, double t, double r, double b) => [
    Offset(l, t),
    Offset(r, t),
    Offset(r, b),
    Offset(l, b),
  ];

  var n = 0;
  SceneObject f(
    String kind,
    double x,
    double y,
    double w,
    double d, [
    double rot = 0,
  ]) => SceneObject.furniture(
    id: '${kind}_${n++}',
    kind: kind,
    center: Offset(x, y),
    w: w,
    d: d,
    rotation: rot,
  );

  return Scene(
    rooms: [
      SceneRoom(id: 'wohnen', outline: rect(0, 0, 5, 4.5)),
      SceneRoom(id: 'kueche', outline: rect(5, 0, 8.5, 3)),
      // Bad mit schräger Wand oben links.
      SceneRoom(
        id: 'bad',
        outline: const [
          Offset(6, 3),
          Offset(8.5, 3),
          Offset(8.5, 5.5),
          Offset(5, 5.5),
          Offset(5, 4),
        ],
      ),
      // L-förmiger Flur.
      SceneRoom(
        id: 'flur',
        outline: const [
          Offset(0, 4.5),
          Offset(5, 4.5),
          Offset(5, 5.5),
          Offset(3, 5.5),
          Offset(3, 6.5),
          Offset(0, 6.5),
        ],
      ),
      // Schlafzimmer mit schräger Ecke oben links.
      SceneRoom(
        id: 'schlafen',
        outline: const [
          Offset(1, 6.5),
          Offset(3, 6.5),
          Offset(3, 10.5),
          Offset(0, 10.5),
          Offset(0, 7.5),
        ],
      ),
      SceneRoom(id: 'arbeiten', outline: rect(3, 5.5, 8.5, 10.5)),
    ],
    objects: [
      // Wohnen
      f('sofa', 2.2, 3.85, 2.2, 0.9, 180),
      f('coffee_table', 2.2, 2.7, 1.2, 0.6),
      f('rug', 2.2, 2.7, 2.6, 1.8),
      f('armchair', 4.2, 2.6, 0.9, 0.9, 270),
      f('tv_board', 2.2, 0.3, 1.8, 0.45),
      f('plant', 0.4, 0.4, 0.5, 0.5),
      f('shelf', 0.25, 2.2, 1.0, 0.4, 270),
      f('window', 2.2, 0.0, 1.6, 0.2),
      f('door', 4.0, 4.05, 0.9, 0.9),
      // Küche
      f('kitchen_counter', 6.8, 0.3, 1.8, 0.6),
      f('stove', 8.2, 1.2, 0.6, 0.6, 90),
      f('sink', 5.5, 0.3, 0.8, 0.6),
      f('fridge', 8.18, 2.5, 0.6, 0.65, 90),
      f('dining_table', 6.3, 1.9, 1.8, 1.5),
      f('window', 6.75, 0.0, 1.2, 0.2),
      // Bad
      f('bathtub', 6.85, 5.1, 1.7, 0.8, 180),
      f('toilet', 8.1, 3.4, 0.4, 0.7, 90),
      f('washbasin', 6.6, 3.25, 0.6, 0.5),
      f('shower', 5.5, 5.0, 0.9, 0.9),
      // Flur
      f('wardrobe', 0.35, 5.5, 1.6, 0.6, 270),
      f('door', 1.5, 6.95, 0.9, 0.9, 180),
      // Schlafen
      f('bed_double', 1.5, 9.4, 1.8, 2.1, 180),
      f('nightstand', 0.3, 10.2, 0.5, 0.45, 180),
      f('nightstand', 2.7, 10.2, 0.5, 0.45, 180),
      f('window', 0.0, 8.7, 1.2, 0.2, 90),
      // Arbeiten
      f('desk', 7.6, 8.0, 1.5, 0.7, 90),
      f('office_chair', 7.0, 8.0, 0.6, 0.6, 90),
      f('bed_single', 4.0, 9.4, 1.0, 2.1, 180),
      f('window', 8.5, 8.0, 1.4, 0.2, 90),
      // Pflanze genau in der Raummitte (Lichttest).
      f('plant', 5.75, 8.0, 0.6, 0.6),
    ],
    markers: [
      SceneMarker(
        id: 'licht_wohnen',
        at: const Offset(2.5, 2.2),
        kind: MarkerKind.light,
        lamp: const LampState(),
      ),
      SceneMarker(
        id: 'temp_wohnen',
        at: const Offset(4.9, 1.0),
        kind: MarkerKind.temperature,
      ),
      SceneMarker(
        id: 'melder_flur',
        at: const Offset(0.2, 4.7),
        kind: MarkerKind.presence,
      ),
      SceneMarker(
        id: 'schalter_flur',
        at: const Offset(4.85, 4.6),
        kind: MarkerKind.remote,
      ),
      SceneMarker(
        id: 'licht_kueche',
        at: const Offset(6.75, 1.5),
        kind: MarkerKind.light,
        lamp: const LampState(brightness: 0.7, color: Color(0xFFFFE2C0)),
      ),
      SceneMarker(
        id: 'kontakt_schlafen',
        at: const Offset(0.1, 8.5),
        kind: MarkerKind.contact,
      ),
      // Arbeiten: drei farbige Lampen um die Pflanze (Lichttest).
      SceneMarker(
        id: 'licht_arbeiten_rot',
        at: const Offset(4.4, 6.9),
        kind: MarkerKind.light,
        lamp: const LampState(color: Color(0xFFFF4D6D)),
      ),
      SceneMarker(
        id: 'licht_arbeiten_blau',
        at: const Offset(7.3, 6.7),
        kind: MarkerKind.light,
        lamp: const LampState(color: Color(0xFF4D8DFF)),
      ),
      SceneMarker(
        id: 'licht_arbeiten_gruen',
        at: const Offset(5.6, 9.7),
        kind: MarkerKind.light,
        lamp: const LampState(brightness: 0.8, color: Color(0xFF5DFF8A)),
      ),
      SceneMarker(
        id: 'lautsprecher',
        at: const Offset(3.2, 0.3),
        kind: MarkerKind.media,
      ),
    ],
  );
}
