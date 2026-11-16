import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/adaptive/breakpoints.dart';
import '../../core/adaptive/hover.dart';
import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/entry_animation.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/skeleton.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/haven_card.dart';
import '../../core/widgets/press_scale.dart';
import '../../core/widgets/screen_header.dart';
import '../../core/widgets/section_header.dart';
import 'widgets/device_icon.dart';
import 'widgets/mesh_card.dart';
import 'widgets/zb_common.dart';
import 'zigbee_actions.dart';
import 'zigbee_device_screen.dart';
import 'zigbee_selection.dart';
import 'zigbee_model.dart';
import 'zigbee_providers.dart';

String zigbeeDevicePath(String ieee) => '/zigbee/device/$ieee';
const zigbeePairPath = '/zigbee/pair';

/// Zigbee: Kopf, Gerät hinzufügen, Netz-Slot, „Braucht dich“, Geräteliste.
class ZigbeeScreen extends ConsumerStatefulWidget {
  const ZigbeeScreen({super.key});

  @override
  ConsumerState<ZigbeeScreen> createState() => _ZigbeeScreenState();
}

class _ZigbeeScreenState extends ConsumerState<ZigbeeScreen> {
  ZbFilter? _filter;
  bool _allNeeds = false;

  @override
  void initState() {
    super.initState();
    // `?select=<IEEE>` wählt am Desktop ein Gerät (Links, Screenshots).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sel = GoRouterState.of(context).uri.queryParameters['select'];
      if (sel != null) ref.read(zigbeeSelectionProvider.notifier).select(sel);
    });
  }

  @override
  Widget build(BuildContext context) {
    final list = _list(context);
    if (!context.isDesktopLayout) return list;
    // Desktop: Master-Detail, Liste links, Gerät rechts.
    final hv = context.hv;
    final sel = ref.watch(zigbeeSelectionProvider);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: DesktopMetrics.masterWidth + 40,
          child: ZigbeeMasterScope(child: list),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 20, 20),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: hv.s1.withValues(alpha: hv.isDark ? 0.4 : 0.6),
                borderRadius: BorderRadius.circular(HavenRadii.l),
                border: Border.all(color: hv.ln),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(HavenRadii.l),
                child: AnimatedSwitcher(
                  duration: context.motion(HavenMotion.d2),
                  child: sel == null
                      ? const _NoSelection()
                      : ZigbeeDeviceScreen(
                          key: ValueKey(sel),
                          ieee: sel,
                          embedded: true,
                        ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _list(BuildContext context) => _listBody(context);

  String _subtitle(ZigbeeData z, int count) {
    final parts = <String>[
      '$count ${count == 1 ? 'Gerät' : 'Geräte'}',
      if (z.info.channel != null) 'Kanal ${z.info.channel}',
      if (z.info.version != null) 'Z2M ${z.info.version}',
    ];
    return parts.join(' · ');
  }

  Widget _listBody(BuildContext context) {
    final hv = context.hv;
    final z = ref.watch(zigbeeProvider);
    final views = ref.watch(zigbeeViewsProvider);
    final needs = ref.watch(zigbeeNeedsProvider);
    final rooms = ref.watch(roomsProvider);
    final roomsKnown = views.any((v) => v.device.hasAreaInfo);

    final shown = _filter == null
        ? views
        : [
            for (final v in views)
              if (_filter!.matches(v)) v,
          ];
    final items = _grouped(shown, rooms.map((r) => r.id).toList(), roomsKnown);

    return RefreshIndicator(
      color: hv.acc,
      backgroundColor: hv.s1,
      onRefresh: () async {
        Haptics.tick();
        await Future.wait([
          ref.read(zigbeeProvider.notifier).reload(),
          ref.read(repositoryProvider).refresh(),
        ]);
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: ScreenHeader(
              title: 'Zigbee',
              subtitle: z.loaded ? _subtitle(z, views.length) : 'Lädt',
              large: false,
              actions: const [SettingsButton()],
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              HavenSpace.page,
              18,
              HavenSpace.page,
              0,
            ),
            sliver: SliverList.list(
              children: [
                EntryAnimation(
                  index: 0,
                  child: HavenButton(
                    label: 'Gerät hinzufügen',
                    icon: Icons.add_rounded,
                    primary: true,
                    onTap: () => context.push(zigbeePairPath),
                  ),
                ),
                const SizedBox(height: 14),
                EntryAnimation(index: 1, child: ZigbeeMeshCard(views: views)),
                if (z.error != null && views.isEmpty) ...[
                  const SizedBox(height: 14),
                  _ErrorCard(
                    message: z.error!,
                    onRetry: () => ref.read(zigbeeProvider.notifier).reload(),
                  ),
                ],
                const SizedBox(height: 22),
                _NeedsSection(
                  needs: needs,
                  all: _allNeeds,
                  loaded: z.loaded,
                  onToggle: () => setState(() => _allNeeds = !_allNeeds),
                ),
                const SizedBox(height: 22),
                const SectionHeader('Geräte'),
                const SizedBox(height: 12),
                _FilterChips(
                  views: views,
                  selected: _filter,
                  onSelect: (f) => setState(() => _filter = f),
                ),
                const SizedBox(height: 14),
              ],
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: HavenSpace.page),
            sliver: items.isEmpty
                ? SliverToBoxAdapter(
                    child: !z.loaded
                        ? const SkeletonScope(
                            label: 'Geräte werden geladen',
                            child: Column(
                              children: [
                                SkeletonRow(),
                                SkeletonRow(titleWidth: 120),
                                SkeletonRow(titleWidth: 180),
                                SkeletonRow(titleWidth: 140),
                              ],
                            ),
                          )
                        : Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Text(
                              'Keine Geräte in dieser Auswahl.',
                              textAlign: TextAlign.center,
                              style: HavenText.body.copyWith(color: hv.tx2),
                            ),
                          ),
                  )
                : SliverList.builder(
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final it = items[i];
                      if (it is _RoomHeader) {
                        return Padding(
                          padding: EdgeInsets.only(
                            top: i == 0 ? 0 : 14,
                            bottom: 8,
                          ),
                          child: Row(
                            children: [
                              Text(
                                it.name,
                                style: HavenText.label.copyWith(
                                  color: hv.tx,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${it.count}',
                                style: HavenText.caption.copyWith(
                                  color: hv.tx3,
                                ),
                              ),
                            ],
                          ),
                        );
                      }
                      return ZbDeviceRow(view: it as ZbDeviceView);
                    },
                  ),
          ),
          SliverToBoxAdapter(child: SizedBox(height: context.navClearance)),
        ],
      ),
    );
  }

  /// Flache Liste aus Raum-Köpfen und Geräten. Reihenfolge der Räume wie in
  /// der App, dann weitere, „Ohne Raum“ zuletzt.
  List<Object> _grouped(
    List<ZbDeviceView> views,
    List<String> roomOrder,
    bool roomsKnown,
  ) {
    if (!roomsKnown) return [...views];
    final byRoom = <String?, List<ZbDeviceView>>{};
    final names = <String?, String>{};
    for (final v in views) {
      byRoom.putIfAbsent(v.roomId, () => []).add(v);
      names[v.roomId] = v.roomName ?? 'Ohne Raum';
    }
    final keys = byRoom.keys.toList()
      ..sort((a, b) {
        int rank(String? k) => k == null
            ? 1 << 20
            : (roomOrder.contains(k) ? roomOrder.indexOf(k) : 1000);
        final c = rank(a).compareTo(rank(b));
        return c != 0 ? c : (names[a] ?? '').compareTo(names[b] ?? '');
      });
    return [
      for (final k in keys) ...[
        _RoomHeader(names[k]!, byRoom[k]!.length),
        ...byRoom[k]!,
      ],
    ];
  }
}

