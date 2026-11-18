import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/skeleton.dart';
import '../../../core/widgets/haven_button.dart';
import '../../../core/widgets/haven_card.dart';
import '../../../core/widgets/press_scale.dart';
import '../../../core/widgets/section_header.dart';
import '../../../data/models/floor_plan.dart';
import '../../../data/models/zigbee_network.dart';
import '../../map/floor_plan_store.dart';
import '../../map/map_routes.dart';
import '../widgets/zb_common.dart';
import '../zigbee_model.dart';
import '../zigbee_providers.dart';
import '../zigbee_screen.dart' show zigbeeDevicePath;
import '../../map/map_3d.dart';
import 'mesh_graph.dart';
import 'mesh_providers.dart';
import 'mesh_scene.dart';
import '../../../core/widgets/horizontal_scroller.dart';

const String zigbeeMeshPath = '/zigbee/mesh';

/// Vollbild: Netz-Graph auf dem Grundriss (Spec 5a).
class ZigbeeMeshScreen extends ConsumerStatefulWidget {
  const ZigbeeMeshScreen({super.key, this.select, this.filter});

  /// IEEE eines Knotens, der beim Öffnen gewählt ist.
  final String? select;

  /// Filter beim Öffnen (Standard: nur die Wege).
  final MeshFilter? filter;

  @override
  ConsumerState<ZigbeeMeshScreen> createState() => _ZigbeeMeshScreenState();
}

class _ZigbeeMeshScreenState extends ConsumerState<ZigbeeMeshScreen> {
  final _state = ValueNotifier(const MeshViewState());
  final _proj = MeshProjection();
  MeshFilter _filter = MeshFilter.tree;
  bool _cancelled = false;
  String? _selected;
  bool _placing = false;
  PlanPoint? _draft;
  Offset? _dragPx;

  @override
  void initState() {
    super.initState();
    _selected = widget.select;
    _filter = widget.filter ?? MeshFilter.tree;
  }

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  void _recompute(ZbNetworkMap? map) {
    _state.value = map == null
        ? MeshViewState(filter: _filter)
        : MeshViewState.of(map, filter: _filter, selected: _selected);
  }

  void _back() => context.canPop() ? context.pop() : context.go('/zigbee');

  void _select(ZbNetworkMap map, String ieee) {
    _selected = _selected == ieee ? null : ieee;
    _recompute(map);
  }

