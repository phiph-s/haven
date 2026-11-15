import 'package:flutter/foundation.dart';

/// Modelle für Zigbee2MQTT-Geräte, wie die Haven-Integration sie liefert
/// (`haven/zigbee/devices`, `haven/zigbee/device`, siehe integration/README.md).
/// Parser sind nachsichtig: Fehlende Felder werden `null`, nichts wirft.

String? _s(dynamic v) => v?.toString();
num? _n(dynamic v) => v is num ? v : (v is String ? num.tryParse(v) : null);
List<Map<String, dynamic>> _maps(dynamic v) => [
  if (v is List)
    for (final e in v)
      if (e is Map) Map<String, dynamic>.from(e),
];

/// Gerätetypen der Klassifizierung.
abstract final class ZbType {
  static const light = 'light';
  static const plug = 'plug_meter';
  static const switch_ = 'switch';
  static const relay = 'relay';
  static const climate = 'climate_sensor';
  static const motion = 'motion';
  static const presence = 'presence';
  static const contact = 'contact';
  static const remote = 'remote';
  static const knob = 'knob';
  static const thermostat = 'thermostat';
  static const unknown = 'unknown';
}

@immutable
class ZbEnumValue {
  const ZbEnumValue(this.value, this.label);
  final String value;
  final String label;
}

@immutable
class ZbPreset {
  const ZbPreset(this.name, this.value, [this.description]);
  final String name;
  final dynamic value;
  final String? description;
}

/// Ein Z2M-Feature (Expose) mit deutschem Label und Hilfetext.
@immutable
class ZbFeature {
  const ZbFeature({
    required this.property,
    required this.label,
    this.help,
    this.area = 'settings',
    this.group,
    this.type = 'text',
    this.canRead = true,
    this.canWrite = false,
    this.source = 'table',
    this.unit,
    this.min,
    this.max,
    this.step,
    this.valueOn,
    this.valueOff,
    this.valueToggle,
    this.presets = const [],
    this.values = const [],
    this.parent,
    this.endpoint,
    this.features = const [],
  });

  factory ZbFeature.fromJson(Map<String, dynamic> j) {
    final access = j['access'] is Map ? j['access'] as Map : const {};
    return ZbFeature(
      property: _s(j['property']) ?? '',
      label: _s(j['label']) ?? _s(j['property']) ?? '',
      help: _s(j['help']),
      area: _s(j['area']) ?? 'settings',
      group: _s(j['group']),
      type: _s(j['type']) ?? 'text',
      canRead: access['read'] != false,
      canWrite: access['write'] == true,
      source: _s(j['source']) ?? 'table',
      unit: _s(j['unit']),
      min: _n(j['min']),
      max: _n(j['max']),
      step: _n(j['step']),
      valueOn: j['value_on'],
      valueOff: j['value_off'],
      valueToggle: j['value_toggle'],
      presets: [
        for (final p in _maps(j['presets']))
          ZbPreset(_s(p['name']) ?? '', p['value'], _s(p['description'])),
      ],
      values: [
        for (final v in _maps(j['values']))
          ZbEnumValue(_s(v['value']) ?? '', _s(v['label']) ?? _s(v['value'])!),
      ],
      parent: _s(j['parent']),
      endpoint: _s(j['endpoint']),
      features: [for (final f in _maps(j['features'])) ZbFeature.fromJson(f)],
    );
  }

  final String property;
  final String label;
  final String? help;
  final String area;
  final String? group;

  /// `binary`, `numeric`, `enum`, `text` oder `composite`.
  final String type;
  final bool canRead;
  final bool canWrite;

  /// `table` (gepflegt) oder `generic` (Rückfall, Label nur humanisiert).
  final String source;
  final String? unit;
  final num? min;
  final num? max;
  final num? step;
  final dynamic valueOn;
  final dynamic valueOff;
  final dynamic valueToggle;
  final List<ZbPreset> presets;
  final List<ZbEnumValue> values;
  final String? parent;
  final String? endpoint;
  final List<ZbFeature> features;

  bool get isBinary => type == 'binary';
  bool get isEnum => type == 'enum';
  bool get isNumeric => type == 'numeric';

  /// Deutsches Label zu einem Enum-Wert, sonst der Wert selbst.
  String labelOf(dynamic value) {
    final s = value?.toString();
    for (final v in values) {
      if (v.value == s) return v.label;
    }
    return s ?? '–';
  }

  /// Ist der binäre Wert [v] der Einschaltwert?
  bool isOn(dynamic v) {
    if (v == null) return false;
    if (valueOn != null) return v.toString() == valueOn.toString();
    if (v is bool) return v;
    final s = v.toString().toUpperCase();
    return s == 'ON' || s == 'TRUE' || s == '1';
  }

