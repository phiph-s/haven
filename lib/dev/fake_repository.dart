import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../core/light/color_math.dart';
import '../data/base_repository.dart';
import '../data/haven_repository.dart';
import '../data/models/entity_state.dart';
import '../data/models/floor_plan.dart';
import '../data/models/haven_automation.dart';
import '../data/models/lamp.dart';
import '../data/models/room_heating.dart';
import '../data/models/room.dart';
import '../data/models/snapshot.dart';
import '../data/models/state_history.dart';
import '../data/models/zigbee.dart';
import '../data/models/zigbee_network.dart';
import '../data/storage/settings_store.dart';
import '../data/models/scene_check.dart';
import '../data/scene_look.dart';
import '../data/scene_styles.dart';
import 'fake_automations.dart';
import 'fake_heating.dart';
import 'fake_data.dart';
import 'fake_floor_plan.dart';
import 'fake_rooms.dart';
import '../data/models/device.dart';
import 'fake_thermostat_sim.dart';
import 'fake_updates.dart';
import 'fake_zigbee.dart';
import '../data/models/weather.dart';
import '../data/models/lamp_calibration.dart';
import '../data/render_api.dart';

/// Gedächtnis einer Lampe, damit Farbe und Helligkeit beim Aus- und
/// Einschalten erhalten bleiben (HA macht das über die Lampe selbst).
class _Mem {
  _Mem(this.on, this.brightness, this.rgb, this.kelvin);
  bool on;
  int brightness;
  Rgb rgb;

  /// Gesetzt im Weißmodus, `null` im Farbmodus.
  int? kelvin;
}

/// Entwicklungsdaten: Eine erfundene Beispielwohnung (`fake_data.dart`) mit
/// simulierten Zuständen, für Screenshots und die Arbeit ohne Home Assistant.
/// Schalten, Helligkeit und Szenen ändern die Lampenfarben, damit die
/// Oberfläche lebt. Aktiv nur mit `--dart-define=HAVEN_FAKE=true`.
class FakeRepository extends BaseRepository {
  FakeRepository({
    this.inventory = kFakeInventory,
    Map<String, dynamic> zigbee = kFakeZigbee,
    this.simulate = true,
    Random? random,
    Duration joinDelay = const Duration(seconds: 5),
    LocalPrefs? localPrefs,
  }) : _rng = random ?? Random(7),
       _local = localPrefs ?? MemoryPrefs(),
       _zb = FakeZigbee(
         inventory: inventory,
         zigbee: zigbee,
         joinDelay: joinDelay,
       );

  /// Räume, Geräte, Gruppen und HA-Entities (Form: `fake_data.dart`).
  final Map<String, dynamic> inventory;

  /// Mit `false` laufen keine Timer (Tests).
  final bool simulate;
  final Random _rng;
  final FakeZigbee _zb;
  late final FakeAutomations _auto = FakeAutomations(
    repo: this,
    zigbee: _zb,
    inventory: inventory,
    simulate: simulate,
  );

  /// Ein Durchlauf der simulierten Heizungsregelung (Tests).
  void heatingTick([DateTime? now]) => _heat.tick(now ?? DateTime.now());

  late final FakeHeating _heat = FakeHeating(
    entities: () => _entities,
    trvState: _zb.stateOf,
    trvSet: zigbeeSet,
    trvName: (ieee) => _zb.nameOf(ieee) ?? ieee,
    thermostats: () => _thermostats.keys,
  );
  final LocalPrefs _local;
  Set<String> _excluded = const {};
  Set<String> _locked = const {};
  WeatherConfig _weather = const WeatherConfig();
  LampCalibrations _calibration = LampCalibrations.empty;

  /// Lampentypen aus dem erfundenen Zigbee-Bestand (wie Zigbee2MQTT sie
  /// meldet).
  late final Map<String, LampModel> _lampModels = Map.unmodifiable({
    for (final d in (inventory['z2m_devices'] as List))
      for (final id in ((d as Map)['entities'] as Map).keys.cast<String>())
        if (id.startsWith('light.'))
          id: LampModel(
            vendor: d['vendor'] as String?,
            model: d['model'] as String?,
            description: d['description'] as String?,
          ),
  });

  final Map<String, EntityState> _entities = {};
  final Map<String, _Mem> _mem = {};
  final Map<String, Map<String, dynamic>> _lampStatic = {};
  final Map<String, List<String>> _lastOn = {};
  final Map<String, String> _activeScenes = {};
  List<Room> _rooms = const [];

  /// Szenen je Gruppe (`[{id, name, look}]`) und je gespeicherter Szene der
  /// Zustand jeder Lampe (`"gruppe:szene"`), wie Z2M ihn auf den Geräten hält.
  final Map<int, List<Map<String, dynamic>>> _sceneDefs = {};
  final Map<String, Map<String, _Mem>> _sceneLamps = {};
  Timer? _timer;
  bool _started = false;

  @override
  bool get isFake => true;

  // ---- Bilder der Wohnung: im Speicher (für die Vorschau des Ablaufs) ----

  String? _renderKey;
  Set<String> _renderSets = const {};
  Map<String, Uint8List> _renderFiles = const {};
  final _renderCtrl = StreamController<void>.broadcast();

  @override
  Future<RenderStatus?> renderStatus() async {
    final info = <String, RenderSetInfo>{};
    for (final set in _renderSets) {
      final meta = _renderFiles['$set/meta.json'];
      if (meta == null) continue;
      final m = jsonDecode(utf8.decode(meta)) as Map<String, dynamic>;
      final view = (m['view'] as Map?) ?? const {};
      info[set] = RenderSetInfo(
        room: view['room'] as String?,
        theme: '${m['theme'] ?? ''}',
        lamps: [...((m['lamps'] as Map?)?.keys.map((k) => '$k') ?? const [])],
      );
    }
    return RenderStatus(
      key: _renderKey,
      sets: _renderSets,
      info: info,
      files: true,
    );
  }

  @override
  Future<Uint8List> renderFile(String set, String name) async {
    final f = _renderFiles['$set/$name'];
    if (f == null) {
      throw HavenException('$set/$name gibt es nicht', code: 'not_found');
    }
    return f;
  }

  @override
  Stream<void> get renderChanges => _renderCtrl.stream;

