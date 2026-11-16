import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/haven_card.dart';
import '../../core/widgets/press_scale.dart';
import '../../core/widgets/segmented.dart';
import '../../data/models/floor_plan.dart';
import '../zigbee/widgets/device_icon.dart';
import '../zigbee/zigbee_providers.dart';
import 'device_pool.dart';
import 'floor_assign_sheet.dart';
import 'floor_editor_ops.dart';
import 'floor_plan_store.dart';
import 'floor_plan_view.dart';
import 'map_markers.dart';

enum _Mode { rooms, devices }

enum _OpKind { create, move, vertex, edge }

class _Op {
  _Op(this.kind, this.base, {this.roomId, this.index = 0, this.start});
  final _OpKind kind;

  /// Stand vor der Geste (für Rückgängig und als Ausgang jeder Änderung).
  final HavenFloorPlan base;
  final String? roomId;

  /// Ecke (vertex) bzw. Kante (edge).
  int index;
  final GridPoint? start;
  GridPoint? last;
  bool changed = false;
}

/// Was beim Ziehen eines Geräts über dem Finger steht.
@immutable
class EditorDragInfo {
  const EditorDragInfo({
    required this.name,
    required this.kind,
    this.target,
    this.remove = false,
  });
  final String name;
  final FloorKind kind;

  /// Zielort (Raumname oder „Draußen“), `null` außerhalb des Rasters.
  final String? target;

  /// Loslassen entfernt das Gerät vom Grundriss.
  final bool remove;
}

/// Grundriss-Editor (Vollbild): Räume als Polygone zeichnen und bearbeiten,
/// danach Geräte aus dem Pool auf Rasterzellen legen, auch draußen.
class FloorEditorScreen extends ConsumerStatefulWidget {
  const FloorEditorScreen({
    super.key,
    this.startInDevices = false,
    this.startSelected,
    this.startDrag,
  });

  /// Nur für Screenshots und Tests.
  final bool startInDevices;
  final String? startSelected;

  /// Zeigt das Ziehen-Label für diese Entity (Screenshot, kein echtes Ziehen).
  final String? startDrag;

  @override
  ConsumerState<FloorEditorScreen> createState() => _FloorEditorScreenState();
}

class _FloorEditorScreenState extends ConsumerState<FloorEditorScreen> {
  HavenFloorPlan? _plan;
  final List<HavenFloorPlan> _undo = [];
  late _Mode _mode = widget.startInDevices ? _Mode.devices : _Mode.rooms;
  String? _sel;
  String? _hover;
  GridPoint? _dragCell;
  _Op? _op;
  Rect? _draft; // Zellen
  bool _draftValid = true;
  FloorRoom? _invalid; // ungültige Form beim Ziehen (rot)
  int? _activeVertex;
  String? _hint;
  Timer? _hintTimer;
  FloorGeometry? _geo;
  Size _size = Size.zero;
  final _canvasKey = GlobalKey();
  final _dragInfo = ValueNotifier<EditorDragInfo?>(null);
  bool _zigbeeOpen = true;
  bool _otherOpen = false;
  bool _migrated = false;

  @override
  void dispose() {
    _hintTimer?.cancel();
    _dragInfo.dispose();
    super.dispose();
  }

  // ---- Zustand ---------------------------------------------------------

  void _say(String text) {
    setState(() => _hint = text);
    _hintTimer?.cancel();
    _hintTimer = Timer(const Duration(milliseconds: 2800), () {
      if (mounted) setState(() => _hint = null);
    });
  }

  /// Übernimmt [next] als neuen Stand. [before] landet im Rückgängig-Stapel.
  void _commit(HavenFloorPlan before, HavenFloorPlan next) {
    if (before == next) return;
    _undo.add(before);
    if (_undo.length > 40) _undo.removeAt(0);
    setState(() => _plan = next);
    unawaited(ref.read(floorPlanProvider.notifier).save(next));
  }

  void _undoLast() {
    if (_undo.isEmpty) return;
    Haptics.tap();
    final prev = _undo.removeLast();
    setState(() {
      _plan = prev;
      if (_sel != null && prev.room(_sel!) == null) _sel = null;
    });
    unawaited(ref.read(floorPlanProvider.notifier).save(prev));
  }

  // ---- Geometrie -------------------------------------------------------

  FloorGeometry _geometry(Size size) {
    _size = size;
    return _geo = FloorGeometry.compute(
      plan: _plan!,
      size: size,
      fitGrid: true,
      withOutside: true,
    );
  }

  /// Nächster Rasterpunkt (Ecke) zum Pixel.
  GridPoint _pointAt(Offset px) {
    final c = _geo!.pxToCell(px);
    final g = _plan!.grid;
    return GridPoint(
      c.dx.round().clamp(0, g.cols),
      c.dy.round().clamp(0, g.rows),
    );
  }

  /// Rasterzelle unter dem Pixel oder `null` außerhalb des Rasters.
  GridPoint? _cellAt(Offset px) {
    final c = _geo!.pxToCell(px);
    final cell = GridPoint(c.dx.floor(), c.dy.floor());
    return _plan!.grid.containsCell(cell.x, cell.y) ? cell : null;
  }

