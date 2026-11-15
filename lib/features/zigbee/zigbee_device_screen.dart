import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/entry_animation.dart';
import '../../core/widgets/skeleton.dart';
import '../../core/widgets/haven_card.dart';
import '../../core/widgets/press_scale.dart';
import '../../core/widgets/section_header.dart';
import '../../data/models/zigbee.dart';
import 'widgets/device_icon.dart';
import 'widgets/device_main.dart';
import 'widgets/device_settings.dart';
import 'widgets/zb_common.dart';
import 'zigbee_actions.dart';
import 'zigbee_model.dart';
import 'zigbee_providers.dart';

/// Gerät-Detail im Vollbild: Kopf, Hauptfunktion, Einstellungen, Diagnose,
/// Rohdaten und Aktionen.
class ZigbeeDeviceScreen extends ConsumerWidget {
  const ZigbeeDeviceScreen({super.key, required this.ieee});
  final String ieee;

  void _back(BuildContext context) =>
      context.canPop() ? context.pop() : context.go('/zigbee');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final view = ref.watch(zigbeeViewProvider(ieee));
    final loaded = ref.watch(zigbeeProvider.select((z) => z.loaded));
    final detail = ref.watch(zigbeeDetailProvider(ieee)).value;

    Widget body;
    if (view == null) {
      body = loaded
          ? Center(
              child: Text(
                'Dieses Gerät gibt es nicht mehr.',
                style: HavenText.body.copyWith(color: hv.tx2),
              ),
            )
          : const Padding(
              padding: EdgeInsets.fromLTRB(
                HavenSpace.page,
                16,
                HavenSpace.page,
                0,
              ),
              child: SkeletonScope(
                label: 'Gerät lädt',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Skeleton(height: 72, circle: true),
                    SizedBox(height: 16),
                    Skeleton(width: 200, height: 22),
                    SizedBox(height: 10),
                    Skeleton(width: 140, height: 13),
                    SizedBox(height: 24),
                    Skeleton(
                      width: double.infinity,
                      height: 150,
                      radius: HavenRadii.l,
                    ),
                    SizedBox(height: 16),
                    SkeletonRow(),
                    SkeletonRow(titleWidth: 120),
                  ],
                ),
              ),
            );
    } else {
      final listed = view.device.classified;
      final cls = (listed.primary.isEmpty && listed.settings.isEmpty)
          ? (detail?.classified ?? listed)
          : listed;
      body = _Body(view: view, classified: cls);
    }
    return Scaffold(
      backgroundColor: hv.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Row(
                children: [
                  RoundIconButton(
                    icon: Icons.arrow_back_rounded,
                    label: 'Zurück',
                    onTap: () => _back(context),
                  ),
                  const Spacer(),
                  if (view != null &&
                      (detail?.classified.canIdentify ??
                          view.device.classified.canIdentify))
                    RoundIconButton(
                      icon: Icons.lightbulb_outline_rounded,
                      label: 'Identifizieren',
                      onTap: () => _identify(context, ref, view),
                    ),
                ],
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

Future<void> _identify(
  BuildContext context,
  WidgetRef ref,
  ZbDeviceView v,
) async {
  try {
    await ref.read(repositoryProvider).zigbeeIdentify(v.ieee);
    if (context.mounted) {
      zbToast(context, '${v.name} meldet sich jetzt mit Licht oder Ton');
    }
  } catch (e) {
    if (context.mounted) zbToast(context, '$e', error: true);
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.view, required this.classified});
  final ZbDeviceView view;
  final ZbClassified classified;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final hasSettings = classified.groupedSettings.isNotEmpty;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        HavenSpace.page,
        4,
        HavenSpace.page,
        40,
      ),
      children: [
        EntryAnimation(index: 0, child: _Hero(view: view)),
        const SizedBox(height: 14),
        EntryAnimation(index: 1, child: ZbMainFunction(view: view)),
        if (hasSettings) ...[
          const SizedBox(height: 26),
          const SectionHeader('Einstellungen'),
          const SizedBox(height: 12),
          ZbSettingsSection(view: view, classified: classified),
        ] else
          const SizedBox(height: 10),
        const SectionHeader('Diagnose'),
        const SizedBox(height: 12),
        _Diagnostics(view: view, classified: classified),
        const SizedBox(height: 16),
        _RawData(view: view, hidden: classified.hidden),
        const SizedBox(height: 26),
        const SectionHeader('Aktionen'),
        const SizedBox(height: 12),
        _Actions(view: view, canIdentify: classified.canIdentify),
        const SizedBox(height: 8),
        Center(
          child: Text(
            view.ieee,
            style: HavenText.caption.copyWith(color: hv.tx3),
          ),
        ),
      ],
    );
  }
}

