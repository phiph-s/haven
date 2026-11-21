import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/adaptive/hover.dart';
import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/haven_switch.dart';
import '../../core/widgets/press_scale.dart';
import '../../core/widgets/protocol_badge.dart';
import '../../core/widgets/section_header.dart';
import '../../data/models/device.dart';
import '../../data/models/entity_state.dart';
import '../../data/models/zigbee.dart';
import 'widgets/device_icon.dart';
import 'widgets/zb_common.dart';

// Matter im Netzwerk-Tab: Geräte aus der Matter-Integration von Home
// Assistant (`haven/rooms` liefert `protocol: matter` ab Integration 0.6.34).
// Gekoppelt wird in HA, Haven zeigt und schaltet sie.

/// Matter-Geräte, nach Name.
final matterDevicesProvider = Provider<List<HavenDevice>>((ref) {
  final devices = ref.watch(snapshotProvider.select((s) => s.devices));
  return [
    for (final d in devices)
      if (d.isMatter) d,
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
});

/// Hauptentity eines Matter-Geräts: Licht, Schalter, sonst die erste.
String? matterMainEntity(HavenDevice d) {
  for (final domain in ['light', 'switch', 'fan', 'cover', 'climate', 'lock']) {
    for (final e in d.entityIds) {
      if (e.startsWith('$domain.')) return e;
    }
  }
  return d.entityIds.isEmpty ? null : d.entityIds.first;
}

/// Symbol (`ZbType`) zur Hauptentity.
String matterIconType(String? main) => switch (main?.split('.').first) {
  'light' => ZbType.light,
  'switch' => ZbType.plug,
  'climate' => ZbType.thermostat,
  'binary_sensor' => ZbType.contact,
  'sensor' => ZbType.climate,
  _ => ZbType.unknown,
};

/// Abschnitt „Matter“ im Netzwerk-Tab.
class MatterSection extends ConsumerWidget {
  const MatterSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final devices = ref.watch(matterDevicesProvider);
    return Column(
      key: const ValueKey('matter-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          'Matter',
          trailing: devices.isEmpty
              ? null
              : Text(
                  '${devices.length}',
                  style: HavenText.caption.copyWith(color: hv.tx3),
                ),
        ),
        const SizedBox(height: 12),
        if (devices.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Keine Matter-Geräte. Matter-Geräte koppelst du in Home '
              'Assistant (Einstellungen › Geräte & Dienste › Matter), dann '
              'erscheinen sie hier und lassen sich auf der Karte platzieren.',
              style: HavenText.caption.copyWith(color: hv.tx2),
            ),
          )
        else
          for (final d in devices) MatterDeviceRow(device: d),
      ],
    );
  }
}

