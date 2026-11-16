import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/adaptive/breakpoints.dart';
import '../../core/adaptive/context_menu.dart';
import '../../core/light/color_math.dart';
import '../../core/light/room_palette.dart';
import '../../core/router/router.dart';
import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/accent_scope.dart';
import '../../core/widgets/animated_palette.dart';
import '../../core/widgets/entry_animation.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/haven_card.dart';
import '../../core/widgets/press_scale.dart';
import '../../core/widgets/screen_header.dart';
import '../../data/models/floor_plan.dart';
import '../../data/models/state_history.dart';
import '../zigbee/mesh/mesh_graph.dart';
import '../zigbee/mesh/mesh_painter.dart';
import '../zigbee/mesh/mesh_providers.dart';
import '../zigbee/mesh/mesh_scene.dart';
import '../zigbee/mesh/mesh_screen.dart' show zigbeeMeshPath;
import 'floor_plan_store.dart';
import 'floor_plan_view.dart';
import 'heatmap.dart';
import 'map_data.dart';
import 'map_layer_widgets.dart';
import 'map_inspector.dart';
import 'map_layers.dart';
import 'map_markers.dart';
import 'map_painters.dart';
import 'map_readings.dart';
import 'map_routes.dart';

/// Karte: Grundriss mit Kartenarten (Licht, Temperatur, Luftfeuchte,
/// Bewegung, Funknetz, Batterie). Die Lichtfarbe der Wohnung färbt Akzent
/// und Glow.
class MapScreen extends ConsumerWidget {
  const MapScreen({
    super.key,
    this.startMenu = false,
    this.startMinutes,
    this.startInspect,
  });

