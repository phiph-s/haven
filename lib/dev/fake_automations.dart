import 'dart:async';

import '../data/haven_repository.dart';
import '../data/models/haven_automation.dart';
import 'fake_zigbee.dart';

/// Haven-Automationen in den Entwicklungsdaten: drei Beispiele im Speicher
/// (Drehregler im Salon, Taster im Ruheraum, Bewegungslicht im Waschraum) und
/// simulierte Gesten bzw. Zustände des Bewegungslichts.
///
/// Gesten wirken wie in der Integration auf die Lampen des Raums (über die
/// Raum-Aktionen des Fake-Repositorys). Solange jemand die Auslösungen hört
/// (Live-Test) und Zeitgeber laufen dürfen, dreht und drückt ein erfundener
/// Nutzer im 1,4-s-Takt an den Geräten.
class FakeAutomations {
  FakeAutomations({
    required this.repo,
    required this.zigbee,
    required this.inventory,
    required this.simulate,
  }) {
    _triggers = StreamController<AutomationTrigger>.broadcast(
      onListen: _startSimulation,
      onCancel: _stopSimulation,
    );
  }

  final HavenRepository repo;
  final FakeZigbee zigbee;
  final Map<String, dynamic> inventory;
  final bool simulate;

  static const salonKnob = '0x00124b0000000016';
  static const ruheraumButton = '0x00124b0000000008';
  static const waschraumPresence = '0x00124b000000001f';

  late final StreamController<AutomationTrigger> _triggers;
  final _changed = StreamController<void>.broadcast();
  Timer? _sim;
  int _simTick = 0;
  int _nextId = 3;
  final Map<String, int> _lastScene = {};

  int _motionTick = 0;
  Timer? _motionSim;

  late List<HavenAutomation> _items = [
    HavenAutomation(
      id: 'demo-salon',
      name: 'Drehregler Salon',
      roomAreaId: 'salon',
      devices: const [salonKnob],
      options: const KnobOptions(
        gestures: {
          KnobGesture.rotate: GestureBinding(GestureAction.brightness),
          KnobGesture.single: GestureBinding(GestureAction.toggle),
          KnobGesture.double: GestureBinding(GestureAction.nextScene),
          KnobGesture.hold: GestureBinding(GestureAction.off),
        },
        scenes: [0, 3, 1],
      ),
      lastTriggered: AutomationFired(
        DateTime.now().subtract(const Duration(minutes: 12)),
        'rotate_right',
      ),
    ),
    HavenAutomation(
      id: 'demo-ruheraum',
      name: 'Taster Ruheraum',
      roomAreaId: 'ruheraum',
      devices: const [ruheraumButton],
      options: const KnobOptions(
        gestures: {
          KnobGesture.rotate: GestureBinding(GestureAction.none),
          KnobGesture.single: GestureBinding(GestureAction.nextScene),
          KnobGesture.double: GestureBinding(GestureAction.none),
          KnobGesture.hold: GestureBinding(GestureAction.toggle),
        },
      ),
      lastTriggered: AutomationFired(
        DateTime.now().subtract(const Duration(hours: 3)),
        'single',
      ),
    ),
    HavenAutomation(
      id: 'demo-waschraum',
      type: kMotionType,
      name: 'Bewegungslicht Waschraum',
      roomAreaId: 'waschraum',
      devices: const [waschraumPresence],
      motion: const MotionOptions(
        windows: [TimeWindow('18:00', '07:00')],
        sun: SunWindow(from: SunEdge('sunset'), until: SunEdge('sunrise', 60)),
        luxBelow: 30,
        light: MotionLight(brightness: 140, colorTemp: 2700),
        night: NightLight(),
        delay: 90,
        warn: true,
      ),
      motionStatus: MotionStatus(
        phase: MotionPhase.motion,
        offAt: DateTime.now().add(const Duration(seconds: 80)),
        night: false,
        lux: 12,
        detectors: const ['binary_sensor.prasenz_waschraum_presence'],
      ),
      lastTriggered: AutomationFired(
        DateTime.now().subtract(const Duration(seconds: 10)),
        'motion_extend',
      ),
    ),
  ];