// ---- Kopf --------------------------------------------------------------------

class _Hero extends ConsumerWidget {
  const _Hero({required this.view});
  final ZbDeviceView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final v = view;
    final icon = ZbDeviceIcon(type: v.type, size: 150);
    final image = v.device.image;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        color: hv.s1,
        borderRadius: BorderRadius.circular(HavenRadii.xl),
        border: Border.all(color: hv.ln),
        boxShadow: hv.shadowSmall,
      ),
      child: Column(
        children: [
          SizedBox(
            height: 150,
            child: image == null || image.isEmpty
                ? icon
                : Image.network(
                    image,
                    height: 150,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => icon,
                    loadingBuilder: (_, child, p) => p == null ? child : icon,
                  ),
          ),
          const SizedBox(height: 10),
          Text(
            v.name,
            textAlign: TextAlign.center,
            style: HavenText.title.copyWith(color: hv.tx, fontSize: 26),
          ),
          const SizedBox(height: 4),
          Text(
            [
              if (v.device.modelLine.isNotEmpty) v.device.modelLine,
              deviceTypeLabel(v.type),
            ].join(' · '),
            textAlign: TextAlign.center,
            style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              _RoomChip(view: v),
              if (!v.available) ZbPill(text: 'Nicht erreichbar', color: hv.bad),
              if (v.available && v.device.isBattery && v.battery != null)
                ZbPill(
                  text: 'Batterie ${v.battery} %',
                  color: batteryColor(context, v.battery!),
                  icon: Icons.battery_std_rounded,
                ),
              if (v.available && v.lqi != null)
                ZbPill(
                  text: 'Signal ${v.lqiLevel!.label}',
                  color: lqiColor(context, v.lqi!),
                  icon: Icons.network_wifi_rounded,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RoomChip extends ConsumerWidget {
  const _RoomChip({required this.view});
  final ZbDeviceView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final has = view.hasRoom;
    return PressScale(
      onTap: () => pickRoom(context, ref, view),
      child: Container(
        constraints: const BoxConstraints(minHeight: 32),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: hv.s2,
          borderRadius: BorderRadius.circular(HavenRadii.pill),
          border: Border.all(color: has ? hv.ln2 : hv.warn),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.meeting_room_outlined,
              size: 15,
              color: has ? hv.tx2 : hv.warn,
            ),
            const SizedBox(width: 6),
            Text(
              has ? view.roomName! : 'Kein Raum',
              style: HavenText.label.copyWith(
                color: has ? hv.tx : hv.warn,
                fontSize: 12.5,
              ),
            ),
            Icon(Icons.expand_more_rounded, size: 16, color: hv.tx3),
          ],
        ),
      ),
    );
  }
}

// ---- Diagnose --------------------------------------------------------------------

class _Diagnostics extends StatelessWidget {
  const _Diagnostics({required this.view, required this.classified});
  final ZbDeviceView view;
  final ZbClassified classified;

