import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/adaptive/breakpoints.dart';
import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/accent_scope.dart';
import '../../core/widgets/animated_palette.dart';
import '../../core/widgets/entry_animation.dart';
import '../../core/widgets/haven_card.dart';
import '../../core/widgets/screen_header.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/section_header.dart';
import '../../core/widgets/skeleton.dart';
import '../../data/models/room.dart';
import '../../data/models/snapshot.dart';
import '../../data/models/widget_config.dart';
import '../updates/app_update_provider.dart';
import '../updates/app_update_widgets.dart';
import 'weather_text.dart';
import 'widgets/home_widgets.dart';
import 'widgets/room_tile.dart';

/// Zuhause: Raumkacheln, darunter konfigurierbare Widgets.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    // Beim Start nach einer neuen App-Version sehen, höchstens alle 6 Stunden.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(appUpdateProvider.notifier).checkIfDue());
    });
  }

  static String _greeting() {
    final h = DateTime.now().hour;
    if (h < 5) return 'Gute Nacht';
    if (h < 11) return 'Guten Morgen';
    if (h < 17) return 'Guten Tag';
    return 'Guten Abend';
  }

  String _subtitle() {
    final house = ref.watch(houseViewProvider);
    final snap = ref.read(snapshotProvider);
    final n = house.onCount;
    final lights = n == 0
        ? 'Alle Lichter aus'
        : (n == 1 ? 'Ein Licht an' : '$n Lichter an');
    final w = ref
        .watch(widgetsProvider)
        .where((c) => c.type == HavenWidgetType.weather)
        .firstOrNull;
    if (w == null) return lights;
    final we = w.entityIds.isEmpty ? null : snap.entity(w.entityIds.first);
    final tId = w.options['sensorTemp'] as String?;
    final t =
        (tId == null ? null : snap.entity(tId)?.number) ??
        (we?.attributes['temperature'] as num?)?.toDouble();
    if (t == null) return lights;
    return '$lights · draußen ${t.round()} °C${we == null ? '' : ', ${weatherLabel(we.state)}'}';
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final house = ref.watch(houseViewProvider);
    final rooms = ref.watch(orderedRoomsProvider);
    final snap = ref.watch(snapshotProvider);
    final repo = ref.read(repositoryProvider);
    final widgets = ref.watch(widgetsProvider);
    final palette = house.palette(dark: hv.isDark);

    // Schnellaktionen: alles aus plus bekannte Szenen.
    final quick = <(String, IconData, VoidCallback)>[
      ('Alles aus', Icons.nightlight_outlined, () => repo.allLightsOff()),
    ];
    for (final name in const ['Kinoabend', 'Fokus', 'Golden Hour']) {
      for (final r in rooms) {
        final s = r.scenes.where((s) => s.name == name).firstOrNull;
        if (s != null) {
          quick.add((
            name,
            name == 'Kinoabend'
                ? Icons.movie_outlined
                : name == 'Fokus'
                ? Icons.wb_sunny_outlined
                : Icons.lightbulb_outline_rounded,
            () => repo.applyScene(r.id, s.id),
          ));
          break;
        }
      }
    }

    return AccentScope(
      palette: palette,
      child: Builder(
        builder: (context) {
          final hv = context.hv;
          final top = MediaQuery.paddingOf(context).top;
          final desktop = context.isDesktopLayout;
          final pad = desktop ? 28.0 : HavenSpace.page;

          final header = ScreenHeader(
            eyebrow: _greeting(),
            title: 'Zuhause',
            subtitle: _subtitle(),
            actions: [
              RoundIconButton(
                icon: _editing ? Icons.check_rounded : Icons.edit_outlined,
                label: _editing ? 'Bearbeiten beenden' : 'Übersicht bearbeiten',
                active: _editing,
                onTap: () => setState(() => _editing = !_editing),
              ),
              // Am Desktop steht der Zugang in der Seitenleiste.
              if (!desktop) const SettingsButton(),
            ],
          );
          final quickChips = SizedBox(
            height: 56,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: pad, vertical: 10),
              itemCount: quick.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) => _QuickChip(
                label: quick[i].$1,
                icon: quick[i].$2,
                onTap: () {
                  HapticFeedback.selectionClick();
                  quick[i].$3();
                },
              ),
            ),
          );
          final roomsHeader = SectionHeader(
            'Räume',
            padding: EdgeInsets.fromLTRB(pad, 12, pad, 10),
          );
          final roomGrid = Padding(
            padding: EdgeInsets.symmetric(horizontal: pad),
            child: LayoutBuilder(
              builder: (context, c) {
                final half = (c.maxWidth - 12) / 2;
                if (rooms.isEmpty &&
                    snap.status != ConnectionStatus.connected) {
                  return _RoomSkeleton(half: half);
                }
                if (_editing) return _RoomOrderList(rooms: rooms);
                if (desktop) {
                  // Raster: gleich breite Kacheln, so viele wie passen.
                  final n = gridColumns(
                    c.maxWidth,
                    minItem: DesktopMetrics.roomTileMin,
                    max: 5,
                  );
                  final w = (c.maxWidth - 12 * (n - 1)) / n;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (var i = 0; i < rooms.length; i++)
                        SizedBox(
                          width: w,
                          child: EntryAnimation(
                            index: i,
                            child: RoomTile(roomId: rooms[i].id, wide: true),
                          ),
                        ),
                    ],
                  );
                }
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (var i = 0; i < rooms.length; i++)
                      SizedBox(
                        width: (i == 0 && rooms.length.isOdd)
                            ? c.maxWidth
                            : half,
                        child: EntryAnimation(
                          index: i,
                          child: RoomTile(
                            roomId: rooms[i].id,
                            wide: i == 0 && rooms.length.isOdd,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          );
          final roomHint = Padding(
            padding: EdgeInsets.fromLTRB(pad, 8, pad, 0),
            child: Text(
              _editing
                  ? 'Halten und ziehen sortiert die Räume, auf allen Geräten.'
                  : desktop
                  ? 'Klick schaltet. Pfeil oder Rechtsklick öffnet den Raum.'
                  : 'Tippen schaltet. Halten oder Pfeil öffnet den Raum.',
              style: HavenText.caption.copyWith(color: hv.tx3),
            ),
          );
          final widgetsHeader = SectionHeader(
            'Widgets',
            padding: EdgeInsets.fromLTRB(
              desktop ? 0 : pad,
              14,
              desktop ? 0 : pad,
              6,
            ),
            trailing: TextLink(
              _editing ? 'Fertig' : 'Bearbeiten',
              onTap: () => setState(() => _editing = !_editing),
            ),
          );
          final widgetList = _editing
              ? _EditList(widgets: widgets)
              : _WidgetGrid(widgets: widgets);

          Future<void> refresh() async {
            Haptics.tick();
            await repo.refresh();
          }

          final Widget content;
          if (desktop) {
            // Desktop: Räume im Raster links, Widgets in einer Seitenspalte.
            content = Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.only(bottom: context.navClearance),
                    children: [
                      header,
                      _Notices(snap: snap, fake: repo.isFake),
                      const UpdateNotices(),
                      quickChips,
                      roomsHeader,
                      roomGrid,
                      roomHint,
                    ],
                  ),
                ),
                Container(
                  width: DesktopMetrics.sideColumn + 24,
                  margin: const EdgeInsets.fromLTRB(0, 16, 20, 16),
                  decoration: BoxDecoration(
                    color: hv.s1.withValues(alpha: hv.isDark ? 0.35 : 0.5),
                    borderRadius: BorderRadius.circular(HavenRadii.l),
                    border: Border.all(color: hv.ln),
                  ),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                    children: [widgetsHeader, widgetList],
                  ),
                ),
              ],
            );
          } else {
            content = RefreshIndicator(
              color: hv.acc,
              backgroundColor: hv.s1,
              onRefresh: refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: HavenSpace.navClearance),
                children: [
                  header,
                  _Notices(snap: snap, fake: repo.isFake),
                  const UpdateNotices(),
                  quickChips,
                  roomsHeader,
                  roomGrid,
                  roomHint,
                  widgetsHeader,
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: pad),
                    child: widgetList,
                  ),
                ],
              ),
            );
          }
          return Stack(
            children: [
              // Der Glow beginnt am oberen Bildschirmrand, hinter der
              // durchsichtigen Statusleiste (edge-to-edge).
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 440 + top,
                child: IgnorePointer(
                  child: MeshGlow(palette: palette, style: MeshStyle.ambient),
                ),
              ),
              SafeArea(bottom: false, child: content),
            ],
          );
        },
      ),
    );
  }
}

