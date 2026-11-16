import 'package:flutter/foundation.dart';

/// Zustand einer Home-Assistant-Entity, wie HA ihn liefert.
@immutable
class EntityState {
  const EntityState(
    this.entityId,
    this.state, [
    this.attributes = const <String, dynamic>{},
    this.lastChanged,
  ]);

  factory EntityState.fromJson(Map<String, dynamic> j) => EntityState(
    j['entity_id'] as String,
    (j['state'] ?? 'unknown').toString(),
    Map<String, dynamic>.from((j['attributes'] as Map?) ?? const {}),
    DateTime.tryParse('${j['last_changed'] ?? ''}'),
  );

  final String entityId;
  final String state;
  final Map<String, dynamic> attributes;

  /// Letzter Wechsel des Zustands (`last_changed`), falls bekannt.
  final DateTime? lastChanged;

  String get domain => entityId.split('.').first;
  bool get isOn => state == 'on';
  bool get isAvailable => state != 'unavailable' && state != 'unknown';

  String get name =>
      (attributes['friendly_name'] as String?) ?? entityId.split('.').last;

  /// Zahl aus dem Zustand, `null` bei unavailable und Text.
  double? get number => double.tryParse(state);

  String? get unit => attributes['unit_of_measurement'] as String?;
  String? get deviceClass => attributes['device_class'] as String?;

  /// Neuer Zustand. Wechselt [state], gilt [changedAt] (sonst jetzt) als
  /// letzter Wechsel.
  EntityState copyWith({
    String? state,
    Map<String, dynamic>? attributes,
    DateTime? changedAt,
  }) => EntityState(
    entityId,
    state ?? this.state,
    attributes ?? this.attributes,
    state != null && state != this.state
        ? (changedAt ?? DateTime.now())
        : (changedAt ?? lastChanged),
  );

  @override
  bool operator ==(Object other) =>
      other is EntityState &&
      other.entityId == entityId &&
      other.state == state &&
      other.lastChanged == lastChanged &&
      mapEquals(other.attributes, attributes);

  @override
  int get hashCode => Object.hash(entityId, state, attributes.length);
}
