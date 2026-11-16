import 'dart:async';
import 'dart:ui' show Offset;

import '../data/haven_repository.dart';
import '../data/models/floor_plan.dart';
import '../data/models/zigbee.dart';
import '../data/models/zigbee_network.dart';
import 'fake_floor_plan.dart';
import 'fake_rooms.dart';

/// Zigbee in den Entwicklungsdaten: Geräte aus `kFakeZigbee`, Einstellungen im
/// Speicher, Anlernen simuliert. Alle Schreibbefehle wirken nur lokal.
class FakeZigbee {
  FakeZigbee({
    required Map<String, dynamic> inventory,
    required Map<String, dynamic> zigbee,
    this.joinDelay = const Duration(seconds: 5),
  }) {
    final rooms = FakeRooms(inventory);
    final raw = (zigbee['devices'] as List).cast<Map<String, dynamic>>();
    for (final d in (inventory['z2m_devices'] as List)) {
      final ents = (d['entities'] as Map?)?.keys.cast<String>().toList() ?? [];
      ents.sort((a, b) {
        int rank(String x) => x.startsWith('light.')
            ? 0
            : x.startsWith('switch.')
            ? 1
            : 2;
        return rank(a).compareTo(rank(b));
      });
      _entityIds['${d['friendly_name']}'] = ents;
    }
    for (final j in raw) {
      var d = ZbDevice.fromJson({
        ...j,
        'area_id': rooms.roomOfDevice(j['friendly_name'] as String),
      });
      _devices.add(d);
      _states[d.ieee] = _initialState(d);
    }
    // Das Funkbild bestimmt das Signal der Geräte (Liste und Netzkarte stimmen
    // so überein).
    final map = _buildMap();
    for (final d in _devices) {
      final q = map.lqiToParent(d.ieee);
      if (q != null) _states[d.ieee]!['linkquality'] = q;
    }
    _groups = [
      for (final g in (inventory['z2m_groups'] as List))
        ZbGroup(
          id: g['id'] as int,
          friendlyName: g['name'] as String,
          memberIeees: [
            for (final m in (g['members'] as List))
              for (final d in _devices)
                if (d.friendlyName == m) d.ieee,
          ],
        ),
    ];
  }

  /// Zeit bis ein simuliertes Gerät „gefunden“ wird.
  final Duration joinDelay;

  final List<ZbDevice> _devices = [];
  final Map<String, List<String>> _entityIds = {};
  DateTime _measuredAt = DateTime.now().subtract(const Duration(minutes: 14));
  late List<ZbGroup> _groups;
  final Map<String, Map<String, dynamic>> _states = {};
  final _events = StreamController<ZbEvent>.broadcast();
  final _measureResults = StreamController<ZbMeasureResult>.broadcast();
  bool _measuring = false;
  DateTime? _measureStarted;
  final List<Timer> _timers = [];
  bool _permit = false;

  Stream<ZbEvent> get events => _events.stream;

  /// Geräte, die sich lange nicht gemeldet haben (Geister-Erkennung).
  static const kFakeSilent = {
    'Lampe Ruhebett': Duration(days: 180),
    'Sensor Ruheraum': Duration(days: 5),
  };

  static const _weak = {'Lüfter Waschraum': 58, 'Sensor Terrasse': 71};