  /// Nur für Screenshots: Auswahl aufgeklappt, Zeitstrahl verschoben,
  /// Raum im Inspektor (Desktop).
  final bool startMenu;
  final double? startMinutes;
  final String? startInspect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(floorPlanProvider);
    final p = plan.value;
    final has = p != null && !p.isEmpty;
    final dark = context.hv.isDark;
    final palette = ref.watch(houseViewProvider).palette(dark: dark);
    return AccentScope(
      palette: palette,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: 320,
            child: IgnorePointer(
              child: MeshGlow(palette: palette, style: MeshStyle.ambient),
            ),
          ),
          Column(
            children: [
              _MapHeader(plan: has ? p : null),
              Expanded(
                child: !plan.hasValue
                    ? const SizedBox.shrink()
                    : has
                    ? _MapBody(
                        plan: p,
                        startMenu: startMenu,
                        startMinutes: startMinutes,
                        startInspect: startInspect,
                      )
                    : const _EmptyMap(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _range(double a, double b, HeatKind k) {
  final u = k == HeatKind.temperature ? ' °C' : ' %';
  if ((a - b).abs() < 0.05) return '${heatValue(a, k)}$u';
  return '${heatValue(a, k)} bis ${heatValue(b, k)}$u';
}

class _MapHeader extends ConsumerWidget {
  const _MapHeader({required this.plan});
  final HavenFloorPlan? plan;

  String _lightSub(WidgetRef ref) {
    final l = ref.watch(mapLightsProvider(plan!));
    final n = l.onCount;
    final t = l.avgTemp;
    return (n == 0
            ? 'Alle Lichter aus'
            : n == 1
            ? 'Ein Licht an'
            : '$n Lichter an') +
        (t == null ? '' : ' · ${num1(t)} °C im Schnitt');
  }

  String _heatSub(WidgetRef ref, HeatKind k) {
    final d = ref.watch(mapReadingsProvider(plan!)).heat(k);
    final vals = [
      for (final l in d.rooms.values)
        for (final s in l) s.value,
    ];
    final out = d.outsideValue;
    final what = k == HeatKind.temperature
        ? 'Temperatursensoren'
        : 'Feuchtesensoren';
    if (vals.isEmpty && out == null) return 'Keine $what auf dem Grundriss';
    vals.sort();
    final inside = vals.isEmpty
        ? null
        : 'Innen ${_range(vals.first, vals.last, k)}';
    final o = out == null
        ? null
        : '$kOutsideName ${heatValue(out, k)}${k == HeatKind.temperature ? ' °C' : ' %'}';
    return [?inside, ?o].join(' · ');
  }

  String _presenceSub(WidgetRef ref) {
    final r = ref.watch(mapReadingsProvider(plan!)).motion;
    if (r.isEmpty) return 'Keine Melder auf dem Grundriss';
    final active = [
      for (final m in r)
        if (m.motion) _locName(plan!, m.location),
    ];
    if (active.isNotEmpty) return 'Bewegung: ${active.toSet().join(', ')}';
    DateTime? last;
    for (final m in r) {
      if (m.motionSince != null &&
          (last == null || m.motionSince!.isAfter(last))) {
        last = m.motionSince;
      }
    }
    return last == null
        ? 'Gerade ruhig'
        : 'Gerade ruhig · zuletzt ${agoText(last, DateTime.now())}';
  }

  String _batterySub(WidgetRef ref) {
    final b = ref.watch(mapReadingsProvider(plan!)).batteries;
    if (b.isEmpty) return 'Keine Batteriegeräte auf dem Grundriss';
    final weak = b.where((x) => x.battery! < 20).length;
    return '${b.length} mit Batterie · ${weak == 0 ? 'alle in Ordnung' : '$weak schwach'}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layer = ref.watch(mapLayerProvider);
    final String sub;
    if (plan == null) {
      sub = 'Dein Zuhause im Grundriss';
    } else {
      sub = switch (layer) {
        MapLayer.light => _lightSub(ref),
        MapLayer.temperature => _heatSub(ref, HeatKind.temperature),
        MapLayer.humidity => _heatSub(ref, HeatKind.humidity),
        MapLayer.presence => _presenceSub(ref),
        MapLayer.network => 'Funknetz auf dem Grundriss',
        MapLayer.battery => _batterySub(ref),
      };
    }
    return ScreenHeader(
      title: 'Karte',
      subtitle: sub,
      large: false,
      actions: [
        if (plan != null)
          RoundIconButton(
            icon: Icons.edit_outlined,
            label: 'Grundriss bearbeiten',
            onTap: () => context.push(mapEditorPath),
          ),
        if (!context.isDesktopLayout) const SettingsButton(),
      ],
    );
  }
}

String _locName(HavenFloorPlan plan, String id) =>
    id == kOutsideId ? kOutsideName : (plan.room(id)?.name ?? id);

class _MapBody extends ConsumerStatefulWidget {
  const _MapBody({
    required this.plan,
    this.startMenu = false,
    this.startMinutes,
    this.startInspect,
  });
  final HavenFloorPlan plan;
  final bool startMenu;
  final double? startMinutes;
  final String? startInspect;

  @override
  ConsumerState<_MapBody> createState() => _MapBodyState();
}

class _MapBodyState extends ConsumerState<_MapBody> {
  String? _info;
  Timer? _infoTimer;
  final _heat = HeatCache();
  final _mesh = ValueNotifier(const MeshViewState());
  String? _meshSel;
  late bool _menuOpen = widget.startMenu;

  /// Raum im Inspektor (nur Desktop).
  late String? _inspect = widget.startInspect;
  final _pickerKey = GlobalKey<MapLayerPickerState>();

  // Bewegung: Zeitstrahl und Takt fürs Abklingen.
  late double _minutes = widget.startMinutes ?? 0;
  Timer? _clock;
  Map<String, List<StateChange>> _history = const {};
  DateTime _historyAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _loadingHistory = false;

  @override
  void dispose() {
    _infoTimer?.cancel();
    _clock?.cancel();
    _heat.dispose();
    _mesh.dispose();
    super.dispose();
  }

  void _say(String text) {
    setState(() => _info = text);
    _infoTimer?.cancel();
    _infoTimer = Timer(const Duration(milliseconds: 2600), () {
      if (mounted) setState(() => _info = null);
    });
  }

  // ---- Bewegung --------------------------------------------------------------

  void _ensureClock(bool on) {
    if (!on) {
      _clock?.cancel();
      _clock = null;
      return;
    }
    _clock ??= Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadHistory(List<String> ids) async {
    if (_loadingHistory || ids.isEmpty) return;
    if (DateTime.now().difference(_historyAt) < const Duration(minutes: 1)) {
      return;
    }
    _loadingHistory = true;
    final h = await ref
        .read(repositoryProvider)
        .stateHistory(
          ids,
          DateTime.now().subtract(const Duration(minutes: 61)),
        );
    _loadingHistory = false;
    if (!mounted) return;
    setState(() {
      _history = h;
      _historyAt = DateTime.now();
    });
  }

  // ---- Antippen -------------------------------------------------------------

  void _tapNode(FloorNode n) {
    final plan = widget.plan;
    final p = plan.placementOf(n.id);
    if (p == null) return;
    final repo = ref.read(repositoryProvider);
    final e = ref.read(entityProvider(n.id));
    final name = e?.name ?? n.id;
    switch (p.resolvedKind) {
      case FloorKind.light:
        Haptics.tick();
        final on = e?.isOn ?? false;
        unawaited(repo.setLights([n.id], on: !on));
      case FloorKind.switchKind:
        Haptics.tick();
        unawaited(repo.callService('switch', 'toggle', entityId: n.id));
        _say('$name ${(e?.isOn ?? false) ? 'aus' : 'an'}');
      case FloorKind.temperature:
        Haptics.tick();
        final v = e?.number;
        _say(v == null ? name : '$name · ${num1(v)} °C');
      case FloorKind.presence:
        Haptics.tick();
        _say('$name · ${(e?.isOn ?? false) ? 'Bewegung' : 'ruhig'}');
      case FloorKind.contact:
        Haptics.tick();
        _say('$name · ${(e?.isOn ?? false) ? 'offen' : 'zu'}');
      case FloorKind.media || FloorKind.remote || FloorKind.device:
        Haptics.tick();
        _say(name);
    }
  }

  void _tapReading(FloorNode n, String text) {
    Haptics.tick();
    final e = ref.read(entityProvider(n.id));
    _say('${e?.name ?? n.id} · $text');
  }

  void _tapRoom(FloorRoom r) {
    // Desktop: der Inspektor rechts zeigt den Raum, geöffnet wird von dort.
    if (context.isDesktopLayout) {
      Haptics.tick();
      setState(() => _inspect = _inspect == r.id ? null : r.id);
      return;
    }
    final sr = snapshotRoomFor(ref.read(snapshotProvider), r);
    if (sr != null && sr.lightIds.isNotEmpty) {
      Haptics.tick();
      context.push(Routes.room(sr.id));
    } else {
      _say('${r.name} hat noch keine Lichter');
    }
  }

  /// Rechtsklick auf die Karte (Desktop).
  void _secondaryRoom(FloorRoom? r, Offset at) {
    final items = <HavenMenuItem>[];
    if (r != null) {
      final sr = snapshotRoomFor(ref.read(snapshotProvider), r);
      final view = sr == null ? null : ref.read(roomViewProvider(sr.id));
      setState(() => _inspect = r.id);
      if (sr != null && sr.lightIds.isNotEmpty) {
        items.add(
          HavenMenuItem(
            label: 'Raum öffnen',
            icon: Icons.open_in_new_rounded,
            onSelected: () => context.push(Routes.room(sr.id)),
          ),
        );
      }
      if (view != null && view.lamps.isNotEmpty) {
        items.add(
          HavenMenuItem(
            label: view.anyOn ? 'Licht aus' : 'Licht an',
            icon: view.anyOn
                ? Icons.lightbulb_outline_rounded
                : Icons.lightbulb_rounded,
            onSelected: () => ref.read(repositoryProvider).toggleRoom(view.id),
          ),
        );
      }
      items.add(
        HavenMenuItem(
          label: 'Einrichten',
          icon: Icons.chair_outlined,
          onSelected: () =>
              context.push('$mapEditorPath?mode=furniture&sel=${r.id}'),
        ),
      );
    }
    items.add(
      HavenMenuItem(
        label: 'Grundriss bearbeiten',
        icon: Icons.edit_outlined,
        onSelected: () => context.push(mapEditorPath),
      ),
    );
    showHavenContextMenu(context, at, items);
  }

  void _setLayer(MapLayer l) {
    ref.read(mapLayerProvider.notifier).set(l);
    setState(() {
      _menuOpen = false;
      _meshSel = null;
    });
  }

  // ---- Aufbau ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final plan = widget.plan;
    final layer = ref.watch(mapLayerProvider);
    final readings = ref.watch(mapReadingsProvider(plan));
    _ensureClock(layer == MapLayer.presence);

    final _LayerView v = switch (layer) {
      MapLayer.light => _lightView(plan),
      MapLayer.temperature => _heatView(plan, readings, HeatKind.temperature),
      MapLayer.humidity => _heatView(plan, readings, HeatKind.humidity),
      MapLayer.presence => _presenceView(plan, readings),
      MapLayer.network => _networkView(plan),
      MapLayer.battery => _batteryView(plan, readings),
    };

    if (context.isDesktopLayout) return _desktop(context, plan, layer, v);

    return Stack(
      children: [
        Column(
          children: [
            const SizedBox(height: 4),
            Expanded(
              child: EntryAnimation(
                index: 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  // Etwas unter der Mitte: oben bleibt Platz für die Auswahl
                  // der Kartenart, die Karte sitzt nah an ihrer Legende.
                  child: Align(
                    alignment: const Alignment(0, 0.4),
                    child: FloorPlanView(
                      key: const ValueKey('map'),
                      plan: v.plan,
                      gap: v.gap,
                      reserveGap: 2,
                      nodes: v.nodes,
                      nodeBuilder: v.nodeBuilder,
                      underlayPainter: v.underlay,
                      overlayPainter: v.overlay,
                      roomStyle: v.roomStyle,
                      roomSubtitle: v.subtitle,
                      onNodeTap: v.onNodeTap,
                      onRoomTap: v.onRoomTap,
                      onOutsideTap: v.onOutsideTap,
                      showOutside: v.showOutside,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HavenSpace.page,
                8,
                HavenSpace.page,
                0,
              ),
              child: HavenCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                radius: HavenRadii.m,
                child: AnimatedSize(
                  duration: context.motion(HavenMotion.d3),
                  curve: HavenMotion.out,
                  alignment: Alignment.topCenter,
                  child: AnimatedSwitcher(
                    duration: context.motion(HavenMotion.d2),
                    child: _info != null
                        ? SizedBox(
                            key: ValueKey(_info),
                            height: 44,
                            width: double.infinity,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                _info!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: HavenText.body.copyWith(color: hv.tx),
                              ),
                            ),
                          )
                        : KeyedSubtree(
                            key: ValueKey('card-${layer.name}'),
                            child: v.card,
                          ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: HavenSpace.navClearance),
          ],
        ),
        // Schleier hinter der aufgeklappten Auswahl, Tippen klappt zu.
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_menuOpen,
            child: AnimatedOpacity(
              opacity: _menuOpen ? 1 : 0,
              duration: context.motion(HavenMotion.d2),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _pickerKey.currentState?.close(),
                child: ColoredBox(color: hv.bg.withValues(alpha: 0.55)),
              ),
            ),
          ),
        ),
        Positioned(
          top: 2,
          right: 14,
          child: MapLayerPicker(
            key: _pickerKey,
            layer: layer,
            startOpen: widget.startMenu,
            onChanged: _setLayer,
            onOpenChanged: (o) => setState(() => _menuOpen = o),
          ),
        ),
      ],
    );
  }

  /// Desktop: Karte mit viel Fläche (Mausrad zoomt), rechts der Inspektor.
  Widget _desktop(
    BuildContext context,
    HavenFloorPlan plan,
    MapLayer layer,
    _LayerView v,
  ) {
    final hv = context.hv;
    final inspect = _inspect != null && plan.room(_inspect!) != null
        ? _inspect
        : null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 8, 20),
                  child: EntryAnimation(
                    index: 1,
                    child: FloorPlanView(
                      key: const ValueKey('map'),
                      plan: v.plan,
                      gap: v.gap,
                      reserveGap: 2,
                      fill: true,
                      maxScale: 6,
                      nodes: v.nodes,
                      nodeBuilder: v.nodeBuilder,
                      underlayPainter: v.underlay,
                      overlayPainter: v.overlay,
                      roomStyle: (r) {
                        final base = v.roomStyle?.call(r);
                        if (r.id != inspect) return base;
                        return FloorRoomStyle(
                          fill: base?.fill,
                          border: hv.acc,
                          borderWidth: 2,
                        );
                      },
                      roomSubtitle: v.subtitle,
                      onNodeTap: v.onNodeTap,
                      onRoomTap: v.onRoomTap,
                      onOutsideTap: () {
                        if (_inspect != null) {
                          setState(() => _inspect = null);
                        }
                        v.onOutsideTap?.call();
                      },
                      onRoomSecondaryTap: _secondaryRoom,
                      showOutside: v.showOutside,
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: !_menuOpen,
                  child: AnimatedOpacity(
                    opacity: _menuOpen ? 1 : 0,
                    duration: context.motion(HavenMotion.d2),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _pickerKey.currentState?.close(),
                      child: ColoredBox(color: hv.bg.withValues(alpha: 0.55)),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 2,
                right: 14,
                child: MapLayerPicker(
                  key: _pickerKey,
                  layer: layer,
                  startOpen: widget.startMenu,
                  onChanged: _setLayer,
                  onOpenChanged: (o) => setState(() => _menuOpen = o),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 20, 20),
          child: SizedBox(
            width: DesktopMetrics.sideColumn,
            child: MapInspector(
              plan: plan,
              selected: inspect,
              onSelect: (id) => setState(() => _inspect = id),
              layerCard: KeyedSubtree(
                key: ValueKey('card-${layer.name}'),
                child: v.card,
              ),
              info: _info,
            ),
          ),
        ),
      ],
    );
  }

  // ---- Licht ----------------------------------------------------------------

  _LayerView _lightView(HavenFloorPlan plan) {
    final hv = context.hv;
    final lights = ref.watch(mapLightsProvider(plan));
    return _LayerView(
      plan: plan,
      nodes: [
        for (final p in plan.placements)
          FloorNode(id: p.entityId, point: plan.pointOfCell(p.cell)),
      ],
      nodeBuilder: (context, n) =>
          MapMarker(entityId: n.id, kind: plan.placementOf(n.id)!.resolvedKind),
      underlay: MapLightPainter(plan: plan, lights: lights, hv: hv),
      subtitle: (r) {
        final v = lights.rooms[r.id];
        if (v == null) return null;
        return [
          if (v.temp != null) '${num1(v.temp!)}°',
          if (v.hum != null) '${v.hum!.round()} %',
        ].join(' · ');
      },
      onNodeTap: _tapNode,
      onRoomTap: _tapRoom,
      card: _StatusCard(lights: lights),
    );
  }

  // ---- Temperatur und Feuchte ----------------------------------------------

  _LayerView _heatView(
    HavenFloorPlan plan,
    MapReadings readings,
    HeatKind kind,
  ) {
    final hv = context.hv;
    final data = readings.heat(kind);
    final scale = data.scale;
    final values = <String, double>{};
    for (final r in readings.items) {
      final v = kind == HeatKind.temperature ? r.temp : r.hum;
      if (v != null) values[r.entityId] = v;
    }
    String text(double v) => '${heatValue(v, kind)}${kind.unit}';
    return _LayerView(
      plan: plan,
      nodes: [
        for (final r in readings.items)
          if (values.containsKey(r.entityId))
            FloorNode(
              id: r.entityId,
              point: PlanPoint(r.center.dx, r.center.dy, r.location),
            ),
      ],
      nodeBuilder: (context, n) {
        final v = values[n.id]!;
        final r = readings.of(n.id)!;
        return HeatValueMarker(
          label: ref.read(entityProvider(n.id))?.name ?? n.id,
          text: text(v),
          outside: r.location == kOutsideId,
          color: scale == null ? hv.s2 : kind.ramp.at(scale.t(v)),
        );
      },
      underlay: HeatmapPainter(plan: plan, data: data, cache: _heat, hv: hv),
      subtitle: (r) {
        final range = data.roomRange(r.id);
        if (range == null) return null;
        final (a, b) = range;
        if ((a - b).abs() < 0.05) return text(a);
        return '${heatValue(a, kind)} bis ${text(b)}';
      },
      roomStyle: (r) => data.rooms.containsKey(r.id)
          ? null
          : FloorRoomStyle(fill: hv.s1.withValues(alpha: 0.7)),
      onNodeTap: (n) => _tapReading(n, text(values[n.id]!)),
      onRoomTap: (r) {
        final range = data.roomRange(r.id);
        _say(
          range == null
              ? '${r.name}: kein Sensor auf dem Grundriss'
              : '${r.name}: ${_range(range.$1, range.$2, kind)}',
        );
      },
      card: HeatLegend(data: data),
    );
  }

  // ---- Bewegung -------------------------------------------------------------

  _LayerView _presenceView(HavenFloorPlan plan, MapReadings readings) {
    final hv = context.hv;
    final motion = readings.motion;
    final ids = [for (final m in motion) m.motionId!];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadHistory(ids));
    });
    final now = DateTime.now();
    final past = _minutes < -0.5 && _history.isNotEmpty;
    final at = past ? now.add(Duration(seconds: (_minutes * 60).round())) : now;
    final levels = presenceAt(motion, at, history: past ? _history : null);
    final sensorLevels = <String, double>{};
    for (final m in motion) {
      var on = m.motion;
      var since = m.motionSince;
      if (past) {
        final st = stateAt(_history[m.motionId] ?? const [], at);
        on = st?.isOn ?? false;
        since = st?.at;
      }
      sensorLevels[m.entityId] = presenceLevel(on: on, since: since, now: at);
    }
    return _LayerView(
      plan: plan,
      nodes: [
        for (final m in motion)
          FloorNode(
            id: m.entityId,
            point: PlanPoint(m.center.dx, m.center.dy, m.location),
          ),
      ],
      nodeBuilder: (context, n) => PresenceMarker(
        entityId: readings.of(n.id)!.motionId!,
        level: sensorLevels[n.id] ?? 0,
        // Auf dem Zeitstrahl zählt der Zustand von damals, ohne Puls.
        historic: past ? (sensorLevels[n.id] ?? 0) >= 1 : null,
      ),
      underlay: PresencePainter(
        plan: plan,
        levels: levels,
        sensors: [
          for (final m in motion) (m.center, sensorLevels[m.entityId] ?? 0),
        ],
        hv: hv,
      ),
      subtitle: (r) {
        final l = levels[r.id];
        if (l == null) return null;
        if (l.active) return past ? 'Bewegung' : 'Bewegung jetzt';
        if (l.since == null) return 'ruhig';
        return agoText(l.since!, at);
      },
      onNodeTap: (n) {
        final m = readings.of(n.id)!;
        final e = ref.read(entityProvider(m.motionId!));
        _tapReading(
          n,
          m.motion
              ? 'Bewegung'
              : (m.motionSince == null
                    ? 'ruhig'
                    : 'ruhig, ${agoText(m.motionSince!, now)}'),
        );
        if (e == null) return;
      },
      onRoomTap: _tapRoom,
      card: _PresenceCard(
        plan: plan,
        levels: levels,
        at: at,
        past: past,
        history: _history,
        now: now,
        minutes: _minutes,
        onMinutes: (v) {
          if (v.round() != _minutes.round()) Haptics.tick();
          setState(() => _minutes = v);
        },
        hasSensors: motion.isNotEmpty,
      ),
    );
  }

  // ---- Funknetz -------------------------------------------------------------

  _LayerView _networkView(HavenFloorPlan plan) {
    final hv = context.hv;
    final data = ref.watch(zigbeeMeshProvider);
    final scene = ref.watch(meshSceneProvider);
    final map = data.map;
    if (scene == null || map == null) {
      return _LayerView(
        plan: plan,
        gap: 2,
        card: _NetworkCard(
          text: data.loaded
              ? (data.error ??
                    'Noch keine Netzkarte. Miss das Netz im Vollbild.')
              : 'Netzkarte lädt',
          onOpen: () => context.push(zigbeeMeshPath),
        ),
      );
    }
    final st = MeshViewState.of(map, selected: _meshSel);
    if (_mesh.value != st) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _mesh.value = st;
      });
    }
    final sel = _meshSel == null ? null : scene.infos[_meshSel!];
    final lqi = _meshSel == null ? null : map.lqiToParent(_meshSel!);
    return _LayerView(
      plan: scene.plan,
      gap: 2,
      showOutside: !scene.autoLayout,
      nodes: MeshGraph.floorNodes(scene, map),
      nodeBuilder: (context, node) =>
          MeshNodeDot(info: scene.infos[node.id]!, map: map, state: _mesh),
      overlay: MeshEdgePainter(
        edges: map.edges,
        scene: scene,
        state: _mesh,
        hv: hv,
      ),
      roomStyle: (room) => FloorRoomStyle(
        fill: room.id == kNoRoomId ? hv.s2.withValues(alpha: 0.55) : null,
        border: hv.ln2,
      ),
      onNodeTap: (n) {
        Haptics.tick();
        setState(() => _meshSel = _meshSel == n.id ? null : n.id);
      },
      onRoomTap: (_) {
        if (_meshSel != null) setState(() => _meshSel = null);
      },
      onOutsideTap: () {
        if (_meshSel != null) setState(() => _meshSel = null);
      },
      card: _NetworkCard(
        text: sel == null
            ? '${map.nodes.length - 1} Geräte. Tippe ein Gerät für seinen Weg '
                  'zum Koordinator.'
            : '${sel.name}${sel.roomName == null ? '' : ' · ${sel.roomName}'}'
                  '${lqi == null ? '' : ' · LQI $lqi'}',
        legend: true,
        onOpen: () => context.push(
          _meshSel == null
              ? zigbeeMeshPath
              : '$zigbeeMeshPath?select=${Uri.encodeComponent(_meshSel!)}',
        ),
      ),
    );
  }

  // ---- Batterie -------------------------------------------------------------

  _LayerView _batteryView(HavenFloorPlan plan, MapReadings readings) {
    final bats = readings.batteries;
    final weak = [...bats.where((b) => b.battery! < 20)]
      ..sort((a, b) => a.battery!.compareTo(b.battery!));
    String name(String id) => ref.read(entityProvider(id))?.name ?? id;
    return _LayerView(
      plan: plan,
      nodes: [
        for (final b in bats)
          FloorNode(
            id: b.entityId,
            point: PlanPoint(b.center.dx, b.center.dy, b.location),
          ),
      ],
      nodeBuilder: (context, n) =>
          BatteryMarker(label: name(n.id), level: readings.of(n.id)!.battery!),
      subtitle: (r) {
        final mine = bats.where((b) => b.location == r.id).toList();
        if (mine.isEmpty) return null;
        final w = mine.where((b) => b.battery! < 20).length;
        return w == 0 ? '${mine.length} ok' : '$w schwach';
      },
      onNodeTap: (n) =>
          _tapReading(n, 'Batterie ${readings.of(n.id)!.battery!.round()} %'),
      onRoomTap: _tapRoom,
      card: _BatteryCard(
        total: bats.length,
        weak: [
          for (final w in weak) (_shortName(name(w.entityId)), w.battery!),
        ],
      ),
    );
  }
}

