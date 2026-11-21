import 'package:flutter/foundation.dart';

/// Heizungsregelung je Raum (`haven/heating/*`, Integration mit Feature
/// `heating`). Haven führt die Thermostate eines Raums als Gruppe, regelt
/// nach Raumthermometern statt nach dem Fühler am Heizkörper, pausiert bei
/// offenem Fenster und im Sommer. Vertrag siehe README der Integration.

/// Betriebsart des Raums (`mode`).
enum HeatingMode {
  heat('heat', 'Manuell'),
  comfort('comfort', 'Komfort'),
  eco('eco', 'Eco'),
  away('away', 'Abwesend'),
  off('off', 'Aus');

  const HeatingMode(this.wire, this.label);
  final String wire;
  final String label;

  static HeatingMode parse(Object? v) =>
      values.firstWhere((m) => m.wire == v, orElse: () => heat);
}

/// Wie Haven den Unterschied zwischen Heizkörper und Raum ausgleicht.
enum HeatingCalibration {
  offset(
    'offset',
    'Messung abgleichen',
    'Das Thermostat bekommt die Abweichung als Kalibrierung und regelt dann so, als hinge es im Raum. Leise und schont die Batterie.',
  ),
  target(
    'target',
    'Zieltemperatur verschieben',
    'Haven stellt am Thermostat so viel mehr ein, wie es am Heizkörper wärmer misst. Für Thermostate ohne Kalibrierung.',
  ),
  none(
    'none',
    'Nicht ausgleichen',
    'Haven hält nur Ziel, Betriebsart, Fenster und Sommer für alle Thermostate gleich.',
  );

  const HeatingCalibration(this.wire, this.label, this.help);
  final String wire;
  final String label;
  final String help;

  static HeatingCalibration parse(Object? v) =>
      values.firstWhere((m) => m.wire == v, orElse: () => offset);
}

double? _d(Object? v) => v is num ? v.toDouble() : null;
DateTime? _t(Object? v) => v is String ? DateTime.tryParse(v) : null;
List<String> _ls(Object? v) =>
    v is List ? [for (final x in v) '$x'] : const <String>[];

const Map<HeatingMode, double> kDefaultHeatingPresets = {
  HeatingMode.comfort: 21,
  HeatingMode.eco: 18,
  HeatingMode.away: 16,
};

/// Einstellungen der Regelung eines Raums.
@immutable
class HeatingConfig {
  const HeatingConfig({
    required this.areaId,
    this.enabled = true,
    this.trvs = const [],
    this.sensors = const [],
    this.windows = const [],
    this.windowOpenDelay = 60,
    this.windowCloseDelay = 120,
    this.calibration = HeatingCalibration.offset,
    this.outdoorEntity,
    this.outdoorThreshold = 16,
    this.presets = kDefaultHeatingPresets,
    this.lockManual = false,
    this.calibrateReleased = true,
    this.display,
  });

  factory HeatingConfig.fromJson(Map<String, dynamic> j) {
    final outdoor = j['outdoor'];
    final presets = j['presets'];
    return HeatingConfig(
      areaId: '${j['area_id']}',
      enabled: j['enabled'] != false,
      trvs: _ls(j['trvs']),
      sensors: _ls(j['sensors']),
      windows: _ls(j['windows']),
      windowOpenDelay: (j['window_open_delay'] as num?)?.toInt() ?? 60,
      windowCloseDelay: (j['window_close_delay'] as num?)?.toInt() ?? 120,
      calibration: HeatingCalibration.parse(j['calibration']),
      outdoorEntity: outdoor is Map ? outdoor['entity'] as String? : null,
      outdoorThreshold: outdoor is Map ? _d(outdoor['threshold']) ?? 16 : 16,
      presets: {
        for (final m in kDefaultHeatingPresets.keys)
          m: presets is Map
              ? _d(presets[m.wire]) ?? kDefaultHeatingPresets[m]!
              : kDefaultHeatingPresets[m]!,
      },
      lockManual: j['lock_manual'] == true,
      calibrateReleased: j['calibrate_released'] != false,
      display: j['display'] is String ? j['display'] as String : null,
    );
  }

