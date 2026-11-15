import 'package:flutter/foundation.dart';

import '../../data/models/entity_state.dart';
import '../../data/models/floor_plan.dart';
import '../../data/models/light_groups.dart';
import '../../data/models/snapshot.dart';
import '../../data/models/zigbee.dart';

/// Ein Gerät im Pool des Grundriss-Editors. Platziert wird das Gerät: Die
/// Position gilt für [mainEntityId], die übrigen [entityIds] erben sie.
@immutable
class PoolDevice {
  const PoolDevice({
    required this.id,
    required this.name,
    required this.mainEntityId,
    required this.entityIds,
    required this.kind,
    required this.iconType,
    this.areaId,
    this.zigbee = false,
  });

  /// IEEE bei Zigbee, sonst HA-Geräte-ID (oder die Entity, wenn die
  /// Integration keine Geräte liefert).
  final String id;
  final String name;
  final String mainEntityId;

  /// Hauptentity zuerst.
  final List<String> entityIds;
  final FloorKind kind;

  /// `ZbType` für `ZbDeviceIcon`.
  final String iconType;
  final String? areaId;
  final bool zigbee;

  FloorDevice get floorDevice => FloorDevice(id, entityIds, roomId: areaId);
}

/// Geräte eines Raums im Pool.
@immutable
class PoolRoomGroup {
  const PoolRoomGroup({
    required this.title,
    required this.areaId,
    required this.devices,
    required this.placed,
  });

  final String title;

  /// HA-Bereich, `null` für „Ohne Raum“.
  final String? areaId;

  /// Noch nicht platzierte Geräte.
  final List<PoolDevice> devices;

  /// Schon platziert (für den Fortschritt).
  final int placed;
}

/// Ein Abschnitt: „Zigbee-Geräte“ oder „Weitere Geräte“.
@immutable
class PoolSection {
  const PoolSection({
    required this.title,
    required this.groups,
    required this.total,
    required this.placed,
  });
  final String title;
  final List<PoolRoomGroup> groups;
  final int total;
  final int placed;

  int get open => total - placed;
}

@immutable
class DevicePool {
  const DevicePool({
    required this.zigbee,
    required this.other,
    required this.all,
  });
  final PoolSection zigbee;
  final PoolSection other;

  /// Alle Geräte (platziert oder nicht), für Migration und Karte.
  final List<PoolDevice> all;

  int get open => zigbee.open + other.open;
}

const kNoRoom = 'Ohne Raum';

/// Baut den Pool aus Zigbee-Geräten ([zigbee], mit `ha_entities`) und den
/// übrigen HA-Geräten (`snapshot.devices`, ab Integration 0.2.0). Ohne
/// Geräteliste (Integration 0.1.0) werden die Lampen und Klimasensoren der
/// Räume, die zu keinem Zigbee-Gerät gehören, einzeln angeboten.
DevicePool buildDevicePool(
  HavenSnapshot s,
  List<ZbDevice> zigbee,
  HavenFloorPlan plan,
) {
  final zb = <PoolDevice>[];
  final taken = <String>{};
  for (final d in zigbee) {
    if (d.isCoordinator || d.disabled) continue;
    final ents = d.haEntities.isNotEmpty
        ? d.haEntities
        : _guessEntities(d, s.entities);
    final main = zigbeeMainEntity(d.deviceType, ents, s.entities);
    if (main == null) continue;
    taken.addAll(ents);
    zb.add(
      PoolDevice(
        id: d.ieee,
        name: d.friendlyName,
        mainEntityId: main,
        entityIds: [
          main,
          for (final e in ents)
            if (e != main) e,
        ],
        kind: _kindOfZigbee(d.deviceType, main),
        iconType: d.deviceType,
        areaId: d.areaId,
        zigbee: true,
      ),
    );
  }

  final other = <PoolDevice>[];
  if (s.devices.isNotEmpty) {
    for (final d in s.devices) {
      if (d.ieee != null || d.entityIds.any(taken.contains)) continue;
      final ents = [
        for (final id in d.entityIds)
          if (_useful(id, s.entities[id])) id,
      ];
      if (ents.isEmpty) continue;
      ents.sort(
        (a, b) => _rank(a, s.entities[a]).compareTo(_rank(b, s.entities[b])),
      );
      final main = ents.first;
      other.add(
        PoolDevice(
          id: d.id,
          name: d.name,
          mainEntityId: main,
          entityIds: [
            main,
            for (final e in d.entityIds)
              if (e != main) e,
          ],
          kind: _kindOfEntity(main, s.entities[main]),
          iconType: _iconOfEntity(main, s.entities[main]),
          areaId: d.areaId,
        ),
      );
    }
  } else {
    // Integration 0.1.0: einzelne Entities aus den Räumen.
    for (final r in s.rooms) {
      for (final id in [...r.lightIds, ?r.temperatureId]) {
        final e = s.entities[id];
        if (taken.contains(id) || e == null || !_useful(id, e)) continue;
        taken.add(id);
        other.add(
          PoolDevice(
            id: id,
            name: e.name,
            mainEntityId: id,
            entityIds: [id],
            kind: _kindOfEntity(id, e),
            iconType: _iconOfEntity(id, e),
            areaId: r.areaId ?? r.id,
          ),
        );
      }
    }
  }

  return DevicePool(
    zigbee: _section('Zigbee-Geräte', zb, s, plan),
    other: _section('Weitere Geräte', other, s, plan),
    all: [...zb, ...other],
  );
}