  /// Z2M-Wert zum Schalten.
  dynamic binaryValue(bool on) => on ? (valueOn ?? true) : (valueOff ?? false);
}

/// Klassifizierung eines Geräts (`classified`).
@immutable
class ZbClassified {
  const ZbClassified({
    this.deviceType = ZbType.unknown,
    this.capabilities = const [],
    this.primary = const [],
    this.settings = const [],
    this.diagnostic = const [],
    this.hidden = const [],
    this.settingGroups = const [],
  });

  factory ZbClassified.fromJson(Map<String, dynamic> j) => ZbClassified(
    deviceType: _s(j['device_type']) ?? ZbType.unknown,
    capabilities: [for (final c in (j['capabilities'] as List? ?? [])) '$c'],
    primary: [for (final f in _maps(j['primary'])) ZbFeature.fromJson(f)],
    settings: [for (final f in _maps(j['settings'])) ZbFeature.fromJson(f)],
    diagnostic: [for (final f in _maps(j['diagnostic'])) ZbFeature.fromJson(f)],
    hidden: [for (final f in _maps(j['hidden'])) ZbFeature.fromJson(f)],
    settingGroups: [for (final g in (j['setting_groups'] as List? ?? [])) '$g'],
  );

  static const empty = ZbClassified();

  final String deviceType;
  final List<String> capabilities;
  final List<ZbFeature> primary;
  final List<ZbFeature> settings;
  final List<ZbFeature> diagnostic;
  final List<ZbFeature> hidden;
  final List<String> settingGroups;

  /// Einstellungen ohne die Aktion „identify“, nach Gruppe in der Reihenfolge
  /// [settingGroups]. Einstellungen ohne Gruppe kommen zuletzt unter „Weitere“.
  List<(String, List<ZbFeature>)> get groupedSettings {
    final rest = [
      for (final f in settings)
        if (f.property != 'identify') f,
    ];
    final order = [...settingGroups];
    for (final f in rest) {
      final g = f.group ?? 'Weitere';
      if (!order.contains(g)) order.add(g);
    }
    return [
      for (final g in order)
        if (rest.any((f) => (f.group ?? 'Weitere') == g))
          (
            g,
            [
              for (final f in rest)
                if ((f.group ?? 'Weitere') == g) f,
            ],
          ),
    ];
  }

  bool get canIdentify => settings.any((f) => f.property == 'identify');

  ZbFeature? primaryOf(String property) {
    for (final f in primary) {
      if (f.property == property) return f;
    }
    return null;
  }
}

/// Ein Zigbee-Gerät (Listeneintrag, bei `haven/zigbee/device` mit
/// [classified]).
@immutable
class ZbDevice {
  const ZbDevice({
    required this.ieee,
    required this.friendlyName,
    this.type = 'EndDevice',
    this.vendor,
    this.model,
    this.description,
    this.powerSource,
    this.image,
    this.supported = true,
    this.disabled = false,
    this.interviewCompleted = true,
    this.deviceType = ZbType.unknown,
    this.capabilities = const [],
    this.classified = ZbClassified.empty,
    this.haEntities = const [],
    this.areaId,
    this.hasAreaInfo = false,
  });

  factory ZbDevice.fromJson(Map<String, dynamic> j) {
    final c = j['classified'] is Map
        ? ZbClassified.fromJson(Map<String, dynamic>.from(j['classified']))
        : ZbClassified.empty;
    final dt = _s(j['device_type']) ?? c.deviceType;
    return ZbDevice(
      ieee: _s(j['ieee']) ?? _s(j['ieee_address']) ?? '',
      friendlyName: _s(j['friendly_name']) ?? _s(j['ieee']) ?? '',
      type: _s(j['type']) ?? 'EndDevice',
      vendor: _s(j['vendor']),
      model: _s(j['model']),
      description: _s(j['description']),
      powerSource: _s(j['power_source']),
      image: _s(j['image']),
      supported: j['supported'] != false,
      disabled: j['disabled'] == true,
      interviewCompleted: j['interview_completed'] != false,
      deviceType: dt,
      capabilities: j['capabilities'] is List
          ? [for (final x in j['capabilities'] as List) '$x']
          : c.capabilities,
      classified: c,
      haEntities: [for (final e in (j['ha_entities'] as List? ?? [])) '$e'],
      areaId: _s(j['area_id']),
      hasAreaInfo: j.containsKey('area_id'),
    );
  }

  final String ieee;
  final String friendlyName;