  Stream<AutomationTrigger> get triggers => _triggers.stream;
  Stream<void> get changed => _changed.stream;

  List<Map<String, dynamic>> get _groups => [
    for (final g in (inventory['z2m_groups'] as List))
      g as Map<String, dynamic>,
  ];

  Map<String, AutomationRoom> _rooms() {
    final out = <String, AutomationRoom>{};
    for (final r in repo.snapshot.rooms) {
      final g = _groups.where((g) => g['room'] == r.id).firstOrNull;
      out[r.id] = AutomationRoom(
        areaId: r.id,
        name: r.name,
        group: g?['name'] as String?,
        scenes: [
          for (final s in (g?['scenes'] as List? ?? const []))
            GroupScene((s['id'] as num).toInt(), '${s['name']}'),
        ],
        lights: r.lightIds,
      );
    }
    return out;
  }

  Future<HavenAutomations> list() async => HavenAutomations(
    automations: List.unmodifiable(_items),
    rooms: _rooms(),
    // Die HA-Automation „Knopf schaltet Ruheraum“ hängt am selben Taster.
    deviceAutomations: const {
      ruheraumButton: ['automation.knopf_schaltet_ruheraum'],
    },
  );

  Future<HavenAutomation> save(HavenAutomation a) async {
    final rooms = _rooms();
    final room = rooms[a.roomAreaId];
    if (room == null) {
      throw HavenException('Unbekannter Raum.', code: 'not_found');
    }
    if (!room.hasLights) {
      throw HavenException(
        '${room.name} hat keine Lichter, die Haven steuern kann',
        code: 'no_lights',
      );
    }
    if (a.devices.isEmpty) {
      throw HavenException(
        a.isMotion
            ? 'Wähl mindestens einen Melder'
            : 'Wähl mindestens einen Regler oder Taster',
        code: 'invalid_format',
      );
    }
    if (a.enabled) {
      for (final d in a.devices) {
        final owner = _items
            .where(
              (x) =>
                  x.enabled &&
                  x.id != a.id &&
                  x.type == a.type &&
                  x.devices.contains(d),
            )
            .firstOrNull;
        if (owner != null) {
          throw HavenException(
            a.isMotion
                ? 'Der Melder meldet schon für ${owner.name}'
                : 'Das Gerät steuert schon ${owner.name}',
            code: 'device_taken',
          );
        }
      }
    }
    final saved = a.id == null ? a.copyWith(id: 'demo-${_nextId++}') : a;
    final i = _items.indexWhere((x) => x.id == saved.id);
    _items = [..._items];
    if (i < 0) {
      _items.add(saved);
    } else {
      _items[i] = saved.copyWith(
        lastTriggered: _items[i].lastTriggered,
        motionStatus: _items[i].motionStatus,
      );
    }
    _changed.add(null);
    return _items.firstWhere((x) => x.id == saved.id);
  }

  Future<void> delete(String id) async {
    _items = [..._items]..removeWhere((x) => x.id == id);
    _changed.add(null);
  }

  Future<void> test(String id, String action) async {
    final a = _items.where((x) => x.id == id).firstOrNull;
    if (a == null) throw HavenException('Unbekannt.', code: 'not_found');
    if (a.isMotion) return _testMotion(a, action);
    await _fire(a, action, null, 'test');
  }