  final String areaId;
  final bool enabled;

  /// IEEEs der Thermostate.
  final List<String> trvs;

  /// Raumthermometer (`sensor.*`), Mittelwert.
  final List<String> sensors;

  /// Fensterkontakte (`binary_sensor.*`).
  final List<String> windows;

  /// Sekunden offen, bis die Heizung pausiert.
  final int windowOpenDelay;

  /// Sekunden zu, bis wieder geheizt wird.
  final int windowCloseDelay;
  final HeatingCalibration calibration;

  /// `sensor.*` oder `weather.*`, `null` = keine Sommerpause.
  final String? outdoorEntity;
  final double outdoorThreshold;
  final Map<HeatingMode, double> presets;

  /// Änderungen am Thermostat zurücksetzen statt übernehmen.
  final bool lockManual;

  /// Am Thermostat freigegebene Geräte (eigener Wochenplan, Ventil offen)
  /// weiter auf das Raumthermometer kalibrieren.
  final bool calibrateReleased;

  /// IEEE eines als Display markierten Thermostats, das den Raum steuert:
  /// misst die Raumtemperatur, was daran eingestellt wird, gilt für den
  /// ganzen Raum, und es zeigt das Ziel des Raums. `null`: keins.
  final String? display;

  Map<String, dynamic> toJson() => {
    'area_id': areaId,
    'enabled': enabled,
    'trvs': trvs,
    'sensors': sensors,
    'windows': windows,
    'window_open_delay': windowOpenDelay,
    'window_close_delay': windowCloseDelay,
    'calibration': calibration.wire,
    'outdoor': outdoorEntity == null
        ? null
        : {'entity': outdoorEntity, 'threshold': outdoorThreshold},
    'presets': {for (final e in presets.entries) e.key.wire: e.value},
    'lock_manual': lockManual,
    'calibrate_released': calibrateReleased,
    'display': display,
  };

  HeatingConfig copyWith({
    bool? enabled,
    List<String>? trvs,
    List<String>? sensors,
    List<String>? windows,
    int? windowOpenDelay,
    int? windowCloseDelay,
    HeatingCalibration? calibration,
    String? outdoorEntity,
    bool clearOutdoor = false,
    double? outdoorThreshold,
    Map<HeatingMode, double>? presets,
    bool? lockManual,
    bool? calibrateReleased,
    String? display,
    bool clearDisplay = false,
  }) => HeatingConfig(
    areaId: areaId,
    enabled: enabled ?? this.enabled,
    trvs: trvs ?? this.trvs,
    sensors: sensors ?? this.sensors,
    windows: windows ?? this.windows,
    windowOpenDelay: windowOpenDelay ?? this.windowOpenDelay,
    windowCloseDelay: windowCloseDelay ?? this.windowCloseDelay,
    calibration: calibration ?? this.calibration,
    outdoorEntity: clearOutdoor ? null : (outdoorEntity ?? this.outdoorEntity),
    outdoorThreshold: outdoorThreshold ?? this.outdoorThreshold,
    presets: presets ?? this.presets,
    lockManual: lockManual ?? this.lockManual,
    calibrateReleased: calibrateReleased ?? this.calibrateReleased,
    display: clearDisplay ? null : (display ?? this.display),
  );

  @override
  bool operator ==(Object other) =>
      other is HeatingConfig &&
      mapEquals(other.toJson()['outdoor'], toJson()['outdoor']) &&
      other.areaId == areaId &&
      other.enabled == enabled &&
      listEquals(other.trvs, trvs) &&
      listEquals(other.sensors, sensors) &&
      listEquals(other.windows, windows) &&
      other.windowOpenDelay == windowOpenDelay &&
      other.windowCloseDelay == windowCloseDelay &&
      other.calibration == calibration &&
      mapEquals(other.presets, presets) &&
      other.lockManual == lockManual &&
      other.calibrateReleased == calibrateReleased &&
      other.display == display;

  @override
  int get hashCode => Object.hash(areaId, trvs.length, sensors.length);
}