  Map<String, dynamic> _initialState(ZbDevice d) {
    final h = d.ieee.codeUnits.fold<int>(7, (a, c) => (a * 31 + c) & 0xffff);
    final s = <String, dynamic>{
      'linkquality': _weak[d.friendlyName] ?? 96 + h % 150,
      'last_seen': DateTime.now()
          .subtract(Duration(minutes: 1 + h % 40))
          .toIso8601String(),
    };
    // Geister: eine Netzlampe seit 180 Tagen still, ein Batteriemelder seit 5.
    final quiet = kFakeSilent[d.friendlyName];
    if (quiet != null) {
      s['last_seen'] = DateTime.now().subtract(quiet).toIso8601String();
    }
    if (d.friendlyName == 'Sensor Terrasse') s['battery'] = 18;
    if (d.friendlyName == 'Kontaktsensor Schrank') {
      s['availability'] = 'offline';
    }
    switch (d.deviceType) {
      case ZbType.knob:
        s['action'] = 'rotate_right';
      case ZbType.remote:
        s['action'] = 'single';
    }
    for (final f in d.classified.settings) {
      if (f.property == 'identify') continue;
      s[f.property] = switch (f.type) {
        'enum' => f.values.isEmpty ? null : f.values.first.value,
        'binary' => f.binaryValue(false),
        'numeric' => f.min ?? 0,
        _ => null,
      };
    }
    // Plausible Voreinstellungen.
    if (s.containsKey('sensitivity')) {
      s['sensitivity'] = d.deviceType == ZbType.motion
          ? 'high'
          : s['sensitivity'];
    }
    if (s.containsKey('illuminance_interval')) s['illuminance_interval'] = 60;
    if (s.containsKey('keep_time')) s['keep_time'] = '10';
    if (s.containsKey('power_outage_memory')) {
      s['power_outage_memory'] = 'restore';
    }
    if (s.containsKey('power_on_behavior')) s['power_on_behavior'] = 'previous';
    return s;
  }

  Future<List<ZbDevice>> devices() async => List.unmodifiable(_devices);

  Future<ZbDevice> device(String ieee) async => _devices.firstWhere(
    (d) => d.ieee == ieee,
    orElse: () =>
        throw HavenException('Gerät nicht gefunden.', code: 'not_found'),
  );

  Future<List<ZbGroup>> groups() async => _groups;

  Future<bool> enableLastSeen() async {
    _lastSeenEnabled = true;
    return false;
  }

  bool _lastSeenEnabled = true;

  Future<ZbBridgeInfo> info() async => ZbBridgeInfo(
    lastSeenEnabled: _lastSeenEnabled,
    availabilityEnabled: false,
    version: '2.14.3',
    channel: 25,
    coordinatorType: 'ZStack3x0',
    permitJoin: _permit,
    deviceCount: _devices.length,
  );

  ZbNetworkMap _buildMap() => buildFakeNetworkMap(
    _devices,
    entityIds: {
      for (final d in _devices) d.ieee: _entityIds[d.friendlyName] ?? const [],
    },
    measuredAt: _measuredAt,
  );

  /// Die Topologie ist fest. Neu messen dauert kurz und setzt nur den
  /// Zeitstempel.
  Future<ZbNetworkMap> networkMap({bool refresh = false}) async {
    if (refresh) {
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      _measuredAt = DateTime.now();
    }
    return _buildMap();
  }

  Stream<ZbMeasureResult> get measureResults => _measureResults.stream;

  /// Wie die Integration ab 0.5.1: sofortige Antwort, Ergebnis später.
  Future<ZbMeasureStart> startMeasure() async {
    if (_measuring) {
      return ZbMeasureStart(alreadyRunning: true, startedAt: _measureStarted);
    }
    _measuring = true;
    _measureStarted = DateTime.now();
    Future<void>.delayed(const Duration(milliseconds: 1600), () {
      _measuring = false;
      _measuredAt = DateTime.now();
      if (!_measureResults.isClosed) {
        _measureResults.add(const ZbMeasureResult(ok: true));
      }
    });
    return ZbMeasureStart(alreadyRunning: false, startedAt: _measureStarted);
  }

  Future<Map<String, Map<String, dynamic>>> states() async => {
    for (final e in _states.entries) e.key: Map.of(e.value),
  };

  void _pushDevices() => _events.add(
    ZbEvent('devices', {
      'devices': [
        for (final d in _devices) {'ieee': d.ieee},
      ],
    }),
  );

  void _emitState(String ieee, Map<String, dynamic> values) =>
      _events.add(ZbEvent('state', {'ieee': ieee, 'values': values}));

  /// Gerätemeldung von außen (simulierte Gesten der Haven-Automationen).
  void emitDeviceState(String ieee, Map<String, dynamic> values) {
    if (!_events.isClosed) _emitState(ieee, values);
  }