  RoomHandle? _handle(Offset p) {
    final id = _sel;
    if (id == null) return null;
    final px = _geo?.polygons[id];
    if (px == null) return null;
    return handleAt(px, p);
  }

  String _roomName(String id) =>
      id == kOutsideId ? kOutsideName : (_plan!.room(id)?.name ?? id);

  // ---- Räume zeichnen ----------------------------------------------------

  void _panStart(DragStartDetails d) {
    final plan = _plan!;
    final p = d.localPosition;
    switch (_handle(p)) {
      case VertexHandle(:final index):
        Haptics.tick();
        _op = _Op(_OpKind.vertex, plan, roomId: _sel, index: index);
        setState(() => _activeVertex = index);
        return;
      case EdgeHandle(:final index):
        _op = _Op(_OpKind.edge, plan, roomId: _sel, index: index);
        return;
      case null:
    }
    final id = _geo!.roomAt(p);
    if (id != null) {
      Haptics.tick();
      setState(() => _sel = id);
      _op = _Op(_OpKind.move, plan, roomId: id, start: _pointAt(p));
      return;
    }
    setState(() => _sel = null);
    _op = _Op(_OpKind.create, plan, start: _pointAt(p));
  }

  void _panUpdate(DragUpdateDetails d) {
    final op = _op;
    if (op == null) return;
    final pt = _pointAt(d.localPosition);
    switch (op.kind) {
      case _OpKind.create:
        final a = op.start!;
        final r = cellRect(a.x, a.y, pt.x, pt.y);
        if (op.last != pt) Haptics.tick();
        op.last = pt;
        final probe = FloorRoom.rect(
          id: '_draft',
          name: '',
          x: r.x,
          y: r.y,
          w: r.w,
          h: r.h,
        );
        setState(() {
          _draft = Rect.fromLTWH(
            r.x.toDouble(),
            r.y.toDouble(),
            r.w.toDouble(),
            r.h.toDouble(),
          );
          _draftValid = _createProblem(op.base, probe) == null;
        });
      case _OpKind.move:
        if (op.last == pt) return;
        op.last = pt;
        final room = op.base.room(op.roomId!)!;
        final m = moveRoom(
          room,
          pt.x - op.start!.x,
          pt.y - op.start!.y,
          op.base.grid,
        );
        final next = op.base.withRoomMoved(room.id, m.dx, m.dy);
        _applyRoom(op, next, next.room(room.id)!);
      case _OpKind.edge:
        // Ziehen an der Kantenmitte fügt dort eine Ecke ein und zieht sie.
        final room = op.base.room(op.roomId!)!;
        final n = room.points.length;
        if (pt == room.points[op.index] ||
            pt == room.points[(op.index + 1) % n]) {
          return;
        }
        final seed = insertVertex(
          room,
          op.index,
          edgeMidpoint(room, op.index) ?? pt,
        )!;
        _opBase = op.base;
        _op = _Op(
          _OpKind.vertex,
          op.base.withRoom(seed),
          roomId: room.id,
          index: op.index + 1,
        );
        Haptics.tick();
        setState(() => _activeVertex = op.index + 1);
        _panUpdate(d);
      case _OpKind.vertex:
        if (op.last == pt) return;
        op.last = pt;
        final room = op.base.room(op.roomId!)!;
        final cand = moveVertex(room, op.index, pt, op.base.grid);
        final problem = op.base.roomProblem(cand);
        if (problem != null) {
          if (_invalid == null) Haptics.tap();
          setState(() => _invalid = cand);
          _sayQuiet(problem);
          return;
        }
        if (_invalid != null) setState(() => _invalid = null);
        _applyRoom(op, op.base.withRoom(cand), cand);
    }
  }

  /// Ausgangsstand für Rückgängig, wenn eine Geste den Plan zwischendurch
  /// erweitert hat (Kante gezogen: erst Ecke einfügen, dann ziehen).
  HavenFloorPlan? _opBase;

  void _sayQuiet(String text) {
    if (_hint == text) return;
    _say(text);
  }

  String? _createProblem(HavenFloorPlan plan, FloorRoom r) {
    final b = r.bounds;
    if (b.width < 2 || b.height < 2) return 'Mindestens 2 × 2 Zellen';
    return plan.roomProblem(r);
  }

  void _applyRoom(_Op op, HavenFloorPlan next, FloorRoom room) {
    final plan = _plan!;
    final cur = plan.room(room.id);
    if (cur == room && plan == next) return;
    if (op.base.roomProblem(room) != null) return;
    Haptics.tick();
    op.changed = true;
    setState(() => _plan = next);
  }

  Future<void> _panEnd([DragEndDetails? _]) async {
    final op = _op;
    _op = null;
    final base = _opBase ?? op?.base;
    _opBase = null;
    setState(() {
      _activeVertex = null;
      _invalid = null;
    });
    if (op == null) return;
    final plan = _plan!;
    switch (op.kind) {
      case _OpKind.create:
        final d = _draft;
        final valid = _draftValid;
        setState(() => _draft = null);
        if (d == null) return;
        final probe = FloorRoom.rect(
          id: 'r${DateTime.now().microsecondsSinceEpoch}',
          name: 'Neuer Raum',
          x: d.left.round(),
          y: d.top.round(),
          w: d.width.round(),
          h: d.height.round(),
        );
        if (!valid) {
          Haptics.tap();
          _say(_createProblem(plan, probe) ?? 'Passt dort nicht hin');
          return;
        }
        Haptics.tap();
        _commit(plan, plan.withRoom(probe));
        setState(() => _sel = probe.id);
        await _assign(probe.id);
      case _OpKind.move || _OpKind.vertex || _OpKind.edge:
        if (op.changed && base != null && base != plan) {
          _undo.add(base);
          if (_undo.length > 40) _undo.removeAt(0);
          unawaited(ref.read(floorPlanProvider.notifier).save(plan));
          setState(() {});
        }
    }
  }