/// Zustand eines Thermostats in der Regelung.
@immutable
class HeatingTrvStatus {
  const HeatingTrvStatus({
    required this.ieee,
    this.name = '',
    this.available = true,
    this.localTemperature,
    this.setpoint,
    this.calibration,
    this.heating,
    this.valve,
    this.method = HeatingCalibration.none,
    this.correction,
    this.desiredSetpoint,
    this.desiredCalibration,
    this.pending = false,
    this.released = false,
    this.releasedMode,
    this.releaseUntil,
  });

  factory HeatingTrvStatus.fromJson(Map<String, dynamic> j) => HeatingTrvStatus(
    ieee: '${j['ieee']}',
    name: '${j['name'] ?? ''}',
    available: j['available'] != false,
    localTemperature: _d(j['local_temperature']),
    setpoint: _d(j['setpoint']),
    calibration: _d(j['calibration']),
    heating: j['heating'] as bool?,
    valve: (j['valve'] as num?)?.round(),
    method: HeatingCalibration.parse(j['method']),
    correction: _d(j['correction']),
    desiredSetpoint: _d(j['desired_setpoint']),
    desiredCalibration: _d(j['desired_calibration']),
    pending: j['pending'] == true,
    released: j['released'] == true,
    releasedMode: j['released_mode'] as String?,
    releaseUntil: _t(j['release_until']),
  );

  final String ieee;
  final String name;
  final bool available;

  /// Was das Thermostat misst (mit seiner Kalibrierung).
  final double? localTemperature;
  final double? setpoint;
  final double? calibration;
  final bool? heating;
  final int? valve;

  /// Korrektur, die gerade greift (`none` auch ohne Raumthermometer).
  final HeatingCalibration method;

  /// Raum minus Rohmessung am Heizkörper.
  final double? correction;
  final double? desiredSetpoint;
  final double? desiredCalibration;

  /// Ein Befehl ist unterwegs (Gerät hat ihn noch nicht bestätigt).
  final bool pending;

  /// Am Gerät auf eigene Steuerung gestellt: Haven schickt weder Modus noch
  /// Sollwert ([releasedMode] z. B. `on` = Ventil offen, `auto` =
  /// Wochenplan des Geräts).
  final bool released;
  final String? releasedMode;

  /// Ventil offen: bis dahin, danach übernimmt Haven wieder.
  final DateTime? releaseUntil;
}

/// Zustand des Displays (Raumregler) in der Regelung.
@immutable
class HeatingDisplayStatus {
  const HeatingDisplayStatus({
    required this.ieee,
    this.name = '',
    this.available = true,
    this.localTemperature,
    this.setpoint,
    this.mode,
    this.preset,
    this.ecoTemperature,
    this.battery,
    this.pending = false,
  });

  factory HeatingDisplayStatus.fromJson(Map<String, dynamic> j) =>
      HeatingDisplayStatus(
        ieee: '${j['ieee']}',
        name: '${j['name'] ?? ''}',
        available: j['available'] != false,
        localTemperature: _d(j['local_temperature']),
        setpoint: _d(j['setpoint']),
        mode: j['mode'] as String?,
        preset: j['preset'] as String?,
        ecoTemperature: _d(j['eco_temperature']),
        battery: (j['battery'] as num?)?.round(),
        pending: j['pending'] == true,
      );

  final String ieee;
  final String name;
  final bool available;

  /// Was das Display im Raum misst.
  final double? localTemperature;

  /// Was das Display gerade anzeigt (Ziel des Raums).
  final double? setpoint;
  /// Ein/Aus am Gerät (`heat`/`off` bzw. sein Regelmodus).
  final String? mode;

  /// Eigener Modus des Geräts (Beok: `manual`, `eco`, `auto`), falls es einen
  /// getrennt von Ein/Aus hat.
  final String? preset;

  /// Eco-Temperatur am Gerät (Haven hält sie gleich der des Raums).
  final double? ecoTemperature;

  /// Batterie in Prozent, `null`: Netzbetrieb oder unbekannt.
  final int? battery;

  /// Display ist aus (Raum aus oder Fensterpause).
  bool get isOff => mode == 'off';

  /// Haven hat das Ziel gesendet, das Display hat es noch nicht bestätigt.
  final bool pending;
}

