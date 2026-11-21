import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/light/color_math.dart';
import '../base_repository.dart';
import '../haven_repository.dart';
import '../render_api.dart';
import '../light_targets.dart';
import '../models/device.dart';
import '../models/entity_state.dart';
import '../models/floor_plan.dart';
import '../models/haven_automation.dart';
import '../models/room_heating.dart';
import '../models/scene_check.dart';
import '../models/lamp.dart';
import '../models/lamp_calibration.dart';
import '../models/light_groups.dart';
import '../models/room.dart';
import '../models/snapshot.dart';
import '../models/state_history.dart';
import '../models/zigbee.dart';
import '../models/zigbee_network.dart';
import '../scene_look.dart';
import '../scene_styles.dart';
import '../storage/settings_store.dart';
import '../sync/app_data.dart';
import 'ha_automations.dart';
import 'ha_heating.dart';
import 'ha_render.dart';
import 'ha_zigbee.dart';
import 'ha_client.dart';
import '../models/weather.dart';

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
    Future<String> Function()? tokenProvider,
  }) : client =
           client ??
           HaClient(url: url, token: token, tokenProvider: tokenProvider),
       _local = localPrefs ?? MemoryPrefs();

  final HaClient client;
  final bool failFast;
  final Duration registryDebounce;
  final LocalPrefs _local;
  late final HaZigbee _zb = HaZigbee(client);
  late final HaAutomations _auto = HaAutomations(client);
  late final HaHeating _heat = HaHeating(client);
  late final HaRender _render = HaRender(client);

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
  Set<String> _locked = const {};
  WeatherConfig _weather = const WeatherConfig();
  LampCalibrations _calibration = LampCalibrations.empty;

  /// Schlüssel in `haven/prefs`, die diese App nicht kennt (neuere Fassung
  /// auf einem anderen Gerät): bleiben beim Speichern erhalten.
  Map<String, dynamic> _prefsExtra = const {};
  Map<String, LampModel> _lampModels = const {};
  List<ZbDevice> _zbLamps = const [];
  bool _prefsShared = false;

  /// Revision der Prefs in HA (Feature `revisions`), siehe [_changePrefs].
  int? _prefsRevision;
  bool _integrationMissing = false;
  Timer? _roomsDebounce;
  Future<void>? _roomsLoading;
  bool _roomsAgain = false;
  ConnectionStatus _status = ConnectionStatus.connecting;
  bool _subscribed = false;

  /// `features` aus `haven/info` (z. B. `data_events` ab 0.3.0).
  Set<String> _features = const {};
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
        try {
          await client.subscribe({
            'type': 'subscribe_events',
            'event_type': dataUpdatedEvent,
          }, _onDataUpdated);
        } catch (e) {
          // Ohne Admin erlaubt HA nur bestimmte Ereignisse: Dann gleicht
          // die App nur beim Verbinden und Aktualisieren ab.
          debugPrint('Abo $dataUpdatedEvent: $e');
        }
        try {
          await client.subscribe({
            'type': 'subscribe_events',
            'event_type': networkMapEvent,
          }, _onNetworkMapUpdated);
        } catch (e) {
          // Ohne Abo fragt die App alle 15 s nach.
          debugPrint('Abo $networkMapEvent: $e');
        }
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
      await _loadInfo();
      await _loadPrefs();
      await _loadRooms();
      _status = ConnectionStatus.connected;
      _pushNow();
      // Nach jedem Verbinden: geteilte Dokumente abgleichen.
      emitAppData(AppDataKind.floorplan);
      emitAppData(AppDataKind.widgets);
      _auto.notifyChanged();
      _heat.notifyChanged();
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

  /// HA-Ereignis der Integration nach jedem `set` (ab 0.3.0).
  static const dataUpdatedEvent = 'haven_data_updated';

  /// Ende einer Hintergrund-Netzmessung (ab Integration 0.5.1).
  static const networkMapEvent = 'haven_networkmap_updated';

  final _measureResults = StreamController<ZbMeasureResult>.broadcast();

  void _onNetworkMapUpdated(dynamic event) {
    final data = (event as Map?)?['data'];
    if (data is Map && !_measureResults.isClosed) {
      _measureResults.add(
        ZbMeasureResult.fromJson(Map<String, dynamic>.from(data)),
      );
    }
  }

  void _onDataUpdated(dynamic event) {
    final data = (event as Map?)?['data'] as Map?;
    if (data?['kind'] == 'automations') return _auto.notifyChanged();
    if (data?['kind'] == 'heating') return _heat.notifyChanged();
    if (data?['kind'] == 'render') return _renderCtrl.add(null);
    final kind = AppDataKind.parse(data?['kind']);
    if (kind == null) return;
    if (kind == AppDataKind.prefs) {
      unawaited(
        _loadPrefs().then((_) {
          if (!disposed) _pushNow();
        }),
      );
    }
    emitAppData(kind);
  }

  Future<void> _loadInfo() async {
    try {
      final r = await client.send({'type': 'haven/info'}) as Map?;
      _features = {for (final f in (r?['features'] as List? ?? const [])) '$f'};
    } on HavenException catch (e) {
      debugPrint('haven/info: $e');
    }
  }

  /// Integration speichert `updated_at` und `layout` (ab 0.3.0). Ältere
  /// lehnen unbekannte Felder ab.
  bool get _v3 => _features.contains('data_events');

  /// Revisionen und `base_revision` (siehe `sync/app_data.dart`).
  @override
  bool get appDataRevisions => _features.contains('revisions');

  @override
  Future<Map<String, List<StateChange>>> stateHistory(
    List<String> entityIds,
    DateTime start,
  ) async {
    if (entityIds.isEmpty) return const {};
    try {
      final r = await client.send({
        'type': 'history/history_during_period',
        'start_time': start.toUtc().toIso8601String(),
        'entity_ids': entityIds,
        'minimal_response': true,
        'no_attributes': true,
        'significant_changes_only': false,
      });
      return parseStateHistory(r);
    } catch (e) {
      debugPrint('history: $e');
      return const {};
    }
  }

  @override
  Future<RemoteDoc> fetchAppData(AppDataKind kind) async {
    switch (kind) {
      case AppDataKind.floorplan:
        final r = await client.send({'type': 'haven/floorplan/get'}) as Map?;
        final plan = r?['plan'];
        if (plan is! Map) return RemoteDoc.empty;
        return RemoteDoc(
          data: {'plan': Map<String, dynamic>.from(plan)},
          updatedAt:
              parseStamp(r?['updated_at']) ?? parseStamp(plan['updatedAt']),
          revision: parseRevision(r?['revision']),
        );
      case AppDataKind.widgets:
        final r = await client.send({'type': 'haven/widgets/get'}) as Map?;
        final w = r?['widgets'];
        if (w is! List) return RemoteDoc.empty;
        final layout = r?['layout'];
        return RemoteDoc(
          data: {
            'widgets': w,
            'layout': layout is Map ? Map<String, dynamic>.from(layout) : null,
          },
          updatedAt: parseStamp(r?['updated_at']),
          revision: parseRevision(r?['revision']),
        );
      case AppDataKind.prefs:
        final r = await client.send({'type': 'haven/prefs/get'}) as Map?;
        final p = r?['prefs'];
        return RemoteDoc(
          data: p is Map ? Map<String, dynamic>.from(p) : null,
          updatedAt: p is Map ? parseStamp(p['updatedAt']) : null,
          revision: parseRevision(r?['revision']),
        );
    }
  }

  @override
  Future<int?> storeAppData(
    AppDataKind kind,
    Map<String, dynamic> data,
    int updatedAt, {
    int? baseRevision,
  }) async {
    final base = appDataRevisions && baseRevision != null
        ? {'base_revision': baseRevision}
        : const <String, dynamic>{};
    final Object? r;
    switch (kind) {
      case AppDataKind.floorplan:
        r = await client.send({
          'type': 'haven/floorplan/set',
          // Der Stempel steht auch im Dokument, das speichert jede Version.
          'plan': {...data['plan'] as Map, 'updatedAt': updatedAt},
          if (_v3) 'updated_at': updatedAt,
          ...base,
        });
      case AppDataKind.widgets:
        r = await client.send({
          'type': 'haven/widgets/set',
          'widgets': data['widgets'],
          if (_v3) 'layout': data['layout'],
          if (_v3) 'updated_at': updatedAt,
          ...base,
        });
      case AppDataKind.prefs:
        r = await client.send({
          'type': 'haven/prefs/set',
          'prefs': data,
          ...base,
        });
    }
    return r is Map ? parseRevision(r['revision']) : null;
  }

  /// Ob die Integration das Layout (Reihenfolge der Räume) speichern kann.
  bool get storesLayout => _v3;

  Future<void> _loadPrefs() async {
    try {
      final res = await client.send({'type': 'haven/prefs/get'}) as Map?;
      final prefs = (res?['prefs'] as Map?) ?? const {};
      _prefsRevision = parseRevision(res?['revision']);
      _excluded = {
        for (final id in (prefs['excluded_lights'] as List? ?? const [])) '$id',
      };
      _locked = {
        for (final id in (prefs['locked'] as List? ?? const [])) '$id',
      };
      _weather = WeatherConfig.fromJson(prefs['weather']);
      _calibration = LampCalibrations.fromJson(prefs['lamp_calibration']);
      _prefsExtra = {
        for (final e in prefs.entries)
          if (!_knownPrefs.contains(e.key)) '${e.key}': e.value,
      };
      _prefsShared = true;
    } on HavenException catch (e) {
      // Integration 0.1.0 kennt den Befehl nicht: lokal weiter.
      debugPrint('haven/prefs/get: $e');
      _prefsShared = false;
      _excluded = {..._local.excludedLights};
      _locked = {..._local.lockedIds};
      _weather = WeatherConfig.fromJson(_local.weatherConfig);
      _calibration = LampCalibrations.fromJson(_local.lampCalibration);
    }
  }

  static const _knownPrefs = {
    'excluded_lights',
    'locked',
    'weather',
    'lamp_calibration',
  };

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
        : roomsFromHaven(
            roomsRes,
            groupsRes,
            _entities,
            sceneCommands: _features.contains('scenes'),
          );
    _devices = roomsRes == null ? const [] : devicesFromHaven(roomsRes);
    _lampModels = lampModelsOf(devices: _devices, zigbee: _zbLamps);
    if (roomsRes != null) unawaited(_loadZigbeeLampModels());
  }

  /// Zigbee-Modelle der Lampen (genauer als das HA-Register). Läuft im
  /// Hintergrund, ohne Zigbee2MQTT bleibt es beim HA-Register.
  Future<void> _loadZigbeeLampModels() async {
    try {
      final all = await _zb.devices();
      if (disposed) return;
      _zbLamps = [
        for (final d in all)
          if (d.haEntities.any((id) => id.startsWith('light.'))) d,
      ];
      final next = lampModelsOf(devices: _devices, zigbee: _zbLamps);
      if (mapEquals(next, _lampModels)) return;
      _lampModels = next;
      _pushNow();
    } catch (e) {
      debugPrint('Lampenmodelle aus Zigbee2MQTT: $e');
    }
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
    Map<String, EntityState> entities, {
    bool sceneCommands = false,
  }) {
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
        final groupId = (g['id'] as num?)?.toInt();
        for (final s in (g['scenes'] as List? ?? const [])) {
          final name = '${s['name']}';
          final number = (s['id'] as num?)?.toInt();
          final entityId = 'scene.${gslug}_${s['id']}_${slugify(name)}';
          // Mit `scenes` ruft die Integration die Szene auf, die HA-Entity
          // braucht es nicht (sie fehlt kurz nach dem Anlegen und behält nach
          // dem Umbenennen ihre alte ID).
          final hasEntity = entities.containsKey(entityId);
          if (!hasEntity && !(sceneCommands && number != null)) continue;
          final look = SceneLook.fromJson(s['look']);
          final style = sceneStyleFor(name);
          scenes.add(
            RoomScene(
              id: slugify(name),
              name: name,
              colors: look?.cardColors ?? style.colors,
              brightness: look?.brightness ?? style.brightness,
              kelvin: look == null ? style.kelvin : look.kelvin,
              entityId: hasEntity ? entityId : null,
              groupId: sceneCommands ? groupId : null,
              number: sceneCommands ? number : null,
              stored: look != null,
              sync: SceneSync.parse(s['sync']),
              checkedAt: DateTime.tryParse('${s['checked_at'] ?? ''}'),
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
          zigbeeGroupId: (g?['id'] as num?)?.toInt(),
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
        locked: Set.unmodifiable(_locked),
        weather: _weather,
        devices: _devices,
        lampModels: Map.unmodifiable(_lampModels),
        lampCalibration: _calibration,
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
    // Gesperrte Lampen („immer an“) schaltet Haven nicht.
    entityIds = [
      for (final id in entityIds)
        if (!_locked.contains(id)) id,
    ];
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
      // Gruppen mit gesperrten Lampen nicht nehmen: einzeln schalten.
      excluded: {..._excluded, ..._locked},
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
    if (r == null || scene == null) return;
    if (!scene.editable && scene.entityId == null) return;
    _activeScenes[roomId] = sceneId;
    _pushNow();
    if (scene.editable) {
      await client.send({
        'type': 'haven/zigbee/scene_recall',
        'group_id': scene.groupId,
        'scene_id': scene.number,
      });
      return;
    }
    await client.send({
      'type': 'call_service',
      'domain': 'scene',
      'service': 'turn_on',
      'target': {'entity_id': scene.entityId},
    });
  }

  @override
  bool canEditScenes(String roomId) =>
      _features.contains('scenes') && _room(roomId)?.zigbeeGroupId != null;

  /// Alle Lampen der Raumgruppe, auch ausgenommene: Z2M speichert die Szene
  /// für jedes Mitglied.
  List<Lamp> _sceneLamps(Room r) => [
    for (final id in r.lightIds)
      if (_entities[id] != null) Lamp.fromEntity(_entities[id]!),
  ];

  @override
  Future<int> storeScene(String roomId, {String? name, int? number}) async {
    final r = _room(roomId);
    if (r?.zigbeeGroupId == null) {
      throw HavenException(
        'Dieser Raum hat keine Zigbee-Gruppe',
        code: 'not_found',
      );
    }
    final res = await client.send({
      'type': 'haven/zigbee/scene_store',
      'group_id': r!.zigbeeGroupId,
      'scene_id': ?number,
      'name': ?name,
      'look': sceneLookOf(_sceneLamps(r)).toJson(),
    }) as Map;
    final stored = (res['scene_id'] as num).toInt();
    await reloadRooms();
    final scene = _room(roomId)?.scenes
        .where((s) => s.number == stored)
        .firstOrNull;
    if (scene != null) {
      _activeScenes[roomId] = scene.id;
      _pushNow();
    }
    return stored;
  }

  @override
  Future<void> renameScene(String roomId, int number, String name) async {
    final r = _room(roomId);
    await client.send({
      'type': 'haven/zigbee/scene_rename',
      'group_id': r?.zigbeeGroupId,
      'scene_id': number,
      'name': name,
    });
    await reloadRooms();
  }

  @override
  Future<void> removeScene(String roomId, int number) async {
    final r = _room(roomId);
    await client.send({
      'type': 'haven/zigbee/scene_remove',
      'group_id': r?.zigbeeGroupId,
      'scene_id': number,
    });
    _activeScenes.remove(roomId);
    await reloadRooms();
  }

  // ---- Szenen-Abgleich (Feature `scene_sync`) --------------------------------

  @override
  bool get canSyncScenes => _features.contains('scene_sync');

  /// Messen und Abgleichen schalten Lampen und warten auf sie: mehr Zeit als
  /// die übliche Frist.
  static const _syncTimeout = Duration(seconds: 90);

  Map<String, dynamic> _sceneRef(String roomId, int number) {
    final gid = _room(roomId)?.zigbeeGroupId;
    if (gid == null) {
      throw HavenException(
        'Dieser Raum hat keine Zigbee-Gruppe',
        code: 'not_found',
      );
    }
    return {'group_id': gid, 'scene_id': number};
  }

  Future<SceneCheck> _sceneCheckCommand(
    String type,
    String roomId,
    int number,
  ) async {
    final res = await client.send({
      'type': type,
      ..._sceneRef(roomId, number),
    }, timeout: _syncTimeout);
    // Der Stand des Abgleichs steht in der Gruppenliste.
    await reloadRooms();
    return SceneCheck.fromJson(Map<String, dynamic>.from(res as Map));
  }

  @override
  Future<SceneCheck> checkScene(String roomId, int number) =>
      _sceneCheckCommand('haven/zigbee/scene_check', roomId, number);

  @override
  Future<void> adoptScene(String roomId, int number) async {
    await client.send({
      'type': 'haven/zigbee/scene_adopt',
      ..._sceneRef(roomId, number),
    }, timeout: _syncTimeout);
    await reloadRooms();
  }

  @override
  Future<SceneCheck> repairScene(String roomId, int number) =>
      _sceneCheckCommand('haven/zigbee/scene_repair', roomId, number);

  @override
  Future<void> allLightsOff() =>
      setLights([for (final r in _rooms) ..._controlled(r)], on: false);

  @override
  bool get prefsShared => _prefsShared;

  @override
  Future<void> setLightExcluded(String entityId, bool excluded) =>
      _changePrefs(() {
        final next = {..._excluded};
        excluded ? next.add(entityId) : next.remove(entityId);
        _excluded = next;
      }, local: () => _local.setExcludedLights(_excluded));

  @override
  Future<void> setLampCalibration(LampCalibrations calibration) => _changePrefs(
    () => _calibration = calibration,
    local: () => _local.setLampCalibration(calibration.toJson()),
  );

  @override
  Future<void> setWeatherConfig(WeatherConfig config) => _changePrefs(
    () => _weather = config,
    local: () => _local.setWeatherConfig(config.toJson()),
  );

  @override
  Future<void> setLocked(Iterable<String> ids, bool locked) {
    final list = [...ids];
    return _changePrefs(() {
      final next = {..._locked};
      locked ? next.addAll(list) : next.removeAll(list);
      _locked = next;
    }, local: () => _local.setLockedIds(_locked));
  }

  /// Ändert die Prefs mit [apply] (sofort sichtbar) und speichert sie in HA,
  /// ohne geteilte Prefs nur lokal ([local]).
  ///
  /// `haven/prefs/set` ersetzt das ganze Dokument. Damit ein Gerät mit
  /// altem Stand nicht die Änderung eines anderen überschreibt, geht die
  /// Revision mit (`base_revision`, Feature `revisions`). Lehnt HA mit
  /// `conflict` ab, lädt die App die Prefs neu und wendet [apply] erneut an.
  Future<void> _changePrefs(
    void Function() apply, {
    required Future<void> Function() local,
  }) async {
    final before = (_excluded, _locked, _weather, _calibration);
    apply();
    _pushNow();
    try {
      if (!_prefsShared) return await local();
      for (var attempt = 0; ; attempt++) {
        try {
          await _sendPrefs();
          return;
        } on HavenException catch (e) {
          if (!isConflictError(e) || attempt >= 2) rethrow;
          await _loadPrefs();
          apply();
          _pushNow();
        }
      }
    } catch (e) {
      _excluded = before.$1;
      _locked = before.$2;
      _weather = before.$3;
      _calibration = before.$4;
      _pushNow();
      rethrow;
    }
  }

  /// Ausnahmen und Sperren zusammen: `haven/prefs/set` ersetzt das Dokument.
  Future<void> _sendPrefs() async {
    final res = await client.send({
      'type': 'haven/prefs/set',
      'prefs': {
        ..._prefsExtra,
        'excluded_lights': _excluded.toList()..sort(),
        'locked': _locked.toList()..sort(),
        if (!_weather.isEmpty) 'weather': _weather.toJson(),
        if (!_calibration.isEmpty) 'lamp_calibration': _calibration.toJson(),
      },
      if (appDataRevisions && _prefsRevision != null)
        'base_revision': _prefsRevision,
    });
    if (res is Map) _prefsRevision = parseRevision(res['revision']);
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
    if (const {'turn_off', 'turn_on', 'toggle'}.contains(service)) {
      checkLocked(entityId);
    }
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
  Future<void> zigbeeSet(String ieee, Map<String, dynamic> values) async {
    if (BaseRepository.controlsDevice(values)) checkLocked(ieee);
    await _zb.set(ieee, values);
  }

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
  bool get zigbeeGhostDetection => _features.contains('ghost_detection');

  @override
  Future<bool> zigbeeEnableLastSeen() => _zb.enableLastSeen();

  @override
  bool get zigbeeBackgroundMeasure =>
      _features.contains('networkmap_background');

  @override
  Future<ZbMeasureStart> zigbeeStartNetworkMeasure() => _zb.startMeasure();

  @override
  Stream<ZbMeasureResult> get zigbeeMeasureResults => _measureResults.stream;

  // ---- Bilder der Wohnung (haven/render/*) ---------------------------------
  /// Zurück im Vordergrund: Verbindung prüfen. Steht sie noch, gleichen die
  /// geteilten Dokumente trotzdem ab, im Hintergrund können Ereignisse
  /// anderer Geräte gefehlt haben (Android hält die App an).
  @override
  void nudgeConnection() {
    client.nudge();
    if (client.isConnected && _status == ConnectionStatus.connected) {
      emitAppData(AppDataKind.floorplan);
      emitAppData(AppDataKind.widgets);
      unawaited(
        _loadPrefs().then((_) {
          if (!disposed) _pushNow();
        }),
      );
    }
  }

  @override
  Future<RenderStatus?> renderStatus() async {
    // Der Client meldet „verbunden“ schon vor `haven/info` (siehe _load):
    // dann die Fähigkeiten hier holen, sonst gäbe es „keine Bilder“.
    if (_features.isEmpty) await _loadInfo();
    if (!_features.contains('render')) return null;
    return _render.status(files: _features.contains('render_files'));
  }

  @override
  Future<Uint8List> renderFile(String set, String name) {
    if (!_features.contains('render_files')) {
      throw HavenException(
        'Home Assistant kann die Bilder noch nicht zurückgeben',
        code: 'not_supported',
      );
    }
    return _render.file(set, name);
  }

  final _renderCtrl = StreamController<void>.broadcast();

  @override
  Stream<void> get renderChanges => _renderCtrl.stream;

  @override
  Future<void> uploadRenders(
    String key,
    List<RenderFile> files, {
    void Function(int sent, int total)? onProgress,
    bool Function()? cancelled,
  }) =>
      _render.upload(key, files, onProgress: onProgress, cancelled: cancelled);

  // ---- Heizungsregelung (haven/heating/*) ----------------------------------
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

  // ---- Haven-Automationen (haven/automations/*) ---------------------------
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

  @override
  Future<void> dispose() async {
    await _zb.dispose();
    await _measureResults.close();
    await _auto.dispose();
    await _heat.dispose();
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