  /// `Coordinator`, `Router` oder `EndDevice`.
  final String type;
  final String? vendor;
  final String? model;
  final String? description;
  final String? powerSource;
  final String? image;
  final bool supported;
  final bool disabled;
  final bool interviewCompleted;
  final String deviceType;
  final List<String> capabilities;
  final ZbClassified classified;

  /// HA-Entity-IDs des Geräts, falls die Integration sie liefert.
  final List<String> haEntities;

  /// HA-Bereich (Raum-ID). Nur gesetzt, wenn die Integration `area_id` liefert.
  final String? areaId;

  /// Die Integration liefert überhaupt Raumangaben (auch `null` = kein Raum).
  final bool hasAreaInfo;

  bool get isRouter => type == 'Router';
  bool get isCoordinator => type == 'Coordinator';
  bool get isBattery =>
      (powerSource ?? '').toLowerCase().contains('battery') ||
      (!isRouter && !isCoordinator && powerSource == null);

  /// Hersteller und Modell, z. B. „HOBEIAN ZG-204ZL“.
  String get modelLine =>
      [vendor, model].whereType<String>().where((s) => s.isNotEmpty).join(' ');

  ZbDevice copyWith({
    String? friendlyName,
    String? areaId,
    bool clearArea = false,
    bool? hasAreaInfo,
    ZbClassified? classified,
  }) => ZbDevice(
    ieee: ieee,
    friendlyName: friendlyName ?? this.friendlyName,
    type: type,
    vendor: vendor,
    model: model,
    description: description,
    powerSource: powerSource,
    image: image,
    supported: supported,
    disabled: disabled,
    interviewCompleted: interviewCompleted,
    deviceType: deviceType,
    capabilities: capabilities,
    classified: classified ?? this.classified,
    haEntities: haEntities,
    areaId: clearArea ? null : (areaId ?? this.areaId),
    hasAreaInfo: hasAreaInfo ?? this.hasAreaInfo,
  );
}

@immutable
class ZbGroup {
  const ZbGroup({
    required this.id,
    required this.friendlyName,
    this.memberIeees = const [],
  });

  factory ZbGroup.fromJson(Map<String, dynamic> j) => ZbGroup(
    id: (_n(j['id']) ?? 0).toInt(),
    friendlyName: _s(j['friendly_name']) ?? '',
    memberIeees: [
      for (final m in _maps(j['members']))
        if (m['ieee'] != null) '${m['ieee']}',
    ],
  );

  final int id;
  final String friendlyName;
  final List<String> memberIeees;
}

/// Zustand der Z2M-Bridge (`haven/info` → `z2m`).
@immutable
class ZbBridgeInfo {
  const ZbBridgeInfo({
    this.version,
    this.channel,
    this.coordinatorType,
    this.online = true,
    this.permitJoin = false,
    this.deviceCount,
  });

  factory ZbBridgeInfo.fromJson(Map<String, dynamic> j) => ZbBridgeInfo(
    version: _s(j['version']),
    channel: _n(j['channel'])?.toInt(),
    coordinatorType: _s(j['coordinator_type']),
    online: j['bridge_state'] == null || j['bridge_state'] == 'online',
    permitJoin: j['permit_join'] == true,
    deviceCount: _n(j['device_count'])?.toInt(),
  );

  static const empty = ZbBridgeInfo();

  final String? version;

  /// Funkkanal. Steht nicht im Vertrag von `haven/info`, siehe Bericht.
  final int? channel;
  final String? coordinatorType;
  final bool online;
  final bool permitJoin;
  final int? deviceCount;
}

/// Ereignis aus `haven/subscribe_zigbee` bzw. des `FakeRepository`.
@immutable
class ZbEvent {
  const ZbEvent(this.kind, this.data);

  /// `devices`, `groups`, `info`, `state`, `event`.
  final String kind;
  final Map<String, dynamic> data;

  factory ZbEvent.fromJson(Map<String, dynamic> j) {
    final kind = _s(j['kind']) ?? 'event';
    return ZbEvent(kind, Map<String, dynamic>.from(j)..remove('kind'));
  }

  /// Bei `kind == 'event'`: Bridge-Ereignis, z. B. `device_joined`.
  String? get bridgeType {
    final e = data['event'];
    return e is Map ? _s(e['type']) : null;
  }

  Map<String, dynamic> get bridgeData {
    final e = data['event'];
    final d = e is Map ? e['data'] : null;
    return d is Map ? Map<String, dynamic>.from(d) : const {};
  }
}

/// Ergebnis von `permit_join`.
@immutable
class ZbPermitResult {
  const ZbPermitResult(this.seconds);
  final int seconds;
}
