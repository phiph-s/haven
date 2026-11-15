import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/light/color_math.dart';
import '../base_repository.dart';
import '../haven_repository.dart';
import '../light_targets.dart';
import '../models/device.dart';
import '../models/entity_state.dart';
import '../models/floor_plan.dart';
import '../models/light_groups.dart';
import '../models/room.dart';
import '../models/snapshot.dart';
import '../models/zigbee.dart';
import '../models/zigbee_network.dart';
import '../scene_styles.dart';
import '../storage/settings_store.dart';
import 'ha_zigbee.dart';
import 'ha_client.dart';

/// Echte Verbindung zu Home Assistant. Räume, Szenen und Bedienelemente
/// kommen aus den `haven/*`-Befehlen der Integration (siehe
/// integration/README.md), Zustände aus `get_states` und `state_changed`.
///
/// Räume werden neu geladen, wenn sich Bereiche, Geräte oder Entities in HA
/// ändern (`*_registry_updated`) und direkt nach eigenen Schreibbefehlen
/// (Raum setzen, Umbenennen, Entfernen). Vorher lud die App sie nur beim
/// Verbinden, deshalb blieben Räume nach einer Zuordnung leer.
///
/// Getestet gegen Fake-Kanäle mit anonymisierten Antworten einer echten
/// HA-Installation (test/ha_live_fixtures_test.dart).
class HaRepository extends BaseRepository {
  HaRepository({
    required String url,
    required String token,
    HaClient? client,
    this.failFast = false,
    LocalPrefs? localPrefs,
    this.registryDebounce = const Duration(milliseconds: 400),
  }) : client = client ?? HaClient(url: url, token: token),
       _local = localPrefs ?? MemoryPrefs();

  final HaClient client;
  final bool failFast;
  final Duration registryDebounce;
  final LocalPrefs _local;
  late final HaZigbee _zb = HaZigbee(client);

  /// HA-Ereignisse, nach denen die Räume neu geladen werden.
  static const registryEvents = [
    'area_registry_updated',
    'device_registry_updated',
    'entity_registry_updated',
  ];

  final Map<String, EntityState> _entities = {};
  final Map<String, String> _activeScenes = {};
  List<Room> _rooms = const [];
  List<HavenDevice> _devices = const [];
  Set<String> _excluded = const {};
  bool _prefsShared = false;
  bool _integrationMissing = false;
  Timer? _roomsDebounce;
  Future<void>? _roomsLoading;
  bool _roomsAgain = false;
  ConnectionStatus _status = ConnectionStatus.connecting;
  bool _subscribed = false;
  Timer? _flush;
  StreamSubscription<void>? _connSub;
  StreamSubscription<ConnectionStatus>? _statusSub;

  @override
  bool get isFake => false;

  @override
  HavenFloorPlan? get sampleFloorPlan => null;

  @override
  Future<void> start() async {
    _statusSub = client.statusStream.listen((s) {
      _status = s;
      _push();
    });
    _connSub = client.onConnected.listen((_) => _load());
    publish(const HavenSnapshot());
    // Beim Start im Hintergrund: Fehler zeigt der Status, kein Wurf.
    await client.start(failFast: failFast);
  }

  Future<void> _load() async {
    try {
      final states = await client.send({'type': 'get_states'}) as List;
      _entities
        ..clear()
        ..addEntries([
          for (final s in states)
            MapEntry(
              (s as Map)['entity_id'] as String,
              EntityState.fromJson(Map<String, dynamic>.from(s)),
            ),
        ]);
      if (!_subscribed) {
        _subscribed = true;
        await client.subscribe({
          'type': 'subscribe_events',
          'event_type': 'state_changed',
        }, _onStateChanged);
        for (final t in registryEvents) {
          try {
            await client.subscribe({
              'type': 'subscribe_events',
              'event_type': t,
            }, (_) => _scheduleRooms());
          } catch (e) {
            debugPrint('Abo $t: $e');
          }
        }
      }
      await _loadPrefs();
      await _loadRooms();
      _status = ConnectionStatus.connected;
      _pushNow();
    } catch (e) {
      debugPrint('Laden fehlgeschlagen: $e');
    }
  }