/// Gerätename ohne angehängte Eigenschaft („Sensor Terrasse Temperatur“).
String _shortName(String n) {
  for (final s in [
    ' Temperatur',
    ' Luftfeuchtigkeit',
    ' Belegung',
    ' Batterie',
    ' Tür',
  ]) {
    if (n.endsWith(s)) return n.substring(0, n.length - s.length);
  }
  return n;
}

/// Alles, was eine Kartenart der `FloorPlanView` übergibt.
class _LayerView {
  const _LayerView({
    required this.plan,
    required this.card,
    this.gap = 0,
    this.nodes = const [],
    this.nodeBuilder,
    this.underlay,
    this.overlay,
    this.roomStyle,
    this.subtitle,
    this.onNodeTap,
    this.onRoomTap,
    this.onOutsideTap,
    this.showOutside = true,
  });
  final HavenFloorPlan plan;
  final Widget card;
  final double gap;
  final List<FloorNode> nodes;
  final FloorNodeBuilder? nodeBuilder;
  final FloorOverlayPainter? underlay;
  final FloorOverlayPainter? overlay;
  final FloorRoomStyle? Function(FloorRoom)? roomStyle;
  final String? Function(FloorRoom)? subtitle;
  final ValueChanged<FloorNode>? onNodeTap;
  final ValueChanged<FloorRoom>? onRoomTap;
  final VoidCallback? onOutsideTap;
  final bool showOutside;
}

