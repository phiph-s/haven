import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

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
import 'widgets/room_row.dart';
import '../../core/widgets/horizontal_scroller.dart';
import '../search/search_sheet.dart';
import '../../core/widgets/haven_switch.dart';
import '../../core/widgets/segmented.dart';
import '../settings/settings_widgets.dart';
import '../zigbee/widgets/zb_common.dart' show showZbSheet;

/// Zuhause: Raumkacheln, darunter konfigurierbare Widgets.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _editing = false;

  /// Die Raumliste: der Farbverlauf oben scrollt mit ihr.
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

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
    final newRooms = ref.watch(newRoomsProvider);
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
              const SearchButton(),
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
            child: HorizontalScroller(
              builder: (context, controller) => ListView.separated(
                controller: controller,
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
            ),
          );
          Future<void> refresh() async {
            Haptics.tick();
            await repo.refresh();
          }

          void toggleEdit() => setState(() => _editing = !_editing);

          // Ein Widget der Hauptspalte (Kopf, Hinweise, Szenen).
          Widget single(HavenWidgetConfig w) => switch (w.type) {
            HavenWidgetType.header => header,
            HavenWidgetType.notices => Column(
              children: [
                _Notices(snap: snap, fake: repo.isFake),
                const UpdateNotices(),
              ],
            ),
            HavenWidgetType.scenes => quickChips,
            _ => const SizedBox.shrink(),
          };

          // Folgen gleicher Art zusammen: Räume (kompakte paarweise) und
          // kleine Karten (nebeneinander, breite über die ganze Zeile).
          List<Widget> stream(
            List<HavenWidgetConfig> ws, {
            required bool wideRooms,
          }) {
            final out = <Widget>[];
            var i = 0;
            var roomIndex = 0;
            while (i < ws.length) {
              final w = ws[i];
              if (w.type == HavenWidgetType.room) {
                final run = <HavenWidgetConfig>[];
                while (i < ws.length && ws[i].type == HavenWidgetType.room) {
                  run.add(ws[i++]);
                }
                out.add(_SectionLabel('Räume', count: run.length, pad: pad));
                out.add(
                  Padding(
                    padding: EdgeInsets.fromLTRB(pad, 0, pad, 8),
                    child: LayoutBuilder(
                      builder: (context, c) {
                        const gap = 14.0;
                        // Desktop: ausführliche zwei je Zeile (breit
                        // genug), sonst eine, aber nicht endlos breit
                        // (die Bedienung bleibt beim Bild); kompakte drei.
                        // Handy: eins bzw. zwei.
                        final full = wideRooms && c.maxWidth >= 900
                            ? (c.maxWidth - gap) / 2
                            : wideRooms
                            ? math.min(c.maxWidth, 760.0)
                            : c.maxWidth;
                        final small = wideRooms
                            ? (c.maxWidth - gap * 2) / 3
                            : (c.maxWidth - gap) / 2;
                        return Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          children: [
                            for (final r in run)
                              SizedBox(
                                key: ValueKey(r.id),
                                width: r.compact ? small : full,
                                child: EntryAnimation(
                                  index: roomIndex++,
                                  child: RoomPlate(
                                    roomId: r.roomId!,
                                    child: RoomRow(
                                      roomId: r.roomId!,
                                      config: r,
                                      detailed: !r.compact,
                                      large: desktop && !r.compact,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                );
                continue;
              }
              if (!w.isMain) {
                final run = <HavenWidgetConfig>[];
                while (i < ws.length && !ws[i].isMain) {
                  run.add(ws[i++]);
                }
                out.add(
                  Padding(
                    padding: EdgeInsets.fromLTRB(pad, 14, pad, 6),
                    child: _SmallCards(widgets: run),
                  ),
                );
                continue;
              }
              out.add(single(w));
              i++;
            }
            return out;
          }

          final hasRooms = widgets.any((w) => w.type == HavenWidgetType.room);
          final loading =
              !hasRooms && snap.status != ConnectionStatus.connected;
          final prompts = _NewRoomPrompts(rooms: newRooms, pad: pad);
          final skeleton = loading
              ? Padding(
                  padding: EdgeInsets.fromLTRB(pad, 16, pad, 0),
                  child: LayoutBuilder(
                    builder: (context, c) =>
                        _RoomSkeleton(half: (c.maxWidth - 12) / 2),
                  ),
                )
              : null;
          // Kopf (falls vorhanden) zuerst, dann die Frage nach neuen Räumen.
          List<Widget> withPrompts(List<Widget> items) {
            final head = widgets.firstOrNull?.type == HavenWidgetType.header;
            return [
              if (head) items.first,
              prompts,
              ...head ? items.skip(1) : items,
              ?skeleton,
            ];
          }

          final Widget content;
          if (_editing) {
            final list = ListView(
              controller: _scroll,
              padding: EdgeInsets.only(
                top: desktop ? 0 : top,
                bottom: context.navClearance,
              ),
              children: [
                header,
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: pad),
                  child: _HomeEditList(widgets: widgets, onDone: toggleEdit),
                ),
              ],
            );
            content = desktop
                ? Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: list,
                    ),
                  )
                : list;
          } else if (desktop) {
            // Desktop: Hauptspalte links, kleine Karten rechts (ohne Titel).
            final main = [
              for (final w in widgets)
                if (w.isMain) w,
            ];
            final side = [
              for (final w in widgets)
                if (!w.isMain) w,
            ];
            content = Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ListView(
                    controller: _scroll,
                    padding: EdgeInsets.only(bottom: context.navClearance),
                    children: withPrompts(stream(main, wideRooms: true)),
                  ),
                ),
                if (side.isNotEmpty)
                  Container(
                    width: DesktopMetrics.sideColumn + 24,
                    margin: const EdgeInsets.fromLTRB(0, 16, 20, 16),
                    decoration: BoxDecoration(
                      color: hv.s1.withValues(alpha: hv.isDark ? 0.35 : 0.5),
                      borderRadius: BorderRadius.circular(HavenRadii.l),
                      border: Border.all(color: hv.ln),
                    ),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                      children: [_SmallCards(widgets: side)],
                    ),
                  ),
              ],
            );
          } else {
            content = RefreshIndicator(
              color: hv.acc,
              backgroundColor: hv.s1,
              onRefresh: refresh,
              edgeOffset: top,
              child: ListView(
                controller: _scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                // Unter der Statusleiste beginnen, beim Scrollen dahinter
                // durch (dort verschwommen).
                padding: EdgeInsets.only(
                  top: top,
                  bottom: HavenSpace.navClearance,
                ),
                children: withPrompts(stream(widgets, wideRooms: false)),
              ),
            );
          }
          return Stack(
            children: [
              // Der Glow beginnt am oberen Bildschirmrand, hinter der
              // durchsichtigen Statusleiste (edge-to-edge), und scrollt mit
              // dem Inhalt.
              AnimatedBuilder(
                animation: _scroll,
                builder: (context, child) => Positioned(
                  left: 0,
                  right: 0,
                  top: _scroll.hasClients ? -_scroll.offset : 0,
                  height: 440 + top,
                  child: child!,
                ),
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: MeshGlow(palette: palette, style: MeshStyle.ambient),
                  ),
                ),
              ),
              if (desktop)
                SafeArea(bottom: false, child: content)
              else
                SafeArea(top: false, bottom: false, child: content),
              // Was hinter die Statusleiste scrollt, verschwimmt stark.
              if (!desktop && top > 0)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: top,
                  child: IgnorePointer(
                    child: ClipRect(
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                        // Leichte Tönung erst, wenn Inhalt darunter liegt:
                        // ganz oben bleibt die Leiste unsichtbar.
                        child: AnimatedBuilder(
                          animation: _scroll,
                          builder: (context, _) {
                            final off = _scroll.hasClients
                                ? _scroll.offset
                                : 0.0;
                            final k = (off / 40).clamp(0.0, 1.0);
                            return ColoredBox(
                              color: hv.bg.withValues(alpha: 0.3 * k),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
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

/// Kleine Karten nebeneinander (breite über die ganze Zeile).
class _SmallCards extends StatelessWidget {
  const _SmallCards({required this.widgets});
  final List<HavenWidgetConfig> widgets;

  @override
  Widget build(BuildContext context) {
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

/// Frage nach neuen Räumen: auf die Startseite oder nicht.
class _NewRoomPrompts extends ConsumerWidget {
  const _NewRoomPrompts({required this.rooms, required this.pad});
  final List<Room> rooms;
  final double pad;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final ctl = ref.read(widgetsProvider.notifier);
    return AnimatedSize(
      duration: context.motion(HavenMotion.d3),
      curve: HavenMotion.out,
      alignment: Alignment.topCenter,
      child: Column(
        children: [
          for (final r in rooms)
            Padding(
              key: ValueKey('new-room-${r.id}'),
              padding: EdgeInsets.fromLTRB(pad, 12, pad, 0),
              child: HavenCard(
                padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                radius: HavenRadii.m,
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: hv.acc.withValues(alpha: 0.16),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.meeting_room_outlined,
                        size: 19,
                        color: hv.acc,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Neuer Raum: ${r.name}',
                            style: HavenText.label.copyWith(
                              color: hv.tx,
                              fontSize: 14.5,
                            ),
                          ),
                          Text(
                            'Zur Startseite hinzufügen?',
                            style: HavenText.caption.copyWith(color: hv.tx2),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () {
                                  Haptics.tick();
                                  ctl.hideRoom(r.id);
                                },
                                child: Text(
                                  'Nein',
                                  style: HavenText.label.copyWith(
                                    color: hv.tx2,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: hv.acc,
                                  foregroundColor: hv.ai,
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: () {
                                  Haptics.tap();
                                  ctl.addRoom(r.id);
                                },
                                child: const Text('Hinzufügen'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Bearbeiten: alle Widgets der Startseite in einer Liste. Halten oder der
/// Griff sortiert, Räume haben Einstellungen, der Kopf bleibt (er trägt den
/// Bearbeiten-Knopf).
class _HomeEditList extends ConsumerWidget {
  const _HomeEditList({required this.widgets, required this.onDone});
  final List<HavenWidgetConfig> widgets;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final ctl = ref.read(widgetsProvider.notifier);
    final rooms = {for (final r in ref.watch(roomsProvider)) r.id: r};
    String title(HavenWidgetConfig w) => w.type == HavenWidgetType.room
        ? rooms[w.roomId]?.name ?? 'Raum'
        : widgetTitle(w);
    String? subtitle(HavenWidgetConfig w) {
      if (w.type != HavenWidgetType.room) return null;
      final shown = [
        for (final k in RoomWidgetOptions.all)
          if (w.shows(k)) RoomWidgetOptions.label(k),
      ];
      return '${w.compact ? 'Kompakt' : 'Ausführlich'} · '
          '${shown.isEmpty ? 'nur Name' : shown.join(', ')}';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
          child: Text(
            'Halten und ziehen sortiert. Die Startseite gilt auf allen '
            'Geräten.',
            style: HavenText.caption.copyWith(color: hv.tx3),
          ),
        ),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderStart: (_) => Haptics.tick(),
          onReorderItem: ctl.reorder,
          proxyDecorator: (child, _, a) => AnimatedBuilder(
            animation: a,
            builder: (context, child) => Transform.scale(
              scale: 1 + 0.03 * Curves.easeOut.transform(a.value),
              child: child,
            ),
            child: Material(color: const Color(0x00000000), child: child),
          ),
          children: [
            for (var i = 0; i < widgets.length; i++)
              ReorderableDelayedDragStartListener(
                key: ValueKey('edit-${widgets[i].id}'),
                index: i,
                child: _EditItem(
                  icon: widgetIcon(widgets[i]),
                  title: title(widgets[i]),
                  subtitle: subtitle(widgets[i]),
                  index: i,
                  onRemove: widgets[i].type == HavenWidgetType.header
                      ? null
                      : () {
                          Haptics.tick();
                          ctl.remove(widgets[i].id);
                        },
                  onSettings: widgets[i].type == HavenWidgetType.room
                      ? () => showRoomWidgetSettings(context, widgets[i].id)
                      : null,
                ),
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
        const SizedBox(height: 12),
        Center(child: TextLink('Fertig', onTap: onDone)),
      ],
    );
  }
}

class _EditItem extends StatelessWidget {
  const _EditItem({
    required this.icon,
    required this.title,
    required this.index,
    this.subtitle,
    this.onRemove,
    this.onSettings,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final int index;
  final VoidCallback? onRemove;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: HavenCard(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        radius: HavenRadii.m,
        child: SizedBox(
          height: subtitle == null ? 56 : 64,
          child: Row(
            children: [
              SizedBox(
                width: HavenSpace.touch,
                height: HavenSpace.touch,
                child: onRemove == null
                    ? Icon(Icons.lock_outline_rounded, size: 16, color: hv.tx3)
                    : Semantics(
                        button: true,
                        label: '$title entfernen',
                        excludeSemantics: true,
                        onTap: onRemove,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onRemove,
                          child: Center(
                            child: Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                color: hv.bad,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.remove_rounded,
                                size: 18,
                                color: Color(0xFFFFFFFF),
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
              Icon(icon, size: 20, color: hv.tx2),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HavenText.label.copyWith(
                        color: hv.tx,
                        fontSize: 15,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HavenText.caption.copyWith(color: hv.tx3),
                      ),
                  ],
                ),
              ),
              if (onSettings != null)
                IconButton(
                  tooltip: 'Einstellen',
                  icon: Icon(Icons.tune_rounded, color: hv.tx2),
                  onPressed: onSettings,
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
    );
  }
}

/// Einstellungen eines Raum-Widgets: Größe und was es zeigt.
Future<void> showRoomWidgetSettings(BuildContext context, String widgetId) =>
    showZbSheet<void>(
      context,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final hv = context.hv;
          final w = ref
              .watch(widgetsProvider)
              .where((w) => w.id == widgetId)
              .firstOrNull;
          if (w == null) return const SizedBox.shrink();
          final room = ref
              .watch(roomsProvider)
              .where((r) => r.id == w.roomId)
              .firstOrNull;
          final ctl = ref.read(widgetsProvider.notifier);
          void set(String key, Object v) => ctl.update(w.withOptions({key: v}));
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                room?.name ?? 'Raum',
                style: HavenText.section.copyWith(color: hv.tx, fontSize: 22),
              ),
              const SizedBox(height: 4),
              Text(
                'Was das Widget auf der Startseite zeigt.',
                style: HavenText.caption.copyWith(color: hv.tx2),
              ),
              const SizedBox(height: 14),
              HavenSegmented<bool>(
                options: const [(false, 'Ausführlich'), (true, 'Kompakt')],
                selected: w.compact,
                onChanged: (v) {
                  Haptics.tick();
                  set(RoomWidgetOptions.size, v ? 'compact' : 'detailed');
                },
              ),
              const SizedBox(height: 6),
              Text(
                w.compact
                    ? 'Schmal, zwei nebeneinander: Bild, Name und Lichtknopf.'
                    : 'Eine Zeile: Bild, Lichtknopf, Szenen, Heizung und '
                          'Bewegungslicht.',
                style: HavenText.caption.copyWith(color: hv.tx3),
              ),
              const SizedBox(height: 14),
              SettingsGroup(
                children: [
                  for (final k in RoomWidgetOptions.all)
                    if (!w.compact ||
                        k == RoomWidgetOptions.picture ||
                        k == RoomWidgetOptions.light)
                      SettingsRow(
                        key: ValueKey('room-widget-$k'),
                        icon: switch (k) {
                          RoomWidgetOptions.picture =>
                            Icons.view_in_ar_outlined,
                          RoomWidgetOptions.light =>
                            Icons.lightbulb_outline_rounded,
                          RoomWidgetOptions.scenes => Icons.palette_outlined,
                          RoomWidgetOptions.heat => Icons.thermostat_rounded,
                          _ => Icons.directions_walk_rounded,
                        },
                        title: RoomWidgetOptions.label(k),
                        trailing: HavenSwitch(
                          value: w.shows(k),
                          onChanged: (v) => set(k, v),
                          semanticLabel: RoomWidgetOptions.label(k),
                        ),
                        onTap: () => set(k, !w.shows(k)),
                      ),
                ],
              ),
            ],
          );
        },
      ),
    );

/// Kleiner Abschnittskopf mit Trennlinie (z. B. „Räume · 5“).
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {this.count, required this.pad});
  final String text;
  final int? count;
  final double pad;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad + 2, 18, pad, 10),
      child: Row(
        children: [
          Text(
            text.toUpperCase(),
            style: HavenText.caption.copyWith(
              color: hv.tx2,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 6),
            Text(
              '$count',
              style: HavenText.caption.copyWith(
                color: hv.tx3,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(width: 12),
          Expanded(child: Container(height: 1, color: hv.ln)),
        ],
      ),
    );
  }
}