/// Eine Zeile wie bei Zigbee: Symbol mit Matter-Zeichen, Name, Raum und
/// Modell, Zustand.
class MatterDeviceRow extends ConsumerWidget {
  const MatterDeviceRow({super.key, required this.device});
  final HavenDevice device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final d = device;
    final main = matterMainEntity(d);
    final e = main == null
        ? null
        : ref.watch(snapshotProvider.select((s) => s.entities[main]));
    final online = d.entityIds.any(
      (id) => ref.read(snapshotProvider).entities[id]?.isAvailable ?? false,
    );
    final room = _roomName(ref, d.areaId);
    final sub = [
      ?room,
      [d.manufacturer, d.model].whereType<String>().join(' '),
    ].where((s) => s.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        button: true,
        label: '${d.name}, Matter',
        child: PressScale(
          pressedScale: 0.98,
          onTap: () => showMatterDevice(context, d),
          child: HoverBuilder(
            builder: (context, hover) => AnimatedContainer(
              key: ValueKey('matter-row-${d.id}'),
              duration: context.motion(HavenMotion.d1),
              padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
              decoration: BoxDecoration(
                color: Color.alphaBlend(hoverOverlay(hv, hover), hv.s1),
                borderRadius: BorderRadius.circular(HavenRadii.m),
                border: Border.all(color: hv.ln),
              ),
              child: Row(
                children: [
                  WithProtocolMark(
                    protocol: DeviceProtocol.matter,
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: hv.s2,
                        borderRadius: BorderRadius.circular(HavenRadii.s + 2),
                      ),
                      padding: const EdgeInsets.all(4),
                      child: ZbDeviceIcon(type: matterIconType(main), size: 40),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          d.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HavenText.label.copyWith(
                            color: hv.tx,
                            fontSize: 14.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          sub.isEmpty ? 'Matter-Gerät' : sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HavenText.caption.copyWith(color: hv.tx2),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (!online)
                    ZbPill(text: 'Offline', color: hv.bad)
                  else if (e != null && _stateText(e) != null)
                    ZbPill(
                      text: _stateText(e)!,
                      color: e.isOn ? hv.acc : hv.tx2,
                    ),
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right_rounded, color: hv.tx3, size: 22),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String? _roomName(WidgetRef ref, String? areaId) {
  if (areaId == null) return null;
  for (final r in ref.read(roomsProvider)) {
    if (r.areaId == areaId || r.id == areaId) return r.name;
  }
  return null;
}

String? _stateText(EntityState e) => switch (e.domain) {
  'light' || 'switch' || 'fan' => e.isOn ? 'An' : 'Aus',
  'sensor' => e.unit == null ? e.state : '${e.state} ${e.unit}',
  _ => null,
};

/// Detail als Blatt: Protokoll, Hersteller, Modell, Firmware, Raum, Werte
/// und An/Aus für Licht und Schalter.
Future<void> showMatterDevice(BuildContext context, HavenDevice device) {
  Haptics.tick();
  return showZbSheet<void>(
    context,
    builder: (_) => _MatterDetail(device: device),
  );
}

class _MatterDetail extends ConsumerWidget {
  const _MatterDetail({required this.device});
  final HavenDevice device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final d = device;
    final entities = ref.watch(snapshotProvider.select((s) => s.entities));
    final main = matterMainEntity(d);
    final me = main == null ? null : entities[main];
    final canToggle =
        me != null &&
        me.isAvailable &&
        (me.domain == 'light' || me.domain == 'switch');
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: HavenText.caption.copyWith(color: hv.tx2),
            ),
          ),
          Expanded(
            child: Text(value, style: HavenText.body.copyWith(color: hv.tx)),
          ),
        ],
      ),
    );
    return Column(
      key: ValueKey('matter-detail-${d.id}'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            ZbDeviceIcon(type: matterIconType(main), size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                d.name,
                style: HavenText.section.copyWith(color: hv.tx, fontSize: 20),
              ),
            ),
            if (canToggle)
              HavenSwitch(
                value: me.isOn,
                semanticLabel: '${d.name} an',
                onChanged: (on) => unawaited(_toggle(ref, me, on)),
              ),
          ],
        ),
        const SizedBox(height: 10),
        const ProtocolPill(DeviceProtocol.matter),
        const SizedBox(height: 10),
        if (_roomName(ref, d.areaId) case final r?) row('Raum', r),
        if (d.manufacturer != null) row('Hersteller', d.manufacturer!),
        if (d.model != null) row('Modell', d.model!),
        if (d.swVersion != null) row('Firmware', d.swVersion!),
        const SizedBox(height: 8),
        Text('Werte', style: HavenText.label.copyWith(color: hv.tx)),
        const SizedBox(height: 4),
        for (final id in d.entityIds)
          if (entities[id] case final e?)
            row(
              e.name,
              e.isAvailable ? (_stateText(e) ?? e.state) : 'nicht erreichbar',
            ),
        const SizedBox(height: 8),
        Text(
          'Kopplung, Thread-Netz und Firmware verwaltet Home Assistant '
          '(Matter-Integration).',
          style: HavenText.caption.copyWith(color: hv.tx3),
        ),
      ],
    );
  }

  Future<void> _toggle(WidgetRef ref, EntityState e, bool on) async {
    Haptics.tap();
    final repo = ref.read(repositoryProvider);
    if (e.domain == 'light') {
      await repo.setLights([e.entityId], on: on);
    } else {
      await repo.callService(
        e.domain,
        on ? 'turn_on' : 'turn_off',
        entityId: e.entityId,
      );
    }
  }
}