class _PresenceCard extends StatelessWidget {
  const _PresenceCard({
    required this.plan,
    required this.levels,
    required this.at,
    required this.past,
    required this.history,
    required this.now,
    required this.minutes,
    required this.onMinutes,
    required this.hasSensors,
  });

  final HavenFloorPlan plan;
  final Map<String, RoomPresence> levels;
  final DateTime at;
  final bool past;
  final Map<String, List<StateChange>> history;
  final DateTime now;
  final double minutes;
  final ValueChanged<double> onMinutes;
  final bool hasSensors;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    if (!hasSensors) {
      return SizedBox(
        height: 44,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Setz Bewegungs- oder Präsenzmelder im Editor auf den Grundriss.',
            style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
          ),
        ),
      );
    }
    final active = [
      for (final e in levels.entries)
        if (e.value.active) _locName(plan, e.key),
    ];
    MapEntry<String, RoomPresence>? last;
    for (final e in levels.entries) {
      final s = e.value.since;
      if (e.value.active || s == null) continue;
      if (last == null || s.isAfter(last.value.since!)) last = e;
    }
    final when = past ? 'vor ${(-minutes).round()} min' : 'Jetzt';
    final String text;
    if (active.isNotEmpty) {
      text = '$when: Bewegung im ${active.join(' und im ')}';
    } else if (last != null) {
      text =
          '$when ruhig. Zuletzt ${_locName(plan, last.key)}, '
          '${agoText(last.value.since!, at)}';
    } else {
      text = '$when ruhig';
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active.isNotEmpty ? presenceColor(hv) : hv.tx3,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HavenText.label.copyWith(color: hv.tx, fontSize: 13.5),
              ),
            ),
            if (past)
              PressScale(
                onTap: () => onMinutes(0),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 6,
                  ),
                  child: Text(
                    'Jetzt',
                    style: HavenText.label.copyWith(
                      color: hv.acc,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (history.isNotEmpty) ...[
          const SizedBox(height: 6),
          MotionTimeline(
            history: history,
            now: now,
            minutes: minutes,
            onChanged: onMinutes,
          ),
        ],
      ],
    );
  }
}