  String? _firmware() {
    final u = view.values['update'];
    if (u is Map && u['installed_version'] != null) {
      return '${u['installed_version']}';
    }
    for (final e in view.entities) {
      if (e.domain == 'update') {
        final iv = e.attributes['installed_version'];
        if (iv != null) return '$iv';
      }
    }
    final fv = view.values['software_build_id'] ?? view.values['sw_version'];
    return fv?.toString();
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final v = view;
    final lqi = v.lqi;
    final rows = <Widget>[];

    if (v.device.isBattery || v.battery != null) {
      final b = v.battery;
      rows.add(
        _DiagRow(
          label: 'Batterie',
          child: b == null
              ? Text(
                  'unbekannt',
                  style: HavenText.label.copyWith(color: hv.tx2),
                )
              : Row(
                  children: [
                    Expanded(
                      child: _Bar(
                        value: b / 100,
                        color: batteryColor(context, b),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text('$b %', style: HavenText.label.copyWith(color: hv.tx)),
                  ],
                ),
        ),
      );
    }
    rows.add(
      _DiagRow(
        label: 'Signal',
        child: lqi == null
            ? Text('unbekannt', style: HavenText.label.copyWith(color: hv.tx2))
            : Row(
                children: [
                  Expanded(
                    child: _Bar(
                      value: lqi / 255,
                      color: lqiColor(context, lqi),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${v.lqiLevel!.label} · $lqi',
                    style: HavenText.label.copyWith(
                      color: lqiColor(context, lqi),
                    ),
                  ),
                ],
              ),
      ),
    );
    rows.add(_kv('Stromversorgung', powerSourceLabel(v.device.powerSource)));
    rows.add(_kv('Rolle im Netz', nodeTypeLabel(v.device.type)));
    rows.add(_kv('Firmware', _firmware() ?? 'unbekannt'));
    for (final f in classified.diagnostic) {
      if (f.property == 'battery' || f.property == 'linkquality') continue;
      final x = v.read(f);
      if (x == null) continue;
      rows.add(
        _kv(
          f.label,
          '${x is num ? fmtNum(x) : x}${f.unit == null ? '' : ' ${unitLabel(f.unit)}'}',
        ),
      );
    }
    if (v.lastSeen != null) {
      rows.add(_kv('Zuletzt gesehen', agoLabel(v.lastSeen!)));
    }
    rows.add(
      _kv('Modell', v.device.modelLine.isEmpty ? '–' : v.device.modelLine),
    );
    rows.add(_kv('Adresse', v.ieee, small: true));

    return HavenCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, color: hv.ln),
            rows[i],
          ],
        ],
      ),
    );
  }

  Widget _kv(String k, String value, {bool small = false}) =>
      _DiagRow(label: k, value: value, small: small);
}

class _DiagRow extends StatelessWidget {
  const _DiagRow({
    required this.label,
    this.child,
    this.value,
    this.small = false,
  });
  final String label;
  final Widget? child;
  final String? value;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 124,
            child: Text(
              label,
              style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
            ),
          ),
          Expanded(
            child:
                child ??
                Text(
                  value ?? '',
                  textAlign: TextAlign.end,
                  style: HavenText.label.copyWith(
                    color: hv.tx,
                    fontSize: small ? 12 : 14,
                  ),
                ),
          ),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.value, required this.color});
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Container(
      height: 8,
      decoration: BoxDecoration(
        color: hv.s3,
        borderRadius: BorderRadius.circular(4),
      ),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: value.clamp(0.02, 1.0),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
          child: const SizedBox(height: 8),
        ),
      ),
    );
  }
}

// ---- Rohdaten ---------------------------------------------------------------------

class _RawData extends StatefulWidget {
  const _RawData({required this.view, required this.hidden});
  final ZbDeviceView view;
  final List<ZbFeature> hidden;

  @override
  State<_RawData> createState() => _RawDataState();
}

