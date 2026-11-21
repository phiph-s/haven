import '../data/models/floor_plan.dart';

GridPoint _p(int x, int y) => GridPoint(x + 3, y + 3);

FloorPlacement _at(String entityId, int x, int y) =>
    FloorPlacement(entityId: entityId, x: x + 3, y: y + 3);

/// Möbel mit Mitte (x, y) in Zellen der Wohnung (ohne Rand).
FloorFurniture _f(
  String id,
  String kind,
  double x,
  double y, {
  double rot = 0,
  double? w,
  double? h,
}) {
  final t = furnitureType(kind)!;
  return FloorFurniture(
    id: id,
    kind: kind,
    x: x + 3,
    y: y + 3,
    w: w ?? t.w,
    h: h ?? t.h,
    rotation: rot,
  );
}

/// Beispielgrundriss der erfundenen Wohnung (Schema 2): Salon und Diele
/// greifen als L-Formen ineinander, der Kochbereich hat eine abgeschrägte
/// Ecke, zwischen Ruheraum und Waschraum steht eine schräge Wand. Der
/// Sensor Terrasse liegt draußen, im Salon messen zwei Sensoren (Verlauf in
/// der Heatmap). Tischlampe und Stehlampe im Salon stehen auf demselben Feld
/// (Gruppe). Einige Geräte fehlen bewusst (sie bleiben im Pool des Editors).
///
/// Alle Koordinaten liegen 3 Zellen vom Rand, damit „Draußen“ Platz hat.
final HavenFloorPlan kFakeFloorPlan = HavenFloorPlan(
  grid: const FloorGrid(cols: 27, rows: 28),
  rooms: [
    FloorRoom(
      id: 'salon',
      name: 'Salon',
      areaId: 'salon',
      points: [
        _p(0, 0),
        _p(12, 0),
        _p(12, 7),
        _p(15, 7),
        _p(15, 12),
        _p(0, 12),
      ],
    ),
    FloorRoom(
      id: 'kochbereich',
      name: 'Kochbereich',
      areaId: 'kochbereich',
      points: [_p(12, 0), _p(17, 0), _p(20, 3), _p(20, 7), _p(12, 7)],
    ),
    FloorRoom(
      id: 'diele',
      name: 'Diele',
      areaId: 'diele',
      points: [
        _p(15, 7),
        _p(20, 7),
        _p(20, 15),
        _p(12, 15),
        _p(12, 12),
        _p(15, 12),
      ],
    ),
    FloorRoom(
      id: 'ruheraum',
      name: 'Ruheraum',
      areaId: 'ruheraum',
      points: [_p(0, 12), _p(12, 12), _p(12, 15), _p(10, 22), _p(0, 22)],
    ),
    FloorRoom(
      id: 'waschraum',
      name: 'Waschraum',
      areaId: 'waschraum',
      points: [_p(12, 15), _p(20, 15), _p(20, 22), _p(10, 22)],
    ),
  ],
  placements: [
    _at('light.tischlampe_salon', 9, 2),
    _at('light.lampe_salon', 9, 2),
    _at('light.lampe_decke_salon', 5, 6),
    _at('sensor.sensor_salon_temperature', 10, 5),
    _at('sensor.sensor_salon_fenster_temperature', 1, 10),
    _at('binary_sensor.bewegungsmelder_salon_occupancy', 8, 10),
    _at('light.kochbereich_arbeitslicht_2', 15, 2),
    _at('light.kochbereich_arbeitslicht_1', 17, 4),
    _at('switch.steckdose_messung_5', 13, 5),
    _at('binary_sensor.kontaktsensor_schrank_contact', 18, 11),
    _at('light.lichtleiste_links', 2, 15),
    _at('light.lichtleiste_rechts', 8, 15),
    _at('light.lampe_decke_ruheraum', 5, 17),
    _at('sensor.sensor_ruheraum_temperature', 8, 20),
    _at('light.lampe_waschraum', 15, 18),
    _at('switch.lufter_waschraum', 18, 20),
    _at('binary_sensor.prasenz_waschraum_presence', 18, 16),
    _at('sensor.sensor_terrasse_temperature', 21, 5),
    // Heizkörperthermostate unter den Fenstern.
    _at('climate.thermostat_salon', 1, 7),
    _at('climate.thermostat_ruheraum', 2, 21),
  ],
  coordinator: _p(16, 8),
  furniture: [
    // Salon
    _f('rug', 'rug', 5, 6.6, w: 6, h: 4.4),
    _f('sofa', 'sofa', 5, 9.4, rot: 180),
    _f('table', 'coffee_table', 5, 6.4),
    _f('tv', 'sideboard', 5, 0.55),
    _f('chair', 'armchair', 9.6, 6.6, rot: 270),
    _f('plant', 'plant', 11.3, 0.8),
    _f('shelf', 'shelf', 0.5, 4, rot: 270),
    _f('dining', 'dining_table', 12.4, 9.6, w: 3.4, h: 3.2),
    _f('win1', 'window', 0.2, 6.6, rot: 90),
    _f('win2', 'window', 4, 0.2, w: 3),
    // Kochbereich
    _f('counter', 'kitchen_counter', 14.5, 0.6, w: 5),
    _f('sink', 'sink', 13.4, 0.6),
    _f('stove', 'stove', 15.9, 0.6),
    _f('fridge', 'fridge', 19.35, 5.6, rot: 90),
    // Diele
    _f('wardrobe2', 'wardrobe', 19.4, 10.6, rot: 90, w: 4.4),
    _f('door1', 'door', 17.9, 14.1),
    // Ruheraum
    _f('bed', 'bed_double', 2.1, 17, rot: 270),
    _f('ns1', 'nightstand', 0.45, 14.6, rot: 270),
    _f('ns2', 'nightstand', 0.45, 19.4, rot: 270),
    _f('wardrobe', 'wardrobe', 6, 12.6),
    _f('desk', 'desk', 10, 13.2, w: 2.8),
    _f('ochair', 'office_chair', 10, 14.6),
    _f('win3', 'window', 5, 21.8),
    // Waschraum
    _f('tub', 'bathtub', 17.8, 21.15),
    _f('wc', 'toilet', 19.3, 18.4, rot: 90),
    _f('basin', 'washbasin', 15.6, 15.5),
    _f('shower', 'shower', 13, 16),
  ],
);