class _NetworkCard extends StatelessWidget {
  const _NetworkCard({
    required this.text,
    required this.onOpen,
    this.legend = false,
  });
  final String text;
  final VoidCallback onOpen;
  final bool legend;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    Widget key(Color c, String t) => Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 14,
            height: 3,
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 5),
          Text(t, style: HavenText.caption.copyWith(color: hv.tx2)),
        ],
      ),
    );
    return Row(
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: HavenText.body.copyWith(color: hv.tx, fontSize: 14),
              ),
              if (legend) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    key(hv.ok, 'stark'),
                    key(hv.warn, 'mittel'),
                    key(hv.bad, 'schwach'),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        RoundIconButton(
          icon: Icons.open_in_full_rounded,
          label: 'Funknetz im Vollbild',
          onTap: onOpen,
        ),
      ],
    );
  }
}

class _BatteryCard extends StatelessWidget {
  const _BatteryCard({required this.total, required this.weak});
  final int total;
  final List<(String, double)> weak;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return SizedBox(
      width: double.infinity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            total == 0
                ? 'Keine Batteriegeräte auf dem Grundriss'
                : weak.isEmpty
                ? 'Alle $total Batterien in Ordnung'
                : weak.length == 1
                ? 'Eine Batterie ist schwach'
                : '${weak.length} Batterien sind schwach',
            style: HavenText.label.copyWith(color: hv.tx, fontSize: 13.5),
          ),
          if (weak.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              [for (final (n, v) in weak.take(3)) '$n ${v.round()} %']
                  .join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: HavenText.caption.copyWith(color: hv.bad),
            ),
          ],
        ],
      ),
    );
  }
}