  @override
  Future<void> uploadRenders(
    String key,
    List<RenderFile> files, {
    void Function(int sent, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    final total = files.fold<int>(0, (a, f) => a + f.bytes.length);
    var sent = 0;
    for (final f in files) {
      if (cancelled?.call() ?? false) throw const RenderUploadCancelled();
      await Future<void>.delayed(Duration.zero);
      sent += f.bytes.length;
      onProgress?.call(sent, total);
    }
    _renderKey = key;
    _renderSets = {for (final f in files) f.path.split('/').first};
    _renderFiles = {for (final f in files) f.path: f.bytes};
    _renderCtrl.add(null);
  }

  @override
  HavenFloorPlan? get sampleFloorPlan => kFakeFloorPlan;

  static const _defaults = <String, (int, int?, Rgb?)>{
    'light.tischlampe_salon': (100, 2732, (255, 168, 90)),
    'light.lampe_salon': (70, 2700, null),
    'light.lampe_decke_salon': (80, 2700, null),
    'light.lichtleiste_links': (60, null, (150, 92, 255)),
    'light.lichtleiste_rechts': (60, null, (255, 84, 170)),
    'light.lampe_decke_ruheraum': (45, 2200, null),
    'light.lampe_ruhebett': (40, 2400, null),
    'light.kochbereich_arbeitslicht_1': (90, 4000, null),
    'light.kochbereich_arbeitslicht_2': (80, 3200, null),
    'light.lampe_waschraum': (100, 4000, null),
  };

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _build();
    _excluded = {..._local.excludedLights};
    _locked = {..._local.lockedIds};
    _weather = WeatherConfig.fromJson(_local.weatherConfig);
    _calibration = LampCalibrations.fromJson(_local.lampCalibration);
    publish(
      HavenSnapshot(
        status: ConnectionStatus.connected,
        entities: Map.unmodifiable(_entities),
        rooms: _rooms,
        excludedLights: Set.unmodifiable(_excluded),
        locked: Set.unmodifiable(_locked),
        weather: _weather,
        lampModels: _lampModels,
        lampCalibration: _calibration,
        devices: _haDevices(),
      ),
    );
    if (simulate) {
      _timer = Timer.periodic(const Duration(seconds: 4), (_) => _tick());
      // Das Add-on, das beim Start schon läuft, macht weiter.
      for (final e in _entities.values.toList()) {
        if (e.attributes['in_progress'] == true) {
          _setProgress(
            e.entityId,
            ((e.attributes['update_percentage'] as num?) ?? 0).toInt(),
          );
        }
      }
    }
  }

  /// HA-Geräte wie `haven/rooms` sie liefert: Zigbee (mit IEEE) und Matter.
  List<HavenDevice> _haDevices() => [
    for (final d in (inventory['z2m_devices'] as List))
      HavenDevice(
        id: 'z2m_${d['ieee']}',
        name: d['friendly_name'] as String,
        entityIds: (d['entities'] as Map).keys.cast<String>().toList(),
        ieee: d['ieee'] as String,
        areaId: d['room'] as String?,
        manufacturer: d['vendor'] as String?,
        model: d['model'] as String?,
        protocol: DeviceProtocol.zigbee,
      ),
    for (final d in (inventory['matter_devices'] as List? ?? const []))
      HavenDevice(
        id: d['device_id'] as String,
        name: d['name'] as String,
        entityIds: (d['entities'] as Map).keys.cast<String>().toList(),
        areaId: d['room'] as String?,
        manufacturer: d['manufacturer'] as String?,
        model: d['model'] as String?,
        protocol: DeviceProtocol.matter,
        swVersion: d['sw_version'] as String?,
      ),
  ];

  void _build() {
    for (final e in buildFakeUpdateEntities()) {
      _entities[e.entityId] = e;
    }
    for (final d in (inventory['z2m_devices'] as List)) {
      final caps = ((d['capabilities'] as List?) ?? const []).cast<String>();
      final ents = d['entities'] as Map<String, dynamic>;
      ents.forEach((id, v) {
        final attrs = Map<String, dynamic>.from(v['attributes'] as Map);
        if (id.startsWith('light.')) {
          final def = _defaults[id] ?? (80, 2700, null);
          final color = def.$3 ?? kelvinToRgb(def.$2 ?? 2700);
          _mem[id] = _Mem(
            id == 'light.tischlampe_salon',
            def.$1,
            color,
            def.$3 == null ? def.$2 : null,
          );
          attrs['supported_color_modes'] =
              caps.contains('color_xy') || caps.contains('color_hs')
              ? ['color_temp', 'xy']
              : caps.contains('color_temp')
              ? ['color_temp']
              : ['brightness'];
          attrs['min_color_temp_kelvin'] = 2000;
          attrs['max_color_temp_kelvin'] = 6535;
          _lampStatic[id] = attrs;
          _entities[id] = _lampEntity(id);
        } else {
          _entities[id] = EntityState(id, '${v['state']}', attrs);
        }
      });
    }
    // Matter-Geräte: Lampen wie die Zigbee-Lampen, sonst Zustände.
    for (final d in (inventory['matter_devices'] as List? ?? const [])) {
      final ents = d['entities'] as Map<String, dynamic>;
      ents.forEach((id, v) {
        final attrs = Map<String, dynamic>.from(v['attributes'] as Map);
        if (id.startsWith('light.')) {
          final on = v['state'] == 'on';
          _mem[id] = _Mem(on, 70, kelvinToRgb(2700), 2700);
          _lampStatic[id] = attrs;
          _entities[id] = _lampEntity(id);
        } else {
          _entities[id] = EntityState(id, '${v['state']}', attrs);
        }
      });
    }
    // Sonnenstand (für die Sonne der 3D-Karte): früher Nachmittag im Süden.
    _entities['sun.sun'] = const EntityState('sun.sun', 'above_horizon', {
      'friendly_name': 'Sonne',
      'azimuth': 205.0,
      'elevation': 26.0,
    });
    // Wetter, Automationen und Szenen aus dem restlichen Bestand.
    for (final e in (inventory['ha_other'] as List)) {
      final id = e['entity_id'] as String;
      if (id.startsWith('weather.')) {
        _entities[id] = EntityState(id, '${e['state']}', {
          'friendly_name': 'Zuhause',
          'temperature': 8.0,
          'humidity': 100,
          'temperature_unit': '°C',
        });
      } else if (id.startsWith('automation.')) {
        // Zuletzt-ausgelöst-Zeiten sind erfunden (Inventar hat sie nicht).
        final n = _entities.keys
            .where((k) => k.startsWith('automation.'))
            .length;
        const mins = [
          4,
          38,
          95,
          12,
          3,
          41,
          300,
          1500,
          22,
          1440,
          610,
          615,
          7,
          19,
          66,
          260,
          31,
          29,
          160,
          175,
          880,
        ];
        _entities[id] = EntityState(id, '${e['state']}', {
          'friendly_name': e['name'] ?? id,
          'id': '${1700000000000 + n * 1337}',
          'last_triggered': e['state'] == 'on'
              ? DateTime.now()
                    .toUtc()
                    .subtract(Duration(minutes: mins[n % mins.length]))
                    .toIso8601String()
              : null,
        });
      } else if (id.startsWith('scene.')) {
        _entities[id] = EntityState(id, '${e['state']}', {
          'friendly_name': e['name'] ?? id,
        });
      }
    }
    for (final g in (inventory['z2m_groups'] as List)) {
      _sceneDefs[g['id'] as int] = [
        for (final sc in (g['scenes'] as List))
          {'id': sc['id'], 'name': sc['name'], 'look': null},
      ];
    }
    _rooms = FakeRooms(_inventory).derive(scenes: _sceneDefs);
    _initSceneSync();
    for (final t in _thermostats.entries) {
      _entities.addAll(
        thermostatEntities(t.value, _zb.stateOf(t.key), _entities),
      );
    }
    // Melder: letzte Auslösung kurz vor dem Start (Anwesenheit auf der Karte).
    final now = DateTime.now();
    _motionAgo.forEach((id, min) {
      final e = _entities[id];
      if (e != null) {
        _entities[id] = EntityState(
          id,
          e.state,
          e.attributes,
          now.subtract(Duration(minutes: min)),
        );
      }
    });
  }

  /// Minuten seit dem letzten Wechsel der Melder beim Start.
  static const _motionAgo = {
    'binary_sensor.bewegungsmelder_salon_occupancy': 1,
    'binary_sensor.prasenz_waschraum_presence': 3,
  };

  /// Auslöse-Muster der Melder im Takt von 4 s: (Periode, Takte an, Versatz).
  static const _motionPattern = {
    'binary_sensor.bewegungsmelder_salon_occupancy': (9, 4, 0),
    'binary_sensor.prasenz_waschraum_presence': (13, 2, 6),
  };
  int _motionTick = 0;

  bool _isMotion(EntityState? e) =>
      e != null &&
      e.domain == 'binary_sensor' &&
      const {'occupancy', 'motion', 'presence'}.contains(e.deviceClass);

  bool _isClimate(EntityState? e) =>
      e != null &&
      e.domain == 'sensor' &&
      const {'temperature', 'humidity'}.contains(e.deviceClass) &&
      e.number != null;

  /// Erfundener Tagesverlauf eines Klimasensors: eine Welle um den aktuellen
  /// Wert, alle 30 Minuten ein Punkt, der letzte ist der echte Zustand.
  List<StateChange> _climateHistory(String id, EntityState e, DateTime start) {
    final now = DateTime.now();
    final base = e.number!;
    final temp = e.deviceClass == 'temperature';
    final amp = temp ? 1.4 : 4.0;
    final seed = id.codeUnits.fold<int>(7, (a, c) => (a * 31 + c) & 0xffff);
    final phase = (seed % 628) / 100;
    double wave(DateTime t) =>
        sin(
              t.millisecondsSinceEpoch / Duration.millisecondsPerDay * 2 * pi +
                  phase,
            ) *
            amp +
        sin(t.millisecondsSinceEpoch / 1800000 + phase) * amp * 0.15;
    final offset = wave(now);
    String fmt(double v) => temp ? v.toStringAsFixed(1) : v.toStringAsFixed(0);
    final out = <StateChange>[];
    var t = start.subtract(const Duration(minutes: 30));
    while (t.isBefore(now.subtract(const Duration(minutes: 20)))) {
      out.add(StateChange(fmt(base + wave(t) - offset), t));
      t = t.add(const Duration(minutes: 30));
    }
    out.add(StateChange(e.state, now));
    return out;
  }

  /// Erfundene, aber feste History der Melder für die letzte Stunde: Wechsel
  /// rückwärts ab dem letzten echten Wechsel, Längen aus einem Hash.
  @override
  Future<Map<String, List<StateChange>>> stateHistory(
    List<String> entityIds,
    DateTime start,
  ) async {
    final out = <String, List<StateChange>>{};
    for (final id in entityIds) {
      final e = _entities[id];
      if (_isClimate(e)) {
        out[id] = _climateHistory(id, e!, start);
        continue;
      }
      if (!_isMotion(e)) continue;
      final list = <StateChange>[];
      var on = e!.isOn;
      var t = e.lastChanged ?? DateTime.now();
      list.add(StateChange(e.state, t));
      var seed = id.codeUnits.fold<int>(17, (a, c) => (a * 31 + c) & 0xffff);
      while (t.isAfter(start)) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        // Vorheriger Zustand: das Gegenteil, mit seiner Dauer.
        on = !on;
        final minutes = on ? 1 + seed % 4 : 3 + seed % 10;
        t = t.subtract(Duration(minutes: minutes, seconds: seed % 50));
        list.add(StateChange(on ? 'on' : 'off', t));
      }
      out[id] = list.reversed.toList();
    }
    return out;
  }