  /// Test eines Bewegungslichts: `motion`, `clear`, `takeover`.
  Future<void> _testMotion(HavenAutomation a, String action) async {
    final delay = a.motion?.delay ?? 120;
    final (event, status) = switch (action) {
      'motion' => (
        'motion_on',
        MotionStatus(
          phase: MotionPhase.motion,
          occupied: true,
          night: false,
          lux: 12,
          detectors: a.motionStatus?.detectors ?? const [],
        ),
      ),
      'clear' => (
        'motion_extend',
        MotionStatus(
          phase: MotionPhase.motion,
          offAt: DateTime.now().add(Duration(seconds: delay)),
          lux: 12,
          detectors: a.motionStatus?.detectors ?? const [],
        ),
      ),
      _ => (
        'takeover',
        MotionStatus(
          phase: MotionPhase.manual,
          lux: 12,
          detectors: a.motionStatus?.detectors ?? const [],
        ),
      ),
    };
    _emitMotion(a, event, status, 'test');
    if (event == 'motion_on') {
      await repo.setRoomBrightness(a.roomAreaId, 55);
    }
  }

  void _emitMotion(
    HavenAutomation a,
    String event,
    MotionStatus status,
    String source,
  ) {
    final now = DateTime.now();
    final i = _items.indexWhere((x) => x.id == a.id);
    if (i < 0) return;
    _items = [..._items]
      ..[i] = _items[i].copyWith(
        motionStatus: status,
        lastTriggered: AutomationFired(now, event),
      );
    if (!_triggers.isClosed) {
      _triggers.add(
        AutomationTrigger(
          id: a.id!,
          action: event,
          room: a.roomAreaId,
          source: source,
          at: now,
          motion: status,
        ),
      );
    }
  }

  // Erfundener Ablauf für das Bewegungslicht: an, verlängern, Nachlauf,
  // Vorwarnung, aus, Übernahme von Hand, wieder frei.
  void _motionStep() {
    final a = _items.where((x) => x.id == 'demo-waschraum').firstOrNull;
    if (a == null || !a.enabled) return;
    const det = ['binary_sensor.prasenz_waschraum_presence'];
    final now = DateTime.now();
    final script = <(String, MotionStatus)>[
      (
        'motion_on',
        const MotionStatus(
          phase: MotionPhase.motion,
          occupied: true,
          night: false,
          lux: 12,
          detectors: det,
        ),
      ),
      (
        'motion_extend',
        MotionStatus(
          phase: MotionPhase.motion,
          offAt: now.add(const Duration(seconds: 90)),
          lux: 12,
          detectors: det,
        ),
      ),
      (
        'warn',
        MotionStatus(
          phase: MotionPhase.warn,
          offAt: now.add(const Duration(seconds: 20)),
          lux: 12,
          detectors: det,
        ),
      ),
      (
        'motion_off',
        const MotionStatus(phase: MotionPhase.idle, lux: 12, detectors: det),
      ),
      (
        'motion_on',
        const MotionStatus(
          phase: MotionPhase.motion,
          occupied: true,
          night: true,
          lux: 12,
          detectors: det,
        ),
      ),
      (
        'takeover',
        const MotionStatus(phase: MotionPhase.manual, lux: 12, detectors: det),
      ),
      (
        'motion_off',
        const MotionStatus(
          phase: MotionPhase.inactive,
          inactive: 'lux',
          lux: 80,
          detectors: det,
        ),
      ),
    ];
    final (event, status) = script[_motionTick++ % script.length];
    _emitMotion(a, event, status, 'device');
  }

  /// Eine Geste an einem Gerät: Meldung wie von Z2M, dann die Automation.
  Future<void> gesture(String ieee, String action) async {
    zigbee.emitDeviceState(ieee, {'action': action});
    final a = _items
        .where((x) => x.enabled && x.devices.contains(ieee))
        .firstOrNull;
    if (a != null) await _fire(a, action, ieee, 'device');
  }

  Future<void> _fire(
    HavenAutomation a,
    String action,
    String? ieee,
    String source,
  ) async {
    final now = DateTime.now();
    final i = _items.indexOf(a);
    if (i >= 0) {
      _items = [..._items]
        ..[i] = a.copyWith(lastTriggered: AutomationFired(now, action));
    }
    if (!_triggers.isClosed) {
      _triggers.add(
        AutomationTrigger(
          id: a.id!,
          action: action,
          room: a.roomAreaId,
          device: ieee,
          source: source,
          at: now,
        ),
      );
    }
    await _execute(a, action);
  }

