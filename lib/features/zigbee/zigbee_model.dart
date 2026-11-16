import '../../data/models/entity_state.dart';
import '../../data/models/room.dart';
import '../../data/models/zigbee.dart';
import '../../data/models/zigbee_network.dart' show ZbMeshNode;
import 'ghost_rules.dart';

/// Schwellen für „Braucht dich“.
const int kLowBattery = 30;
const int kWeakLqi = 80;
const int kGoodLqi = 150;

/// HA-Slug wie `slugify`: Umlaute und ß aufgelöst, alles andere zu `_`.
String haSlug(String s) {
  var t = s.toLowerCase();
  const map = {'ä': 'a', 'ö': 'o', 'ü': 'u', 'ß': 'ss'};
  map.forEach((k, v) => t = t.replaceAll(k, v));
  t = t.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  return t.replaceAll(RegExp(r'^_+|_+$'), '');
}

/// Verständliche Stufe zu einer Funkqualität (LQI 0..255).
enum LqiLevel {
  good('gut'),
  medium('mittel'),
  weak('schwach');

  const LqiLevel(this.label);
  final String label;

  static LqiLevel of(int lqi) => lqi >= kGoodLqi
      ? good
      : lqi >= kWeakLqi
      ? medium
      : weak;
}

/// Ein Gerät mit seinen aktuellen Werten, Raum und Erreichbarkeit. Reine
/// Daten, ohne Riverpod, damit Regeln und Filter einfach zu testen sind.
class ZbDeviceView {
  const ZbDeviceView({
    required this.device,
    this.values = const {},
    this.entities = const [],
    this.roomId,
    this.roomName,
    this.battery,
    this.lqi,
    this.available = true,
    this.lastSeen,
    this.lastSeenSource,
    this.networkMeasuredAt,
    this.availability,
  });

  /// Baut die Sicht aus Gerät, Z2M-Werten, allen HA-Entities und den Räumen.
  /// [roomsKnown] ist `false`, wenn die Integration keine Raumzuordnung liefert.
  factory ZbDeviceView.build(
    ZbDevice device, {
    Map<String, dynamic>? state,
    Map<String, EntityState> allEntities = const {},
    List<Room> rooms = const [],
    ZbMeshNode? meshNode,
    DateTime? meshMeasuredAt,
  }) {
    final mine = matchEntities(device, allEntities);
    final v = ZbDeviceView(device: device, values: state ?? const {});
    final withEnt = ZbDeviceView(
      device: device,
      values: state ?? const {},
      entities: mine,
    );
    final bat = withEnt.number('battery');
    final lqi = withEnt.number('linkquality');
    final availability = switch (v.values['availability']) {
      final String s when s == 'online' || s == 'offline' => s,
      false => 'offline',
      _ => device.availability,
    };
    final offline =
        availability == 'offline' ||
        (mine.isNotEmpty && mine.every((e) => e.state == 'unavailable'));
    String? roomId;
    String? roomName;
    final area = device.areaId;
    if (area != null) {
      for (final r in rooms) {
        if (r.id == area || r.areaId == area) {
          roomId = r.id;
          roomName = r.name;
          break;
        }
      }
      roomId ??= area;
      roomName ??= area;
    }
    // Zuletzt gesehen: Z2M-Zustand (live), dann die Integration, dann die
    // Netzkarte der App (ältere Integration ohne `ghost_detection`).
    var seen = ZbDevice.parseLastSeen(v.values['last_seen']);
    String? source = seen == null ? null : 'z2m';
    if (seen == null && device.lastSeen != null) {
      seen = device.lastSeen;
      source = device.lastSeenSource;
    }
    if (seen == null && meshNode?.lastSeen != null) {
      seen = meshNode!.lastSeen;
      source = 'networkmap';
    }
    return ZbDeviceView(
      device: device,
      values: state ?? const {},
      entities: mine,
      roomId: roomId,
      roomName: roomName,
      battery: bat?.round(),
      lqi: lqi?.round(),
      available: !offline,
      lastSeen: seen,
      lastSeenSource: source,
      networkMeasuredAt: source == 'networkmap' ? meshMeasuredAt : null,
      availability: availability,
    );
  }

