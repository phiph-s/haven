import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/providers.dart';
import '../../data/models/haven_automation.dart';
import '../zigbee/zigbee_model.dart';
import '../zigbee/zigbee_providers.dart';
import 'automations_provider.dart';
import 'knob_logic.dart';

/// Haven-Automationen aus der Integration. Lädt neu bei `haven_data_updated`
/// (`kind: automations`) und nach jedem Verbinden.
class HavenAutomationsNotifier extends AsyncNotifier<HavenAutomations> {
  StreamSubscription<void>? _sub;
  StreamSubscription<AutomationTrigger>? _trig;

  @override
  Future<HavenAutomations> build() async {
    final repo = ref.watch(repositoryProvider);
    _sub?.cancel();
    _sub = repo.automationsChanged.listen((_) => unawaited(reload()));
    _trig?.cancel();
    _trig = repo.automationTriggers.listen(_onTrigger);
    ref.onDispose(() {
      _sub?.cancel();
      _trig?.cancel();
    });
    return repo.havenAutomations();
  }

  /// Zustand eines Bewegungslichts live aus dem Ereignis übernehmen.
  void _onTrigger(AutomationTrigger t) {
    final status = t.motion;
    final cur = state.value;
    if (status == null || cur == null || !ref.mounted) return;
    final a = cur.byId(t.id);
    if (a == null || !a.isMotion) return;
    state = AsyncData(
      cur.copyWith(
        automations: [
          for (final x in cur.automations)
            x.id == t.id
                ? x.copyWith(
                    motionStatus: status,
                    lastTriggered: AutomationFired(t.at, t.action),
                  )
                : x,
        ],
      ),
    );
  }

  Future<void> reload() async {
    try {
      final next = await ref.read(repositoryProvider).havenAutomations();
      if (!ref.mounted) return;
      state = AsyncData(next);
    } catch (e, st) {
      if (ref.mounted && !state.hasValue) state = AsyncError(e, st);
    }
  }

  HavenAutomations get _current => state.value ?? HavenAutomations.empty;

  /// Speichert und übernimmt die Antwort sofort.
  Future<HavenAutomation> save(HavenAutomation a) async {
    final saved = await ref.read(repositoryProvider).saveHavenAutomation(a);
    if (!ref.mounted) return saved;
    final list = [..._current.automations];
    final i = list.indexWhere((x) => x.id == saved.id);
    if (i < 0) {
      list.add(saved);
    } else {
      list[i] = saved;
    }
    state = AsyncData(_current.copyWith(automations: list));
    return saved;
  }

  /// Schalter auf der Karte: sofort sichtbar, bei Fehler zurück.
  Future<void> setEnabled(String id, bool on) async {
    final before = _current;
    final a = before.byId(id);
    if (a == null) return;
    state = AsyncData(
      before.copyWith(
        automations: [
          for (final x in before.automations)
            x.id == id ? x.copyWith(enabled: on) : x,
        ],
      ),
    );
    try {
      await ref
          .read(repositoryProvider)
          .saveHavenAutomation(a.copyWith(enabled: on));
    } catch (_) {
      if (ref.mounted) state = AsyncData(before);
      rethrow;
    }
  }

  Future<void> delete(String id) async {
    await ref.read(repositoryProvider).deleteHavenAutomation(id);
    if (!ref.mounted) return;
    state = AsyncData(
      _current.copyWith(
        automations: [
          for (final x in _current.automations)
            if (x.id != id) x,
        ],
      ),
    );
  }

  Future<void> test(String id, String action) =>
      ref.read(repositoryProvider).testHavenAutomation(id, action);
}

final havenAutomationsProvider =
    AsyncNotifierProvider<HavenAutomationsNotifier, HavenAutomations>(
      HavenAutomationsNotifier.new,
    );

/// Drehregler und Taster aus der Zigbee-Liste.
final knobDevicesProvider = Provider<List<ZbDeviceView>>((ref) {
  return [
    for (final v in ref.watch(zigbeeViewsProvider))
      if (kActionDeviceTypes.contains(v.device.deviceType)) v,
  ];
});

/// Bewegungs- und Anwesenheitsmelder aus der Zigbee-Liste.
final motionDevicesProvider = Provider<List<ZbDeviceView>>((ref) {
  return [
    for (final v in ref.watch(zigbeeViewsProvider))
      if (kMotionDeviceTypes.contains(v.device.deviceType)) v,
  ];
});

/// IEEE → Name für Texte.
final knobDeviceNamesProvider = Provider<Map<String, String>>((ref) {
  return {for (final v in ref.watch(zigbeeViewsProvider)) v.ieee: v.name};
});

/// Haven-Automation, die ein Gerät steuert (Gerät-Detail).
final automationForDeviceProvider = Provider.family<HavenAutomation?, String>((
  ref,
  ieee,
) {
  final all = ref.watch(havenAutomationsProvider).value;
  return all?.ownerOf(ieee) ??
      all?.automations.where((a) => a.devices.contains(ieee)).firstOrNull;
});

/// HA-Automationen, die dieselben Regler ansprechen wie [draft].
final haConflictsProvider = Provider.family<List<HaConflict>, HavenAutomation>((
  ref,
  draft,
) {
  final all = ref.watch(havenAutomationsProvider).value;
  if (all == null) return const [];
  return findHaConflicts(
    devices: draft.devices,
    roomName: all.rooms[draft.roomAreaId]?.name,
    deviceNames: ref.watch(knobDeviceNamesProvider),
    deviceAutomations: all.deviceAutomations,
    haAutomations: ref.watch(automationsProvider).items,
    words: draft.isMotion ? kMotionWords : kKnobWords,
  );
});
