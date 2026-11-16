import '../data/models/floor_plan.dart';

GridPoint _p(int x, int y) => GridPoint(x + 3, y + 3);

FloorPlacement _at(String entityId, int x, int y) =>
    FloorPlacement(entityId: entityId, x: x + 3, y: y + 3);

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
  ],
  coordinator: _p(16, 8),
);
