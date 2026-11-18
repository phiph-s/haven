import 'dart:async';

import '../haven_repository.dart';
import '../models/room_heating.dart';
import 'ha_client.dart';

/// Heizungsregelung gegen die Integration (`haven/heating/*`). Live-Status
/// über das Ereignis `haven_heating_updated`.
class HaHeating {
  HaHeating(this.client) {
    _updates = StreamController<HeatingUpdate>.broadcast(
      onListen: _subscribe,
      onCancel: _unsubscribe,
    );
  }

  final HaClient client;
  late final StreamController<HeatingUpdate> _updates;
  final StreamController<void> _changed = StreamController<void>.broadcast();
  int? _handle;

  static const updatedEvent = 'haven_heating_updated';

  Stream<HeatingUpdate> get updates => _updates.stream;
  Stream<void> get changed => _changed.stream;

  /// Bei `haven_data_updated` (`kind: heating`) und nach jedem Verbinden.
  void notifyChanged() {
    if (!_changed.isClosed) _changed.add(null);
  }

  /// Rohes Ereignis zu einem Update, `null` bei Unbrauchbarem.
  static HeatingUpdate? parseEvent(dynamic event) {
    final data = (event as Map?)?['data'];
    if (data is! Map || data['area_id'] is! String || data['status'] is! Map) {
      return null;
    }
    return (
      areaId: data['area_id'] as String,
      status: HeatingStatus.fromJson(
        Map<String, dynamic>.from(data['status'] as Map),
      ),
    );
  }

  Future<void> _subscribe() async {
    if (_handle != null) return;
    try {
      _handle = await client.subscribe(
        {'type': 'subscribe_events', 'event_type': updatedEvent},
        (e) {
          final u = parseEvent(e);
          if (u != null && !_updates.isClosed) _updates.add(u);
        },
      );
    } catch (_) {
      // Ohne Admin kein Abo: Der Status kommt dann mit jedem Neuladen.
    }
  }

  Future<void> _unsubscribe() async {
    final h = _handle;
    _handle = null;
    if (h != null) await client.unsubscribe(h);
  }

  Future<Map<String, dynamic>> _send(
    String type, [
    Map<String, dynamic> payload = const {},
  ]) async {
    final r = await client.send({'type': type, ...payload});
    return r is Map ? Map<String, dynamic>.from(r) : const {};
  }

  Future<HeatingRooms> list() async {
    try {
      return HeatingRooms.fromJson(await _send('haven/heating/list'));
    } on HavenException catch (e) {
      if (e.code == 'unknown_command') return HeatingRooms.unsupported;
      rethrow;
    }
  }

  Future<RoomHeating> save(HeatingConfig c) async => RoomHeating.fromJson(
    await _send('haven/heating/set', {'config': c.toJson()}),
  );

  Future<void> delete(String areaId) =>
      _send('haven/heating/delete', {'area_id': areaId});

  Future<HeatingStatus> control(
    String areaId, {
    double? target,
    HeatingMode? mode,
  }) async {
    final r = await _send('haven/heating/control', {
      'area_id': areaId,
      'target': ?target,
      'mode': ?mode?.wire,
    });
    final s = r['status'];
    return s is Map
        ? HeatingStatus.fromJson(Map<String, dynamic>.from(s))
        : const HeatingStatus();
  }

  Future<void> dispose() async {
    await _updates.close();
    await _changed.close();
  }
}