  void _tap(TapUpDetails d) {
    final plan = _plan!;
    switch (_handle(d.localPosition)) {
      case EdgeHandle(:final index):
        final room = plan.room(_sel!)!;
        final next = insertVertex(room, index);
        if (next == null) {
          _say('Die Wand ist zu kurz für eine neue Ecke');
          return;
        }
        final problem = plan.roomProblem(next);
        if (problem != null) {
          _say(problem);
          return;
        }
        Haptics.tap();
        _commit(plan, plan.withRoom(next));
        _say('Neue Ecke. Zieh sie an ihren Platz.');
        return;
      case VertexHandle():
        Haptics.tick();
        _say('Ecke ziehen verschiebt sie, lange drücken entfernt sie.');
        return;
      case null:
    }
    final id = _geo!.roomAt(d.localPosition);
    Haptics.tick();
    setState(() => _sel = id);
  }

  void _longPress(LongPressStartDetails d) {
    final plan = _plan!;
    final h = _handle(d.localPosition);
    if (h is VertexHandle) {
      final room = plan.room(_sel!)!;
      final next = removeVertex(room, h.index);
      if (next == null) {
        Haptics.tap();
        _say('Ein Raum braucht mindestens drei Ecken');
        return;
      }
      final problem = plan.roomProblem(next);
      if (problem != null) {
        _say(problem);
        return;
      }
      Haptics.tap();
      _commit(plan, plan.withRoom(next));
      _say('Ecke entfernt');
      return;
    }
    final id = _geo!.roomAt(d.localPosition);
    if (id != null && id != _sel) {
      Haptics.tick();
      setState(() => _sel = id);
    }
  }

  Future<void> _assign(String roomId) async {
    final plan = _plan;
    final room = plan?.room(roomId);
    if (room == null || !mounted) return;
    final snap = ref.read(snapshotProvider);
    final res = await showRoomAssignSheet(
      context,
      room: room,
      areas: snap.rooms,
      usedAreaIds: {
        for (final r in plan!.rooms)
          if (r.id != roomId && r.areaId != null) r.areaId!,
      },
    );
    if (res == null || !mounted) return;
    final cur = _plan!;
    final r = cur.room(roomId);
    if (r == null) return;
    _commit(
      cur,
      cur.withRoom(
        res.areaId == null
            ? r.copyWith(name: res.name, clearArea: true)
            : r.copyWith(name: res.name, areaId: res.areaId),
      ),
    );
  }

  void _deleteSelected() {
    final plan = _plan!;
    final id = _sel;
    if (id == null) return;
    Haptics.tap();
    _commit(plan, plan.withoutRoom(id));
    setState(() => _sel = null);
  }

  // ---- Geräte ------------------------------------------------------------

  Offset? _toLocal(Offset global) {
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    return box?.globalToLocal(global);
  }

  /// Zelle unter dem Finger oder `null` (außerhalb der Fläche oder des
  /// Rasters: Loslassen entfernt das Gerät).
  GridPoint? _dropCell(Offset global) {
    final local = _toLocal(global);
    if (local == null || _geo == null) return null;
    if (local.dx < 0 ||
        local.dy < 0 ||
        local.dx > _size.width ||
        local.dy > _size.height) {
      return null;
    }
    return _cellAt(local);
  }

  void _dragHover(Offset global, String name, FloorKind kind) {
    final cell = _dropCell(global);
    final loc = cell == null ? null : _plan!.locationOfCell(cell.x, cell.y);
    _dragInfo.value = EditorDragInfo(
      name: name,
      kind: kind,
      target: loc == null ? null : _roomName(loc),
      remove: cell == null,
    );
    if (cell != _dragCell || loc != _hover) {
      if (loc != _hover && loc != null) Haptics.tick();
      setState(() {
        _hover = loc;
        _dragCell = cell;
      });
    }
  }

  void _dropEntity(
    String entityId,
    Offset global, {
    FloorKind? kind,
    String? deviceId,
  }) {
    final plan = _plan!;
    final old = plan.placementOf(entityId);
    final cell = _dropCell(global);
    _dragInfo.value = null;
    setState(() {
      _hover = null;
      _dragCell = null;
    });
    if (cell == null) {
      // Außerhalb des Grundrisses: die Platzierung fällt weg, das Gerät
      // kehrt in den Pool zurück.
      if (old != null) {
        Haptics.tap();
        _commit(plan, plan.withoutPlacement(entityId));
        _say('Wieder in der Liste');
      }
      return;
    }
    final p = FloorPlacement(
      entityId: entityId,
      x: cell.x,
      y: cell.y,
      kind: kind ?? old?.kind,
      deviceId: deviceId ?? old?.deviceId,
    );
    Haptics.tap();
    _commit(plan, plan.withPlacement(p));
    if (plan.locationOfCell(cell.x, cell.y) == kOutsideId &&
        (old == null || plan.locationOf(old) != kOutsideId)) {
      _say('Steht jetzt draußen');
    }
  }

