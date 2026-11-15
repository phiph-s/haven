import 'dart:convert';
import 'dart:io';

import 'package:haven/data/models/entity_state.dart';

import 'fake_ha.dart';

/// Anonymisierte Antworten einer echten HA-Installation (Integration 0.1.0,
/// 2026-11-15), gekürzt auf die Entities der Räume und Zigbee-Geräte. Namen,
/// Räume, Entity-IDs und IEEE-Adressen sind ersetzt, die Struktur ist echt.
dynamic liveJson(String name) =>
    jsonDecode(File('test/fixtures/ha/$name.json').readAsStringSync());

Map<String, dynamic> liveRooms() =>
    Map<String, dynamic>.from(liveJson('rooms') as Map);
Map<String, dynamic> liveGroups() =>
    Map<String, dynamic>.from(liveJson('zigbee_groups') as Map);
Map<String, dynamic> liveDevices() =>
    Map<String, dynamic>.from(liveJson('zigbee_devices') as Map);
List<dynamic> liveStates() => liveJson('get_states') as List;

Map<String, EntityState> liveEntities() => {
  for (final s in liveStates())
    (s as Map)['entity_id'] as String: EntityState.fromJson(
      Map<String, dynamic>.from(s),
    ),
};

/// Fake-HA, das auf die Befehle mit den Live-Antworten reagiert. [answers]
/// überschreibt einzelne Befehle (Rückgabe `null` = Erfolg ohne Inhalt,
/// [unknown] = HA kennt den Befehl nicht).
class LiveHa {
  LiveHa({this.prefsSupported = true});

  bool prefsSupported;
  final Map<String, dynamic Function(Map<String, dynamic> msg)> answers = {};
  final List<Map<String, dynamic>> received = [];
  final List<FakeChannel> channels = [];
  Map<String, dynamic> prefs = {'excluded_lights': <String>[]};
  static const unknown = Object();

  FakeChannel get channel => channels.last;

  /// Abo-IDs je Ereignistyp (`state_changed`, `device_registry_updated` ...).
  final Map<String, int> subscriptions = {};

  void respond(FakeServer server, Map<String, dynamic> m) {
    received.add(m);
    final type = m['type'] as String;
    dynamic result;
    var ok = true;
    final custom = answers[type];
    if (custom != null) {
      result = custom(m);
      ok = !identical(result, unknown);
    } else {
      switch (type) {
        case 'get_states':
          result = liveStates();
        case 'haven/rooms':
          result = liveRooms();
        case 'haven/zigbee/groups':
          result = liveGroups();
        case 'haven/zigbee/devices':
          result = liveDevices();
        case 'haven/info':
          result = liveJson('info');
        case 'haven/prefs/get':
          if (prefsSupported) {
            result = {'prefs': prefs};
          } else {
            ok = false;
          }
        case 'haven/prefs/set':
          if (prefsSupported) {
            prefs = Map<String, dynamic>.from(m['prefs'] as Map);
            result = {'ok': true, 'prefs': prefs};
          } else {
            ok = false;
          }
        case 'subscribe_events':
          subscriptions[m['event_type'] as String] = m['id'] as int;
          result = null;
        case 'call_service' || 'haven/subscribe_zigbee':
          result = null;
        default:
          ok = false;
      }
    }
    server.send({
      'id': m['id'],
      'type': 'result',
      'success': ok,
      'result': ok ? result : null,
      if (!ok)
        'error': {'code': 'unknown_command', 'message': 'Unknown command.'},
    });
  }

  /// HA-Ereignis an das passende Abo schicken.
  void fire(String eventType, [Map<String, dynamic> data = const {}]) {
    final id = subscriptions[eventType];
    if (id == null) throw StateError('Kein Abo für $eventType');
    channel.server.send({
      'id': id,
      'type': 'event',
      'event': {'event_type': eventType, 'data': data},
    });
  }

  List<Map<String, dynamic>> calls() => [
    for (final m in received)
      if (m['type'] == 'call_service') m,
  ];
}