  /// Viele Registry-Ereignisse kurz hintereinander (z. B. Gerät umbenannt mit
  /// zwölf Entities) ergeben ein Neuladen.
  void _scheduleRooms() {
    _roomsDebounce?.cancel();
    _roomsDebounce = Timer(registryDebounce, () => unawaited(reloadRooms()));
  }

  /// Lädt die Räume neu und veröffentlicht sie. Läuft schon ein Laden, folgt
  /// genau ein weiteres danach, damit keine Änderung verloren geht.
  Future<void> reloadRooms() async {
    if (_roomsLoading != null) {
      _roomsAgain = true;
      return _roomsLoading;
    }
    final f = () async {
      do {
        _roomsAgain = false;
        try {
          await _loadRooms();
          _pushNow();
        } catch (e) {
          debugPrint('Räume neu laden: $e');
        }
      } while (_roomsAgain && !disposed);
    }();
    _roomsLoading = f;
    try {
      await f;
    } finally {
      _roomsLoading = null;
    }
  }

  Future<void> _loadPrefs() async {
    try {
      final res = await client.send({'type': 'haven/prefs/get'}) as Map?;
      final prefs = (res?['prefs'] as Map?) ?? const {};
      _excluded = {
        for (final id in (prefs['excluded_lights'] as List? ?? const [])) '$id',
      };
      _prefsShared = true;
    } on HavenException catch (e) {
      // Integration 0.1.0 kennt den Befehl nicht: lokal weiter.
      debugPrint('haven/prefs/get: $e');
      _prefsShared = false;
      _excluded = {..._local.excludedLights};
    }
  }

  Future<void> _loadRooms() async {
    Map<String, dynamic>? roomsRes;
    try {
      roomsRes = Map<String, dynamic>.from(
        await client.send({'type': 'haven/rooms'}) as Map,
      );
      _integrationMissing = false;
    } on HavenException catch (e) {
      _integrationMissing =
          e.code == 'not_found' || e.code == 'unknown_command';
      debugPrint('haven/rooms: $e');
    }
    Map<String, dynamic>? groupsRes;
    if (roomsRes != null) {
      try {
        groupsRes = Map<String, dynamic>.from(
          await client.send({'type': 'haven/zigbee/groups'}) as Map,
        );
      } on HavenException catch (e) {
        debugPrint('haven/zigbee/groups: $e');
      }
    }
    _rooms = roomsRes == null
        ? _fallbackRooms()
        : roomsFromHaven(roomsRes, groupsRes, _entities);
    _devices = roomsRes == null ? const [] : devicesFromHaven(roomsRes);
  }

  /// Ohne Integration: ein Raum mit allen Lichtern, damit die App benutzbar bleibt.
  List<Room> _fallbackRooms() {
    final lights = [
      for (final e in _entities.values)
        if (e.domain == 'light' &&
            e.attributes['supported_color_modes'] != null &&
            !isLightGroup(e))
          e.entityId,
    ]..sort();
    return [Room(id: 'alle', name: 'Alle Lichter', lightIds: lights)];
  }

  /// Geräte aus `rooms[].devices` (ab 0.2.0) und `unassigned`.
  @visibleForTesting
  static List<HavenDevice> devicesFromHaven(Map<String, dynamic> roomsRes) => [
    for (final r in (roomsRes['rooms'] as List? ?? const []))
      for (final d in ((r as Map)['devices'] as List? ?? const []))
        HavenDevice.fromJson(
          Map<String, dynamic>.from(d as Map),
          areaId: '${r['area_id']}',
        ),
    for (final d in (roomsRes['unassigned'] as List? ?? const []))
      HavenDevice.fromJson(Map<String, dynamic>.from(d as Map)),
  ];