/// Raumkacheln, solange die erste Verbindung läuft.
class _RoomSkeleton extends StatelessWidget {
  const _RoomSkeleton({required this.half});
  final double half;

  @override
  Widget build(BuildContext context) {
    return SkeletonScope(
      label: 'Räume laden',
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (var i = 0; i < 4; i++)
            Skeleton(width: half, height: 132, radius: HavenRadii.l),
        ],
      ),
    );
  }
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({
    required this.label,
    required this.icon,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: HavenSpace.touch,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: hv.s1,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: hv.ln),
            boxShadow: hv.shadowSmall,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: hv.tx2),
              const SizedBox(width: 8),
              Text(label, style: HavenText.label.copyWith(color: hv.tx)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Notices extends StatelessWidget {
  const _Notices({required this.snap, required this.fake});
  final HavenSnapshot snap;
  final bool fake;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final notes = <(IconData, String, Color)>[
      if (fake)
        (
          Icons.science_outlined,
          'Entwicklungsdaten: erfundene Wohnung, die Werte ändern sich nur hier.',
          hv.tx2,
        ),
      if (snap.status == ConnectionStatus.connecting)
        (
          Icons.sync_rounded,
          'Verbindung zu Home Assistant wird aufgebaut.',
          hv.warn,
        ),
      if (snap.status == ConnectionStatus.reconnecting)
        (
          Icons.wifi_off_rounded,
          'Verbindung zu Home Assistant unterbrochen. Haven verbindet neu, die Werte können veraltet sein.',
          hv.warn,
        ),
      if (snap.status == ConnectionStatus.offline && !fake)
        (
          Icons.cloud_off_rounded,
          'Home Assistant ist nicht erreichbar. Prüf das WLAN oder die Adresse in den Einstellungen.',
          hv.bad,
        ),
      if (snap.status == ConnectionStatus.authFailed)
        (
          Icons.lock_outline_rounded,
          'Home Assistant hat den Token abgelehnt. Tippe hier und verbinde dich neu.',
          hv.bad,
        ),
      if (snap.integrationMissing)
        (
          Icons.extension_off_outlined,
          'Die Haven-Integration ist in Home Assistant nicht geladen. Haven zeigt alle Lichter in einem Raum.',
          hv.warn,
        ),
    ];
    if (notes.isEmpty) return const SizedBox(height: 4);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HavenSpace.page,
        14,
        HavenSpace.page,
        0,
      ),
      child: Column(
        children: [
          for (final n in notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              // Fehler führen in die Einstellungen (Neu verbinden).
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: n.$3 == hv.bad
                    ? () => GoRouter.of(context).push('/settings')
                    : null,
                child: HavenCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  radius: HavenRadii.m,
                  child: Row(
                    children: [
                      Icon(n.$1, size: 18, color: n.$3),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          n.$2,
                          style: HavenText.caption.copyWith(
                            color: hv.tx,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                      if (n.$3 == hv.bad)
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 18,
                          color: hv.tx3,
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _WidgetGrid extends StatelessWidget {
  const _WidgetGrid({required this.widgets});
  final List<HavenWidgetConfig> widgets;

  @override
  Widget build(BuildContext context) {
    if (widgets.isEmpty) {
      return HavenCard(
        child: Text(
          'Keine Widgets. Tippe auf Bearbeiten, um welche hinzuzufügen.',
          style: HavenText.body.copyWith(color: context.hv.tx2),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        final half = (c.maxWidth - 12) / 2;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final w in widgets)
              SizedBox(
                key: ValueKey(w.id),
                width: w.isWide ? c.maxWidth : half,
                child: HomeWidgetCard(config: w),
              ),
          ],
        );
      },
    );
  }
}

/// Bearbeiten: Räume als Liste, per langem Drücken (oder am Griff sofort)
/// sortierbar. Die Reihenfolge liegt im geteilten Übersichts-Dokument.
class _RoomOrderList extends ConsumerWidget {
  const _RoomOrderList({required this.rooms});
  final List<Room> rooms;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ReorderableListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorderStart: (_) => Haptics.tick(),
      onReorderItem: (from, to) {
        final ids = [for (final r in rooms) r.id];
        final id = ids.removeAt(from);
        ids.insert(to, id);
        HapticFeedback.selectionClick();
        ref.read(homeLayoutProvider.notifier).setRoomOrder(ids);
      },
      proxyDecorator: (child, _, a) => AnimatedBuilder(
        animation: a,
        builder: (context, child) => Transform.scale(
          scale: 1 + 0.03 * Curves.easeOut.transform(a.value),
          child: child,
        ),
        child: Material(color: const Color(0x00000000), child: child),
      ),
      children: [
        for (var i = 0; i < rooms.length; i++)
          ReorderableDelayedDragStartListener(
            key: ValueKey('room-${rooms[i].id}'),
            index: i,
            child: _RoomOrderRow(room: rooms[i], index: i),
          ),
      ],
    );
  }
}

class _RoomOrderRow extends ConsumerWidget {
  const _RoomOrderRow({required this.room, required this.index});
  final Room room;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final view = ref.watch(roomViewProvider(room.id));
    final palette = view?.palette(dark: hv.isDark);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        label:
            '${room.name}, Position ${index + 1}. Halten und ziehen zum Sortieren.',
        child: HavenCard(
          padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
          radius: HavenRadii.m,
          child: SizedBox(
            height: 56,
            child: Row(
              children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: palette != null && palette.isOn
                        ? palette.primary
                        : hv.s3,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    room.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HavenText.label.copyWith(color: hv.tx, fontSize: 15),
                  ),
                ),
                ReorderableDragStartListener(
                  index: index,
                  child: SizedBox(
                    width: HavenSpace.touch,
                    height: HavenSpace.touch,
                    child: Icon(Icons.drag_handle_rounded, color: hv.tx3),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EditList extends ConsumerWidget {
  const _EditList({required this.widgets});
  final List<HavenWidgetConfig> widgets;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final ctl = ref.read(widgetsProvider.notifier);
    return Column(
      children: [
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: ctl.reorder,
          proxyDecorator: (child, _, _) =>
              Material(color: const Color(0x00000000), child: child),
          children: [
            for (var i = 0; i < widgets.length; i++)
              EditRow(
                key: ValueKey(widgets[i].id),
                config: widgets[i],
                index: i,
                onRemove: () => ctl.remove(widgets[i].id),
              ),
          ],
        ),
        const SizedBox(height: 4),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => showAddWidgetSheet(context, ref),
          child: Container(
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(HavenRadii.l),
              border: Border.all(color: hv.ln2, width: 2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_rounded, color: hv.tx2),
                const SizedBox(width: 8),
                Text(
                  'Widget hinzufügen',
                  style: HavenText.label.copyWith(color: hv.tx2, fontSize: 15),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
