import 'models/room_heating.dart';

/// Heizungsregelung je Raum (`haven/heating/*`, Integration mit Feature
/// `heating`). Teil von `HavenRepository`.
abstract interface class HeatingApi {
  /// `haven/heating/list`. Ältere Integration: [HeatingRooms.unsupported].
  Future<HeatingRooms> heatingRooms();

  /// `haven/heating/set` (Admin). Fehler als `HavenException` mit `code`
  /// (`device_taken`, `invalid_format`, `not_found`).
  Future<RoomHeating> saveHeating(HeatingConfig config);

  /// `haven/heating/delete` (Admin). Haven nimmt dabei seine Kalibrierung an
  /// den Thermostaten zurück.
  Future<void> deleteHeating(String areaId);

  /// `haven/heating/display` (Admin): Thermostat [ieee] als reines Display
  /// markieren oder nicht. Abwählen nimmt es auch als Raumregler heraus.
  /// Fehler `device_taken`, wenn es als Heizkörperthermostat geregelt wird.
  /// Liefert alle markierten Displays.
  Future<Set<String>> setHeatingDisplay(String ieee, bool display);

  /// `haven/heating/control` (Admin): Ziel und/oder Betriebsart des Raums.
  /// Ein Ziel ohne Betriebsart schaltet auf Manuell. Jede Bedienung (oder
  /// nur [resume]) übernimmt am Thermostat freigegebene Geräte wieder.
  Future<HeatingStatus> controlHeating(
    String areaId, {
    double? target,
    HeatingMode? mode,
    bool resume = false,
  });

  /// Ereignis `haven_heating_updated` (Status in Echtzeit).
  Stream<HeatingUpdate> get heatingUpdates;

  /// `haven_data_updated` mit `kind: heating`, außerdem nach jedem Verbinden.
  Stream<void> get heatingChanged;
}