class _RoomHeader {
  const _RoomHeader(this.name, this.count);
  final String name;
  final int count;
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return HavenCard(
      child: Row(
        children: [
          Icon(Icons.cloud_off_rounded, color: hv.bad),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Zigbee-Daten nicht geladen. $message',
              style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
            ),
          ),
          TextLink('Neu laden', onTap: onRetry),
        ],
      ),
    );
  }
}

// ---- Braucht dich -----------------------------------------------------------

class _NeedsSection extends ConsumerWidget {
  const _NeedsSection({
    required this.needs,
    required this.all,
    required this.loaded,
    required this.onToggle,
  });
  final List<ZbNeed> needs;
  final bool all;
  final bool loaded;
  final VoidCallback onToggle;

  static const _collapsed = 4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final shown = all ? needs : needs.take(_collapsed).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          'Braucht dich',
          trailing: needs.isEmpty
              ? null
              : Text(
                  '${needs.length} offen',
                  style: HavenText.label.copyWith(color: hv.tx2),
                ),
        ),
        const SizedBox(height: 12),
        if (needs.isEmpty)
          HavenCard(
            child: Row(
              children: [
                Icon(Icons.check_circle_rounded, color: hv.ok),
                const SizedBox(width: 12),
                Text(
                  loaded ? 'Alles in Ordnung' : 'Prüfe Geräte',
                  style: HavenText.label.copyWith(color: hv.tx),
                ),
              ],
            ),
          )
        else ...[
          for (final n in shown) _NeedRow(need: n),
          if (needs.length > _collapsed)
            Align(
              alignment: Alignment.centerLeft,
              child: TextLink(
                all ? 'Weniger anzeigen' : 'Alle ${needs.length} anzeigen',
                onTap: onToggle,
              ),
            ),
        ],
      ],
    );
  }
}