  EntityState _lampEntity(String id) {
    final m = _mem[id]!;
    final attrs = Map<String, dynamic>.from(_lampStatic[id]!);
    if (!m.on) {
      return EntityState(id, 'off', attrs);
    }
    final modes = (attrs['supported_color_modes'] as List).cast<String>();
    attrs['brightness'] = (m.brightness * 2.55).round().clamp(1, 255);
    if (modes.contains('xy') || modes.contains('color_temp')) {
      attrs['rgb_color'] = [m.rgb.$1, m.rgb.$2, m.rgb.$3];
      if (m.kelvin != null) attrs['color_temp_kelvin'] = m.kelvin;
      attrs['color_mode'] = m.kelvin != null ? 'color_temp' : 'xy';
    }
    return EntityState(id, 'on', attrs);
  }

  Room? _room(String id) {
    for (final r in _rooms) {
      if (r.id == id) return r;
    }
    return null;
  }

  Room? _roomOfLight(String id) {
    for (final r in _rooms) {
      if (r.lightIds.contains(id)) return r;
    }
    return null;
  }

  void _commit(
    Iterable<String> changed, {
    Iterable<String> manualFor = const [],
  }) {
    for (final id in changed) {
      _entities[id] = _lampEntity(id);
    }
    for (final id in manualFor) {
      final r = _roomOfLight(id);
      if (r != null) _activeScenes.remove(r.id);
    }
    _push();
  }

  void _push() {
    publish(
      snapshot.copyWith(
        entities: Map.unmodifiable(Map.of(_entities)),
        activeScenes: Map.unmodifiable(Map.of(_activeScenes)),
        rooms: _rooms,
        excludedLights: Set.unmodifiable(_excluded),
        locked: Set.unmodifiable(_locked),
        weather: _weather,
        lampCalibration: _calibration,
      ),
    );
  }

  @override
  Future<void> setLocked(Iterable<String> ids, bool locked) async {
    final next = {..._locked};
    locked ? next.addAll(ids) : next.removeAll(ids);
    _locked = next;
    _push();
    await _local.setLockedIds(next);
  }