/// Warum gerade nicht geheizt wird.
enum HeatingPause {
  off('Aus'),
  window('Fenster offen'),
  summer('Sommerpause');

  const HeatingPause(this.label);
  final String label;

  static HeatingPause? parse(Object? v) => switch (v) {
    'off' => off,
    'window' => window,
    'summer' => summer,
    _ => null,
  };
}

/// Laufender Zustand der Regelung eines Raums.
@immutable
class HeatingStatus {
  const HeatingStatus({
    this.mode = HeatingMode.heat,
    this.target = 21,
    this.effectiveTarget,
    this.roomTemperature,
    this.roomSource,
    this.sensorValues = const {},
    this.pause,
    this.heating,
    this.windowOpen = false,
    this.windowPaused = false,
    this.windowOverride = false,
    this.pauseAt,
    this.resumeAt,
    this.contacts = const {},
    this.outdoorValue,
    this.outdoorCurrent,
    this.summer = false,
    this.trvs = const [],
    this.running = true,
    this.released = false,
    this.display,
  });

  factory HeatingStatus.fromJson(Map<String, dynamic> j) {
    final window = j['window'] is Map
        ? Map<String, dynamic>.from(j['window'] as Map)
        : const <String, dynamic>{};
    final outdoor = j['outdoor'] is Map
        ? Map<String, dynamic>.from(j['outdoor'] as Map)
        : null;
    return HeatingStatus(
      mode: HeatingMode.parse(j['mode']),
      target: _d(j['target']) ?? 21,
      effectiveTarget: _d(j['effective_target']),
      roomTemperature: _d(j['room_temperature']),
      roomSource: j['room_source'] as String?,
      sensorValues: {
        for (final s in (j['sensors'] as List? ?? const []))
          if (s is Map) '${s['entity_id']}': _d(s['value']),
      },
      pause: HeatingPause.parse(j['reason']),
      heating: j['heating'] as bool?,
      windowOpen: window['open'] == true,
      windowPaused: window['paused'] == true,
      windowOverride: window['override'] == true,
      pauseAt: _t(window['pause_at']),
      resumeAt: _t(window['resume_at']),
      contacts: {
        for (final c in (window['contacts'] as List? ?? const []))
          if (c is Map) '${c['entity_id']}': c['open'] as bool?,
      },
      outdoorValue: _d(outdoor?['value']),
      outdoorCurrent: _d(outdoor?['current']),
      summer: outdoor?['summer'] == true,
      trvs: [
        for (final t in (j['trvs'] as List? ?? const []))
          if (t is Map) HeatingTrvStatus.fromJson(Map<String, dynamic>.from(t)),
      ],
      running: j['running'] != false,
      released: j['released'] == true,
      display: j['display'] is Map
          ? HeatingDisplayStatus.fromJson(
              Map<String, dynamic>.from(j['display'] as Map),
            )
          : null,
    );
  }

  final HeatingMode mode;

  /// Ziel im Modus Manuell.
  final double target;

  /// Ziel, das gerade gilt (nach Betriebsart), `null` bei Aus.
  final double? effectiveTarget;
  final double? roomTemperature;

  /// `sensors` (Raumthermometer, mit Display), `display` (nur das Display),
  /// `trv` (Rückfall) oder `null`.
  final String? roomSource;
  final Map<String, double?> sensorValues;
  final HeatingPause? pause;
  final bool? heating;
  final bool windowOpen;
  final bool windowPaused;

  /// Am Display trotz offenem Fenster eingeschaltet: keine Pause, bis alle
  /// Fenster wieder zu sind.
  final bool windowOverride;

  /// Fenster offen, Pause beginnt um.
  final DateTime? pauseAt;

  /// Fenster zu, Heizung läuft wieder ab.
  final DateTime? resumeAt;
  final Map<String, bool?> contacts;

  /// Geglättete Außentemperatur.
  final double? outdoorValue;
  final double? outdoorCurrent;
  final bool summer;
  final List<HeatingTrvStatus> trvs;
  final bool running;

  /// Mindestens ein Thermostat steuert gerade selbst (am Gerät gestellt).
  final bool released;