/// Unter der Karte: leuchtende Lampen als Punkte und „Alle aus“, oder eine
/// kurze Rückmeldung zum letzten Antippen.
class _StatusCard extends ConsumerWidget {
  const _StatusCard({required this.lights});
  final MapLights lights;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final on = [
      for (final l in lights.lamps.values)
        if (l.on) l,
    ];
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Expanded(
            child: on.isEmpty
                ? Text(
                    'Alle Lichter sind aus',
                    style: HavenText.body.copyWith(color: hv.tx2),
                  )
                : Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      height: 26,
                      width: 26.0 + 20 * (on.length.clamp(1, 8) - 1),
                      child: Stack(
                        children: [
                          for (var i = 0; i < on.length && i < 8; i++)
                            Positioned(
                              left: 20.0 * i,
                              child: Container(
                                width: 26,
                                height: 26,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: colorOf(
                                    uiColor(on[i].color, dark: hv.isDark),
                                  ),
                                  border: Border.all(color: hv.s1, width: 2),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
          ),
          if (on.isNotEmpty)
            PressScale(
              onTap: () {
                Haptics.tick();
                unawaited(ref.read(repositoryProvider).allLightsOff());
              },
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: hv.s2,
                  borderRadius: BorderRadius.circular(HavenRadii.pill),
                  border: Border.all(color: hv.ln2),
                ),
                child: Text(
                  'Alle aus',
                  style: HavenText.label.copyWith(color: hv.tx, fontSize: 13.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Leerzustand: kein Grundriss vorhanden.
class _EmptyMap extends StatelessWidget {
  const _EmptyMap();

  static final _sample = HavenFloorPlan(
    grid: const FloorGrid(cols: 12, rows: 10),
    rooms: [
      FloorRoom.rect(id: 'a', name: 'a', x: 0, y: 0, w: 7, h: 6),
      const FloorRoom(
        id: 'b',
        name: 'b',
        points: [
          GridPoint(7, 0),
          GridPoint(10, 0),
          GridPoint(12, 2),
          GridPoint(12, 4),
          GridPoint(7, 4),
        ],
      ),
      FloorRoom.rect(id: 'c', name: 'c', x: 7, y: 4, w: 5, h: 6),
      FloorRoom.rect(id: 'd', name: 'd', x: 0, y: 6, w: 7, h: 4),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        HavenSpace.page,
        24,
        HavenSpace.page,
        context.navClearance,
      ),
      children: [
        EntryAnimation(
          index: 0,
          child: HavenCard(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 190,
                  child: FloorPlanView(
                    plan: _sample,
                    interactive: false,
                    showLabels: false,
                    fill: true,
                    gap: 0.6,
                    padding: 4,
                    showOutside: false,
                    roomStyle: (r) => FloorRoomStyle(
                      fill: hv.acc.withValues(alpha: r.id == 'a' ? 0.28 : 0.12),
                      border: hv.acc.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Noch kein Grundriss',
                  textAlign: TextAlign.center,
                  style: HavenText.section.copyWith(color: hv.tx),
                ),
                const SizedBox(height: 8),
                Text(
                  'Zeichne deine Räume, gern auch schräg oder als L. Lampen und '
                  'Sensoren stehen dann an ihrem Platz, auch draußen.',
                  textAlign: TextAlign.center,
                  style: HavenText.body.copyWith(color: hv.tx2),
                ),
                const SizedBox(height: 24),
                HavenButton(
                  label: 'Grundriss zeichnen',
                  icon: Icons.edit_outlined,
                  primary: true,
                  onTap: () => context.push(mapEditorPath),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
