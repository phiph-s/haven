import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/providers.dart';
import '../../data/models/entity_state.dart';
import '../../data/models/zigbee.dart';
import '../zigbee/zigbee_model.dart';
import '../zigbee/zigbee_providers.dart';
import 'thermostat_model.dart';

/// Ein Thermostat: Zigbee-Gerät ([ieee]) und/oder HA-Climate-Entity
/// ([entityId]). Mindestens eins ist gesetzt.
typedef ThermostatRef = ({String? ieee, String? entityId});

/// Thermostat zu einer Entity auf der Karte: mit Zigbee-Gerät, wenn es eins
/// gibt, die Climate-Entity des Geräts dazu.
ThermostatRef thermostatRefFor(String entityId, List<ZbDevice> devices) {
  for (final d in devices) {
    if (d.haEntities.contains(entityId)) {
      final climate = d.haEntities
          .where((e) => e.startsWith('climate.'))
          .firstOrNull;
      return (ieee: d.ieee, entityId: climate ?? entityId);
    }
  }
  return (ieee: null, entityId: entityId);
}

/// Ist das Zigbee-Gerät bzw. die Entity ein Thermostat?
bool isThermostat({String? zbType, String? entityId}) =>
    zbType == ZbType.thermostat || (entityId?.startsWith('climate.') ?? false);

/// Zustand eines Thermostats, `null` wenn es weder Gerät noch Entity gibt.
final thermostatProvider = Provider.family<ThermostatState?, ThermostatRef>((
  ref,
  r,
) {
  final view = r.ieee == null ? null : ref.watch(zigbeeViewProvider(r.ieee!));
  EntityState? climate = r.entityId == null
      ? null
      : ref.watch(entityProvider(r.entityId!));
  if (climate != null && climate.domain != 'climate') climate = null;
  if (view == null && climate == null) return null;
  ZbClassified? cls;
  if (view != null) {
    cls = view.device.classified;
    if (cls.primary.isEmpty && cls.settings.isEmpty) {
      cls = ref.watch(zigbeeDetailProvider(view.ieee)).value?.classified;
    }
  }
  return ThermostatState.from(view: view, climate: climate, classified: cls);
});

/// Thermostate eines Raums ([roomId] wie in `Room.id`): Zigbee-Geräte vom Typ
/// Thermostat und sonstige Climate-Entities der HA-Geräte im Bereich.
final roomThermostatsProvider = Provider.family<List<ThermostatRef>, String>((
  ref,
  roomId,
) {
  final views = ref.watch(zigbeeViewsProvider);
  final snap = ref.watch(snapshotProvider);
  final room = snap.rooms.where((r) => r.id == roomId).firstOrNull;
  final out = <ThermostatRef>[];
  final seen = <String>{};
  for (final v in views) {
    if (v.type != ZbType.thermostat || v.roomId != roomId) continue;
    final climate = v.device.haEntities
        .where((e) => e.startsWith('climate.'))
        .firstOrNull;
    out.add((ieee: v.ieee, entityId: climate));
    seen.addAll(v.device.haEntities);
  }
  final area = room?.areaId ?? roomId;
  for (final d in snap.devices) {
    if (d.areaId != area && d.areaId != roomId) continue;
    for (final id in d.entityIds) {
      if (id.startsWith('climate.') && !seen.contains(id)) {
        out.add((ieee: null, entityId: id));
        seen.add(id);
      }
    }
  }
  return out;
});

/// Schreibt an ein Thermostat: Zigbee über Z2M (`haven/zigbee/set`,
/// optimistisch), sonst über die HA-Climate-Dienste. Gibt eine Fehlermeldung
/// zurück oder `null`.
class ThermostatWriter {
  ThermostatWriter(this.ref);
  final WidgetRef ref;

  Future<String?> _z2m(ThermostatState t, String prop, dynamic value) =>
      ref.read(zigbeeProvider.notifier).setValue(t.ieee!, prop, value);

  Future<String?> _service(
    ThermostatState t,
    String service,
    Map<String, dynamic> data,
  ) async {
    final id = t.climateEntityId;
    if (id == null) return 'Dieses Thermostat lässt sich nicht steuern.';
    try {
      await ref
          .read(repositoryProvider)
          .callService('climate', service, entityId: id, data: data);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// Zieltemperatur, gerundet auf Schritt und Grenzen.
  Future<String?> setTarget(ThermostatState t, double v) {
    final c = t.clampTarget(v);
    return t.isZigbee
        ? _z2m(t, t.setpointProperty, c)
        : _service(t, 'set_temperature', {'temperature': c});
  }

  Future<String?> setMode(ThermostatState t, ThermoMode m) {
    if (t.isZigbee) return _z2m(t, 'preset', m.z2m);
    if (m == ThermoMode.off) {
      return _service(t, 'set_hvac_mode', {'hvac_mode': 'off'});
    }
    return _service(t, 'set_preset_mode', {'preset_mode': m.z2m});
  }

  /// Boost für [minutes] Minuten, 0 beendet ihn (nur Zigbee).
  Future<String?> setBoost(ThermostatState t, int minutes) async {
    if (!t.isZigbee) return 'Boost geht nur bei Zigbee-Thermostaten.';
    return _z2m(t, 'boost_timeset_countdown', minutes.clamp(0, 120));
  }

  /// Tagesplan (nur Zigbee, Format siehe [formatSchedule]).
  Future<String?> setSchedule(
    ThermostatState t,
    int day,
    List<ScheduleSlot> slots,
  ) async {
    if (!t.isZigbee) return 'Der Wochenplan geht nur bei Zigbee-Thermostaten.';
    final err = validateSchedule(slots);
    if (err != null) return err;
    return _z2m(t, 'schedule_${kWeekdays[day].$1}', formatSchedule(slots));
  }
}

/// Wochenplan eines Zigbee-Thermostats: je Tag (0 = Montag) die Wechsel,
/// `null` für Tage ohne gültigen Plan.
List<List<ScheduleSlot>?> weekScheduleOf(ZbDeviceView v) => [
  for (final (d, _, _) in kWeekdays)
    parseSchedule(v.raw('schedule_$d')?.toString()),
];
