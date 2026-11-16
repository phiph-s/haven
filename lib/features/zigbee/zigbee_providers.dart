import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/providers.dart';
import '../../data/models/zigbee.dart';
import '../../data/models/zigbee_network.dart' show ZbMeshNode;
import 'ghost_rules.dart';
import 'mesh/mesh_providers.dart';
import 'zigbee_model.dart';

/// Stand der Zigbee-Daten: Geräte, Gruppen, Bridge-Info und Z2M-Werte.
class ZigbeeData {
  const ZigbeeData({
    this.devices = const [],
    this.groups = const [],
    this.info = ZbBridgeInfo.empty,
    this.states = const {},
    this.loaded = false,
    this.error,
  });

  final List<ZbDevice> devices;
  final List<ZbGroup> groups;
  final ZbBridgeInfo info;

  /// IEEE → Property → Wert.
  final Map<String, Map<String, dynamic>> states;
  final bool loaded;
  final String? error;

  ZigbeeData copyWith({
    List<ZbDevice>? devices,
    List<ZbGroup>? groups,
    ZbBridgeInfo? info,
    Map<String, Map<String, dynamic>>? states,
    bool? loaded,
    String? error,
    bool clearError = false,
  }) => ZigbeeData(
    devices: devices ?? this.devices,
    groups: groups ?? this.groups,
    info: info ?? this.info,
    states: states ?? this.states,
    loaded: loaded ?? this.loaded,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Lädt Zigbee-Daten über das Repository und hält sie aktuell
/// (`haven/subscribe_zigbee`). Änderungen laufen optimistisch.
class ZigbeeNotifier extends Notifier<ZigbeeData> {
  StreamSubscription<ZbEvent>? _sub;

  @override
  ZigbeeData build() {
    final repo = ref.watch(repositoryProvider);
    ref.onDispose(() => _sub?.cancel());
    _sub = repo.zigbeeEvents.listen(_onEvent);
    Future.microtask(reload);
    return const ZigbeeData();
  }

  Future<void> reload() async {
    final repo = ref.read(repositoryProvider);
    try {
      final devices = await repo.zigbeeDevices();
      final groups = await _safe(repo.zigbeeGroups(), const <ZbGroup>[]);
      final info = await _safe(repo.zigbeeInfo(), ZbBridgeInfo.empty);
      final states = await _safe(
        repo.zigbeeStates(),
        const <String, Map<String, dynamic>>{},
      );
      state = ZigbeeData(
        devices: devices,
        groups: groups,
        info: info,
        states: states,
        loaded: true,
      );
    } catch (e) {
      state = state.copyWith(loaded: true, error: '$e');
    }
  }

  Future<T> _safe<T>(Future<T> f, T fallback) async {
    try {
      return await f;
    } catch (_) {
      return fallback;
    }
  }

  Future<void> _onEvent(ZbEvent e) async {
    final repo = ref.read(repositoryProvider);
    switch (e.kind) {
      case 'devices':
        final d = await _safe<List<ZbDevice>?>(repo.zigbeeDevices(), null);
        if (d != null) state = state.copyWith(devices: d);
      case 'groups':
        final g = await _safe<List<ZbGroup>?>(repo.zigbeeGroups(), null);
        if (g != null) state = state.copyWith(groups: g);
      case 'availability':
        final ieee = '${e.data['ieee']}';
        final a = e.data['availability']?.toString();
        state = state.copyWith(
          devices: [
            for (final d in state.devices)
              d.ieee == ieee ? d.copyWith(availability: a) : d,
          ],
        );
      case 'info' || 'state' when e.data['ieee'] == null:
        final i = await _safe<ZbBridgeInfo?>(repo.zigbeeInfo(), null);
        if (i != null) state = state.copyWith(info: i);
      case 'state':
        final ieee = '${e.data['ieee']}';
        final vals = e.data['values'];
        if (vals is Map) _merge(ieee, Map<String, dynamic>.from(vals));
    }
  }

  void _merge(String ieee, Map<String, dynamic> values) {
    final next = {...state.states};
    next[ieee] = {...?next[ieee], ...values};
    state = state.copyWith(states: next);
  }

  /// Setzt einen Z2M-Wert sofort in der Oberfläche und schickt ihn ab. Bei
  /// einem Fehler wird der alte Wert wiederhergestellt. Gibt die Fehlermeldung
  /// zurück oder `null`.
  Future<String?> setValue(String ieee, String property, dynamic value) async {
    final old = state.states[ieee]?[property];
    final had = state.states[ieee]?.containsKey(property) ?? false;
    _merge(ieee, {property: value});
    try {
      await ref.read(repositoryProvider).zigbeeSet(ieee, {property: value});
      return null;
    } catch (e) {
      final next = {...state.states};
      final m = {...?next[ieee]};
      if (had) {
        m[property] = old;
      } else {
        m.remove(property);
      }
      next[ieee] = m;
      state = state.copyWith(states: next);
      return '$e';
    }
  }

  /// Fehlermeldung oder `null`.
  Future<String?> _guard(Future<void> Function() f) async {
    try {
      await f();
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Future<String?> rename(String ieee, String name) => _guard(() async {
    await ref.read(repositoryProvider).zigbeeRename(ieee, name);
    await _refreshDevices();
  });

  Future<String?> setArea(String ieee, String? areaId) => _guard(() async {
    await ref.read(repositoryProvider).zigbeeSetArea(ieee, areaId);
    await _refreshDevices();
  });

  Future<String?> remove(String ieee, {bool force = false}) => _guard(() async {
    await ref.read(repositoryProvider).zigbeeRemove(ieee, force: force);
    await _refreshDevices();
  });

  Future<void> _refreshDevices() async {
    final d = await _safe<List<ZbDevice>?>(
      ref.read(repositoryProvider).zigbeeDevices(),
      null,
    );
    if (d != null) state = state.copyWith(devices: d);
  }
}

final zigbeeProvider = NotifierProvider<ZigbeeNotifier, ZigbeeData>(
  ZigbeeNotifier.new,
);

/// Alle Geräte mit Werten, Raum und Erreichbarkeit, nach Name sortiert.
final zigbeeViewsProvider = Provider<List<ZbDeviceView>>((ref) {
  final z = ref.watch(zigbeeProvider);
  final snap = ref.watch(snapshotProvider);
  // Ältere Integration ohne `ghost_detection`: „zuletzt gesehen“ aus der
  // Netzkarte, sofern die App eine geladen hat.
  final legacy = !ref.watch(
    repositoryProvider.select((r) => r.zigbeeGhostDetection),
  );
  final map = legacy
      ? ref.watch(zigbeeMeshProvider.select((m) => m.map))
      : null;
  final nodes = {for (final n in map?.nodes ?? const <ZbMeshNode>[]) n.ieee: n};
  final list = [
    for (final d in z.devices)
      ZbDeviceView.build(
        d,
        state: z.states[d.ieee],
        allEntities: snap.entities,
        rooms: snap.rooms,
        meshNode: nodes[d.ieee],
        meshMeasuredAt: map?.measuredAt,
      ),
  ];
  list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return list;
});

/// Eine Geräte-Sicht nach IEEE, `null` wenn es das Gerät nicht (mehr) gibt.
final zigbeeViewProvider = Provider.family<ZbDeviceView?, String>((ref, ieee) {
  for (final v in ref.watch(zigbeeViewsProvider)) {
    if (v.ieee == ieee) return v;
  }
  return null;
});

/// Gerät mit `classified` (`haven/zigbee/device`). Fällt bei Fehlern auf den
/// Listeneintrag zurück.
final zigbeeDetailProvider = FutureProvider.family<ZbDevice?, String>((
  ref,
  ieee,
) async {
  final repo = ref.read(repositoryProvider);
  try {
    return await repo.zigbeeDevice(ieee);
  } catch (_) {
    return null;
  }
});

/// Ignorierte Geister: IEEE → `last_seen`-Stempel, lokal gemerkt.
class GhostIgnoredNotifier extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => ref.read(settingsStoreProvider).ghostIgnored;

  /// Blendet das Gerät bis zur nächsten Meldung aus.
  Future<void> ignore(String ieee, DateTime? lastSeen) async {
    state = {...state, ieee: ghostStamp(lastSeen)};
    await ref.read(settingsStoreProvider).setGhostIgnored(state);
  }
}

final ghostIgnoredProvider =
    NotifierProvider<GhostIgnoredNotifier, Map<String, String>>(
      GhostIgnoredNotifier.new,
    );

/// Die einmalige Hinweiskarte wurde weggewischt.
class GhostHintDismissedNotifier extends Notifier<bool> {
  @override
  bool build() => ref.read(settingsStoreProvider).ghostHintDismissed;

  Future<void> dismiss() async {
    state = true;
    await ref.read(settingsStoreProvider).setGhostHintDismissed(true);
  }
}

final ghostHintDismissedProvider =
    NotifierProvider<GhostHintDismissedNotifier, bool>(
      GhostHintDismissedNotifier.new,
    );

/// Soll die Hinweiskarte „Zuletzt gesehen einschalten“ stehen? Nur mit einer
/// Integration ab 0.5.2, ohne jede Quelle (Option aus, keine Netzkarte mit
/// `lastSeen`) und solange sie nicht weggewischt wurde.
final ghostHintProvider = Provider<bool>((ref) {
  if (ref.watch(ghostHintDismissedProvider)) return false;
  if (!ref.watch(repositoryProvider.select((r) => r.zigbeeGhostDetection))) {
    return false;
  }
  final z = ref.watch(zigbeeProvider);
  if (!z.loaded || z.devices.isEmpty || z.info.lastSeenEnabled != false) {
    return false;
  }
  return ref.watch(zigbeeViewsProvider).every((v) => v.lastSeen == null);
});

/// „Braucht dich“, berechnet aus den Geräten.
final zigbeeNeedsProvider = Provider<List<ZbNeed>>((ref) {
  final views = ref.watch(zigbeeViewsProvider);
  final ignored = ref.watch(ghostIgnoredProvider);
  final roomsKnown = views.any((v) => v.device.hasAreaInfo);
  return computeNeeds(views, roomsKnown: roomsKnown, ignored: ignored);
});