class _NeedRow extends ConsumerWidget {
  const _NeedRow({required this.need});
  final ZbNeed need;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final v = need.view;
    final (IconData icon, Color color, String action) = switch (need.kind) {
      ZbNeedKind.offline => (Icons.link_off_rounded, hv.bad, 'Prüfen'),
      ZbNeedKind.lowBattery => (
        Icons.battery_alert_rounded,
        hv.warn,
        'Ansehen',
      ),
      ZbNeedKind.weakSignal => (
        Icons.network_wifi_1_bar_rounded,
        hv.warn,
        'Ansehen',
      ),
      ZbNeedKind.noRoom => (Icons.meeting_room_outlined, hv.tx2, 'Raum wählen'),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: PressScale(
        onTap: () => openZigbeeDevice(context, v.ieee),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: hv.s1,
            borderRadius: BorderRadius.circular(HavenRadii.m),
            border: Border.all(color: hv.ln),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(HavenRadii.s),
                ),
                child: Icon(icon, size: 22, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      v.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HavenText.label.copyWith(
                        color: hv.tx,
                        fontSize: 14.5,
                      ),
                    ),
                    Text(
                      need.detail,
                      style: HavenText.caption.copyWith(color: hv.tx2),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              PressScale(
                onTap: need.kind == ZbNeedKind.noRoom
                    ? () => pickRoom(context, ref, v)
                    : () => openZigbeeDevice(context, v.ieee),
                child: Container(
                  constraints: const BoxConstraints(
                    minHeight: HavenSpace.touch - 8,
                    minWidth: 76,
                  ),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: hv.s2,
                    borderRadius: BorderRadius.circular(HavenRadii.pill),
                    border: Border.all(color: hv.ln2),
                  ),
                  child: Text(
                    action,
                    style: HavenText.label.copyWith(color: hv.tx, fontSize: 13),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---- Filter ------------------------------------------------------------------

class _FilterChips extends StatelessWidget {
  const _FilterChips({
    required this.views,
    required this.selected,
    required this.onSelect,
  });
  final List<ZbDeviceView> views;
  final ZbFilter? selected;
  final ValueChanged<ZbFilter?> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: HavenSpace.touch,
      child: ListView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        children: [
          _Chip(
            label: 'Alle',
            count: views.length,
            on: selected == null,
            onTap: () => onSelect(null),
          ),
          for (final f in ZbFilter.values)
            _Chip(
              label: f.label,
              count: views.where(f.matches).length,
              on: selected == f,
              onTap: () => onSelect(selected == f ? null : f),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.count,
    required this.on,
    required this.onTap,
  });
  final String label;
  final int count;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Semantics(
        button: true,
        selected: on,
        label: '$label, $count',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Center(
            child: AnimatedContainer(
              duration: context.motion(HavenMotion.d2),
              curve: HavenMotion.out,
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? hv.tx : hv.s2,
                borderRadius: BorderRadius.circular(HavenRadii.pill),
                border: Border.all(color: on ? hv.tx : hv.ln),
              ),
              child: Text(
                '$label  $count',
                style: HavenText.label.copyWith(
                  color: on ? hv.bg : hv.tx2,
                  fontSize: 13.5,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---- Zeile ---------------------------------------------------------------------

/// Eine Gerätezeile: Icon, Name, Modell, Status rechts.
class ZbDeviceRow extends ConsumerWidget {
  const ZbDeviceRow({super.key, required this.view});
  final ZbDeviceView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final v = view;
    // Desktop (Master-Detail): gewählte Zeile mit Akzent.
    final selected =
        ZigbeeMasterScope.active(context) &&
        ref.watch(zigbeeSelectionProvider) == v.ieee;
    final pills = <Widget>[
      if (!v.available)
        ZbPill(text: 'Offline', color: hv.bad)
      else ...[
        if (v.device.isBattery && v.battery != null)
          ZbPill(
            text: '${v.battery} %',
            color: batteryColor(context, v.battery!),
          ),
        if (v.lqi != null && v.lqi! < kWeakLqi)
          ZbPill(text: 'Signal ${v.lqi}', color: lqiColor(context, v.lqi!)),
      ],
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        button: true,
        label: '${v.name}, ${v.device.modelLine}',
        child: PressScale(
          pressedScale: 0.98,
          onTap: () => openZigbeeDevice(context, v.ieee),
          child: HoverBuilder(
            builder: (context, hover) => AnimatedContainer(
              duration: context.motion(HavenMotion.d1),
              padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
              decoration: BoxDecoration(
                color: Color.alphaBlend(
                  selected
                      ? hv.acc.withValues(alpha: 0.12)
                      : hoverOverlay(hv, hover),
                  hv.s1,
                ),
                borderRadius: BorderRadius.circular(HavenRadii.m),
                border: Border.all(
                  color: selected ? hv.acc.withValues(alpha: 0.7) : hv.ln,
                  width: selected ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: hv.s2,
                      borderRadius: BorderRadius.circular(HavenRadii.s + 2),
                    ),
                    padding: const EdgeInsets.all(4),
                    child: ZbDeviceIcon(type: v.type, size: 40),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          v.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HavenText.label.copyWith(
                            color: hv.tx,
                            fontSize: 14.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          v.device.modelLine.isEmpty
                              ? deviceTypeLabel(v.type)
                              : v.device.modelLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HavenText.caption.copyWith(color: hv.tx2),
                        ),
                      ],
                    ),
                  ),
                  if (pills.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Wrap(spacing: 4, runSpacing: 4, children: pills),
                  ],
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

/// Detailspalte ohne Auswahl.
class _NoSelection extends StatelessWidget {
  const _NoSelection();

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hub_outlined, size: 44, color: hv.tx3),
          const SizedBox(height: 12),
          Text(
            'Wähle links ein Gerät',
            style: HavenText.headline.copyWith(color: hv.tx2),
          ),
          const SizedBox(height: 4),
          Text(
            'Einstellungen, Zustand und Diagnose erscheinen hier.',
            style: HavenText.caption.copyWith(color: hv.tx3),
          ),
        ],
      ),
    );
  }
}
