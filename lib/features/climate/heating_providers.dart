import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/providers.dart';
import '../../data/models/room_heating.dart';
import '../zigbee/zigbee_providers.dart';
import 'heating_logic.dart';
import 'thermostat_providers.dart';

/// Heizungsregelungen aller Räume aus der Integration. Lädt neu bei
/// `haven_data_updated` (`kind: heating`) und nach jedem Verbinden, den
/// Status übernimmt es live aus `haven_heating_updated`.
class HeatingNotifier extends AsyncNotifier<HeatingRooms> {
  StreamSubscription<void>? _changed;
  StreamSubscription<HeatingUpdate>? _updates;
  final Map<String, Timer> _debounce = {};

  @override
  Future<HeatingRooms> build() async {
    final repo = ref.watch(repositoryProvider);
    _changed?.cancel();
    _changed = repo.heatingChanged.listen((_) => unawaited(reload()));
    _updates?.cancel();
    _updates = repo.heatingUpdates.listen(_onUpdate);
    ref.onDispose(() {
      _changed?.cancel();
      _updates?.cancel();
      for (final t in _debounce.values) {
        t.cancel();
      }
      _debounce.clear();
    });
    return repo.heatingRooms();
  }

  void _onUpdate(HeatingUpdate u) {
    final cur = state.value;
    if (cur == null || !ref.mounted) return;
    final r = cur.byArea(u.areaId);
    if (r == null) return;
    // Während eine Eingabe noch wartet, nicht mit dem alten Ziel überschreiben.
    final status = _debounce.containsKey(u.areaId)
        ? u.status.copyWith(
            mode: r.status.mode,
            target: r.status.target,
            effectiveTarget: r.status.effectiveTarget,
          )
        : u.status;
    state = AsyncData(cur.replace(r.withStatus(status)));
  }

  Future<void> reload() async {
    try {
      final next = await ref.read(repositoryProvider).heatingRooms();
      if (!ref.mounted) return;
      state = AsyncData(next);
    } catch (e, st) {
      if (ref.mounted && !state.hasValue) state = AsyncError(e, st);
    }
  }

  HeatingRooms get _current => state.value ?? const HeatingRooms();

  Future<RoomHeating> save(HeatingConfig c) async {
    final saved = await ref.read(repositoryProvider).saveHeating(c);
    if (ref.mounted) state = AsyncData(_current.replace(saved));
    return saved;
  }

  Future<void> delete(String areaId) async {
    await ref.read(repositoryProvider).deleteHeating(areaId);
    if (ref.mounted) state = AsyncData(_current.remove(areaId));
  }

  /// Ziel bzw. Betriebsart: sofort sichtbar, das Ziel gebündelt nach
  /// [delay] gesendet (Plus und Minus mehrmals hintereinander). Fehler kommen
  /// als Text zurück.
  Future<String?> control(
    String areaId, {
    double? target,
    HeatingMode? mode,
    Duration delay = const Duration(milliseconds: 700),
  }) async {
    final r = _current.byArea(areaId);
    if (r == null) return 'Keine Regelung für diesen Raum.';
    final m = mode ?? (target != null ? HeatingMode.heat : r.status.mode);
    final t = target ?? r.status.target;
    final eff = m == HeatingMode.off
        ? null
        : (m == HeatingMode.heat ? t : r.config.presets[m]);
    state = AsyncData(
      _current.replace(
        r.withStatus(
          r.status.copyWith(
            mode: m,
            target: t,
            effectiveTarget: eff,
            clearEffective: eff == null,
          ),
        ),
      ),
    );
    final completer = Completer<String?>();
    Future<void> send() async {
      _debounce.remove(areaId);
      try {
        final s = await ref
            .read(repositoryProvider)
            .controlHeating(areaId, target: target, mode: mode);
        final cur = _current.byArea(areaId);
        if (ref.mounted && cur != null && !_debounce.containsKey(areaId)) {
          state = AsyncData(_current.replace(cur.withStatus(s)));
        }
        completer.complete(null);
      } catch (e) {
        if (ref.mounted) unawaited(reload());
        completer.complete('$e');
      }
    }

    _debounce.remove(areaId)?.cancel();
    if (target != null && mode == null && delay > Duration.zero) {
      _debounce[areaId] = Timer(delay, () => unawaited(send()));
    } else {
      await send();
    }
    return completer.future;
  }
}

final heatingProvider = AsyncNotifierProvider<HeatingNotifier, HeatingRooms>(
  HeatingNotifier.new,
);

/// HA-Bereich eines Raums (`Room.areaId`, sonst die ID).
final roomAreaProvider = Provider.family<String, String>((ref, roomId) {
  final rooms = ref.watch(snapshotProvider.select((s) => s.rooms));
  final room = rooms.where((r) => r.id == roomId).firstOrNull;
  return room?.areaId ?? roomId;
});

/// Regelung eines Raums ([roomId] wie in `Room.id`), `null` wenn keine.
final roomHeatingProvider = Provider.family<RoomHeating?, String>((
  ref,
  roomId,
) {
  final area = ref.watch(roomAreaProvider(roomId));
  return ref.watch(heatingProvider).value?.byArea(area);
});

/// Die Integration kann die Heizungsregelung (Feature `heating`).
final heatingSupportedProvider = Provider<bool>(
  (ref) => ref.watch(heatingProvider).value?.supported ?? false,
);

/// Entities, die zu Thermostaten gehören (nicht als Raumthermometer oder
/// Fensterkontakt anbieten: Sie messen am Heizkörper).
final thermostatEntityIdsProvider = Provider<Set<String>>((ref) {
  final out = <String>{};
  for (final v in ref.watch(zigbeeViewsProvider)) {
    if (isThermostat(zbType: v.type)) out.addAll(v.device.haEntities);
  }
  return out;
});

/// Entity → Bereich der Zigbee-Geräte (Raum aus der Integration).
final zigbeeEntityAreasProvider = Provider<Map<String, String>>((ref) {
  return {
    for (final v in ref.watch(zigbeeViewsProvider))
      if (v.roomId != null)
        for (final e in v.device.haEntities) e: v.roomId!,
  };
});

/// Wählbare Raumthermometer für einen Bereich.
final heatingSensorSourcesProvider =
    Provider.family<List<HeatingSource>, String>((ref, areaId) {
      final snap = ref.watch(snapshotProvider);
      return temperatureSources(
        snap,
        areaId,
        excluded: ref.watch(thermostatEntityIdsProvider),
        areas: ref.watch(zigbeeEntityAreasProvider),
      );
    });

/// Wählbare Fensterkontakte für einen Bereich.
final heatingWindowSourcesProvider =
    Provider.family<List<HeatingSource>, String>((ref, areaId) {
      final snap = ref.watch(snapshotProvider);
      return windowSources(
        snap,
        areaId,
        excluded: ref.watch(thermostatEntityIdsProvider),
        areas: ref.watch(zigbeeEntityAreasProvider),
      );
    });

/// Wählbare Quellen der Außentemperatur.
final heatingOutdoorSourcesProvider = Provider<List<HeatingSource>>((ref) {
  return outdoorSources(
    ref.watch(snapshotProvider),
    excluded: ref.watch(thermostatEntityIdsProvider),
    areas: ref.watch(zigbeeEntityAreasProvider),
  );
});