  /// Alle offenen Geräte eines Raums auf einmal in die Raummitte (Raster).
  void _quickPlace(PoolRoomGroup g, FloorRoom room) {
    final plan = _plan!;
    final cells = HavenFloorPlan.quickCells(
      room,
      g.devices.length,
      occupied: {for (final p in plan.placements) p.cell},
    );
    final ps = [
      for (var i = 0; i < g.devices.length; i++)
        FloorPlacement(
          entityId: g.devices[i].mainEntityId,
          x: cells[i].x,
          y: cells[i].y,
          kind: g.devices[i].kind,
          deviceId: g.devices[i].id,
        ),
    ];
    Haptics.tap();
    _commit(plan, plan.withPlacements(ps));
    _say(
      '${ps.length} ${ps.length == 1 ? 'Gerät' : 'Geräte'} in ${room.name}. '
      'Jetzt nur noch an die richtige Stelle ziehen.',
    );
  }

  /// Alle offenen Geräte einer Gruppe nach draußen, rund um die Wohnung.
  void _quickOutside(PoolRoomGroup g) {
    final plan = _plan!;
    final cells = plan.outsideCells(g.devices.length);
    if (cells.isEmpty) {
      _say('Draußen ist kein Platz frei. Vergrößere den Rand im Raster.');
      return;
    }
    final ps = [
      for (var i = 0; i < cells.length; i++)
        FloorPlacement(
          entityId: g.devices[i].mainEntityId,
          x: cells[i].x,
          y: cells[i].y,
          kind: g.devices[i].kind,
          deviceId: g.devices[i].id,
        ),
    ];
    Haptics.tap();
    _commit(plan, plan.withPlacements(ps));
    _say(
      '${ps.length} ${ps.length == 1 ? 'Gerät steht' : 'Geräte stehen'} '
      'jetzt draußen. Zieh sie an ihren Platz.',
    );
  }

