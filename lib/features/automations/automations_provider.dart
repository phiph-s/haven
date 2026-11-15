import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/providers.dart';
import 'automation_logic.dart';

/// Alle Abläufe, nach Name sortiert. Eigene Klasse mit `==`, damit Listen
/// nur bei echten Änderungen neu bauen.
@immutable
class AutomationList {
  const AutomationList(this.items, this.roomNames);
  final List<AutomationItem> items;
  final List<String> roomNames;

  @override
  bool operator ==(Object other) =>
      other is AutomationList &&
      listEquals(other.items, items) &&
      listEquals(other.roomNames, roomNames);

  @override
  int get hashCode => Object.hash(items.length, roomNames.length);
}

final _baseProvider = Provider<AutomationList>((ref) {
  final s = ref.watch(snapshotProvider);
  final rooms = [for (final r in s.rooms) r.name];
  return AutomationList([
    for (final e in s.byDomain('automation'))
      AutomationItem.fromEntity(e, knownRooms: rooms),
  ], rooms);
});

/// Schalter-Wünsche, die noch auf die Bestätigung von HA warten.
class _Pending extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => const {};

  void set(String id, bool on) => state = {...state, id: on};
  void clear(String id) {
    if (!state.containsKey(id)) return;
    state = {...state}..remove(id);
  }
}

final _pendingProvider = NotifierProvider<_Pending, Map<String, bool>>(
  _Pending.new,
);

/// Abläufe mit optimistischem Schalterzustand.
final automationsProvider = Provider<AutomationList>((ref) {
  final base = ref.watch(_baseProvider);
  final pending = ref.watch(_pendingProvider);
  if (pending.isEmpty) return base;
  return AutomationList([
    for (final a in base.items)
      pending.containsKey(a.entityId) ? a.withOn(pending[a.entityId]!) : a,
  ], base.roomNames);
});

/// Aktionen auf Abläufen. Alles läuft über `callService`.
class AutomationActions {
  AutomationActions(this._ref);
  final Ref _ref;

  Future<void> setEnabled(String entityId, bool on) async {
    final pending = _ref.read(_pendingProvider.notifier)..set(entityId, on);
    try {
      await _ref
          .read(repositoryProvider)
          .callService(
            'automation',
            on ? 'turn_on' : 'turn_off',
            entityId: entityId,
          );
    } finally {
      // HA meldet den echten Zustand per state_changed. Bis dahin gilt der Wunsch.
      Timer(const Duration(milliseconds: 1500), () {
        try {
          pending.clear(entityId);
        } catch (_) {}
      });
    }
  }

  Future<void> run(String entityId) => _ref
      .read(repositoryProvider)
      .callService('automation', 'trigger', entityId: entityId);
}

final automationActionsProvider = Provider<AutomationActions>(
  AutomationActions.new,
);