/// `true`, wenn das Gerät (über eine seiner Entities oder `deviceId`) schon
/// im Plan steht.
bool isPlaced(PoolDevice d, HavenFloorPlan plan) {
  for (final p in plan.placements) {
    if (p.deviceId == d.id || d.entityIds.contains(p.entityId)) return true;
  }
  return false;
}

PoolSection _section(
  String title,
  List<PoolDevice> devices,
  HavenSnapshot s,
  HavenFloorPlan plan,
) {
  final names = {for (final r in s.rooms) r.areaId ?? r.id: r.name};
  final order = [for (final r in s.rooms) r.areaId ?? r.id];
  final byArea = <String?, List<PoolDevice>>{};
  final placedBy = <String?, int>{};
  var placed = 0;
  for (final d in devices) {
    final area = names.containsKey(d.areaId) ? d.areaId : null;
    if (isPlaced(d, plan)) {
      placed++;
      placedBy[area] = (placedBy[area] ?? 0) + 1;
    } else {
      (byArea[area] ??= []).add(d);
    }
  }
  final areas = {...byArea.keys, ...placedBy.keys}.toList()
    ..sort((a, b) {
      if (a == null) return 1;
      if (b == null) return -1;
      return order.indexOf(a).compareTo(order.indexOf(b));
    });
  return PoolSection(
    title: title,
    total: devices.length,
    placed: placed,
    groups: [
      for (final a in areas)
        if ((byArea[a] ?? const []).isNotEmpty)
          PoolRoomGroup(
            title: a == null ? kNoRoom : names[a]!,
            areaId: a,
            devices: (byArea[a]!..sort(_byKindThenName)),
            placed: placedBy[a] ?? 0,
          ),
    ],
  );
}