  Future<void> _measure() async {
    final ok = await showZbSheet<bool>(
      context,
      builder: (ctx) {
        final hv = ctx.hv;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Netz neu messen',
              style: HavenText.section.copyWith(color: hv.tx),
            ),
            const SizedBox(height: 8),
            Text(
              'Zigbee2MQTT fragt dafür jedes Gerät nach seinen Nachbarn. Das belastet das Netz kurz und kann bis zu einer Minute dauern. Geräte reagieren in dieser Zeit eventuell langsamer.',
              style: HavenText.body.copyWith(color: hv.tx2),
            ),
            const SizedBox(height: 18),
            HavenButton(
              label: 'Jetzt messen',
              icon: Icons.radar_rounded,
              primary: true,
              onTap: () => Navigator.of(ctx).pop(true),
            ),
            const SizedBox(height: 8),
            HavenButton(
              label: 'Abbrechen',
              onTap: () => Navigator.of(ctx).pop(false),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) return;
    _cancelled = false;
    final err = await ref.read(zigbeeMeshProvider.notifier).refresh();
    if (!mounted || _cancelled) return;
    // Im Hintergrund meldet das Ende die Messung selbst (notice).
    if (err != null) {
      zbToast(context, err, error: true);
    } else if (ref.read(zigbeeMeshProvider).legacy) {
      zbToast(context, 'Netz neu gemessen');
    }
  }

  void _cancelMeasure() {
    _cancelled = true;
    ref.read(zigbeeMeshProvider.notifier).cancel();
  }

  // ---- Koordinator platzieren ----------------------------------------------

  void _togglePlacing() {
    setState(() {
      _placing = !_placing;
      _draft = null;
      if (_placing) {
        unawaited(
          ref.read(meshControllerProvider).show(yaw: 0, pitch: 0, fov: 0),
        );
        _selected = null;
        _recompute(ref.read(zigbeeMeshProvider).map);
      } else {
        // Fertig platziert: zurück zur gewählten Ansicht.
        unawaited(
          showMapOverview(
            ref.read(meshControllerProvider),
            ref.read(map3dSettingsProvider),
          ),
        );
      }
    });
  }

  /// Punkt zu einem Pixel: die Rasterzelle darunter (Raum oder Draußen),
  /// im Raster gehalten, nie im Bereich „Ohne Raum“.
  PlanPoint? _pointAt(MeshScene scene, Offset px) {
    final g = scene.plan.grid;
    final m = _proj.current?.toFloor(px);
    if (m == null) return null;
    final f = m / g.cellMeters;
    final c = GridPoint(f.dx.floor(), f.dy.floor());
    final cell = GridPoint(c.x.clamp(0, g.cols - 1), c.y.clamp(0, g.rows - 1));
    final p = scene.plan.pointOfCell(cell);
    if (p.roomId == kNoRoomId) return null;
    return p;
  }

  Future<void> _dropCoordinator() async {
    final p = _draft;
    _dragPx = null;
    final saved = ref.read(floorPlanProvider).value;
    if (p == null || saved == null) return;
    await ref
        .read(floorPlanProvider.notifier)
        .save(saved.withCoordinator(p.cell));
    if (mounted) setState(() => _draft = null);
  }

  // ---- Bauen ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final data = ref.watch(zigbeeMeshProvider);
    var scene = ref.watch(meshSceneProvider);
    ref.listen(
      zigbeeMeshProvider.select((d) => d.map),
      (_, m) => _recompute(m),
    );
    ref.listen(zigbeeMeshProvider.select((d) => d.noticeId), (_, _) {
      final n = ref.read(zigbeeMeshProvider).notice;
      if (n != null && mounted) zbToast(context, n);
    });
    final map = data.map;
    if (map != null && _state.value.filter != _filter) _recompute(map);
    if (map != null && !_state.value.hasSelection && _selected != null) {
      // Erstes Bild mit `select`.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _recompute(map);
      });
    }
    if (scene != null && _draft != null) scene = scene.withCoordinator(_draft!);

    return Scaffold(
      backgroundColor: hv.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Header(
              measuredAt: map?.measuredAt,
              refreshing: data.refreshing,
              onBack: _back,
              onMeasure: data.refreshing ? null : _measure,
            ),
            if (scene != null && map != null) ...[
              _Controls(
                filter: _filter,
                onFilter: (f) => setState(() {
                  _filter = f;
                  _recompute(map);
                }),
                placing: _placing,
                canPlace: !scene.autoLayout && scene.coordinatorIeee != null,
                onPlace: _togglePlacing,
              ),
              if (data.error != null && !data.refreshing)
                _Hint(
                  icon: Icons.error_outline_rounded,
                  text: map.measuredAt == null
                      ? data.error!
                      : '${data.error!} ${meshStandLabel(map.measuredAt!)}.',
                ),
              if (scene.autoLayout && !_placing)
                _Hint(
                  icon: Icons.edit_outlined,
                  text: 'Zeichne deinen Grundriss für die echte Lage.',
                  onTap: () => context.push(mapEditorPath),
                ),
              if (_placing)
                _Hint(
                  icon: Icons.open_with_rounded,
                  text:
                      'Zieh den Koordinator dorthin, wo der Stick steckt. Die Lage wird im Grundriss gespeichert.',
                ),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: _graph(context, scene, map)),
                    Positioned(
                      left: 12,
                      right: 12,
                      top: 8,
                      child: AnimatedSwitcher(
                        duration: context.motion(HavenMotion.d2),
                        child: data.refreshing
                            ? MeasureProgress(
                                started: data.refreshStarted,
                                legacy: data.legacy,
                                onCancel: data.legacy ? _cancelMeasure : null,
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ],
                ),
              ),
            ] else
              Expanded(
                child: _Empty(
                  data: data,
                  onMeasure: _measure,
                  onCancel: _cancelMeasure,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _graph(BuildContext context, MeshScene scene, ZbNetworkMap map) {
    return LayoutBuilder(
      builder: (context, cons) {
        final cid = scene.coordinatorIeee;
        MeshCoordinatorDrag? drag;
        if (_placing && cid != null) {
          drag = MeshCoordinatorDrag(
            onStart: () => _dragPx = _proj.current?.markers[cid],
            onUpdate: (d) {
              final at =
                  (_dragPx ?? _proj.current?.markers[cid] ?? Offset.zero) + d;
              _dragPx = at;
              final p = _pointAt(scene, at);
              if (p != null && p != _draft) setState(() => _draft = p);
            },
            onEnd: _dropCoordinator,
          );
        }
        return Stack(
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: MeshGraph(
                  scene: scene,
                  map: map,
                  state: _state,
                  projection: _proj,
                  interactive: !_placing,
                  coordinatorDrag: drag,
                  onNodeTap: _placing ? null : (id) => _select(map, id),
                  onRoomTap: () {
                    if (_selected == null) return;
                    _selected = null;
                    _recompute(map);
                  },
                ),
              ),
            ),
            // Wie auf der Karte: Draufsicht oder 3D, zurück zur Übersicht.
            // Beim Platzieren des Koordinators bleibt es bei der Draufsicht.
            if (!_placing)
              Positioned(
                top: 8,
                right: 12,
                child: Map3DControls(
                  axis: Axis.horizontal,
                  controller: ref.watch(meshControllerProvider),
                  insets: EdgeInsets.zero,
                  onRecenter: () {
                    if (_selected == null) return;
                    _selected = null;
                    _recompute(map);
                  },
                ),
              ),
            Positioned.fill(
              child: ValueListenableBuilder<MeshViewState>(
                valueListenable: _state,
                builder: (context, st, _) {
                  // Das Sheet weicht dem Knoten aus: unten, außer er liegt in
                  // der unteren Hälfte.
                  final y = st.selected == null
                      ? null
                      : _proj.current?.markers[st.selected!]?.dy;
                  final top = y != null && y > cons.maxHeight * 0.5;
                  return Align(
                    alignment: top
                        ? Alignment.topCenter
                        : Alignment.bottomCenter,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        12,
                        12,
                        12,
                        12 + MediaQuery.paddingOf(context).bottom,
                      ),
                      child: AnimatedSwitcher(
                        duration: context.motion(HavenMotion.d2),
                        switchInCurve: HavenMotion.out,
                        transitionBuilder: (child, a) => FadeTransition(
                          opacity: a,
                          child: SlideTransition(
                            position: Tween(
                              begin: const Offset(0, 0.25),
                              end: Offset.zero,
                            ).animate(a),
                            child: child,
                          ),
                        ),
                        child: st.selected == null
                            ? const SizedBox.shrink(key: ValueKey('none'))
                            : MeshInfoPanel(
                                key: ValueKey(st.selected),
                                ieee: st.selected!,
                                map: map,
                                scene: scene,
                                onClose: () {
                                  _selected = null;
                                  _recompute(map);
                                },
                              ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---- Kopf, Filter, Hinweise ---------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({
    required this.measuredAt,
    required this.refreshing,
    required this.onBack,
    required this.onMeasure,
  });
  final DateTime? measuredAt;
  final bool refreshing;
  final VoidCallback onBack;
  final VoidCallback? onMeasure;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final sub = refreshing
        ? 'Messung läuft'
        : measuredAt == null
        ? 'Noch nicht gemessen'
        : 'gemessen ${agoLabel(measuredAt!)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 12, 0),
      child: Row(
        children: [
          RoundIconButton(
            icon: Icons.arrow_back_rounded,
            label: 'Zurück',
            onTap: onBack,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Funknetz',
                  style: HavenText.headline.copyWith(color: hv.tx),
                ),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HavenText.caption.copyWith(color: hv.tx2),
                ),
              ],
            ),
          ),
          PressScale(
            onTap: onMeasure,
            child: Semantics(
              button: true,
              label: 'Netz neu messen',
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: hv.s1,
                  borderRadius: BorderRadius.circular(HavenRadii.pill),
                  border: Border.all(color: hv.ln2),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    refreshing
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: hv.acc,
                            ),
                          )
                        : Icon(Icons.refresh_rounded, size: 18, color: hv.tx),
                    const SizedBox(width: 8),
                    Text(
                      'Netz neu messen',
                      style: HavenText.label.copyWith(
                        color: refreshing ? hv.tx3 : hv.tx,
                        fontSize: 13.5,
                      ),
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

class _Controls extends StatelessWidget {
  const _Controls({
    required this.filter,
    required this.onFilter,
    required this.placing,
    required this.canPlace,
    required this.onPlace,
  });
  final MeshFilter filter;
  final ValueChanged<MeshFilter> onFilter;
  final bool placing;
  final bool canPlace;
  final VoidCallback onPlace;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Column(
      children: [
        SizedBox(
          height: 52,
          child: HorizontalScroller(
            builder: (context, controller) => ListView(
              controller: controller,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              children: [
                for (final f in MeshFilter.values)
                  _Chip(
                    label: f.label,
                    selected: filter == f && !placing,
                    onTap: () => onFilter(f),
                  ),
                if (canPlace)
                  _Chip(
                    label: placing ? 'Fertig' : 'Koordinator platzieren',
                    icon: placing ? Icons.check_rounded : Icons.hub_rounded,
                    selected: placing,
                    onTap: onPlace,
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: Wrap(
            spacing: 14,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Key(color: hv.ok, text: 'gut'),
              _Key(color: hv.warn, text: 'mittel'),
              _Key(color: hv.bad, text: 'schwach'),
              Text(
                'Pfeil zum Elternknoten',
                style: HavenText.caption.copyWith(color: hv.tx3),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.color, required this.text});
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 14,
        height: 3,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 5),
      Text(text, style: HavenText.caption.copyWith(color: context.hv.tx2)),
    ],
  );
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: PressScale(
        onTap: onTap,
        child: Semantics(
          button: true,
          selected: selected,
          label: label,
          child: Center(
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: selected ? hv.acc.withValues(alpha: 0.16) : hv.s1,
                borderRadius: BorderRadius.circular(HavenRadii.pill),
                border: Border.all(color: selected ? hv.acc : hv.ln2),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 16, color: selected ? hv.acc : hv.tx2),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    label,
                    style: HavenText.label.copyWith(
                      color: selected ? hv.tx : hv.tx2,
                      fontSize: 13.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text, this.onTap});
  final IconData icon;
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: HavenCard(
        radius: HavenRadii.m,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        onTap: onTap,
        child: Row(
          children: [
            Icon(icon, size: 18, color: hv.acc),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: HavenText.body.copyWith(color: hv.tx, fontSize: 13.5),
              ),
            ),
            if (onTap != null)
              Icon(Icons.chevron_right_rounded, size: 20, color: hv.tx3),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({
    required this.data,
    required this.onMeasure,
    required this.onCancel,
  });
  final MeshData data;
  final VoidCallback onMeasure;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    if (data.refreshing) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: MeasureProgress(
            started: data.refreshStarted,
            legacy: data.legacy,
            onCancel: data.legacy ? onCancel : null,
          ),
        ),
      );
    }
    if (!data.loaded) {
      return Center(
        child: SkeletonScope(
          label: 'Netzkarte lädt',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Skeleton(width: 260, height: 260, radius: HavenRadii.xl),
              const SizedBox(height: 14),
              Text(
                'Netzkarte lädt',
                textAlign: TextAlign.center,
                style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              data.error != null
                  ? Icons.cloud_off_rounded
                  : Icons.radar_rounded,
              size: 36,
              color: hv.tx3,
            ),
            const SizedBox(height: 12),
            Text(
              data.error ??
                  'Es gibt noch keine Netzkarte. Miss das Netz einmal, danach liegt sie in Home Assistant bereit.',
              textAlign: TextAlign.center,
              style: HavenText.body.copyWith(color: hv.tx2),
            ),
            const SizedBox(height: 16),
            HavenButton(
              label: 'Netz neu messen',
              icon: Icons.refresh_rounded,
              onTap: onMeasure,
            ),
          ],
        ),
      ),
    );
  }
}

/// Wartezustand während „Netz neu messen“: laufende Uhr, unbestimmter
/// Fortschritt (die Integration meldet keinen echten) und Hinweis. Mit
/// [onCancel] (nur bei älterer Integration) zusätzlich „Abbrechen“.
class MeasureProgress extends StatefulWidget {
  const MeasureProgress({
    super.key,
    this.started,
    this.onCancel,
    this.legacy = false,
  });
  final DateTime? started;
  final VoidCallback? onCancel;

  /// Integration vor 0.5.1: Hinweis zum Aktualisieren.
  final bool legacy;

  @override
  State<MeasureProgress> createState() => _MeasureProgressState();
}

class _MeasureProgressState extends State<MeasureProgress> {
  Timer? _tick;
  late DateTime _start = widget.started ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(
      const Duration(seconds: 1),
      (_) => mounted ? setState(() {}) : null,
    );
  }

  @override
  void didUpdateWidget(MeasureProgress old) {
    super.didUpdateWidget(old);
    if (widget.started != null && widget.started != old.started) {
      _start = widget.started!;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final elapsed = meshElapsedLabel(DateTime.now().difference(_start));
    return Semantics(
      liveRegion: true,
      label: 'Messung läuft seit $elapsed',
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
        decoration: BoxDecoration(
          color: hv.s1,
          borderRadius: BorderRadius.circular(HavenRadii.l),
          border: Border.all(color: hv.ln2),
          boxShadow: hv.shadow,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.radar_rounded, size: 20, color: hv.acc),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Messung läuft seit $elapsed … das kann mehrere Minuten dauern, wenn Geräte nicht erreichbar sind.',
                    style: HavenText.body.copyWith(color: hv.tx, fontSize: 14),
                  ),
                ),
                if (widget.onCancel != null) ...[
                  const SizedBox(width: 6),
                  TextLink('Abbrechen', onTap: widget.onCancel!),
                ],
                const SizedBox(width: 8),
              ],
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: SizedBox(
                  height: 6,
                  child: LinearProgressIndicator(
                    backgroundColor: hv.s3,
                    color: hv.acc,
                    minHeight: 6,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                widget.legacy
                    ? '$meshLegacyHint. Du kannst die Seite verlassen, das Ergebnis kommt trotzdem an.'
                    : 'Zigbee2MQTT fragt jedes Gerät nach seinen Nachbarn. Du kannst die App weiter benutzen und die Seite verlassen.',
                style: HavenText.caption.copyWith(color: hv.tx2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Info-Sheet ------------------------------------------------------------------

/// Kompaktes Sheet zum gewählten Knoten, unten über dem Graphen. Der Graph
/// bleibt bedienbar und zeigt den Pfad weiter hervorgehoben.
class MeshInfoPanel extends ConsumerWidget {
  const MeshInfoPanel({
    super.key,
    required this.ieee,
    required this.map,
    required this.scene,
    required this.onClose,
  });
  final String ieee;
  final ZbNetworkMap map;
  final MeshScene scene;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final info = scene.infos[ieee];
    final node = map.node(ieee);
    if (info == null || node == null) return const SizedBox.shrink();
    final parent = map.parentOf(ieee);
    final parentName = parent == null ? null : scene.infos[parent]?.name;
    final lqi = map.lqiToParent(ieee);
    final kids = map.childrenOf(ieee).length;
    final hops = math.max(0, map.pathToCoordinator(ieee).length - 1);
    final view = ref.watch(zigbeeViewProvider(ieee));
    final room = scene.roomOf(ieee);
    final roomName = room == kNoRoomId
        ? 'Ohne Raum'
        : (view?.roomName ?? info.roomName);
    final type = switch (info.kind) {
      ZbNodeKind.coordinator => 'Koordinator',
      ZbNodeKind.router => 'Router',
      ZbNodeKind.endDevice => 'Endgerät',
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
      decoration: BoxDecoration(
        color: hv.s1,
        borderRadius: BorderRadius.circular(HavenRadii.l),
        border: Border.all(color: hv.ln2),
        boxShadow: hv.shadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HavenText.headline.copyWith(color: hv.tx),
                    ),
                    Text(
                      [
                        type,
                        ?roomName,
                        if (info.ghost) 'lange nicht gesehen',
                        if (info.failed) 'bei der Messung nicht erreichbar',
                      ].join(' · '),
                      style: HavenText.caption.copyWith(color: hv.tx2),
                    ),
                  ],
                ),
              ),
              RoundIconButton(
                icon: Icons.close_rounded,
                label: 'Schließen',
                onTap: onClose,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Column(
              children: [
                if (lqi != null)
                  _Row(
                    'Signal zum Elternknoten',
                    child: ZbPill(
                      text: '$lqi · ${LqiLevel.of(lqi).label}',
                      color: lqiColor(context, lqi),
                    ),
                  ),
                if (parentName != null) _Row('Elternknoten', value: parentName),
                if (node.kind != ZbNodeKind.endDevice)
                  _Row('Geräte daran', value: kids == 0 ? 'keine' : '$kids'),
                if (map.neighborCount(ieee) > 0)
                  _Row('Nachbarn', value: '${map.neighborCount(ieee)}'),
                if (parent != null)
                  _Row(
                    'Weg zum Koordinator',
                    value: hops == 1 ? 'direkt' : '$hops Sprünge',
                  ),
                if (parent == null && !node.isCoordinator)
                  _Row('Verbindung', value: 'keine bekannt'),
              ],
            ),
          ),
          if (!node.isCoordinator && view != null) ...[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: HavenButton(
                label: 'Gerät öffnen',
                icon: Icons.open_in_new_rounded,
                primary: true,
                onTap: () => context.push(zigbeeDevicePath(ieee)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, {this.value, this.child});
  final String label;
  final String? value;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
            ),
          ),
          const SizedBox(width: 12),
          ?child,
          if (value != null)
            Flexible(
              child: Text(
                value!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HavenText.label.copyWith(color: hv.tx, fontSize: 14.5),
              ),
            ),
        ],
      ),
    );
  }
}