  /// Baut [Room]-Objekte aus den Antworten von `haven/rooms` und
  /// `haven/zigbee/groups`. Öffentlich für Tests.
  @visibleForTesting
  static List<Room> roomsFromHaven(
    Map<String, dynamic> roomsRes,
    Map<String, dynamic>? groupsRes,
    Map<String, EntityState> entities,
  ) {
    final groups = <int, Map<String, dynamic>>{
      for (final g in (groupsRes?['groups'] as List? ?? const []))
        ((g as Map)['id'] as num).toInt(): Map<String, dynamic>.from(g),
    };
    final z2mNames = {
      for (final g in groups.values)
        '${g['friendly_name']}'.trim().toLowerCase(),
    };
    // HA-Entity je Z2M-Gruppe, gefunden über den Namen (Z2M meldet Gruppen
    // als MQTT-Licht mit dem Gruppennamen, meist ohne Bereich).
    final groupEntityByName = <String, String>{};
    for (final e in entities.values) {
      if (e.domain != 'light') continue;
      final n = (e.attributes['friendly_name'] as String?)
          ?.trim()
          .toLowerCase();
      if (n != null && z2mNames.contains(n)) {
        groupEntityByName.putIfAbsent(n, () => e.entityId);
      }
    }
    final rooms = <Room>[];
    for (final r in (roomsRes['rooms'] as List)) {
      final room = Map<String, dynamic>.from(r as Map);
      final groupIds = <String>{
        for (final g in (room['light_groups'] as List? ?? const []))
          '${(g as Map)['entity_id']}',
      };
      final lights = <String>[];
      for (final l in (room['lights'] as List? ?? const [])) {
        final id = '$l';
        final e = entities[id];
        if (groupIds.contains(id) ||
            (e != null && isLightGroup(e, z2mGroupNames: z2mNames))) {
          groupIds.add(id);
        } else {
          lights.add(id);
        }
      }
      final climate = Map<String, dynamic>.from(
        room['climate'] as Map? ?? const {},
      );
      String? first(String key) {
        final l = climate[key] as List?;
        return l == null || l.isEmpty ? null : '${l.first}';
      }

      final scenes = <RoomScene>[];
      final controls = <RoomControl>[];
      final gref = room['group'] as Map?;
      final g = gref == null ? null : groups[(gref['id'] as num?)?.toInt()];
      String? groupEntity = room['group_entity'] as String?;
      if (groupEntity == null && g != null) {
        groupEntity =
            groupEntityByName['${g['friendly_name']}'.trim().toLowerCase()];
      }
      if (g != null) {
        final gslug = slugify(g['friendly_name'] as String);
        for (final s in (g['scenes'] as List? ?? const [])) {
          final name = '${s['name']}';
          final entityId = 'scene.${gslug}_${s['id']}_${slugify(name)}';
          if (!entities.containsKey(entityId)) continue;
          final style = sceneStyleFor(name);
          scenes.add(
            RoomScene(
              id: slugify(name),
              name: name,
              colors: style.colors,
              brightness: style.brightness,
              kelvin: style.kelvin,
              entityId: entityId,
            ),
          );
        }
        for (final m in (g['members'] as List? ?? const [])) {
          final type = m['device_type'];
          if (type != 'knob' && type != 'remote') continue;
          final name = '${m['friendly_name']}';
          final battery = 'sensor.${slugify(name)}_battery';
          controls.add(
            RoomControl(
              name: name,
              kind: type == 'knob' ? 'knob' : 'remote',
              batteryEntityId: entities.containsKey(battery) ? battery : null,
            ),
          );
        }
      }
      rooms.add(
        Room(
          id: '${room['area_id']}',
          areaId: '${room['area_id']}',
          name: '${room['name']}',
          lightIds: lights,
          temperatureId: first('temperature'),
          humidityId: first('humidity'),
          scenes: scenes,
          controls: controls,
          groupEntityId: groupEntity,
          lightGroupIds: groupIds.toList()..sort(),
        ),
      );
    }
    return rooms;
  }

  void _onStateChanged(dynamic event) {
    final data = (event as Map?)?['data'] as Map?;
    if (data == null) return;
    final id = data['entity_id'] as String;
    final ns = data['new_state'];
    if (ns == null) {
      _entities.remove(id);
    } else {
      _entities[id] = EntityState.fromJson(
        Map<String, dynamic>.from(ns as Map),
      );
    }
    _push();
  }

  /// Bündelt viele Ereignisse zu einem Snapshot pro 60 ms.
  void _push() {
    if (_flush?.isActive ?? false) return;
    _flush = Timer(const Duration(milliseconds: 60), _pushNow);
  }