  Future<void> set(String ieee, Map<String, dynamic> values) async {
    if (!_states.containsKey(ieee)) {
      throw HavenException('Gerät nicht gefunden.', code: 'not_found');
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
    _states[ieee]!.addAll(values);
    _emitState(ieee, values);
  }

  Future<void> rename(String ieee, String name) async {
    final i = _devices.indexWhere((d) => d.ieee == ieee);
    if (i < 0) throw HavenException('Gerät nicht gefunden.', code: 'not_found');
    _devices[i] = _devices[i].copyWith(friendlyName: name);
    _pushDevices();
  }

  Future<void> setArea(String ieee, String? areaId) async {
    final i = _devices.indexWhere((d) => d.ieee == ieee);
    if (i < 0) throw HavenException('Gerät nicht gefunden.', code: 'not_found');
    _devices[i] = _devices[i].copyWith(
      areaId: areaId,
      clearArea: areaId == null,
    );
    _pushDevices();
  }

  Future<void> remove(String ieee) async {
    _devices.removeWhere((d) => d.ieee == ieee);
    _states.remove(ieee);
    _pushDevices();
  }

  Future<void> permitJoin(int seconds) async {
    cancelTimers();
    _permit = true;
    _events.add(ZbEvent('info', {'permit_join': true}));
    _timers.addAll([
      Timer(joinDelay, _joined),
      Timer(joinDelay + const Duration(seconds: 1), _interviewStarted),
      Timer(joinDelay + const Duration(seconds: 4), _interviewDone),
      Timer(Duration(seconds: seconds), stopJoin),
    ]);
  }

  static const _newIeee = '0x00124b00000000a1';

  ZbEvent _bridge(String type, Map<String, dynamic> data) => ZbEvent('event', {
    'event': {'type': type, 'data': data},
  });

  void _joined() => _events.add(
    _bridge('device_joined', {
      'friendly_name': _newIeee,
      'ieee_address': _newIeee,
    }),
  );

  void _interviewStarted() => _events.add(
    _bridge('device_interview', {
      'friendly_name': _newIeee,
      'ieee_address': _newIeee,
      'status': 'started',
    }),
  );

  void _interviewDone() {
    // Das neue Gerät hat die Klassifizierung eines vorhandenen SNZB-02.
    final tpl = _devices.firstWhere(
      (d) => d.model == 'SNZB-02',
      orElse: () => _devices.first,
    );
    if (!_devices.any((d) => d.ieee == _newIeee)) {
      _devices.add(
        ZbDevice(
          ieee: _newIeee,
          friendlyName: _newIeee,
          type: 'EndDevice',
          vendor: 'SONOFF',
          model: 'SNZB-02',
          description: 'Temperature and humidity sensor',
          powerSource: 'Battery',
          image: 'https://www.zigbee2mqtt.io/images/devices/SNZB-02.png',
          deviceType: ZbType.climate,
          classified: tpl.classified,
          hasAreaInfo: true,
        ),
      );
      _states[_newIeee] = {
        'linkquality': 182,
        'battery': 100,
        'temperature': 21.3,
        'humidity': 47,
        'last_seen': DateTime.now().toIso8601String(),
      };
    }
    _events.add(
      _bridge('device_interview', {
        'friendly_name': _newIeee,
        'ieee_address': _newIeee,
        'status': 'successful',
        'supported': true,
        'definition': {
          'model': 'SNZB-02',
          'vendor': 'SONOFF',
          'description': 'Temperature and humidity sensor',
        },
      }),
    );
    _pushDevices();
  }

  Future<void> stopJoin() async {
    _permit = false;
    cancelTimers();
    _events.add(ZbEvent('info', {'permit_join': false}));
  }

  void cancelTimers() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
  }

  Future<void> dispose() async {
    cancelTimers();
    await _events.close();
    await _measureResults.close();
  }
}

/// Erfundene IEEE des Koordinators.
const fakeCoordinatorIeee = '0x00124b00000000ff';

