import 'dart:async';

import '../haven_repository.dart';
import '../models/zigbee.dart';
import '../models/zigbee_network.dart';
import 'ha_client.dart';

/// Zigbee gegen die Haven-Integration. Lesebefehle sind im Vertrag
/// (integration/README.md), die Schreibbefehle sind TODO: Die Integration
/// kennt sie noch nicht, die App bekommt dann `unknown_command` und zeigt
/// eine verständliche Meldung. Nicht gegen ein echtes HA geprüft.
class HaZigbee {
  HaZigbee(this.client) {
    _events = StreamController<ZbEvent>.broadcast(
      onListen: _subscribe,
      onCancel: _unsubscribe,
    );
  }

  final HaClient client;
  late final StreamController<ZbEvent> _events;
  int? _handle;

  Stream<ZbEvent> get events => _events.stream;

  Future<void> _subscribe() async {
    if (_handle != null) return;
    try {
      _handle = await client.subscribe({'type': 'haven/subscribe_zigbee'}, (e) {
        if (e is Map && !_events.isClosed) {
          _events.add(ZbEvent.fromJson(Map<String, dynamic>.from(e)));
        }
      });
    } catch (_) {
      // Ohne Abo bleibt die Liste auf dem Stand des letzten Ladens.
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
    try {
      final r = await client.send({'type': type, ...payload});
      return r is Map ? Map<String, dynamic>.from(r) : const {};
    } on HavenException catch (e) {
      if (e.code == 'unknown_command' || e.code == 'not_found') {
        throw HavenException(
          'Das kann die Haven-Integration in Home Assistant noch nicht ($type).',
          code: e.code,
        );
      }
      rethrow;
    }
  }

  Future<List<ZbDevice>> devices() async {
    final r = await _send('haven/zigbee/devices');
    return [
      for (final d in (r['devices'] as List? ?? []))
        if (d is Map) ZbDevice.fromJson(Map<String, dynamic>.from(d)),
    ];
  }

  Future<ZbDevice> device(String ieee) async =>
      ZbDevice.fromJson(await _send('haven/zigbee/device', {'ieee': ieee}));

  Future<List<ZbGroup>> groups() async {
    final r = await _send('haven/zigbee/groups');
    return [
      for (final g in (r['groups'] as List? ?? []))
        if (g is Map) ZbGroup.fromJson(Map<String, dynamic>.from(g)),
    ];
  }

  Future<ZbBridgeInfo> info() async {
    final r = await _send('haven/info');
    final z = r['z2m'];
    return z is Map
        ? ZbBridgeInfo.fromJson(Map<String, dynamic>.from(z))
        : ZbBridgeInfo.empty;
  }

  Future<Map<String, Map<String, dynamic>>> states() async {
    try {
      final r = await _send('haven/zigbee/state'); // TODO Integration
      final m = r['states'];
      return {
        if (m is Map)
          for (final e in m.entries)
            '${e.key}': Map<String, dynamic>.from(e.value as Map),
      };
    } on HavenException {
      return const {};
    }
  }

  Future<void> set(String ieee, Map<String, dynamic> values) =>
      _send('haven/zigbee/set', {'ieee': ieee, 'values': values});

  Future<void> rename(String ieee, String name, bool renameHa) => _send(
    'haven/zigbee/rename',
    {'ieee': ieee, 'name': name, 'rename_ha_entities': renameHa},
  );

  Future<void> setArea(String ieee, String? areaId) =>
      _send('haven/zigbee/set_area', {'ieee': ieee, 'area_id': areaId});

  Future<void> identify(String ieee) =>
      _send('haven/zigbee/identify', {'ieee': ieee});

  Future<void> interview(String ieee) =>
      _send('haven/zigbee/interview', {'ieee': ieee});

  Future<void> remove(String ieee, bool force) =>
      _send('haven/zigbee/remove', {'ieee': ieee, 'force': force});

  Future<void> permitJoin(int seconds, String? via) =>
      _send('haven/zigbee/permit_join', {'time': seconds, 'device': via});

  /// `haven/zigbee/networkmap` (Integration parallel in Arbeit, nur Vertrag).
  Future<ZbNetworkMap> networkMap(bool refresh) async => ZbNetworkMap.fromJson(
    await _send('haven/zigbee/networkmap', {'refresh': refresh}),
  );

  Future<void> dispose() async {
    await _unsubscribe();
    await _events.close();
  }
}