  void _pushNow() {
    _flush?.cancel();
    publish(
      snapshot.copyWith(
        status: _status,
        entities: Map.unmodifiable(Map.of(_entities)),
        rooms: _rooms,
        integrationMissing: _integrationMissing,
        activeScenes: Map.unmodifiable(Map.of(_activeScenes)),
        excludedLights: Set.unmodifiable(_excluded),
        devices: _devices,
      ),
    );
  }

  // ---- Aktionen -------------------------------------------------------

  final Map<String, DateTime> _lastSent = {};
  final Map<String, Timer> _timers = {};

  /// Sendet höchstens alle 120 ms pro Ziel, der letzte Wert gewinnt.
  void _throttled(String key, Future<void> Function() send) {
    final now = DateTime.now();
    final last = _lastSent[key];
    const gap = Duration(milliseconds: 120);
    void fire() {
      _lastSent[key] = DateTime.now();
      send().catchError((Object e) {
        debugPrint('Dienstaufruf fehlgeschlagen: $e');
        unawaited(_resync());
      });
    }

    _timers.remove(key)?.cancel();
    if (last == null || now.difference(last) >= gap) {
      fire();
    } else {
      _timers[key] = Timer(gap - now.difference(last), fire);
    }
  }

  Future<void> _resync() async {
    try {
      await _load();
    } catch (_) {}
  }

  void _patchLights(
    List<String> ids, {
    bool? on,
    int? brightness,
    Rgb? rgb,
    int? kelvin,
  }) {
    for (final id in ids) {
      final e = _entities[id];
      if (e == null) continue;
      final a = Map<String, dynamic>.from(e.attributes);
      var isOn = e.isOn;
      if (on != null) isOn = on;
      if (brightness != null) {
        isOn = brightness > 0;
        if (brightness > 0) {
          a['brightness'] = (brightness * 2.55).round().clamp(1, 255);
        }
      }
      if (rgb != null) {
        a['rgb_color'] = [rgb.$1, rgb.$2, rgb.$3];
        a.remove('color_temp_kelvin');
        isOn = on ?? true;
      }
      if (kelvin != null) {
        a['color_temp_kelvin'] = kelvin;
        final k = kelvinToRgb(kelvin);
        a['rgb_color'] = [k.$1, k.$2, k.$3];
        isOn = on ?? true;
      }
      if (isOn && a['brightness'] == null) a['brightness'] = 255;
      _entities[id] = e.copyWith(state: isOn ? 'on' : 'off', attributes: a);
    }
  }

  Room? _room(String id) => snapshot.room(id);

  @override
  Future<void> setLights(
    List<String> entityIds, {
    bool? on,
    int? brightness,
    Rgb? rgb,
    int? kelvin,
  }) async {
    if (entityIds.isEmpty) return;
    for (final r in _rooms) {
      if (r.lightIds.any(entityIds.contains)) _activeScenes.remove(r.id);
    }
    _patchLights(
      entityIds,
      on: on,
      brightness: brightness,
      rgb: rgb,
      kelvin: kelvin,
    );
    _pushNow();
    final off = on == false || brightness == 0;
    final targets = lightCallTargets(
      entityIds,
      _rooms,
      _entities,
      excluded: _excluded,
    );
    final key = '${off ? 'off' : 'on'}:${entityIds.join(',')}';
    _throttled(key, () async {
      if (off) {
        await client.send({
          'type': 'call_service',
          'domain': 'light',
          'service': 'turn_off',
          'target': {'entity_id': targets},
        });
        return;
      }
      final data = <String, dynamic>{
        'brightness_pct': ?brightness,
        if (rgb != null) 'rgb_color': [rgb.$1, rgb.$2, rgb.$3],
        'color_temp_kelvin': ?kelvin,
      };
      await client.send({
        'type': 'call_service',
        'domain': 'light',
        'service': 'turn_on',
        'service_data': data,
        'target': {'entity_id': targets},
      });
    });
  }

  /// Gesteuerte Lampen des Raums (ohne Gruppen und Ausnahmen).
  List<String> _controlled(Room r) => [
    for (final id in r.lightIds)
      if (!_excluded.contains(id) &&
          _entities[id] != null &&
          !isLightGroup(_entities[id]!))
        id,
  ];

