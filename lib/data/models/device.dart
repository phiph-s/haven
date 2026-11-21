import 'package:flutter/foundation.dart';

/// Ein HA-Gerät mit seinen Haupt-Entities (ohne Diagnose und Konfiguration).
/// Kommt aus `haven/rooms` (`rooms[].devices` ab Integration 0.2.0 und
/// `unassigned`). Grundlage für den Pool im Grundriss-Editor.
@immutable
class HavenDevice {
  const HavenDevice({
    required this.id,
    required this.name,
    required this.entityIds,
    this.ieee,
    this.areaId,
    this.manufacturer,
    this.model,
    this.protocol,
    this.swVersion,
  });

  factory HavenDevice.fromJson(Map<String, dynamic> j, {String? areaId}) =>
      HavenDevice(
        id: '${j['device_id']}',
        name: '${j['name'] ?? j['device_id']}',
        entityIds: [for (final e in (j['entities'] as List? ?? const [])) '$e'],
        ieee: j['ieee'] as String?,
        areaId: areaId ?? j['area_id'] as String?,
        manufacturer: j['manufacturer'] as String?,
        model: j['model'] as String?,
        protocol: DeviceProtocol.parse(j['protocol'], ieee: j['ieee']),
        swVersion: j['sw_version'] as String?,
      );

  /// HA-Geräte-ID.
  final String id;
  final String name;
  final List<String> entityIds;

  /// Gesetzt bei Zigbee-Geräten.
  final String? ieee;
  final String? areaId;
  final String? manufacturer;
  final String? model;

  /// Funkprotokoll (Zigbee aus [ieee], Matter/Z-Wave von der Integration
  /// ab 0.6.34), `null`: unbekannt (WLAN, Cloud, ältere Integration).
  final DeviceProtocol? protocol;

  /// Firmware, nur bei Matter und Z-Wave.
  final String? swVersion;

  bool get isZigbee => ieee != null;
  bool get isMatter => protocol == DeviceProtocol.matter;
}

/// Funkprotokoll eines Geräts.
enum DeviceProtocol {
  zigbee('Zigbee'),
  matter('Matter'),
  zwave('Z-Wave');

  const DeviceProtocol(this.label);
  final String label;

  static DeviceProtocol? parse(Object? v, {Object? ieee}) => switch (v) {
    'matter' => matter,
    'zwave' => zwave,
    'zigbee' => zigbee,
    _ => ieee is String ? zigbee : null,
  };
}