class _RawDataState extends State<_RawData> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    if (widget.hidden.isEmpty) return const SizedBox.shrink();
    return HavenCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PressScale(
            pressedScale: 0.99,
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(Icons.data_object_rounded, size: 20, color: hv.tx2),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Erweitert: Rohdaten',
                      style: HavenText.label.copyWith(color: hv.tx),
                    ),
                  ),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: context.motion(HavenMotion.d2),
                    child: Icon(Icons.expand_more_rounded, color: hv.tx3),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: context.motion(HavenMotion.d2),
            curve: HavenMotion.out,
            alignment: Alignment.topCenter,
            child: _open
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Column(
                      children: [
                        Text(
                          'Technische Werte für Fortgeschrittene. Hier gibt es nichts, was du einstellen musst.',
                          style: HavenText.caption.copyWith(color: hv.tx2),
                        ),
                        const SizedBox(height: 6),
                        for (final f in widget.hidden)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    f.property,
                                    style: HavenText.caption.copyWith(
                                      color: hv.tx2,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                                Text(
                                  '${widget.view.read(f) ?? '–'}',
                                  style: HavenText.caption.copyWith(
                                    color: hv.tx,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

// ---- Aktionen -----------------------------------------------------------------------

class _Actions extends ConsumerWidget {
  const _Actions({required this.view, required this.canIdentify});
  final ZbDeviceView view;
  final bool canIdentify;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final items = <_ActionItem>[
      _ActionItem(
        Icons.edit_outlined,
        'Umbenennen',
        () => renameDevice(context, ref, view),
      ),
      _ActionItem(
        Icons.meeting_room_outlined,
        'Raum ändern',
        () => pickRoom(context, ref, view),
        detail: view.roomName ?? 'Kein Raum',
      ),
      if (canIdentify)
        _ActionItem(
          Icons.lightbulb_outline_rounded,
          'Identifizieren',
          () => _identify(context, ref, view),
        ),
      _ActionItem(
        Icons.refresh_rounded,
        'Neu einrichten',
        () => _interview(context, ref),
      ),
      _ActionItem(
        Icons.delete_outline_rounded,
        'Entfernen',
        () => _remove(context, ref),
        destructive: true,
      ),
    ];
    return HavenCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent: 16,
                endIndent: 16,
                color: hv.ln,
              ),
            _ActionTile(item: items[i]),
          ],
        ],
      ),
    );
  }

  Future<void> _interview(BuildContext context, WidgetRef ref) async {
    final ok = await confirmSheet(
      context,
      title: 'Neu einrichten',
      text: 'Haven fragt das Gerät noch einmal nach seinen Funktionen. Das hilft, wenn Einstellungen fehlen. Bei Batteriegeräten vorher kurz einen Knopf drücken, damit es wach ist.',
      action: 'Starten',
    );
    if (!ok || !context.mounted) return;
    try {
      await ref.read(repositoryProvider).zigbeeInterview(view.ieee);
      if (context.mounted) zbToast(context, 'Einrichtung läuft');
    } catch (e) {
      if (context.mounted) zbToast(context, '$e', error: true);
    }
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final ok = await confirmSheet(
      context,
      title: 'Gerät entfernen',
      text:
          '${view.name} verschwindet aus Zigbee und aus allen Räumen. Zum erneuten Verwenden musst du es neu anlernen.',
      action: 'Entfernen',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    final err = await ref.read(zigbeeProvider.notifier).remove(view.ieee);
    if (!context.mounted) return;
    if (err != null) {
      zbToast(context, err, error: true);
      return;
    }
    zbToast(context, '${view.name} wurde entfernt');
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/zigbee');
    }
  }
}

class _ActionItem {
  const _ActionItem(
    this.icon,
    this.label,
    this.onTap, {
    this.detail,
    this.destructive = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? detail;
  final bool destructive;
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.item});
  final _ActionItem item;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final color = item.destructive ? hv.bad : hv.tx;
    return Semantics(
      button: true,
      label: item.label,
      child: PressScale(
        pressedScale: 0.99,
        onTap: item.onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(
                item.icon,
                size: 22,
                color: item.destructive ? hv.bad : hv.tx2,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  item.label,
                  style: HavenText.label.copyWith(color: color, fontSize: 15),
                ),
              ),
              if (item.detail != null)
                Text(
                  item.detail!,
                  style: HavenText.caption.copyWith(color: hv.tx2),
                ),
              if (!item.destructive)
                Icon(Icons.chevron_right_rounded, color: hv.tx3, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}