int _byKindThenName(PoolDevice a, PoolDevice b) {
  final c = a.kind.index.compareTo(b.kind.index);
  return c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

/// Entities eines Zigbee-Geräts ohne `ha_entities` (ältere Integration): über
/// den Namen.
List<String> _guessEntities(ZbDevice d, Map<String, EntityState> all) {
  final slug = d.friendlyName
      .toLowerCase()
      .replaceAll('ä', 'a')
      .replaceAll('ö', 'o')
      .replaceAll('ü', 'u')
      .replaceAll('ß', 'ss')
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  if (slug.isEmpty) return const [];
  return [
    for (final id in all.keys)
      if (id.split('.').last == slug ||
          id.split('.').last.startsWith('${slug}_'))
        id,
  ]..sort();
}

/// Hauptentity eines Zigbee-Geräts nach seinem Typ.
@visibleForTesting
String? zigbeeMainEntity(
  String type,
  List<String> ents,
  Map<String, EntityState> all,
) {
  String? first(bool Function(String id, EntityState? e) test) {
    for (final id in ents) {
      if (test(id, all[id])) return id;
    }
    return null;
  }

  String? shortest(bool Function(String id) test) {
    String? best;
    for (final id in ents) {
      if (test(id) && (best == null || id.length < best.length)) best = id;
    }
    return best;
  }

  bool dom(String id, String d) => id.startsWith('$d.');
  bool ends(String id, List<String> s) => s.any((x) => id.endsWith('_$x'));
  final bySlot = switch (type) {
    ZbType.light => first(
      (id, e) => dom(id, 'light') && (e == null || !isLightGroup(e)),
    ),
    ZbType.plug || ZbType.switch_ || ZbType.relay =>
      // Der Schalter ohne Zusatz (`switch.x`), nicht `switch.x_child_lock`.
      shortest((id) => dom(id, 'switch')) ?? shortest((id) => dom(id, 'light')),
    ZbType.climate => first(
      (id, e) =>
          dom(id, 'sensor') &&
          (e?.deviceClass == 'temperature' || id.endsWith('_temperature')),
    ),
    ZbType.motion || ZbType.presence => first(
      (id, _) =>
          dom(id, 'binary_sensor') &&
          ends(id, ['occupancy', 'presence', 'motion']),
    ),
    ZbType.contact => first(
      (id, _) =>
          dom(id, 'binary_sensor') && ends(id, ['contact', 'door', 'window']),
    ),
    ZbType.remote || ZbType.knob =>
      first((id, _) => dom(id, 'event')) ??
          first((id, _) => dom(id, 'sensor') && ends(id, ['action'])) ??
          first((id, _) => dom(id, 'sensor') && ends(id, ['battery'])),
    ZbType.thermostat => first((id, _) => dom(id, 'climate')),
    _ => null,
  };
  if (bySlot != null) return bySlot;
  final useful = [
    for (final id in ents)
      if (_useful(id, all[id])) id,
  ]..sort((a, b) => _rank(a, all[a]).compareTo(_rank(b, all[b])));
  return useful.firstOrNull ?? ents.firstOrNull;
}

FloorKind _kindOfZigbee(String type, String main) => switch (type) {
  ZbType.light => FloorKind.light,
  ZbType.plug || ZbType.switch_ || ZbType.relay =>
    main.startsWith('light.') ? FloorKind.light : FloorKind.switchKind,
  ZbType.climate || ZbType.thermostat => FloorKind.temperature,
  ZbType.motion || ZbType.presence => FloorKind.presence,
  ZbType.contact => FloorKind.contact,
  ZbType.remote || ZbType.knob => FloorKind.remote,
  _ => FloorKind.ofEntity(main),
};

FloorKind _kindOfEntity(String id, EntityState? e) {
  final d = id.split('.').first;
  if (d == 'binary_sensor' &&
      const {
        'door',
        'window',
        'opening',
        'garage_door',
      }.contains(e?.deviceClass)) {
    return FloorKind.contact;
  }
  if (d == 'sensor' && e?.deviceClass == 'humidity') {
    return FloorKind.temperature;
  }
  return FloorKind.ofEntity(id);
}

String _iconOfEntity(String id, EntityState? e) =>
    switch (_kindOfEntity(id, e)) {
      FloorKind.light => ZbType.light,
      FloorKind.switchKind => ZbType.plug,
      FloorKind.temperature =>
        id.startsWith('climate.') ? ZbType.thermostat : ZbType.climate,
      FloorKind.presence => ZbType.motion,
      FloorKind.contact => ZbType.contact,
      FloorKind.remote => ZbType.remote,
      FloorKind.media || FloorKind.device => ZbType.unknown,
    };

/// Sinnvoll für den Grundriss: Lichter, Schalter, Klima, Medien, Melder.
/// Nie Diagnose- oder Einstellungs-Domains (`update`, `button`, `number`,
/// `select`, ...), keine Lichtgruppen und keine Zähler-Sensoren.
bool _useful(String id, EntityState? e) {
  final d = id.split('.').first;
  switch (d) {
    case 'light':
      return e == null || !isLightGroup(e);
    case 'switch' ||
        'climate' ||
        'media_player' ||
        'cover' ||
        'fan' ||
        'vacuum' ||
        'lock':
      return true;
    case 'sensor':
      return const {'temperature', 'humidity'}.contains(e?.deviceClass);
    case 'binary_sensor':
      return const {
        'motion',
        'occupancy',
        'presence',
        'door',
        'window',
        'opening',
      }.contains(e?.deviceClass);
  }
  return false;
}

int _rank(String id, EntityState? e) => switch (id.split('.').first) {
  'light' => 0,
  'climate' => 1,
  'media_player' => 2,
  'switch' => 3,
  'cover' || 'fan' || 'vacuum' || 'lock' => 4,
  'binary_sensor' => 5,
  'sensor' => e?.deviceClass == 'temperature' ? 6 : 7,
  _ => 9,
};