  @override
  Future<void> setWeatherConfig(WeatherConfig config) async {
    _weather = config;
    _push();
    await _local.setWeatherConfig(config.toJson());
  }

  @override
  Future<void> setLampCalibration(LampCalibrations calibration) async {
    _calibration = calibration;
    _push();
    await _local.setLampCalibration(calibration.toJson());
  }

  /// Lampen der Lichtsteuerung (ohne Ausnahmen).
  List<String> _controlled(Room r) => [
    for (final id in r.lightIds)
      if (!_excluded.contains(id) && _mem.containsKey(id)) id,
  ];

  @override
  bool get prefsShared => false;

  @override
  Future<void> setLightExcluded(String entityId, bool excluded) async {
    final next = {..._excluded};
    excluded ? next.add(entityId) : next.remove(entityId);
    _excluded = next;
    for (final l in _lastOn.values) {
      l.remove(entityId);
    }
    _push();
    await _local.setExcludedLights(next);
  }

  @override
  Future<void> refresh() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _push();
  }

  @override
  Future<void> setLights(
    List<String> entityIds, {
    bool? on,
    int? brightness,
    Rgb? rgb,
    int? kelvin,
  }) async {
    final changed = <String>[];
    for (final id in entityIds) {
      final m = _mem[id];
      // Gesperrte Lampen („immer an“) schaltet Haven nicht.
      if (m == null || _locked.contains(id)) continue;
      final modes = (_lampStatic[id]!['supported_color_modes'] as List)
          .cast<String>();
      var turnOn = on == true;
      if (brightness != null) {
        if (brightness <= 0) {
          m.on = false;
        } else {
          m.brightness = brightness.clamp(1, 100);
          turnOn = on != false;
        }
      }
      if (rgb != null && modes.contains('xy')) {
        m.rgb = rgb;
        m.kelvin = null;
        turnOn = on != false;
      }
      if (kelvin != null && !modes.contains('brightness')) {
        m.kelvin = kelvin;
        m.rgb = kelvinToRgb(kelvin);
        turnOn = on != false;
      }
      if (on == false) {
        m.on = false;
      } else if (turnOn) {
        m.on = true;
      }
      changed.add(id);
    }
    _commit(changed, manualFor: changed);
  }

  List<String> _lightsOn(Room r) => [
    for (final id in _controlled(r))
      if (_mem[id]?.on == true) id,
  ];

  @override
  Future<void> toggleRoom(String roomId) async {
    final r = _room(roomId);
    if (r == null) return;
    final on = _lightsOn(r);
    if (on.isNotEmpty) {
      _lastOn[roomId] = on;
      await setLights(on, on: false);
    } else {
      final last = _lastOn[roomId];
      await setLights(
        last == null || last.isEmpty ? _controlled(r) : last,
        on: true,
      );
    }
  }

  @override
  Future<void> setRoomBrightness(String roomId, int brightness) async {
    final r = _room(roomId);
    if (r == null) return;
    final on = _lightsOn(r);
    if (brightness <= 0) {
      if (on.isNotEmpty) _lastOn[roomId] = on;
      await setLights(_controlled(r), on: false);
      return;
    }
    final targets = on.isNotEmpty
        ? on
        : (_lastOn[roomId]?.isNotEmpty == true
              ? _lastOn[roomId]!
              : _controlled(r));
    await setLights(targets, brightness: brightness);
  }

  @override
  Future<void> applyScene(String roomId, String sceneId) async {
    final r = _room(roomId);
    if (r == null) return;
    final scene = r.scenes.where((s) => s.id == sceneId).firstOrNull;
    if (scene == null) return;
    final saved = _sceneLamps['${scene.groupId}:${scene.number}'];
    if (saved != null) {
      saved.forEach((id, m) {
        final cur = _mem[id];
        if (cur != null) _assign(cur, m);
      });
      _activeScenes[roomId] = sceneId;
      _commit(saved.keys.where(_mem.containsKey));
      return;
    }
    final style = _styleMems(scene, _controlled(r));
    style.forEach((id, m) => _assign(_mem[id]!, m));
    _activeScenes[roomId] = sceneId;
    _commit(style.keys);
  }

  /// Was die [lamps] bei einer Szene ohne gespeicherten Zustand tun: Farben
  /// und Helligkeit der Karte, Lampe i bekommt `colors[i mod 3]`.
  Map<String, _Mem> _styleMems(RoomScene scene, List<String> lamps) {
    final out = <String, _Mem>{};
    var i = 0;
    for (final id in lamps) {
      final cur = _mem[id]!;
      final only = scene.onlyLightIds;
      if (only != null && !only.contains(id)) {
        out[id] = _Mem(false, cur.brightness, cur.rgb, cur.kelvin);
        continue;
      }
      var rgb = cur.rgb;
      var kelvin = cur.kelvin;
      if (!_modes(id).contains('brightness')) {
        if (scene.kelvin != null) {
          kelvin = scene.kelvin;
          rgb = kelvinToRgb(scene.kelvin!);
        } else {
          kelvin = null;
          rgb = scene.colors[i % 3];
        }
      }
      out[id] = _Mem(true, scene.brightness.clamp(1, 100), rgb, kelvin);
      i++;
    }
    return out;
  }

  List<String> _modes(String id) =>
      (_lampStatic[id]!['supported_color_modes'] as List).cast<String>();

  static void _assign(_Mem to, _Mem from) => to
    ..on = from.on
    ..brightness = from.brightness
    ..rgb = from.rgb
    ..kelvin = from.kelvin;

  static _Mem _copy(_Mem m) => _Mem(m.on, m.brightness, m.rgb, m.kelvin);

  // ---- Szenen anlegen und ändern ------------------------------------------

  @override
  bool canEditScenes(String roomId) => _room(roomId)?.zigbeeGroupId != null;

  List<Map<String, dynamic>> _scenesOf(String roomId) {
    final gid = _room(roomId)?.zigbeeGroupId;
    if (gid == null) {
      throw HavenException(
        'Dieser Raum hat keine Zigbee-Gruppe',
        code: 'not_found',
      );
    }
    return _sceneDefs[gid]!;
  }

  String _sceneName(
    List<Map<String, dynamic>> list,
    String? name,
    int? except,
  ) {
    final clean = (name ?? '').trim().split(RegExp(r'\s+')).join(' ');
    if (clean.isEmpty) {
      throw HavenException(
        'Der Name darf nicht leer sein',
        code: 'invalid_format',
      );
    }
    final owner = list.where(
      (s) =>
          (s['name'] as String).toLowerCase() == clean.toLowerCase() &&
          s['id'] != except,
    );
    if (owner.isNotEmpty) {
      throw HavenException(
        'Die Szene \'${owner.first['name']}\' gibt es schon',
        code: 'name_taken',
      );
    }
    return clean;
  }

  Future<void> _sceneDelay() async {
    if (simulate) await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  void _rebuildRooms() {
    _refreshSync();
    _rooms = FakeRooms(_inventory).derive(scenes: _sceneDefs);
    _push();
  }

  @override
  Future<int> storeScene(String roomId, {String? name, int? number}) async {
    final list = _scenesOf(roomId);
    final gid = _room(roomId)!.zigbeeGroupId!;
    final existing = number == null
        ? null
        : list.where((s) => s['id'] == number).firstOrNull;
    if (number != null && existing == null) {
      throw HavenException('Die Szene gibt es nicht mehr', code: 'not_found');
    }
    final clean = _sceneName(
      list,
      name ?? existing?['name'] as String?,
      number,
    );
    await _sceneDelay();
    final used = {for (final s in list) s['id'] as int};
    final id =
        number ??
        Iterable<int>.generate(256).firstWhere((i) => !used.contains(i));
    final r = _room(roomId)!;
    final lamps = [
      for (final l in r.lightIds)
        if (_mem.containsKey(l)) l,
    ];
    final look = sceneLookOf(
      [for (final l in lamps) snapshot.lamp(l)].nonNulls.toList(),
    );
    final def = <String, dynamic>{
      'id': id,
      'name': clean,
      'look': look.toJson(),
    };
    if (existing != null) {
      list[list.indexOf(existing)] = def;
    } else {
      list.add(def);
    }
    _sceneLamps['$gid:$id'] = {
      for (final l in lamps)
        l: _Mem(
          _mem[l]!.on,
          _mem[l]!.brightness,
          _mem[l]!.rgb,
          _mem[l]!.kelvin,
        ),
    };
    // Wie die Integration: das Speichern merkt sich auch das Soll.
    _sceneTargets['$gid:$id'] = {
      for (final l in lamps) l: _stateOf(l, _mem[l]!),
    };
    _sceneChecks.remove('$gid:$id');
    _activeScenes[roomId] = slugify(clean);
    _rebuildRooms();
    return id;
  }

  @override
  Future<void> renameScene(String roomId, int number, String name) async {
    final list = _scenesOf(roomId);
    final i = list.indexWhere((s) => s['id'] == number);
    if (i < 0) {
      throw HavenException('Die Szene gibt es nicht mehr', code: 'not_found');
    }
    final clean = _sceneName(list, name, number);
    await _sceneDelay();
    final wasActive =
        _activeScenes[roomId] == slugify(list[i]['name'] as String);
    list[i] = {...list[i], 'name': clean};
    if (wasActive) _activeScenes[roomId] = slugify(clean);
    _rebuildRooms();
  }

  @override
  Future<void> removeScene(String roomId, int number) async {
    final list = _scenesOf(roomId);
    final gid = _room(roomId)!.zigbeeGroupId!;
    final i = list.indexWhere((s) => s['id'] == number);
    if (i < 0) return;
    await _sceneDelay();
    if (_activeScenes[roomId] == slugify(list[i]['name'] as String)) {
      _activeScenes.remove(roomId);
    }
    list.removeAt(i);
    _sceneLamps.remove('$gid:$number');
    _sceneTargets.remove('$gid:$number');
    _sceneChecks.remove('$gid:$number');
    _rebuildRooms();
  }

  // ---- Szenen-Abgleich ------------------------------------------------------
  //
  // Wie die Integration (Feature `scene_sync`): je Szene ein Soll je Lampe,
  // Messen ruft die Szene auf und liest die Lampen. Was eine Lampe beim
  // Aufruf tut, steht in `_sceneLamps` (wie auf dem Gerät), sonst folgt sie
  // den Farben der Karte. Beim Start kennt in der ersten Gruppe eine Lampe
  // eine Szene nicht (kam später dazu) und eine andere leuchtet in einer
  // Szene in falscher Farbe.

  /// Soll je Szene (`"gruppe:szene"`) und Lampe.
  final Map<String, Map<String, LampState>> _sceneTargets = {};

  /// Letzte Messung je Szene.
  final Map<String, SceneCheck> _sceneChecks = {};

  @override
  bool get canSyncScenes => true;

  @override
  bool get knobLightActions => true;

  @override
  bool get canCreateRoomGroups => true;

  /// Im Fake angelegte Gruppen (wie `z2m_groups` in den Beispieldaten).
  final List<Map<String, dynamic>> _newGroups = [];

  /// Beispieldaten samt angelegter Gruppen.
  Map<String, dynamic> get _inventory => _newGroups.isEmpty
      ? inventory
      : {
          ...inventory,
          'z2m_groups': [...inventory['z2m_groups'] as List, ..._newGroups],
        };

  @override
  Future<String> createRoomGroup(String roomId) async {
    final r = _room(roomId);
    if (r == null) throw HavenException('Unbekannter Raum', code: 'not_found');
    if (r.zigbeeGroupId != null) {
      throw HavenException(
        '${r.name} hat schon eine Gruppe',
        code: 'group_exists',
      );
    }
    final members = [
      for (final d in inventory['z2m_devices'] as List)
        if ((d as Map)['room'] == roomId && d['device_type'] == 'light')
          '${d['friendly_name']}',
    ];
    if (members.isEmpty) {
      throw HavenException(
        'In ${r.name} gibt es keine Zigbee-Lampen',
        code: 'no_lights',
      );
    }
    await _sceneDelay();
    final ids = [
      for (final g in _inventory['z2m_groups'] as List) (g as Map)['id'] as int,
    ];
    final id = ids.fold(0, (a, b) => a > b ? a : b) + 1;
    _newGroups.add({
      'id': id,
      'name': r.name,
      'room': roomId,
      'members': members,
      'scenes': const <Map<String, dynamic>>[],
    });
    _sceneDefs[id] = [];
    _rebuildRooms();
    return r.name;
  }

  List<String> _groupLamps(Room r) => [
    for (final l in r.lightIds)
      if (_mem.containsKey(l)) l,
  ];

  LampState _stateOf(String id, _Mem m) {
    if (!m.on) return LampState.off;
    if (_modes(id).contains('brightness')) {
      return LampState(on: true, brightness: m.brightness);
    }
    return m.kelvin != null
        ? LampState(on: true, brightness: m.brightness, kelvin: m.kelvin)
        : LampState(on: true, brightness: m.brightness, rgb: m.rgb);
  }

  _Mem _memOf(String id, LampState s) {
    final cur = _mem[id]!;
    return _Mem(
      s.on,
      s.brightness ?? cur.brightness,
      s.rgb ?? (s.kelvin != null ? kelvinToRgb(s.kelvin!) : cur.rgb),
      s.rgb != null ? null : s.kelvin ?? cur.kelvin,
    );
  }

  /// Soll für alle Szenen, dazu die beiden Fehler in der ersten Gruppe.
  void _initSceneSync() {
    var faulted = false;
    for (final r in _rooms) {
      final gid = r.zigbeeGroupId;
      if (gid == null) continue;
      final lamps = _groupLamps(r);
      if (lamps.isEmpty) continue;
      for (final (n, scene) in r.scenes.indexed) {
        final key = '$gid:${scene.number}';
        final style = _styleMems(scene, lamps);
        _sceneTargets[key] = {
          for (final e in style.entries) e.key: _stateOf(e.key, e.value),
        };
        if (faulted || lamps.length < 2 || r.scenes.length < 4) continue;
        if (n == 2) {
          // Kam nach dem Speichern in die Gruppe: kennt die Szene nicht und
          // hat kein Soll (die Szene ist „neu abzugleichen“).
          final late = lamps.last;
          _sceneTargets[key]!.remove(late);
          _sceneLamps[key] = style..remove(late);
        } else if (n == 3) {
          // Neu gekoppelt: die Szene auf der Lampe hat eine andere Farbe.
          final odd = lamps.firstWhere(
            (id) => _modes(id).contains('xy'),
            orElse: () => lamps.first,
          );
          final m = style[odd]!;
          if (_modes(odd).contains('xy')) {
            const a = (40, 200, 255), b = (255, 64, 160);
            final close =
                (m.rgb.$1 - a.$1).abs() < 80 && (m.rgb.$3 - a.$3).abs() < 80;
            m
              ..on = true
              ..rgb = close ? b : a
              ..kelvin = null;
          } else {
            m
              ..on = true
              ..brightness = m.brightness > 50 ? 15 : 90;
          }
          _sceneLamps[key] = style;
          faulted = true;
        }
      }
    }
    _refreshSync();
    _rooms = FakeRooms(_inventory).derive(scenes: _sceneDefs);
  }

  /// Schreibt `sync` und `checked_at` in die Szenen der Gruppen.
  void _refreshSync() {
    for (final r in _rooms) {
      final gid = r.zigbeeGroupId;
      if (gid == null) continue;
      final lamps = _groupLamps(r);
      for (final def in _sceneDefs[gid] ?? const <Map<String, dynamic>>[]) {
        final key = '$gid:${def['id']}';
        final target = _sceneTargets[key];
        final check = _sceneChecks[key];
        def['sync'] = target == null
            ? 'unknown'
            : target.length != lamps.length || !lamps.every(target.containsKey)
            ? 'stale'
            : check != null && check.outcome != SceneCheckOutcome.ok
            ? 'differs'
            : 'ok';
        def['checked_at'] = check?.checkedAt?.toUtc().toIso8601String();
      }
    }
  }

  (Room, RoomScene) _syncScene(String roomId, int number) {
    final r = _room(roomId);
    if (r?.zigbeeGroupId == null) {
      throw HavenException(
        'Dieser Raum hat keine Zigbee-Gruppe',
        code: 'not_found',
      );
    }
    final scene = r!.scenes.where((s) => s.number == number).firstOrNull;
    if (scene == null) {
      throw HavenException('Die Szene gibt es nicht mehr', code: 'not_found');
    }
    return (r, scene);
  }

  /// Ruft die Szene auf, liest jede Lampe und stellt das Licht davor wieder
  /// her. Mit Simulation leuchten die Lampen dabei rund eine Sekunde.
  Future<SceneCheck> _measure(Room r, RoomScene scene) async {
    final gid = r.zigbeeGroupId!;
    final key = '$gid:${scene.number}';
    final lamps = _groupLamps(r);
    final saved = _sceneLamps[key];
    final style = saved == null ? _styleMems(scene, lamps) : null;
    final recalled = <String, _Mem?>{
      for (final id in lamps) id: saved != null ? saved[id] : style![id],
    };
    final before = {for (final id in lamps) id: _copy(_mem[id]!)};
    if (simulate) {
      recalled.forEach((id, m) {
        if (m != null) _assign(_mem[id]!, m);
      });
      _commit(lamps);
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      before.forEach((id, m) => _assign(_mem[id]!, m));
      _commit(lamps);
    }
    final target = _sceneTargets[key];
    final reacted = recalled.values.any((m) => m != null);
    final members = <SceneLampCheck>[];
    for (final id in lamps) {
      final rec = recalled[id];
      final measured = _stateOf(id, rec ?? before[id]!);
      final expected = target?[id];
      final SceneLampStatus status;
      if (rec == null) {
        status = expected != null && expected.matches(measured)
            ? SceneLampStatus.ok
            : expected == null && !reacted
            ? SceneLampStatus.ok
            : SceneLampStatus.missing;
      } else if (expected != null && !expected.matches(measured)) {
        status = SceneLampStatus.differs;
      } else {
        status = SceneLampStatus.ok;
      }
      members.add(
        SceneLampCheck(
          entityId: id,
          name: '${_lampStatic[id]?['friendly_name'] ?? id}',
          expected: expected,
          measured: measured,
          status: status,
        ),
      );
    }
    final look = sceneLookOf([
      for (final m in members)
        Lamp(
          entityId: m.entityId,
          name: m.name,
          on: m.measured!.on,
          brightness: m.measured!.on ? m.measured!.brightness ?? 100 : 0,
          color: m.measured!.color ?? sceneOffColor,
          kelvin: m.measured!.kelvin,
        ),
    ]);
    final check = SceneCheck(
      groupId: gid,
      sceneId: scene.number!,
      name: scene.name,
      hasTarget: target != null,
      status: target == null
          ? SceneCheckStatus.unknown
          : members.every((m) => m.status == SceneLampStatus.ok)
          ? SceneCheckStatus.ok
          : SceneCheckStatus.differs,
      members: members,
      measuredLook: look,
      checkedAt: DateTime.now(),
    );
    _sceneChecks[key] = check;
    _rebuildRooms();
    return check;
  }

  @override
  Future<SceneCheck> checkScene(String roomId, int number) {
    final (r, scene) = _syncScene(roomId, number);
    return _measure(r, scene);
  }

  @override
  Future<void> adoptScene(String roomId, int number) async {
    final (r, scene) = _syncScene(roomId, number);
    final gid = r.zigbeeGroupId!;
    final key = '$gid:$number';
    // Was die Lampen tun, bleibt so, auch wenn sich die Kartenfarben ändern.
    _sceneLamps[key] ??= _styleMems(scene, _groupLamps(r));
    final check = _sceneChecks[key] ?? await _measure(r, scene);
    await _sceneDelay();
    _sceneTargets[key] = {
      for (final m in check.members)
        if (m.measured != null) m.entityId: m.measured!,
    };
    _sceneChecks[key] = check.adopted();
    final list = _sceneDefs[gid]!;
    final i = list.indexWhere((s) => s['id'] == number);
    if (i >= 0 && check.measuredLook != null) {
      list[i] = <String, dynamic>{
        ...list[i],
        'look': check.measuredLook!.toJson(),
      };
    }
    _rebuildRooms();
  }

  @override
  Future<SceneCheck> repairScene(String roomId, int number) async {
    final (r, scene) = _syncScene(roomId, number);
    final key = '${r.zigbeeGroupId}:$number';
    final target = _sceneTargets[key];
    if (target == null) {
      throw HavenException(
        'Für diese Szene gibt es kein Soll. Erst übernehmen oder neu speichern.',
        code: 'no_target',
      );
    }
    final lamps = _groupLamps(r);
    // Soll auf alle Lampen (ohne Soll: aus), Szene neu speichern; das
    // Speichern merkt sich das Soll für alle Mitglieder.
    final stored = {
      for (final id in lamps) id: _memOf(id, target[id] ?? LampState.off),
    };
    if (simulate) await Future<void>.delayed(const Duration(milliseconds: 800));
    _sceneLamps[key] = stored;
    _sceneTargets[key] = {
      for (final e in stored.entries) e.key: _stateOf(e.key, e.value),
    };
    return _measure(r, scene);
  }

  @override
  Future<void> allLightsOff() async {
    for (final r in _rooms) {
      final on = _lightsOn(r);
      if (on.isNotEmpty) _lastOn[r.id] = on;
    }
    await setLights([for (final r in _rooms) ..._controlled(r)], on: false);
  }

  @override
  Future<void> callService(
    String domain,
    String service, {
    String? entityId,
    Map<String, dynamic> data = const {},
  }) async {
    final id = entityId ?? data['entity_id'] as String?;
    if (id == null) return;
    if (const {'turn_off', 'turn_on', 'toggle'}.contains(service)) {
      checkLocked(id);
    }
    if (domain == 'update') return _updateService(service, id);
    if (domain == 'light') {
      if (service == 'turn_off') return setLights([id], on: false);
      if (service == 'turn_on') return setLights([id], on: true);
      if (service == 'toggle') return setLights([id], on: _mem[id]?.on != true);
    }
    final e = _entities[id];
    if (e == null) return;
    if (domain == 'automation' && service == 'trigger') {
      _entities[id] = e.copyWith(
        attributes: {
          ...e.attributes,
          'last_triggered': DateTime.now().toUtc().toIso8601String(),
        },
      );
      _push();
      return;
    }
    final next = switch (service) {
      'turn_on' => 'on',
      'turn_off' => 'off',
      'toggle' => e.isOn ? 'off' : 'on',
      _ => null,
    };
    if (next == null) return;
    _entities[id] = e.copyWith(state: next);
    _push();
  }

  final Map<String, Timer> _installs = {};

  /// `update.install` und `update.skip`. Mit Zeitgebern läuft der Fortschritt
  /// in Schritten hoch, ohne ist die Installation sofort fertig.
  Future<void> _updateService(String service, String id) async {
    final e = _entities[id];
    if (e == null) return;
    if (service == 'skip') {
      _entities[id] = e.copyWith(
        state: 'off',
        attributes: {
          ...e.attributes,
          'skipped_version': e.attributes['latest_version'],
        },
      );
      _push();
      return;
    }
    if (service != 'install') return;
    if (!simulate) {
      _finishInstall(id);
      return;
    }
    _setProgress(
      id,
      ((e.attributes['update_percentage'] as num?) ?? 0).toInt(),
    );
  }

  void _setProgress(String id, int pct) {
    final e = _entities[id];
    if (e == null) return;
    _entities[id] = e.copyWith(
      attributes: {
        ...e.attributes,
        'in_progress': true,
        'update_percentage': pct,
      },
    );
    _push();
    _installs[id]?.cancel();
    _installs[id] = Timer(const Duration(milliseconds: 700), () {
      if (pct >= 100) {
        _finishInstall(id);
      } else {
        _setProgress(id, (pct + 12).clamp(0, 100));
      }
    });
  }

  void _finishInstall(String id) {
    _installs.remove(id)?.cancel();
    final e = _entities[id];
    if (e == null) return;
    _entities[id] = e.copyWith(
      state: 'off',
      attributes: {
        ...e.attributes,
        'in_progress': false,
        'update_percentage': null,
        'installed_version': e.attributes['latest_version'],
      },
    );
    _push();
  }

  @override
  Future<dynamic> command(
    String type, [
    Map<String, dynamic> payload = const {},
  ]) async {
    switch (type) {
      case 'update/release_notes':
        return kFakeReleaseNotes[payload['entity_id']];
      case 'haven/info':
        return {
          'domain': 'haven',
          'version': '0.2.0',
          'api_version': 1,
          'features': ['ghost_detection'],
          'loaded': true,
          'z2m': {
            'bridge_state': 'online',
            'device_count': (inventory['z2m_devices'] as List).length,
            'group_count': (inventory['z2m_groups'] as List).length,
          },
        };
      case 'haven/rooms':
        return {
          'rooms': [
            for (final r in _rooms)
              {
                'area_id': r.id,
                'name': r.name,
                'lights': r.lightIds,
                'climate': {
                  'temperature': [if (r.temperatureId != null) r.temperatureId],
                  'humidity': [if (r.humidityId != null) r.humidityId],
                },
              },
          ],
          'unassigned': <dynamic>[],
        };
      case 'haven/zigbee/devices':
        return {
          'devices': [
            for (final d in (inventory['z2m_devices'] as List))
              {
                for (final k in const [
                  'ieee',
                  'friendly_name',
                  'type',
                  'vendor',
                  'model',
                  'description',
                  'power_source',
                  'image',
                  'device_type',
                  'capabilities',
                ])
                  k: (d as Map)[k],
                'supported': true,
                'disabled': false,
                'interview_completed': true,
              },
          ],
        };
      case 'haven/zigbee/groups':
        final devs = {
          for (final d in (inventory['z2m_devices'] as List))
            d['friendly_name'] as String: d as Map,
        };
        return {
          'groups': [
            for (final g in (inventory['z2m_groups'] as List))
              {
                'id': g['id'],
                'friendly_name': g['name'],
                'members': [
                  for (final m in (g['members'] as List))
                    if (devs[m] != null)
                      {
                        'ieee': devs[m]!['ieee'],
                        'friendly_name': m,
                        'device_type': devs[m]!['device_type'],
                      },
                ],
                'scenes': _sceneDefs[g['id']] ?? g['scenes'],
              },
          ],
        };
    }
    throw HavenException(
      'Der Befehl $type gibt es in den Entwicklungsdaten nicht.',
      code: 'not_found',
    );
  }

  /// Leichte Bewegung in den Messwerten, damit Zahlen leben.
  /// Thermostate: IEEE → Slug der Entities (`climate.<slug>`).
  late final Map<String, String> _thermostats = {
    for (final d in (inventory['z2m_devices'] as List))
      if (d['device_type'] == 'thermostat')
        for (final id in (d['entities'] as Map).keys.cast<String>())
          if (id.startsWith('climate.'))
            d['ieee'] as String: id.substring('climate.'.length),
  };

  void _syncThermostat(String ieee) {
    final slug = _thermostats[ieee];
    if (slug == null) return;
    _entities.addAll(thermostatEntities(slug, _zb.stateOf(ieee), _entities));
  }

  void _tick() {
    var changed = false;
    _motionTick++;
    for (final ieee in _thermostats.keys) {
      final step = thermostatStep(_zb.stateOf(ieee), _motionTick);
      if (step.isEmpty) continue;
      _zb.update(ieee, step);
      _syncThermostat(ieee);
      changed = true;
    }
    _motionPattern.forEach((id, p) {
      final e = _entities[id];
      if (e == null) return;
      final (period, onTicks, offset) = p;
      final next = (_motionTick + offset) % period < onTicks ? 'on' : 'off';
      if (next != e.state) {
        _entities[id] = e.copyWith(state: next);
        changed = true;
      }
    });
    for (final e in _entities.values.toList()) {
      if (e.deviceClass == 'power' && (e.number ?? 0) > 5) {
        final v = (e.number! + (_rng.nextInt(9) - 4)).clamp(5, 400);
        _entities[e.entityId] = e.copyWith(state: v.round().toString());
        changed = true;
      } else if (e.deviceClass == 'temperature' && e.number != null) {
        final v = e.number! + (_rng.nextDouble() - 0.5) * 0.1;
        _entities[e.entityId] = e.copyWith(state: v.toStringAsFixed(2));
        changed = true;
      }
    }
    if (_motionTick % 2 == 0) _heat.tick(DateTime.now());
    if (changed) _push();
  }

  // ---- Zigbee (Entwicklungsdaten, alles im Speicher) --------------------------------
  @override
  Stream<ZbEvent> get zigbeeEvents => _zb.events;
  @override
  Future<List<ZbDevice>> zigbeeDevices() => _zb.devices();
  @override
  Future<ZbDevice> zigbeeDevice(String ieee) => _zb.device(ieee);
  @override
  Future<List<ZbGroup>> zigbeeGroups() => _zb.groups();
  @override
  Future<ZbBridgeInfo> zigbeeInfo() => _zb.info();
  @override
  Future<Map<String, Map<String, dynamic>>> zigbeeStates() => _zb.states();
  @override
  Future<void> zigbeeSet(String ieee, Map<String, dynamic> values) async {
    if (BaseRepository.controlsDevice(values)) checkLocked(ieee);
    if (!_thermostats.containsKey(ieee)) return _zb.set(ieee, values);
    final derived = thermostatDerived(
      _zb.stateOf(ieee),
      values,
      DateTime.now(),
    );
    // Ausdrücklich gesendete Werte gehen vor (Preset und Sollwert zusammen).
    await _zb.set(ieee, {...derived, ...values});
    _syncThermostat(ieee);
    _push();
  }

  @override
  Future<void> zigbeeRename(
    String ieee,
    String name, {
    bool renameHaEntities = true,
  }) => _zb.rename(ieee, name);
  @override
  Future<void> zigbeeSetArea(String ieee, String? areaId) =>
      _zb.setArea(ieee, areaId);
  @override
  Future<void> zigbeeIdentify(String ieee) async {}
  @override
  Future<void> zigbeeInterview(String ieee) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  @override
  Future<void> zigbeeRemove(String ieee, {bool force = false}) =>
      _zb.remove(ieee);
  @override
  Future<void> zigbeePermitJoin({int seconds = 240, String? viaIeee}) =>
      _zb.permitJoin(seconds);
  @override
  Future<void> zigbeeStopJoin() => _zb.stopJoin();
  @override
  Future<ZbNetworkMap> zigbeeNetworkMap({bool refresh = false}) =>
      _zb.networkMap(refresh: refresh);
  @override
  bool get zigbeeBackgroundMeasure => true;
  @override
  bool get zigbeeGhostDetection => true;
  @override
  Future<bool> zigbeeEnableLastSeen() => _zb.enableLastSeen();
  @override
  Future<ZbMeasureStart> zigbeeStartNetworkMeasure() => _zb.startMeasure();
  @override
  Stream<ZbMeasureResult> get zigbeeMeasureResults => _zb.measureResults;

  // ---- Heizungsregelung (Entwicklungsdaten, siehe fake_heating.dart) -------
  @override
  Future<HeatingRooms> heatingRooms() => _heat.list();
  @override
  Future<RoomHeating> saveHeating(HeatingConfig config) => _heat.save(config);
  @override
  Future<void> deleteHeating(String areaId) => _heat.delete(areaId);

  @override
  Future<Set<String>> setHeatingDisplay(String ieee, bool display) =>
      _heat.setDisplay(ieee, display);
  @override
  Future<HeatingStatus> controlHeating(
    String areaId, {
    double? target,
    HeatingMode? mode,
    bool resume = false,
  }) => _heat.control(areaId, target: target, mode: mode, resume: resume);
  @override
  Stream<HeatingUpdate> get heatingUpdates => _heat.updates;
  @override
  Stream<void> get heatingChanged => _heat.changed;

  // ---- Haven-Automationen (Entwicklungsdaten, siehe fake_automations.dart) --
  @override
  Future<HavenAutomations> havenAutomations() => _auto.list();
  @override
  Future<HavenAutomation> saveHavenAutomation(HavenAutomation automation) =>
      _auto.save(automation);
  @override
  Future<void> deleteHavenAutomation(String id) => _auto.delete(id);
  @override
  Future<void> testHavenAutomation(String id, String action) =>
      _auto.test(id, action);
  @override
  Stream<AutomationTrigger> get automationTriggers => _auto.triggers;
  @override
  Stream<void> get automationsChanged => _auto.changed;

  /// Simulierte Geste an einem Drehregler oder Taster (Tests, Live-Test).
  Future<void> simulateGesture(String ieee, String action) =>
      _auto.gesture(ieee, action);

  @override
  Future<void> dispose() async {
    await _auto.dispose();
    await _heat.dispose();
    await _zb.dispose();
    _timer?.cancel();
    for (final t in _installs.values) {
      t.cancel();
    }
    _installs.clear();
    await super.dispose();
  }
}