  Future<void> _execute(HavenAutomation a, String action) async {
    final g = gestureOf(action);
    if (g == null) return;
    final b = a.options.binding(g);
    final roomId = a.roomAreaId;
    final room = repo.snapshot.rooms.where((r) => r.id == roomId).firstOrNull;
    if (room == null) return;
    final on = [
      for (final id in room.lightIds)
        if (repo.snapshot.entity(id)?.isOn == true) id,
    ];
    final bri = on.isEmpty
        ? 0
        : on
              .map(
                (id) =>
                    ((repo.snapshot.entity(id)?.attributes['brightness']
                                as num?) ??
                            0)
                        .toInt(),
              )
              .reduce((x, y) => x > y ? x : y);
    final scenes = _rooms()[roomId]?.scenes ?? const <GroupScene>[];
    Future<void> recall(int? id) async {
      final s = scenes.where((s) => s.id == id).firstOrNull;
      final rs = room.scenes.where((r) => r.name == s?.name).firstOrNull;
      if (s == null || rs == null) return;
      _lastScene[roomId] = s.id;
      await repo.applyScene(roomId, rs.id);
    }

    switch (b.action) {
      case GestureAction.brightness:
        final dir = action == 'rotate_right' ? 1 : -1;
        final next = bri + dir * a.options.step;
        final min = a.options.minBrightness;
        if (dir < 0 && on.isEmpty) return;
        if (dir < 0 && bri <= min) {
          if (a.options.offAtMin) await repo.setRoomBrightness(roomId, 0);
          return;
        }
        final clamped = next.clamp(dir < 0 ? min : 1, 254);
        await repo.setRoomBrightness(roomId, (clamped / 2.55).round());
      case GestureAction.toggle:
        if (on.isEmpty && a.options.onScene != null) {
          await recall(a.options.onScene);
        } else {
          await repo.toggleRoom(roomId);
        }
      case GestureAction.off:
        await repo.setRoomBrightness(roomId, 0);
      case GestureAction.scene:
        await recall(b.scene);
      case GestureAction.nextScene:
        final cycle = [
          for (final id in (a.options.scenes ?? [for (final s in scenes) s.id]))
            if (scenes.any((s) => s.id == id)) id,
        ];
        if (cycle.isEmpty) return;
        final last = _lastScene[roomId];
        final idx = last == null ? -1 : cycle.indexOf(last);
        await recall(cycle[(idx + 1) % cycle.length]);
      case GestureAction.lights:
        for (final t in b.lights) {
          final c = t.rgb;
          await repo.setLights(
            [t.entityId],
            on: t.on,
            brightness: t.on ? t.brightness : null,
            kelvin: t.on && c == null ? t.kelvin : null,
            rgb: t.on && c != null
                ? ((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF)
                : null,
          );
        }
      case GestureAction.none:
        return;
    }
  }

  // Erfundener Nutzer für den Live-Test.
  static const _pattern = [
    (salonKnob, 'rotate_right'),
    (salonKnob, 'rotate_right'),
    (salonKnob, 'rotate_left'),
    (salonKnob, 'single'),
    (ruheraumButton, 'single'),
    (salonKnob, 'single'),
    (salonKnob, 'double'),
    (ruheraumButton, 'hold'),
  ];

  void _startSimulation() {
    if (!simulate || _sim != null) return;
    _sim = Timer.periodic(const Duration(milliseconds: 1400), (_) {
      final (ieee, action) = _pattern[_simTick++ % _pattern.length];
      unawaited(gesture(ieee, action));
    });
    _motionSim = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _motionStep(),
    );
  }

  void _stopSimulation() {
    _sim?.cancel();
    _sim = null;
    _motionSim?.cancel();
    _motionSim = null;
  }

  Future<void> dispose() async {
    _stopSimulation();
    await _triggers.close();
    await _changed.close();
  }
}
