import 'dart:async';
import 'dart:math' as math;

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

enum _OpKind { create, move, resize }

class _Op {
  _Op(
    this.kind,
    this.base, {
    this.room,
    this.mask = 0,
    this.start,
    this.anchor,
  });
  final _OpKind kind;

  /// Stand vor der Geste (für Rückgängig).
  final HavenFloorPlan base;
  final FloorRoom? room;
  final int mask;
  final Offset? start;
  final (int, int)? anchor;
  (int, int)? last;
  bool changed = false;
}

/// Grundriss-Editor (Vollbild): Räume zeichnen, verschieben und in der Größe
/// ziehen, danach Geräte aus dem Pool in Räume legen.
class FloorEditorScreen extends ConsumerStatefulWidget {
  const FloorEditorScreen({
    super.key,
    this.startInDevices = false,
    this.startSelected,
  });

  /// Nur für Screenshots und Tests.
  final bool startInDevices;
  final String? startSelected;

  @override
  ConsumerState<FloorEditorScreen> createState() => _FloorEditorScreenState();
}

class _FloorEditorScreenState extends ConsumerState<FloorEditorScreen> {
  HavenFloorPlan? _plan;
  final List<HavenFloorPlan> _undo = [];
  late _Mode _mode = widget.startInDevices ? _Mode.devices : _Mode.rooms;
  String? _sel;
  String? _hover;
  _Op? _op;
  Rect? _draft; // Zellen
  bool _draftValid = true;
  String? _hint;
  Timer? _hintTimer;
  FloorGeometry? _geo;
  final _canvasKey = GlobalKey();
  bool _zigbeeOpen = true;
  bool _otherOpen = false;
  bool _migrated = false;

