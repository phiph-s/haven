import 'dart:async';
import 'dart:math';

import '../core/light/color_math.dart';
import '../data/base_repository.dart';
import '../data/haven_repository.dart';
import '../data/models/entity_state.dart';
import '../data/models/floor_plan.dart';
import '../data/models/haven_automation.dart';
import '../data/models/room.dart';
import '../data/models/snapshot.dart';
import '../data/models/state_history.dart';
import '../data/models/zigbee.dart';
import '../data/models/zigbee_network.dart';
import '../data/storage/settings_store.dart';
import 'fake_automations.dart';
import 'fake_data.dart';
import 'fake_floor_plan.dart';
import 'fake_rooms.dart';
import 'fake_updates.dart';
import 'fake_zigbee.dart';

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
  final LocalPrefs _local;
  Set<String> _excluded = const {};

  final Map<String, EntityState> _entities = {};
  final Map<String, _Mem> _mem = {};
  final Map<String, Map<String, dynamic>> _lampStatic = {};
  final Map<String, List<String>> _lastOn = {};
  final Map<String, String> _activeScenes = {};
  List<Room> _rooms = const [];
  Timer? _timer;
  bool _started = false;

  @override
  bool get isFake => true;

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
    publish(
      HavenSnapshot(
        status: ConnectionStatus.connected,
        entities: Map.unmodifiable(_entities),
        rooms: _rooms,
        excludedLights: Set.unmodifiable(_excluded),
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
    _rooms = FakeRooms(inventory).derive();
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
      ),
    );
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
      if (m == null) continue;
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
    final changed = <String>[];
    var i = 0;
    for (final id in _controlled(r)) {
      final m = _mem[id]!;
      final only = scene.onlyLightIds;
      if (only != null && !only.contains(id)) {
        m.on = false;
        changed.add(id);
        continue;
      }
      final modes = (_lampStatic[id]!['supported_color_modes'] as List)
          .cast<String>();
      m.on = true;
      m.brightness = scene.brightness.clamp(1, 100);
      if (!modes.contains('brightness')) {
        if (scene.kelvin != null) {
          m.kelvin = scene.kelvin;
          m.rgb = kelvinToRgb(scene.kelvin!);
        } else {
          m.kelvin = null;
          m.rgb = scene.colors[i % 3];
        }
      }
      i++;
      changed.add(id);
    }
    _activeScenes[roomId] = sceneId;
    _commit(changed);
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
                'scenes': g['scenes'],
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
  void _tick() {
    var changed = false;
    _motionTick++;
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
  Future<void> zigbeeSet(String ieee, Map<String, dynamic> values) =>
      _zb.set(ieee, values);
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
  Future<ZbMeasureStart> zigbeeStartNetworkMeasure() => _zb.startMeasure();
  @override
  Stream<ZbMeasureResult> get zigbeeMeasureResults => _zb.measureResults;

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
    await _zb.dispose();
    _timer?.cancel();
    for (final t in _installs.values) {
      t.cancel();
    }
    _installs.clear();
    await super.dispose();
  }
}