  /// Alte Pläne (eine Platzierung je Entity) einmalig auf Geräte umstellen.
  void _migrate(DevicePool pool) {
    if (_migrated || pool.all.isEmpty) return;
    _migrated = true;
    final plan = _plan!;
    final next = plan.migrateDevices(
      [for (final d in pool.all) d.floorDevice],
      kinds: {for (final d in pool.all) d.id: d.kind},
    );
    if (identical(next, plan)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _plan != plan) return;
      setState(() => _plan = next);
      unawaited(ref.read(floorPlanProvider.notifier).save(next));
    });
  }

  Widget _drag(
    String entityId,
    FloorKind kind,
    Widget child, {
    bool pool = false,
    String? deviceId,
    String? name,
  }) {
    String label() =>
        name ?? ref.read(entityProvider(entityId))?.name ?? entityId;
    Widget feedback() => DragFeedback(
      info: _dragInfo,
      child: MapMarker(entityId: entityId, kind: kind),
    );
    void start() {
      _dragInfo.value = EditorDragInfo(name: label(), kind: kind);
    }

    void end(DraggableDetails d) =>
        _dropEntity(entityId, d.offset, kind: kind, deviceId: deviceId);
    if (pool) {
      return LongPressDraggable<String>(
        data: entityId,
        delay: const Duration(milliseconds: 150),
        hapticFeedbackOnStart: true,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: feedback(),
        childWhenDragging: Opacity(opacity: 0.35, child: child),
        onDragStarted: start,
        onDragUpdate: (d) => _dragHover(d.globalPosition, label(), kind),
        onDragEnd: end,
        child: child,
      );
    }
    return Draggable<String>(
      data: entityId,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: feedback(),
      childWhenDragging: Opacity(opacity: 0.25, child: child),
      onDragStarted: () {
        Haptics.tick();
        start();
      },
      onDragUpdate: (d) => _dragHover(d.globalPosition, label(), kind),
      onDragEnd: end,
      child: child,
    );
  }

  // ---- Aufbau --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final async = ref.watch(floorPlanProvider);
    if (_plan == null) {
      if (!async.hasValue) {
        return Scaffold(backgroundColor: hv.bg, body: const SizedBox.shrink());
      }
      _plan = async.value ?? const HavenFloorPlan();
      if (widget.startSelected != null &&
          _plan!.room(widget.startSelected!) != null) {
        _sel = widget.startSelected;
      }
      if (widget.startDrag != null) _previewDrag(widget.startDrag!);
    }
    final plan = _plan!;
    final devices = _mode == _Mode.devices;

    return Scaffold(
      backgroundColor: hv.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Row(
                children: [
                  RoundIconButton(
                    icon: Icons.arrow_back_rounded,
                    label: 'Zurück',
                    onTap: () =>
                        context.canPop() ? context.pop() : context.go('/map'),
                  ),
                  Expanded(
                    child: Text(
                      'Grundriss',
                      textAlign: TextAlign.center,
                      style: HavenText.headline.copyWith(
                        color: hv.tx,
                        fontSize: 22,
                      ),
                    ),
                  ),
                  Opacity(
                    opacity: _undo.isEmpty ? 0.4 : 1,
                    child: RoundIconButton(
                      icon: Icons.undo_rounded,
                      label: 'Rückgängig',
                      onTap: _undoLast,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: HavenSpace.page),
              child: HavenSegmented<_Mode>(
                options: const [
                  (_Mode.rooms, 'Räume zeichnen'),
                  (_Mode.devices, 'Geräte setzen'),
                ],
                selected: _mode,
                onChanged: (m) => setState(() {
                  _mode = m;
                  _hover = null;
                  _dragCell = null;
                }),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                child: LayoutBuilder(
                  builder: (context, cons) {
                    final geo = _geometry(Size(cons.maxWidth, cons.maxHeight));
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(child: _canvas(context, plan, geo)),
                        if (_previewInfo != null)
                          _previewOverlay(geo, _previewInfo!),
                      ],
                    );
                  },
                ),
              ),
            ),
            AnimatedContainer(
              duration: context.motion(HavenMotion.d2),
              curve: HavenMotion.out,
              height: devices ? 300 : 132,
              padding: const EdgeInsets.fromLTRB(
                HavenSpace.page,
                0,
                HavenSpace.page,
                14,
              ),
              child: devices ? _pool(plan) : _roomTools(plan),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Vorschau des Ziehens (nur Screenshots) ----------------------------

  ({String entityId, GridPoint cell, EditorDragInfo info})? _previewInfo;

  void _previewDrag(String entityId) {
    final plan = _plan!;
    final p = plan.placementOf(entityId);
    final room =
        plan.room(widget.startSelected ?? '') ??
        (plan.rooms.isEmpty ? null : plan.rooms.first);
    if (room == null) return;
    final cell = HavenFloorPlan.quickCells(
      room,
      1,
      occupied: {for (final x in plan.placements) x.cell},
    ).first;
    final name = ref.read(entityProvider(entityId))?.name ?? entityId;
    _mode = _Mode.devices;
    _hover = room.id;
    _dragCell = cell;
    _previewInfo = (
      entityId: entityId,
      cell: cell,
      info: EditorDragInfo(
        name: name,
        kind: p?.resolvedKind ?? FloorKind.ofEntity(entityId),
        target: room.name,
      ),
    );
  }

  Widget _previewOverlay(
    FloorGeometry geo,
    ({String entityId, GridPoint cell, EditorDragInfo info}) v,
  ) {
    final at = geo.cellToPx(v.cell.center) + const Offset(10, 14);
    return Positioned(
      left: at.dx,
      top: at.dy,
      child: IgnorePointer(
        child: DragFeedback(
          info: ValueNotifier(v.info),
          child: MapMarker(entityId: v.entityId, kind: v.info.kind),
        ),
      ),
    );
  }

  Widget _canvas(BuildContext context, HavenFloorPlan plan, FloorGeometry geo) {
    final hv = context.hv;
    final rooms = _mode == _Mode.rooms;
    final nodes = [
      for (final p in plan.placements)
        FloorNode(id: p.entityId, point: plan.pointOfCell(p.cell)),
    ];

    // Größe beim Ziehen: aktuelle Zielfläche in Zellen.
    final active = _draft;
    final selected = rooms && _sel != null ? plan.room(_sel!) : null;
    final view = FloorPlanView(
      plan: plan,
      interactive: false,
      fitGrid: true,
      fill: true,
      showGrid: true,
      nodes: nodes,
      nodeBuilder: (context, n) {
        final kind = plan.placementOf(n.id)!.resolvedKind;
        final marker = MapMarker(entityId: n.id, kind: kind);
        if (rooms) return marker;
        return _drag(n.id, kind, marker);
      },
      roomStyle: (r) {
        final isSel = rooms && r.id == _sel;
        final hovered = !rooms && r.id == _hover;
        if (hovered) {
          return FloorRoomStyle(
            fill: Color.alphaBlend(hv.acc.withValues(alpha: 0.22), hv.s1),
            border: hv.acc,
            borderWidth: 2,
          );
        }
        if (isSel) {
          return FloorRoomStyle(
            fill: Color.alphaBlend(hv.acc.withValues(alpha: 0.10), hv.s1),
            border: hv.acc,
            borderWidth: 2,
          );
        }
        return null;
      },
      overlayPainter: _EditorOverlay(
        hv: hv,
        selected: selected,
        active: active,
        valid: _draftValid,
        invalid: _invalid,
        activeVertex: _activeVertex,
        cellMeters: plan.grid.cellMeters,
        dragCell: rooms ? null : _dragCell,
        outsideHover: !rooms && _hover == kOutsideId,
      ),
    );

    return KeyedSubtree(
      key: _canvasKey,
      child: rooms
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              dragStartBehavior: DragStartBehavior.down,
              onPanStart: _panStart,
              onPanUpdate: _panUpdate,
              onPanEnd: _panEnd,
              onPanCancel: _panEnd,
              onTapUp: _tap,
              onLongPressStart: _longPress,
              child: IgnorePointer(child: view),
            )
          : view,
    );
  }

  // ---- Panels ---------------------------------------------------------------

  Widget _roomTools(HavenFloorPlan plan) {
    final hv = context.hv;
    final sel = _sel == null ? null : plan.room(_sel!);
    final m = plan.grid.cellMeters;
    String area(FloorRoom r) {
      final v = r.area * m * m;
      return (v == v.roundToDouble()
              ? v.toStringAsFixed(0)
              : v.toStringAsFixed(1))
          .replaceAll('.', ',');
    }

    return HavenCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      radius: HavenRadii.m,
      child: AnimatedSwitcher(
        duration: context.motion(HavenMotion.d2),
        child: sel == null
            ? Align(
                key: ValueKey('hint${_hint ?? ''}'),
                alignment: Alignment.centerLeft,
                child: Text(
                  _hint ??
                      'Im leeren Bereich ziehen legt einen Raum an. Raum '
                          'antippen wählt ihn, dann Ecken ziehen, Kantenmitte '
                          'antippen für eine neue Ecke.',
                  style: HavenText.body.copyWith(
                    color: _hint == null ? hv.tx2 : hv.warn,
                    fontSize: 14,
                  ),
                ),
              )
            : Row(
                key: ValueKey('sel${sel.id}'),
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          sel.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HavenText.headline.copyWith(color: hv.tx),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _hint ??
                              '${area(sel)} m² · ${sel.points.length} Ecken · '
                                  '${sel.areaId == null ? 'kein Bereich' : 'Bereich zugeordnet'}\n'
                                  'Lange drücken auf eine Ecke entfernt sie.',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: HavenText.caption.copyWith(
                            color: _hint == null ? hv.tx2 : hv.warn,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _ToolButton(
                    label: 'Zuordnen',
                    icon: Icons.label_outline_rounded,
                    onTap: () => _assign(sel.id),
                  ),
                  const SizedBox(width: 4),
                  _ToolButton(
                    label: 'Raum löschen',
                    icon: Icons.delete_outline_rounded,
                    destructive: true,
                    onTap: _deleteSelected,
                  ),
                ],
              ),
      ),
    );
  }

  Widget _pool(HavenFloorPlan plan) {
    final hv = context.hv;
    // Der Pool hängt an den vorhandenen Entities und Geräten, nicht an Werten.
    ref.watch(
      snapshotProvider.select(
        (s) => Object.hash(s.entities.length, s.rooms, s.devices),
      ),
    );
    final zb = ref.watch(zigbeeProvider.select((z) => z.devices));
    final pool = buildDevicePool(ref.read(snapshotProvider), zb, plan);
    _migrate(pool);
    final open = pool.open;
    return HavenCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
      radius: HavenRadii.m,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Geräte platzieren',
                  style: HavenText.headline.copyWith(color: hv.tx),
                ),
              ),
              _CountPill(text: open == 0 ? 'fertig' : '$open offen'),
            ],
          ),
          const SizedBox(height: 2),
          AnimatedSwitcher(
            duration: context.motion(HavenMotion.d2),
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topLeft,
              children: [...previous, ?current],
            ),
            child: Text(
              _hint ??
                  (open == 0
                      ? 'Alles platziert. Zieh ein Gerät hierher zurück, '
                            'dann ist es wieder offen.'
                      : 'Gerät halten und auf sein Feld ziehen. Neben der '
                            'Wohnung steht es draußen.'),
              key: ValueKey(_hint ?? open == 0),
              maxLines: 2,
              style: HavenText.caption.copyWith(
                color: _hint == null ? hv.tx3 : hv.tx,
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 4, right: 8, bottom: 6),
              children: [
                _section(plan, pool.zigbee, _zigbeeOpen, (v) {
                  setState(() => _zigbeeOpen = v);
                }),
                if (pool.other.total > 0)
                  _section(plan, pool.other, _otherOpen, (v) {
                    setState(() => _otherOpen = v);
                  }),
                if (pool.zigbee.total == 0 && pool.other.total == 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      'Noch keine Geräte geladen.',
                      style: HavenText.body.copyWith(
                        color: hv.tx2,
                        fontSize: 14,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(
    HavenFloorPlan plan,
    PoolSection sec,
    bool expanded,
    ValueChanged<bool> onExpand,
  ) {
    final hv = context.hv;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: expanded,
          label: '${sec.title}, ${sec.placed} von ${sec.total} platziert',
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              Haptics.tick();
              onExpand(!expanded);
            },
            child: Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: SizedBox(
                height: 44,
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            sec.title,
                            style: HavenText.label.copyWith(
                              color: hv.tx,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Row(
                            children: [
                              Expanded(
                                child: _Progress(
                                  value: sec.total == 0
                                      ? 1
                                      : sec.placed / sec.total,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                '${sec.placed} von ${sec.total} platziert',
                                style: HavenText.caption.copyWith(
                                  color: hv.tx2,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: context.motion(HavenMotion.d2),
                      curve: HavenMotion.out,
                      child: Icon(Icons.expand_more_rounded, color: hv.tx2),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: context.motion(HavenMotion.d2),
          curve: HavenMotion.out,
          alignment: Alignment.topCenter,
          child: !expanded
              ? const SizedBox(width: double.infinity)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [for (final g in sec.groups) _roomGroup(plan, g)],
                ),
        ),
      ],
    );
  }

  Widget _roomGroup(HavenFloorPlan plan, PoolRoomGroup g) {
    final hv = context.hv;
    final room = g.areaId == null ? null : plan.roomByIdOrArea(g.areaId!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${g.title} · ${g.devices.length}',
                  style: HavenText.label.copyWith(
                    color: hv.tx2,
                    fontSize: 12.5,
                  ),
                ),
              ),
              if (room != null && g.devices.length > 1)
                Semantics(
                  button: true,
                  label: 'Alle ${g.devices.length} in ${room.name} setzen',
                  excludeSemantics: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _quickPlace(g, room),
                    child: SizedBox(
                      height: HavenSpace.touch,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.grid_view_rounded,
                            size: 16,
                            color: hv.acc,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Schnell platzieren',
                            style: HavenText.label.copyWith(
                              color: hv.acc,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (g.areaId == null && plan.rooms.isNotEmpty)
                Semantics(
                  button: true,
                  label: 'Alle ${g.devices.length} nach draußen setzen',
                  excludeSemantics: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _quickOutside(g),
                    child: SizedBox(
                      height: HavenSpace.touch,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.park_outlined, size: 16, color: hv.ok),
                          const SizedBox(width: 6),
                          Text(
                            'Nach draußen',
                            style: HavenText.label.copyWith(
                              color: hv.ok,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final d in g.devices)
              _drag(
                d.mainEntityId,
                d.kind,
                _PoolChip(device: d),
                pool: true,
                deviceId: d.id,
                name: d.name,
              ),
          ],
        ),
        const SizedBox(height: 4),
      ],
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      margin: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(
        color: hv.s2,
        borderRadius: BorderRadius.circular(HavenRadii.pill),
      ),
      child: Text(
        text,
        style: HavenText.caption.copyWith(
          color: hv.tx2,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.value});
  final double value;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 5,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: hv.s3),
            TweenAnimationBuilder<double>(
              tween: Tween(end: value.clamp(0, 1)),
              duration: context.motion(HavenMotion.d3),
              curve: HavenMotion.out,
              builder: (context, v, _) => FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: v,
                child: ColoredBox(color: hv.acc),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.destructive = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      button: true,
      label: label,
      child: PressScale(
        onTap: onTap,
        child: SizedBox(
          width: HavenSpace.touch,
          height: HavenSpace.touch,
          child: Center(
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hv.s2,
                border: Border.all(color: hv.ln2),
              ),
              child: Icon(icon, size: 20, color: destructive ? hv.bad : hv.tx),
            ),
          ),
        ),
      ),
    );
  }
}

class _PoolChip extends StatelessWidget {
  const _PoolChip({required this.device});
  final PoolDevice device;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      label: '${device.name}, halten und auf den Grundriss ziehen',
      child: Container(
        height: 40,
        constraints: const BoxConstraints(maxWidth: 164),
        padding: const EdgeInsets.only(left: 5, right: 12),
        decoration: BoxDecoration(
          color: hv.s2,
          borderRadius: BorderRadius.circular(HavenRadii.pill),
          border: Border.all(color: hv.ln2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ZbDeviceIcon(type: device.iconType, size: 28),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                device.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HavenText.label.copyWith(color: hv.tx, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Was beim Ziehen eines Geräts unter und über dem Finger schwebt: der
/// Marker etwas größer, darüber ein Label mit Symbol, Name und Ziel.
class DragFeedback extends StatelessWidget {
  const DragFeedback({super.key, required this.info, required this.child});
  final ValueListenable<EditorDragInfo?> info;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Transform.translate(
        offset: const Offset(-24, -24),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: Transform.scale(scale: 1.25, child: child),
              ),
              Positioned(
                left: -120,
                right: -120,
                bottom: 62,
                child: Center(
                  child: ValueListenableBuilder<EditorDragInfo?>(
                    valueListenable: info,
                    builder: (context, v, _) => v == null
                        ? const SizedBox.shrink()
                        : DragLabel(info: v),
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

/// Pille über dem Finger: Symbol, Name, Pfeil, Zielraum bzw. „Draußen“.
class DragLabel extends StatelessWidget {
  const DragLabel({super.key, required this.info});
  final EditorDragInfo info;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final remove = info.remove || info.target == null;
    final target = remove ? 'Zurück in die Liste' : info.target!;
    final outside = info.target == kOutsideName;
    final accent = remove ? hv.tx3 : (outside ? hv.ok : hv.acc);
    return Container(
      constraints: const BoxConstraints(maxWidth: 236),
      padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
      decoration: BoxDecoration(
        color: hv.s1,
        borderRadius: BorderRadius.circular(HavenRadii.pill),
        border: Border.all(color: hv.ln2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF000000)
                .withValues(alpha: hv.isDark ? 0.5 : 0.16),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.withValues(alpha: 0.16),
            ),
            child: Icon(floorKindIcon(info.kind), size: 16, color: accent),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HavenText.label.copyWith(color: hv.tx, fontSize: 13),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      remove
                          ? Icons.undo_rounded
                          : (outside
                                ? Icons.park_outlined
                                : Icons.arrow_forward_rounded),
                      size: 12,
                      color: accent,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        target,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HavenText.caption.copyWith(
                          color: remove ? hv.tx2 : accent,
                          fontWeight: FontWeight.w700,
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Griffe am gewählten Raum (Ecken, Kantenmitten), Entwurfsrechteck,
/// ungültige Form, Zielzelle beim Ziehen und Größenangabe.
class _EditorOverlay extends FloorOverlayPainter {
  const _EditorOverlay({
    required this.hv,
    required this.selected,
    required this.active,
    required this.valid,
    required this.invalid,
    required this.activeVertex,
    required this.cellMeters,
    required this.dragCell,
    required this.outsideHover,
  });

  final HavenColors hv;
  final FloorRoom? selected;
  final Rect? active; // Zellen
  final bool valid;
  final FloorRoom? invalid;
  final int? activeVertex;
  final double cellMeters;
  final GridPoint? dragCell;
  final bool outsideHover;

  String _m(double v) =>
      (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1))
          .replaceAll('.', ',');

  @override
  void paint(Canvas canvas, Size size, FloorGeometry geo) {
    if (outsideHover && geo.outside != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(geo.outside!, const Radius.circular(22)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = hv.ok,
      );
    }
    final c = dragCell;
    if (c != null) {
      final r = Rect.fromPoints(
        geo.cellToPx(c.offset),
        geo.cellToPx(c.offset + const Offset(1, 1)),
      ).inflate(2);
      final color = outsideHover ? hv.ok : hv.acc;
      final rr = RRect.fromRectAndRadius(r, const Radius.circular(6));
      canvas.drawRRect(rr, Paint()..color = color.withValues(alpha: 0.22));
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = color,
      );
    }
    final d = active;
    if (d != null) {
      final px = Rect.fromPoints(
        geo.cellToPx(d.topLeft),
        geo.cellToPx(d.bottomRight),
      );
      final color = valid ? hv.acc : hv.bad;
      final path = roundedPolygonPath([
        px.topLeft,
        px.topRight,
        px.bottomRight,
        px.bottomLeft,
      ], math.min(16.0, 0.14 * px.shortestSide));
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.18));
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color,
      );
      _label(
        canvas,
        size,
        px.center,
        '${_m(d.width * cellMeters)} × ${_m(d.height * cellMeters)} m',
        color,
      );
      return;
    }
    final bad = invalid;
    if (bad != null) {
      final pts = [for (final p in bad.offsets) geo.cellToPx(p)];
      final path = roundedPolygonPath(pts, 6);
      canvas.drawPath(path, Paint()..color = hv.bad.withValues(alpha: 0.14));
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = hv.bad,
      );
    }
    final s = selected;
    if (s == null) return;
    final pts = geo.polygons[s.id];
    if (pts == null) return;
    // Kantenmitten: neue Ecke einfügen.
    final plus = Paint()
      ..color = hv.acc
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < pts.length; i++) {
      final a = s.points[i];
      final b = s.points[(i + 1) % pts.length];
      if ((a.x - b.x).abs() < 2 && (a.y - b.y).abs() < 2) continue;
      final m = (pts[i] + pts[(i + 1) % pts.length]) / 2;
      canvas.drawCircle(m, 7.5, Paint()..color = hv.s1);
      canvas.drawCircle(
        m,
        7.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = hv.acc.withValues(alpha: 0.7),
      );
      canvas.drawLine(m - const Offset(3.2, 0), m + const Offset(3.2, 0), plus);
      canvas.drawLine(m - const Offset(0, 3.2), m + const Offset(0, 3.2), plus);
    }
    // Ecken.
    for (var i = 0; i < pts.length; i++) {
      final on = i == activeVertex;
      final r = on ? 11.0 : 8.0;
      if (on) {
        canvas.drawCircle(
          pts[i],
          20,
          Paint()..color = hv.acc.withValues(alpha: 0.16),
        );
      }
      canvas.drawCircle(pts[i], r, Paint()..color = on ? hv.acc : hv.s1);
      canvas.drawCircle(
        pts[i],
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..color = hv.acc,
      );
    }
    if (activeVertex != null) {
      final area = s.area * cellMeters * cellMeters;
      _label(
        canvas,
        size,
        geo.roomCellRect(s.id, s.innerRect).center,
        '${_m((area * 10).round() / 10)} m²',
        hv.acc,
      );
    }
  }

  void _label(
    Canvas canvas,
    Size size,
    Offset center,
    String text,
    Color color,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: HavenText.label.copyWith(
          color: color == hv.acc ? hv.ai : const Color(0xFFFFFFFF),
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    const pad = EdgeInsets.symmetric(horizontal: 10, vertical: 5);
    final w = tp.width + pad.horizontal;
    final h = tp.height + pad.vertical;
    var o = Offset(center.dx - w / 2, center.dy - h / 2);
    o = Offset(
      o.dx.clamp(2, math.max(2, size.width - w - 2)),
      o.dy.clamp(2, math.max(2, size.height - h - 2)),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(o.dx, o.dy, w, h),
        Radius.circular(h / 2),
      ),
      Paint()..color = color,
    );
    tp.paint(canvas, o + Offset(pad.left, pad.top));
  }

  @override
  bool shouldRepaint(_EditorOverlay old) =>
      old.hv != hv ||
      old.selected != selected ||
      old.active != active ||
      old.valid != valid ||
      old.invalid != invalid ||
      old.activeVertex != activeVertex ||
      old.dragCell != dragCell ||
      old.outsideHover != outsideHover;
}