  final ZbDevice device;

  /// Letzte bekannte Z2M-Werte (IEEE-Abo oder `haven/zigbee/state`).
  final Map<String, dynamic> values;

  /// Die HA-Entities des Geräts.
  final List<EntityState> entities;
  final String? roomId;
  final String? roomName;
  final int? battery;
  final int? lqi;
  final bool available;

  /// Zuletzt gesehen und woher: `z2m` (Z2M-Option) oder `networkmap`
  /// (Messung vom [networkMeasuredAt]). `null`: keine Quelle.
  final DateTime? lastSeen;
  final String? lastSeenSource;
  final DateTime? networkMeasuredAt;

  /// Z2M-Verfügbarkeit: `online`, `offline` oder `null`.
  final String? availability;

  String get ieee => device.ieee;
  String get name => device.friendlyName;
  String get type => device.deviceType;
  bool get hasRoom => roomId != null;

  LqiLevel? get lqiLevel => lqi == null ? null : LqiLevel.of(lqi!);

  /// Zuerst Z2M-Wert, dann Entity `<domain>.<name>_<property>`.
  EntityState? entity(String property) {
    for (final e in entities) {
      if (e.entityId.split('.').last.endsWith('_$property')) return e;
    }
    return null;
  }

  /// Die Haupt-Entity zum Schalten: Licht, sonst Schalter.
  EntityState? get mainEntity {
    for (final d in const ['light', 'switch']) {
      for (final e in entities) {
        if (e.domain == d && !e.entityId.contains('_do_not_disturb')) return e;
      }
    }
    return null;
  }

  dynamic raw(String property) {
    if (values.containsKey(property)) return values[property];
    final e = entity(property);
    if (e == null || !e.isAvailable) return null;
    if (e.domain == 'binary_sensor' || e.domain == 'switch') return e.isOn;
    return e.number ?? e.state;
  }

  num? number(String property) {
    final r = raw(property);
    return r is num ? r : (r is String ? num.tryParse(r) : null);
  }

  /// Wert zu einem Feature, in der Form wie Z2M ihn schreibt (bei Binär
  /// `value_on`/`value_off`).
  dynamic read(ZbFeature f) {
    if (values.containsKey(f.property)) return values[f.property];
    final e = entity(f.property);
    if (e == null || !e.isAvailable) return null;
    if (f.isBinary) return f.binaryValue(e.isOn);
    if (f.isNumeric) return e.number;
    return e.state;
  }

  /// Geister-Verdacht nach [evaluateGhost], `null` ohne Verdacht.
  GhostInfo? ghost(DateTime now) => device.isCoordinator || device.disabled
      ? null
      : evaluateGhost(
          isBattery: device.isBattery,
          lastSeen: lastSeen,
          availability: availability,
          now: now,
        );

  ZbDeviceView withDevice(ZbDevice d) => ZbDeviceView(
    device: d,
    values: values,
    entities: entities,
    roomId: roomId,
    roomName: roomName,
    battery: battery,
    lqi: lqi,
    available: available,
    lastSeen: lastSeen,
    lastSeenSource: lastSeenSource,
    networkMeasuredAt: networkMeasuredAt,
    availability: availability,
  );

  /// Entities, die zu [device] gehören: erst die Liste der Integration, sonst
  /// Name als Präfix (HA-Slug) oder IEEE.
  static List<EntityState> matchEntities(
    ZbDevice device,
    Map<String, EntityState> all,
  ) {
    if (device.haEntities.isNotEmpty) {
      return [
        for (final id in device.haEntities)
          if (all[id] != null) all[id]!,
      ];
    }
    final slug = haSlug(device.friendlyName);
    final ieee = device.ieee.toLowerCase();
    return [
      for (final e in all.values)
        if (e.domain != 'automation' &&
            e.domain != 'scene' &&
            e.domain != 'weather')
          if (_startsWith(e.entityId.split('.').last, slug) ||
              _startsWith(e.entityId.split('.').last, ieee))
            e,
    ];
  }