  @override
  void dispose() {
    _hintTimer?.cancel();
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

  FloorGeometry _geometry(Size size) =>
      _geo = FloorGeometry.compute(plan: _plan!, size: size, fitGrid: true);

  (int, int) _cellAt(Offset px) {
    final c = _geo!.pxToCell(px);
    final g = _plan!.grid;
    return (c.dx.round().clamp(0, g.cols), c.dy.round().clamp(0, g.rows));
  }

  int _handleAt(FloorRoom r, Offset p) {
    final rect = _geo!.rooms[r.id];
    if (rect == null) return 0;
    const t = 22.0;
    final inX = p.dx >= rect.left - t && p.dx <= rect.right + t;
    final inY = p.dy >= rect.top - t && p.dy <= rect.bottom + t;
    final dl = (p.dx - rect.left).abs();
    final dr = (p.dx - rect.right).abs();
    final dt = (p.dy - rect.top).abs();
    final db = (p.dy - rect.bottom).abs();
    var m = 0;
    if (inY && math.min(dl, dr) <= t) {
      m |= dl <= dr ? FloorSide.left : FloorSide.right;
    }
    if (inX && math.min(dt, db) <= t) {
      m |= dt <= db ? FloorSide.top : FloorSide.bottom;
    }
    return m;
  }

  // ---- Räume zeichnen ----------------------------------------------------

  void _panStart(DragStartDetails d) {
    final plan = _plan!;
    final p = d.localPosition;
    final sel = _sel == null ? null : plan.room(_sel!);
    if (sel != null) {
      final m = _handleAt(sel, p);
      if (m != 0) {
        Haptics.tick();
        _op = _Op(_OpKind.resize, plan, room: sel, mask: m);
        return;
      }
    }
    final id = _geo!.roomAt(p);
    final room = id == null ? null : plan.room(id);
    if (room != null) {
      Haptics.tick();
      setState(() => _sel = room.id);
      _op = _Op(_OpKind.move, plan, room: room, start: _geo!.pxToCell(p));
      return;
    }
    final a = _cellAt(p);
    setState(() => _sel = null);
    _op = _Op(_OpKind.create, plan, anchor: a);
  }

  void _panUpdate(DragUpdateDetails d) {
    final op = _op;
    if (op == null) return;
    final plan = _plan!;
    final cell = _cellAt(d.localPosition);
    switch (op.kind) {
      case _OpKind.create:
        final a = op.anchor!;
        final r = cellRect(a.$1, a.$2, cell.$1, cell.$2);
        if (op.last != cell) Haptics.tick();
        op.last = cell;
        final probe = FloorRoom(
          id: '_draft',
          name: '',
          x: r.x,
          y: r.y,
          w: r.w,
          h: r.h,
        );
        setState(() {
          _draft = probe.rect;
          _draftValid = plan.roomProblem(probe) == null;
        });
      case _OpKind.move:
        final from = _geo!.pxToCell(d.localPosition) - op.start!;
        final next = moveRoom(
          op.room!,
          from.dx.round(),
          from.dy.round(),
          plan.grid,
        );
        _applyRoom(op, next);
      case _OpKind.resize:
        final next = resizeRoom(op.room!, op.mask, cell.$1, cell.$2, plan.grid);
        _applyRoom(op, next);
    }
  }

  void _applyRoom(_Op op, FloorRoom next) {
    final plan = _plan!;
    final cur = plan.room(op.room!.id)!;
    if (next == cur || plan.roomProblem(next) != null) return;
    Haptics.tick();
    op.changed = true;
    setState(() => _plan = plan.withRoom(next));
  }

  Future<void> _panEnd([DragEndDetails? _]) async {
    final op = _op;
    _op = null;
    if (op == null) return;
    final plan = _plan!;
    switch (op.kind) {
      case _OpKind.create:
        final d = _draft;
        final valid = _draftValid;
        setState(() => _draft = null);
        if (d == null) return;
        if (!valid) {
          Haptics.tap();
          final probe = FloorRoom(
            id: '_',
            name: '',
            x: d.left.round(),
            y: d.top.round(),
            w: d.width.round(),
            h: d.height.round(),
          );
          _say(plan.roomProblem(probe) ?? 'Passt dort nicht hin');
          return;
        }
        final room = FloorRoom(
          id: 'r${DateTime.now().microsecondsSinceEpoch}',
          name: 'Neuer Raum',
          x: d.left.round(),
          y: d.top.round(),
          w: d.width.round(),
          h: d.height.round(),
        );
        Haptics.tap();
        _commit(plan, plan.withRoom(room));
        setState(() => _sel = room.id);
        await _assign(room.id);
      case _OpKind.move || _OpKind.resize:
        if (op.changed) {
          _undo.add(op.base);
          unawaited(ref.read(floorPlanProvider.notifier).save(_plan!));
          setState(() {});
        }
    }
  }

  void _tap(TapUpDetails d) {
    final id = _geo!.roomAt(d.localPosition);
    Haptics.tick();
    setState(() => _sel = id);
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

  void _dragHover(Offset global) {
    final local = _toLocal(global);
    final id = local == null ? null : _geo?.roomAt(local);
    if (id != _hover) {
      if (id != null) Haptics.tick();
      setState(() => _hover = id);
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
    setState(() => _hover = null);
    final local = _toLocal(global);
    final geo = _geo;
    final roomId = local == null || geo == null ? null : geo.roomAt(local);
    if (roomId == null) {
      // Außerhalb: die Platzierung fällt weg, die Entity kehrt in den Pool.
      if (plan.placementOf(entityId) != null) {
        Haptics.tap();
        _commit(plan, plan.withoutPlacement(entityId));
      }
      return;
    }
    final rect = geo!.rooms[roomId]!;
    double rel(double v, double lo, double hi) =>
        (v.clamp(lo, hi) * 100).round() / 100;
    final p = FloorPlacement(
      entityId: entityId,
      roomId: roomId,
      rx: rel((local!.dx - rect.left) / rect.width, 0.06, 0.94),
      ry: rel((local.dy - rect.top) / rect.height, 0.1, 0.92),
      kind: kind ?? old?.kind,
      deviceId: deviceId ?? old?.deviceId,
    );
    Haptics.tap();
    _commit(plan, plan.withPlacement(p));
  }

  /// Alle offenen Geräte eines Raums auf einmal in die Raummitte (Raster).
  void _quickPlace(PoolRoomGroup g, FloorRoom room) {
    final plan = _plan!;
    final pts = HavenFloorPlan.quickGrid(room, g.devices.length);
    final ps = [
      for (var i = 0; i < g.devices.length; i++)
        FloorPlacement(
          entityId: g.devices[i].mainEntityId,
          roomId: room.id,
          rx: pts[i].$1,
          ry: pts[i].$2,
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
  }) {
    Widget feedback() => Material(
      type: MaterialType.transparency,
      child: Transform.translate(
        offset: const Offset(-24, -24),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Transform.scale(
            scale: 1.25,
            child: MapMarker(entityId: entityId, kind: kind),
          ),
        ),
      ),
    );
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
        onDragUpdate: (d) => _dragHover(d.globalPosition),
        onDragEnd: end,
        child: child,
      );
    }
    return Draggable<String>(
      data: entityId,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: feedback(),
      childWhenDragging: Opacity(opacity: 0.25, child: child),
      onDragStarted: Haptics.tick,
      onDragUpdate: (d) => _dragHover(d.globalPosition),
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
                }),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                child: LayoutBuilder(
                  builder: (context, cons) {
                    final geo = _geometry(Size(cons.maxWidth, cons.maxHeight));
                    return _canvas(context, plan, geo);
                  },
                ),
              ),
            ),
            AnimatedContainer(
              duration: context.motion(HavenMotion.d2),
              curve: HavenMotion.out,
              height: devices ? 300 : 120,
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

  Widget _canvas(BuildContext context, HavenFloorPlan plan, FloorGeometry geo) {
    final hv = context.hv;
    final rooms = _mode == _Mode.rooms;
    final nodes = [
      for (final p in plan.placements)
        if (plan.room(p.roomId) != null)
          FloorNode(id: p.entityId, point: p.point),
    ];

    // Größe beim Ziehen: aktuelle Zielfläche in Zellen.
    Rect? active = _draft;
    var valid = _draftValid;
    if (active == null &&
        _op != null &&
        _op!.kind != _OpKind.create &&
        _op!.changed) {
      active = plan.room(_op!.room!.id)?.rect;
      valid = true;
    }

    return KeyedSubtree(
      key: _canvasKey,
      child: GestureDetector(
        dragStartBehavior: DragStartBehavior.down,
        onPanStart: rooms ? _panStart : null,
        onPanUpdate: rooms ? _panUpdate : null,
        onPanEnd: rooms ? _panEnd : null,
        onPanCancel: rooms ? _panEnd : null,
        onTapUp: rooms ? _tap : null,
        child: FloorPlanView(
          plan: plan,
          interactive: false,
          fitGrid: true,
          fill: true,
          showGrid: true,
          nodes: nodes,
          nodeBuilder: (context, n) {
            final kind = plan.placementOf(n.id)!.resolvedKind;
            final marker = MapMarker(entityId: n.id, kind: kind);
            if (rooms) return IgnorePointer(child: marker);
            return _drag(n.id, kind, marker);
          },
          roomStyle: (r) {
            final selected = rooms && r.id == _sel;
            final hovered = !rooms && r.id == _hover;
            if (hovered) {
              return FloorRoomStyle(
                fill: Color.alphaBlend(hv.acc.withValues(alpha: 0.22), hv.s1),
                border: hv.acc,
                borderWidth: 2,
              );
            }
            if (selected) {
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
            selected: rooms && _sel != null ? plan.room(_sel!) : null,
            active: active,
            valid: valid,
            cellMeters: plan.grid.cellMeters,
          ),
        ),
      ),
    );
  }

  // ---- Panels ---------------------------------------------------------------

  Widget _roomTools(HavenFloorPlan plan) {
    final hv = context.hv;
    final sel = _sel == null ? null : plan.room(_sel!);
    final m = plan.grid.cellMeters;
    String meters(int cells) {
      final v = cells * m;
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
                          'antippen wählt ihn, Ecken und Kanten ziehen ändert '
                          'die Größe.',
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
                              '${meters(sel.w)} × ${meters(sel.h)} m · '
                                  '${sel.areaId == null ? 'kein Bereich' : 'Bereich zugeordnet'}',
                          maxLines: 2,
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
                      ? 'Alles platziert. Zieh ein Gerät aus dem Raum heraus, '
                            'dann kehrt es hierher zurück.'
                      : 'Gerät halten und in seinen Raum ziehen.'),
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
      label: '${device.name}, halten und in einen Raum ziehen',
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

/// Griffe am gewählten Raum, Entwurfsrechteck und Größenangabe.
class _EditorOverlay extends FloorOverlayPainter {
  const _EditorOverlay({
    required this.hv,
    required this.selected,
    required this.active,
    required this.valid,
    required this.cellMeters,
  });

  final HavenColors hv;
  final FloorRoom? selected;
  final Rect? active; // Zellen
  final bool valid;
  final double cellMeters;

  @override
  void paint(Canvas canvas, Size size, FloorGeometry geo) {
    Rect? labelRect;
    final d = active;
    if (d != null) {
      final px = Rect.fromLTWH(
        geo.origin.dx + d.left * geo.scale,
        geo.origin.dy + d.top * geo.scale,
        d.width * geo.scale,
        d.height * geo.scale,
      );
      final color = valid ? hv.acc : hv.bad;
      final rr = FloorGeometry.roomShape(px);
      canvas.drawRRect(rr, Paint()..color = color.withValues(alpha: 0.18));
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color,
      );
      labelRect = px;
      _label(canvas, size, px, d, color);
    }
    final s = selected;
    if (s != null) {
      final r = geo.rooms[s.id];
      if (r != null && labelRect == null) {
        // Ecken und Kanten als Griffe.
        final fill = Paint()..color = hv.s1;
        final ring = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..color = hv.acc;
        for (final c in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
          canvas.drawCircle(c, 8, fill);
          canvas.drawCircle(c, 8, ring);
        }
        final pill = Paint()..color = hv.acc;
        void edge(Offset c, bool horizontal) => canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: c,
              width: horizontal ? 22 : 5,
              height: horizontal ? 5 : 22,
            ),
            const Radius.circular(3),
          ),
          pill,
        );
        edge(r.topCenter, true);
        edge(r.bottomCenter, true);
        edge(r.centerLeft, false);
        edge(r.centerRight, false);
      }
    }
  }

  void _label(Canvas canvas, Size size, Rect px, Rect cells, Color color) {
    String m(double c) {
      final v = c * cellMeters;
      return (v == v.roundToDouble()
              ? v.toStringAsFixed(0)
              : v.toStringAsFixed(1))
          .replaceAll('.', ',');
    }

    final tp = TextPainter(
      text: TextSpan(
        text: '${m(cells.width)} × ${m(cells.height)} m',
        style: HavenText.label.copyWith(
          color: valid ? hv.ai : const Color(0xFFFFFFFF),
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final pad = const EdgeInsets.symmetric(horizontal: 10, vertical: 5);
    final w = tp.width + pad.horizontal;
    final h = tp.height + pad.vertical;
    var o = Offset(px.center.dx - w / 2, px.center.dy - h / 2);
    o = Offset(
      o.dx.clamp(2, size.width - w - 2),
      o.dy.clamp(2, size.height - h - 2),
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
      old.valid != valid;
}