/// Plausible, feste Topologie aus den Geräten, ohne Zufall.
///
/// Die Lage kommt aus dem Grundriss [plan] (Standard: Beispielgrundriss, Geräte
/// über die Platzierung ihrer Entities aus [entityIds], sonst Raummitte):
/// - Router hängen am nächstgelegenen Router, der dem Koordinator näher ist,
///   oder am Koordinator selbst.
/// - Endgeräte hängen am nächsten Router im selben Raum, sonst im Nachbarraum,
///   sonst am nächsten überhaupt. Geräte ohne Raum nehmen einen Router per
///   Namens-Hash.
/// - Router, die nah beieinander liegen, sehen sich zusätzlich als Geschwister.
/// - Über Raumgrenzen ist das Signal schwächer. „Lüfter Waschraum“ und
///   „Sensor Terrasse“ sind bewusst schwach (passend zu „Braucht dich“).
ZbNetworkMap buildFakeNetworkMap(
  List<ZbDevice> devices, {
  Map<String, List<String>> entityIds = const {},
  HavenFloorPlan? plan,
  DateTime? measuredAt,
}) {
  final p = plan ?? kFakeFloorPlan;
  final points = p.devicePoints([
    for (final d in devices)
      FloorDevice(d.ieee, entityIds[d.ieee] ?? const [], roomId: d.areaId),
  ]);
  final coordPoint = p.coordinatorPoint;
  final coordPos = coordPoint?.offset ?? const Offset(13, 10);
  final coordRoom = coordPoint?.roomId;

  String? roomOf(String ieee) =>
      ieee == fakeCoordinatorIeee ? coordRoom : points[ieee]?.roomId;
  Offset? posOf(String ieee) =>
      ieee == fakeCoordinatorIeee ? coordPos : points[ieee]?.offset;
  double dist(String a, String b) {
    final pa = posOf(a);
    final pb = posOf(b);
    if (pa == null || pb == null) return 24;
    return (pa - pb).distance;
  }

  bool adjacent(String? a, String? b) {
    if (a == null || b == null || a == b) return false;
    final ra = p.room(a)?.bounds;
    final rb = p.room(b)?.bounds;
    if (ra == null || rb == null) return false;
    final i = ra.inflate(0.01).intersect(rb.inflate(0.01));
    return i.width >= 0 && i.height >= 0;
  }

  int hash(String s) =>
      s.codeUnits.fold<int>(11, (a, c) => (a * 31 + c) & 0xfffff);

  const mid = {'Kontaktsensor Schrank': 112};
  const weak = {'Lüfter Waschraum': 58, 'Sensor Terrasse': 71};
  int lqi(ZbDevice child, String parent, {required bool router}) {
    final w = weak[child.friendlyName] ?? mid[child.friendlyName];
    if (w != null) return w;
    final cross = roomOf(child.ieee) != roomOf(parent);
    final d = dist(child.ieee, parent);
    final jitter = hash('${child.ieee}$parent') % 17 - 8;
    final base = router
        ? 250 - d * 4 - (cross ? 20 : 0)
        : 252 - d * 5 - (cross ? 25 : 0);
    return (base + jitter).round().clamp(100, 252);
  }

  final routers =
      [
        for (final d in devices)
          if (d.isRouter) d,
      ]..sort((a, b) {
        final c = dist(
          a.ieee,
          fakeCoordinatorIeee,
        ).compareTo(dist(b.ieee, fakeCoordinatorIeee));
        return c != 0 ? c : a.ieee.compareTo(b.ieee);
      });
  final parentOf = <String, String>{};
  final depth = <String, int>{fakeCoordinatorIeee: 0};
  final lqiOf = <String, int>{};
  final byName = {for (final d in devices) d.ieee: d};
  for (var i = 0; i < routers.length; i++) {
    final r = routers[i];
    final cands = [
      fakeCoordinatorIeee,
      for (var j = 0; j < i; j++) routers[j].ieee,
    ];
    String best = cands.first;
    var bd = double.infinity;
    if (posOf(r.ieee) == null && i > 0) {
      // Ohne Raum: ein bereits eingebundener Router, per Hash gewählt.
      best = cands[1 + hash(r.ieee) % (cands.length - 1)];
    } else {
      for (final c in cands) {
        final dd = dist(r.ieee, c);
        if (dd < bd || (dd == bd && c.compareTo(best) < 0)) {
          bd = dd;
          best = c;
        }
      }
    }
    parentOf[r.ieee] = best;
    depth[r.ieee] = depth[best]! + 1;
    lqiOf[r.ieee] = lqi(r, best, router: true);
  }
  for (final d in devices) {
    if (d.isRouter || d.isCoordinator) continue;
    final room = roomOf(d.ieee);
    String? best;
    var bd = double.infinity;
    void scan(bool Function(ZbDevice r) ok) {
      for (final r in routers) {
        if (!ok(r)) continue;
        final dd = dist(d.ieee, r.ieee);
        if (dd < bd ||
            (dd == bd && best != null && r.ieee.compareTo(best!) < 0)) {
          bd = dd;
          best = r.ieee;
        }
      }
    }

    if (room != null) {
      scan((r) => roomOf(r.ieee) == room);
      if (best == null) scan((r) => adjacent(roomOf(r.ieee), room));
      if (best == null) scan((r) => true);
    } else if (routers.isNotEmpty) {
      best = routers[hash(d.ieee) % routers.length].ieee;
    }
    best ??= fakeCoordinatorIeee;
    parentOf[d.ieee] = best!;
    depth[d.ieee] = depth[best]! + 1;
    lqiOf[d.ieee] = lqi(d, best!, router: false);
  }

  // Z2M-Rohformat: `target` meldet, `source` ist der Nachbar,
  // `relationship` beschreibt den Nachbarn aus Sicht von `target`.
  final links = <ZbMeshLink>[];
  void report(String reporter, String neighbor, int q, int dep, int rel) =>
      links.add(
        ZbMeshLink(
          source: neighbor,
          target: reporter,
          lqi: q,
          depth: dep,
          relationship: rel,
        ),
      );

  final linked = <String>{};
  String key(String a, String b) => a.compareTo(b) < 0 ? '$a|$b' : '$b|$a';
  final isRouter = {for (final r in routers) r.ieee};
  for (final e in parentOf.entries) {
    final dep = depth[e.key]!;
    final q = lqiOf[e.key]!;
    // Der Elternknoten führt das Kind in seiner Tabelle.
    report(e.value, e.key, q, dep, ZbRelationship.child);
    if (isRouter.contains(e.key)) {
      // Router melden selbst: Eltern nur bei jedem zweiten (wie im echten
      // Netz, dort sind Router meist nur Geschwister), sonst Geschwister.
      final rel = hash(e.key).isEven
          ? ZbRelationship.parent
          : ZbRelationship.sibling;
      report(e.key, e.value, q, dep - 1, rel);
    }
    linked.add(key(e.key, e.value));
  }
  // Geschwister: jeder Router (und der Koordinator) mit den Routern in
  // Reichweite, je Richtung ein Eintrag mit leicht anderem LQI.
  final meshers = [fakeCoordinatorIeee, for (final r in routers) r.ieee];
  for (var i = 0; i < meshers.length; i++) {
    for (var j = i + 1; j < meshers.length; j++) {
      final a = meshers[i], b = meshers[j];
      if (linked.contains(key(a, b))) continue;
      // Die absichtlich schwachen Geräte bekommen keinen besseren Umweg.
      if (weak.containsKey(byName[a]?.friendlyName) ||
          weak.containsKey(byName[b]?.friendlyName)) {
        continue;
      }
      final dd = dist(a, b);
      if (dd > 11) continue;
      linked.add(key(a, b));
      final q = (238 - dd * 11 - hash('$a$b') % 13).round().clamp(40, 240);
      final rel = dd > 9.5 ? ZbRelationship.none : ZbRelationship.sibling;
      report(a, b, q, depth[b] ?? 2, rel);
      report(
        b,
        a,
        (q + hash('$b$a') % 9 - 4).clamp(40, 240),
        depth[a] ?? 2,
        rel,
      );
    }
  }

  return ZbNetworkMap(
    nodes: [
      const ZbMeshNode(
        ieee: fakeCoordinatorIeee,
        name: 'Koordinator',
        kind: ZbNodeKind.coordinator,
        networkAddress: 0,
      ),
      for (final d in devices)
        ZbMeshNode(
          ieee: d.ieee,
          name: byName[d.ieee]!.friendlyName,
          kind: d.isRouter ? ZbNodeKind.router : ZbNodeKind.endDevice,
          networkAddress: 0x1000 + hash(d.ieee) % 0xe000,
        ),
    ],
    links: links,
    measuredAt: measuredAt,
  );
}
