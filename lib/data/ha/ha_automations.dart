import 'dart:async';

import '../haven_repository.dart';
import '../models/haven_automation.dart';
import 'ha_client.dart';

/// Haven-Automationen gegen die Integration (`haven/automations/*`).
/// Nicht gegen ein echtes HA geprüft, nur gegen den Vertrag im README.
class HaAutomations {
  HaAutomations(this.client) {
    _triggers = StreamController<AutomationTrigger>.broadcast(
      onListen: _subscribe,
      onCancel: _unsubscribe,
    );
  }

  final HaClient client;
  late final StreamController<AutomationTrigger> _triggers;
  final StreamController<void> _changed = StreamController<void>.broadcast();
  int? _handle;

  static const triggeredEvent = 'haven_automation_triggered';

  Stream<AutomationTrigger> get triggers => _triggers.stream;
  Stream<void> get changed => _changed.stream;

  /// Vom Repository bei `haven_data_updated` (`kind: automations`) und nach
  /// jedem Verbinden aufgerufen.
  void notifyChanged() {
    if (!_changed.isClosed) _changed.add(null);
  }

  Future<void> _subscribe() async {
    if (_handle != null) return;
    try {
      _handle = await client.subscribe(
        {'type': 'subscribe_events', 'event_type': triggeredEvent},
        (e) {
          final t = AutomationTrigger.fromEvent(e);
          if (t != null && !_triggers.isClosed) _triggers.add(t);
        },
      );
    } catch (_) {
      // Ohne Admin erlaubt HA das Abo nicht. Der Live-Test nutzt dann nur
      // die Gerätezustände aus `haven/subscribe_zigbee`.
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

  Future<HavenAutomations> list() async {
    try {
      return HavenAutomations.fromJson(await _send('haven/automations/list'));
    } on HavenException catch (e) {
      if (e.code == 'unknown_command') return HavenAutomations.unsupported;
      rethrow;
    }
  }

  Future<HavenAutomation> save(HavenAutomation a) async {
    final r = await _send('haven/automations/set', {'automation': a.toJson()});
    final saved = r['automation'];
    return saved is Map
        ? HavenAutomation.fromJson(Map<String, dynamic>.from(saved))
        : a;
  }

  Future<void> delete(String id) =>
      _send('haven/automations/delete', {'automation_id': id});

  Future<void> test(String id, String action) =>
      _send('haven/automations/test', {'automation_id': id, 'action': action});

  Future<void> dispose() async {
    await _triggers.close();
    await _changed.close();
  }
}