  static bool _startsWith(String objectId, String slug) =>
      slug.isNotEmpty && (objectId == slug || objectId.startsWith('${slug}_'));
}

/// Filter der Geräteliste.
enum ZbFilter {
  lights('Lichter'),
  plugs('Steckdosen'),
  sensors('Sensoren'),
  switches('Schalter'),
  battery('Batterie');

  const ZbFilter(this.label);
  final String label;

  bool matches(ZbDeviceView v) {
    final t = v.type;
    return switch (this) {
      lights => t == ZbType.light,
      plugs => t == ZbType.plug,
      sensors =>
        t == ZbType.climate ||
            t == ZbType.motion ||
            t == ZbType.presence ||
            t == ZbType.contact ||
            t == ZbType.thermostat,
      switches =>
        t == ZbType.switch_ ||
            t == ZbType.relay ||
            t == ZbType.remote ||
            t == ZbType.knob,
      battery => v.device.isBattery,
    };
  }
}

/// Wofür ein Gerät „Braucht dich“ steht.
enum ZbNeedKind { ghost, offline, lowBattery, weakSignal, noRoom }

class ZbNeed {
  const ZbNeed(this.kind, this.view, this.detail, [this.ghost]);
  final ZbNeedKind kind;
  final ZbDeviceView view;
  final String detail;

  /// Bei [ZbNeedKind.ghost]: der Verdacht mit Text und Aktionen.
  final GhostInfo? ghost;
}

/// Berechnet „Braucht dich“ aus den Daten. Reihenfolge: Geister, nicht
/// erreichbar, Batterie, Signal, Raum. [ignored] (IEEE → Stempel, siehe
/// [ghostStamp]) blendet Geister bis zur nächsten Meldung aus.
/// Jedes Gerät steht höchstens einmal da, mit dem wichtigsten Grund vorn und
/// den übrigen im Text.
/// [roomsKnown] `false`: Die Integration liefert keine Räume, dann gäbe es
/// sonst für jedes Gerät den Hinweis „Kein Raum“.
List<ZbNeed> computeNeeds(
  Iterable<ZbDeviceView> views, {
  bool roomsKnown = true,
  DateTime? now,
  Map<String, String> ignored = const {},
}) {
  final out = <ZbNeed>[];
  final t = now ?? DateTime.now();
  final list = [
    for (final v in views)
      if (!v.device.isCoordinator && !v.device.disabled) v,
  ];
  final ghosts = <String>{};
  for (final v in list) {
    final g = v.ghost(t);
    if (g == null) continue;
    ghosts.add(v.ieee);
    if (isGhostIgnored(ignored, v.ieee, v.lastSeen)) continue;
    out.add(ZbNeed(ZbNeedKind.ghost, v, g.text, g));
  }
  for (final v in list) {
    if (!v.available && !ghosts.contains(v.ieee)) {
      out.add(ZbNeed(ZbNeedKind.offline, v, 'Nicht erreichbar'));
    }
  }
  for (final v in list) {
    final b = v.battery;
    if (v.available &&
        !ghosts.contains(v.ieee) &&
        v.device.isBattery &&
        b != null &&
        b < kLowBattery) {
      out.add(ZbNeed(ZbNeedKind.lowBattery, v, 'Batterie bei $b %'));
    }
  }
  for (final v in list) {
    final q = v.lqi;
    if (v.available && !ghosts.contains(v.ieee) && q != null && q < kWeakLqi) {
      out.add(ZbNeed(ZbNeedKind.weakSignal, v, 'Schwaches Signal ($q)'));
    }
  }
  if (roomsKnown) {
    for (final v in list) {
      if (!v.hasRoom) out.add(ZbNeed(ZbNeedKind.noRoom, v, 'Kein Raum'));
    }
  }
  final first = <String, int>{};
  final merged = <ZbNeed>[];
  for (final n in out) {
    final i = first[n.view.ieee];
    if (i == null) {
      first[n.view.ieee] = merged.length;
      merged.add(n);
    } else {
      final m = merged[i];
      merged[i] = ZbNeed(m.kind, m.view, '${m.detail} · ${n.detail}');
    }
  }
  return merged;
}
