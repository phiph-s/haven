import 'package:flutter/foundation.dart';

import '../../core/light/color_math.dart';
import '../scene_look.dart';

/// Zustand einer Lampe in einer Szene: Soll (gespeichert in der Integration)
/// oder gemessen. JSON wie im Vertrag `scene_sync`: `{on, brightness,
/// kelvin, rgb}`, bei `on: false` sind die übrigen Felder `null`.
@immutable
class LampState {
  const LampState({required this.on, this.brightness, this.kelvin, this.rgb});

  static const off = LampState(on: false);

  final bool on;

  /// 0..100, `null` bei Lampen ohne Helligkeit.
  final int? brightness;

  /// Weißlicht. Schließt [rgb] aus.
  final int? kelvin;

  /// Farblicht im Farbmodus.
  final Rgb? rgb;

  /// Farbe für die Anzeige: [rgb], sonst aus [kelvin], sonst warmes Weiß.
  /// `null`, wenn die Lampe aus ist.
  Rgb? get color {
    if (!on) return null;
    if (rgb != null) return rgb;
    return kelvinToRgb(kelvin ?? 2700);
  }

  /// `null`, wenn [json] kein gültiger Zustand ist.
  static LampState? fromJson(Object? json) {
    if (json is! Map) return null;
    final on = json['on'];
    if (on is! bool) return null;
    if (!on) return off;
    final hex = json['rgb'];
    return LampState(
      on: true,
      brightness: (json['brightness'] as num?)?.round().clamp(0, 100),
      kelvin: (json['kelvin'] as num?)?.round(),
      rgb: hex is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)
          ? rgbFromHex(hex)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'on': on,
    'brightness': on ? brightness : null,
    'kelvin': on ? kelvin : null,
    'rgb': on && rgb != null ? hexOf(rgb!) : null,
  };

  /// Gleich im Sinne des Abgleichs: an/aus gleich, Helligkeit höchstens
  /// 8 Prozentpunkte daneben und die Farbe nah genug ([colorMatches]).
  bool matches(LampState other) {
    if (on != other.on) return false;
    if (!on) return true;
    if (!brightnessMatches(other)) return false;
    return colorMatches(other);
  }

  bool brightnessMatches(LampState other) {
    final a = brightness, b = other.brightness;
    return a == null || b == null || (a - b).abs() <= 8;
  }

  /// Weiß gegen Weiß: höchstens 300 K Unterschied, sonst je Kanal
  /// höchstens 40. Lampen ohne Farbe passen immer.
  bool colorMatches(LampState other) {
    if (!on || !other.on) return on == other.on;
    if (kelvin != null && other.kelvin != null) {
      return (kelvin! - other.kelvin!).abs() <= 300;
    }
    final hasA = rgb != null || kelvin != null;
    final hasB = other.rgb != null || other.kelvin != null;
    if (!hasA || !hasB) return true;
    final a = color!, b = other.color!;
    return (a.$1 - b.$1).abs() <= 40 &&
        (a.$2 - b.$2).abs() <= 40 &&
        (a.$3 - b.$3).abs() <= 40;
  }

  @override
  bool operator ==(Object other) =>
      other is LampState &&
      other.on == on &&
      other.brightness == brightness &&
      other.kelvin == kelvin &&
      other.rgb == rgb;

  @override
  int get hashCode => Object.hash(on, brightness, kelvin, rgb);

  @override
  String toString() => 'LampState(${toJson()})';
}

/// Ergebnis je Lampe.
enum SceneLampStatus {
  ok,

  /// Die Lampe hat auf die Szene nicht reagiert: sie kennt sie nicht.
  missing,

  /// Reagiert, aber Helligkeit oder Farbe weichen ab.
  differs,

  /// Lampe nicht erreichbar oder ohne Antwort.
  unreachable;

  static SceneLampStatus parse(Object? v) => switch (v) {
    'ok' => ok,
    'missing' => missing,
    'unreachable' => unreachable,
    _ => differs,
  };
}

/// Eine Lampe in der Messung einer Szene.
@immutable
class SceneLampCheck {
  const SceneLampCheck({
    required this.entityId,
    required this.name,
    required this.status,
    this.expected,
    this.measured,
  });

  final String entityId;
  final String name;

  /// Soll, `null` = für diese Lampe kein Soll (z. B. neu in der Gruppe).
  final LampState? expected;

  /// Gemessen, `null` = nicht erreichbar.
  final LampState? measured;
  final SceneLampStatus status;