  List<String> _lightsOn(Room r) => [
    for (final id in _controlled(r))
      if (_entities[id]?.isOn == true) id,
  ];

  @override
  Future<void> toggleRoom(String roomId) async {
    final r = _room(roomId);
    if (r == null) return;
    final on = _lightsOn(r);
    await setLights(on.isNotEmpty ? on : _controlled(r), on: on.isEmpty);
  }

  @override
  Future<void> setRoomBrightness(String roomId, int brightness) async {
    final r = _room(roomId);
    if (r == null) return;
    final on = _lightsOn(r);
    if (brightness <= 0) return setLights(_controlled(r), on: false);
    await setLights(
      on.isNotEmpty ? on : _controlled(r),
      brightness: brightness,
    );
  }

  @override
  Future<void> applyScene(String roomId, String sceneId) async {
    final r = _room(roomId);
    final scene = r?.scenes.where((s) => s.id == sceneId).firstOrNull;
    if (r == null || scene?.entityId == null) return;
    _activeScenes[roomId] = sceneId;
    _pushNow();
    await client.send({
      'type': 'call_service',
      'domain': 'scene',
      'service': 'turn_on',
      'target': {'entity_id': scene!.entityId},
    });
  }

  @override
  Future<void> allLightsOff() =>
      setLights([for (final r in _rooms) ..._controlled(r)], on: false);

  @override
  bool get prefsShared => _prefsShared;

  @override
  Future<void> setLightExcluded(String entityId, bool excluded) async {
    final before = _excluded;
    final next = {..._excluded};
    excluded ? next.add(entityId) : next.remove(entityId);
    _excluded = next;
    _pushNow();
    try {
      if (_prefsShared) {
        await client.send({
          'type': 'haven/prefs/set',
          'prefs': {'excluded_lights': next.toList()..sort()},
        });
      } else {
        await _local.setExcludedLights(next);
      }
    } catch (e) {
      _excluded = before;
      _pushNow();
      rethrow;
    }
  }

  @override
  Future<void> refresh() async {
    if (!client.isConnected) return;
    await _load();
  }

  @override
  Future<void> callService(
    String domain,
    String service, {
    String? entityId,
    Map<String, dynamic> data = const {},
  }) async {
    await client.send({
      'type': 'call_service',
      'domain': domain,
      'service': service,
      if (data.isNotEmpty) 'service_data': data,
      if (entityId != null) 'target': {'entity_id': entityId},
    });
  }

  @override
  Future<dynamic> command(
    String type, [
    Map<String, dynamic> payload = const {},
  ]) => client.send({'type': type, ...payload});

  // ---- Zigbee (Lesen: Vertrag der Integration, Schreiben: TODO) -----------
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
  }) async {
    await _zb.rename(ieee, name, renameHaEntities);
    await reloadRooms();
  }

  @override
  Future<void> zigbeeSetArea(String ieee, String? areaId) async {
    await _zb.setArea(ieee, areaId);
    await reloadRooms();
  }

  @override
  Future<void> zigbeeIdentify(String ieee) => _zb.identify(ieee);
  @override
  Future<void> zigbeeInterview(String ieee) => _zb.interview(ieee);
  @override
  Future<void> zigbeeRemove(String ieee, {bool force = false}) async {
    await _zb.remove(ieee, force);
    await reloadRooms();
  }

  @override
  Future<void> zigbeePermitJoin({int seconds = 240, String? viaIeee}) =>
      _zb.permitJoin(seconds, viaIeee);
  @override
  Future<void> zigbeeStopJoin() => _zb.permitJoin(0, null);
  @override
  Future<ZbNetworkMap> zigbeeNetworkMap({bool refresh = false}) =>
      _zb.networkMap(refresh);

  @override
  Future<void> dispose() async {
    await _zb.dispose();
    _flush?.cancel();
    _roomsDebounce?.cancel();
    for (final t in _timers.values) {
      t.cancel();
    }
    await _connSub?.cancel();
    await _statusSub?.cancel();
    await client.close();
    await super.dispose();
  }
}
