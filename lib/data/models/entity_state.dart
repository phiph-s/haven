import 'package:flutter/foundation.dart';

/// Zustand einer Home-Assistant-Entity, wie HA ihn liefert.
@immutable
class EntityState {
  const EntityState(
    this.entityId,
    this.state, [
    this.attributes = const <String, dynamic>{},
  ]);

  factory EntityState.fromJson(Map<String, dynamic> j) => EntityState(
    j['entity_id'] as String,
    (j['state'] ?? 'unknown').toString(),
    Map<String, dynamic>.from((j['attributes'] as Map?) ?? const {}),
  );

  final String entityId;
  final String state;
  final Map<String, dynamic> attributes;

  String get domain => entityId.split('.').first;
  bool get isOn => state == 'on';
  bool get isAvailable => state != 'unavailable' && state != 'unknown';

  String get name =>
      (attributes['friendly_name'] as String?) ?? entityId.split('.').last;

  /// Zahl aus dem Zustand, `null` bei unavailable und Text.
  double? get number => double.tryParse(state);

  String? get unit => attributes['unit_of_measurement'] as String?;
  String? get deviceClass => attributes['device_class'] as String?;

  EntityState copyWith({String? state, Map<String, dynamic>? attributes}) =>
      EntityState(entityId, state ?? this.state, attributes ?? this.attributes);

  @override
  bool operator ==(Object other) =>
      other is EntityState &&
      other.entityId == entityId &&
      other.state == state &&
      mapEquals(other.attributes, attributes);

  @override
  int get hashCode => Object.hash(entityId, state, attributes.length);
}