  /// Weicht nur in der Helligkeit ab, die Farbe passt.
  bool get brightnessOnly =>
      status == SceneLampStatus.differs &&
      expected != null &&
      measured != null &&
      expected!.on &&
      measured!.on &&
      expected!.colorMatches(measured!) &&
      !expected!.brightnessMatches(measured!);

  factory SceneLampCheck.fromJson(Map<String, dynamic> json) => SceneLampCheck(
    entityId: '${json['entity_id']}',
    name: '${json['name'] ?? json['entity_id']}',
    expected: LampState.fromJson(json['expected']),
    measured: LampState.fromJson(json['measured']),
    status: SceneLampStatus.parse(json['status']),
  );

  Map<String, dynamic> toJson() => {
    'entity_id': entityId,
    'name': name,
    'expected': expected?.toJson(),
    'measured': measured?.toJson(),
    'status': status.name,
  };
}

/// Gesamtstatus laut Integration.
enum SceneCheckStatus {
  ok,
  differs,

  /// Kein Soll gespeichert.
  unknown;

  static SceneCheckStatus parse(Object? v) => switch (v) {
    'ok' => ok,
    'differs' => differs,
    _ => unknown,
  };
}

/// Was die Oberfläche zu einer gemessenen Szene sagt, das Wichtigste zuerst.
enum SceneCheckOutcome { ok, missing, differs, unreachable, noTarget }

/// Messung einer Szene (`haven/zigbee/scene_check` und `scene_repair`).
@immutable
class SceneCheck {
  const SceneCheck({
    required this.groupId,
    required this.sceneId,
    required this.name,
    required this.hasTarget,
    required this.status,
    required this.members,
    this.measuredLook,
    this.checkedAt,
  });

  final int groupId;
  final int sceneId;
  final String name;
  final bool hasTarget;
  final SceneCheckStatus status;
  final List<SceneLampCheck> members;

  /// Wie die Szene gemessen aussieht (wird beim Übernehmen der Look).
  final SceneLook? measuredLook;
  final DateTime? checkedAt;

  int count(SceneLampStatus s) => members.where((m) => m.status == s).length;

  SceneCheckOutcome get outcome {
    if (count(SceneLampStatus.missing) > 0) return SceneCheckOutcome.missing;
    if (count(SceneLampStatus.differs) > 0) return SceneCheckOutcome.differs;
    if (count(SceneLampStatus.unreachable) > 0) {
      return SceneCheckOutcome.unreachable;
    }
    if (!hasTarget) return SceneCheckOutcome.noTarget;
    if (status == SceneCheckStatus.differs) return SceneCheckOutcome.differs;
    return SceneCheckOutcome.ok;
  }

  /// Alle abweichenden Lampen weichen nur in der Helligkeit ab.
  bool get brightnessOnly {
    final d = members.where((m) => m.status == SceneLampStatus.differs);
    return d.isNotEmpty && d.every((m) => m.brightnessOnly);
  }

  /// So steht die Messung nach `scene_adopt` da: das Gemessene ist das Soll.
  /// Nicht erreichbare Lampen bleiben, wie sie sind.
  SceneCheck adopted() => SceneCheck(
    groupId: groupId,
    sceneId: sceneId,
    name: name,
    hasTarget: true,
    status: SceneCheckStatus.ok,
    measuredLook: measuredLook,
    checkedAt: checkedAt,
    members: [
      for (final m in members)
        m.measured == null
            ? m
            : SceneLampCheck(
                entityId: m.entityId,
                name: m.name,
                expected: m.measured,
                measured: m.measured,
                status: SceneLampStatus.ok,
              ),
    ],
  );

  factory SceneCheck.fromJson(Map<String, dynamic> json) => SceneCheck(
    groupId: (json['group_id'] as num).toInt(),
    sceneId: (json['scene_id'] as num).toInt(),
    name: '${json['name'] ?? ''}',
    hasTarget: json['has_target'] == true,
    status: SceneCheckStatus.parse(json['status']),
    members: [
      for (final m in (json['members'] as List? ?? const []))
        SceneLampCheck.fromJson(Map<String, dynamic>.from(m as Map)),
    ],
    measuredLook: SceneLook.fromJson(json['measured_look']),
    checkedAt: DateTime.tryParse('${json['checked_at'] ?? ''}'),
  );

  Map<String, dynamic> toJson() => {
    'group_id': groupId,
    'scene_id': sceneId,
    'name': name,
    'has_target': hasTarget,
    'status': status.name,
    'members': [for (final m in members) m.toJson()],
    'measured_look': measuredLook?.toJson(),
    'checked_at': checkedAt?.toUtc().toIso8601String(),
  };
}