  /// Display, das den Raum steuert, `null`: keins.
  final HeatingDisplayStatus? display;

  /// Raumtemperatur kommt aus dem Raum (Thermometer oder Display), nicht vom
  /// Heizkörper: dann greift die Korrektur.
  bool get usesSensors => roomSource == 'sensors' || roomSource == 'display';

  HeatingStatus copyWith({
    HeatingMode? mode,
    double? target,
    double? effectiveTarget,
    bool clearEffective = false,
  }) => HeatingStatus(
    mode: mode ?? this.mode,
    target: target ?? this.target,
    effectiveTarget: clearEffective
        ? null
        : (effectiveTarget ?? this.effectiveTarget),
    roomTemperature: roomTemperature,
    roomSource: roomSource,
    sensorValues: sensorValues,
    pause: mode == HeatingMode.off
        ? HeatingPause.off
        : (pause == HeatingPause.off && mode != null ? null : pause),
    heating: heating,
    windowOpen: windowOpen,
    windowPaused: windowPaused,
    windowOverride: windowOverride,
    pauseAt: pauseAt,
    resumeAt: resumeAt,
    contacts: contacts,
    outdoorValue: outdoorValue,
    outdoorCurrent: outdoorCurrent,
    summer: summer,
    trvs: trvs,
    running: running,
    released: released,
    display: display,
  );
}

/// Eine eingerichtete Regelung mit ihrem Zustand.
@immutable
class RoomHeating {
  const RoomHeating(this.config, this.status);

  factory RoomHeating.fromJson(Map<String, dynamic> j) => RoomHeating(
    HeatingConfig.fromJson(Map<String, dynamic>.from(j['config'] as Map)),
    j['status'] is Map
        ? HeatingStatus.fromJson(Map<String, dynamic>.from(j['status'] as Map))
        : const HeatingStatus(),
  );

  final HeatingConfig config;
  final HeatingStatus status;

  String get areaId => config.areaId;

  RoomHeating withStatus(HeatingStatus s) => RoomHeating(config, s);
}

/// Antwort von `haven/heating/list`.
@immutable
class HeatingRooms {
  const HeatingRooms({
    this.rooms = const [],
    this.supported = true,
    this.running = true,
    this.displays = const {},
  });

  factory HeatingRooms.fromJson(Map<String, dynamic> j) => HeatingRooms(
    rooms: [
      for (final r in (j['rooms'] as List? ?? const []))
        if (r is Map) RoomHeating.fromJson(Map<String, dynamic>.from(r)),
    ],
    running: j['running'] != false,
    displays: {..._ls(j['displays'])},
  );

  /// Integration ohne Feature `heating`.
  static const unsupported = HeatingRooms(supported: false);

  final List<RoomHeating> rooms;
  final bool supported;
  final bool running;

  /// Als reines Display markierte Thermostate (IEEE): Haven regelt sie nie
  /// als Heizkörperthermostat, sie können einen Raum steuern.
  final Set<String> displays;

  bool isDisplay(String ieee) => displays.contains(ieee);

  /// Raum, den das Display [ieee] steuert.
  RoomHeating? controlledBy(String ieee) =>
      rooms.where((r) => r.config.display == ieee).firstOrNull;

  HeatingRooms withDisplays(Set<String> d) => HeatingRooms(
    rooms: rooms,
    supported: supported,
    running: running,
    displays: d,
  );

  RoomHeating? byArea(String areaId) =>
      rooms.where((r) => r.areaId == areaId).firstOrNull;

  HeatingRooms replace(RoomHeating r) => HeatingRooms(
    rooms: [
      for (final x in rooms)
        if (x.areaId != r.areaId) x,
      r,
    ]..sort((a, b) => a.areaId.compareTo(b.areaId)),
    supported: supported,
    running: running,
    displays: displays,
  );

  HeatingRooms remove(String areaId) => HeatingRooms(
    rooms: [
      for (final x in rooms)
        if (x.areaId != areaId) x,
    ],
    supported: supported,
    running: running,
    displays: displays,
  );
}

/// Ereignis `haven_heating_updated`.
typedef HeatingUpdate = ({String areaId, HeatingStatus status});
