import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:haven_3d/haven_3d.dart' as h3;
import 'package:material_ui/material_ui.dart';

import '../../core/adaptive/breakpoints.dart';
import '../../core/adaptive/context_menu.dart';
import '../../core/adaptive/hover.dart';
import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/haven_card.dart';
import '../../core/widgets/press_scale.dart';
import '../../core/widgets/segmented.dart';
import '../../data/models/floor_plan.dart';
import '../zigbee/widgets/device_icon.dart';
import '../zigbee/widgets/zb_common.dart' show showZbSheet;
import '../zigbee/zigbee_providers.dart';
import 'device_pool.dart';
import 'floor_assign_sheet.dart';
import 'floor_editor_ops.dart';
import 'floor_plan_store.dart';
import 'floor_geometry.dart';
import 'furniture_library.dart';
import 'furniture_ops.dart';
import 'furniture_painter.dart';
import 'map_3d.dart'
    show
        defaultDeviceModel,
        deviceModelOf,
        deviceModelsFor,
        deviceMountOf,
        lampStateOf,
        map3dSettingsProvider,
        mapSunOf,
        markerHeightOf,
        sceneOfPlan,
        spreadNodes;
import 'map_data.dart' show MapLights;
import 'map_markers.dart';

enum _Mode { rooms, devices, furniture }

/// Licht beim Geräte setzen: aus, wie gerade zu Hause, oder alle Lampen an
/// (warmweiß), um die Wirkung der Platzierung zu sehen.
enum _EditorLight { off, live, on }

/// Warmweiß (etwa 3000 K) für „alle Lampen an“ im Editor.
const h3.LampState kEditorWarmWhite = h3.LampState(
  brightness: 0.85,
  color: Color(0xFFFFC489),
);

enum _FurnOpKind { move, resize, rotate }

/// Laufende Geste an einem Möbelstück.
class _FurnOp {
  _FurnOp(this.kind, this.base, this.item, this.start, {this.handle});
  final _FurnOpKind kind;

  /// Stand vor der Geste (Rückgängig).
  final HavenFloorPlan base;
  final FloorFurniture item;

  /// Zelle bei Gestenbeginn.
  final Offset start;
  final FurnitureHandle? handle;
  bool changed = false;
}

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
    this.startInFurniture = false,
    this.startSelected,
    this.startFurniture,
    this.startDrag,
  });

  /// Nur für Screenshots und Tests.
  final bool startInDevices;
  final bool startInFurniture;

  /// Gewähltes Möbelstück beim Start (Screenshots, Tests).
  final String? startFurniture;
  final String? startSelected;

  /// Zeigt das Ziehen-Label für diese Entity (Screenshot, kein echtes Ziehen).
  final String? startDrag;

  @override
  ConsumerState<FloorEditorScreen> createState() => _FloorEditorScreenState();
}

class _FloorEditorScreenState extends ConsumerState<FloorEditorScreen> {
  HavenFloorPlan? _plan;
  final List<HavenFloorPlan> _undo = [];
  late _Mode _mode = widget.startInFurniture
      ? _Mode.furniture
      : (widget.startInDevices ? _Mode.devices : _Mode.rooms);
  String? _sel;

  /// Gewähltes Möbelstück (Modus „Einrichten“).
  late String? _fsel = widget.startFurniture;
  _FurnOp? _fop;

  /// Geräte: gewähltes Gerät (Bauform, Höhe) und 3D-Ansicht.
  String? _dsel;

  /// Licht beim Geräte setzen (aus, live, alle an).
  _EditorLight _light = _EditorLight.off;

  /// Geräte werden nur in 3D gesetzt.
  bool get _view3d => _mode == _Mode.devices;

  /// Gerät, das gerade gezogen wird (sein Modell weicht der Vorschau).
  String? _dragId;
  final _proj = _EditorProjection();
  HavenFloorPlan? _heightBase;
  MouseCursor _cursor = MouseCursor.defer;
  final _focus = FocusNode(debugLabel: 'Grundriss-Editor');
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
    _focus.dispose();
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
      if (_fsel != null && prev.furnitureById(_fsel!) == null) _fsel = null;
    });
    unawaited(ref.read(floorPlanProvider.notifier).save(prev));
  }

  /// Eine Geste hat den Plan schon live geändert: [before] in den
  /// Rückgängig-Stapel, aktuellen Stand speichern.
  void _record(HavenFloorPlan before) {
    final plan = _plan!;
    if (before == plan) return;
    _undo.add(before);
    if (_undo.length > 40) _undo.removeAt(0);
    unawaited(ref.read(floorPlanProvider.notifier).save(plan));
    setState(() {});
  }

  void _close() => context.canPop() ? context.pop() : context.go('/map');

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
  GridPoint? _cellAt(Offset px, {double z = 0}) {
    // 3D (Geräte): Punkt unter dem Finger auf der Höhe des Geräts (sonst
    // spränge eine Deckenlampe beim ersten Ziehen).
    final p = _view3d && _mode == _Mode.devices ? _proj.current : null;
    final floor = p?.camera.unprojectOnPlane(px, p.size, z: z)?.xy;
    final c = floor != null
        ? floor / _plan!.grid.cellMeters
        : _geo!.pxToCell(px);
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
    if (h is EdgeHandle) return _toggleWall(h.index);
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

  /// Wand an Kante [edge] des gewählten Raums öffnen oder schließen. Eine
  /// gemeinsame Wand mit einem Nachbarraum wechselt dort mit.
  void _toggleWall(int edge) {
    final plan = _plan!;
    final room = plan.room(_sel!)!;
    final open = !room.isOpen(edge);
    var next = plan.withRoom(setEdgeOpen(room, edge, open));
    for (final e in sharedEdges(room, edge, plan.rooms).entries) {
      var q = next.room(e.key)!;
      for (final k in e.value) {
        q = setEdgeOpen(q, k, open);
      }
      next = next.withRoom(q);
    }
    Haptics.tap();
    _commit(plan, next);
    _say(open ? 'Wand offen: nur noch Raumgrenze' : 'Wand wieder geschlossen');
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
  GridPoint? _dropCell(Offset global, {double z = 0}) {
    final local = _toLocal(global);
    if (local == null || _geo == null) return null;
    if (local.dx < 0 ||
        local.dy < 0 ||
        local.dx > _size.width ||
        local.dy > _size.height) {
      return null;
    }
    return _cellAt(local, z: z);
  }

  /// Bauform eines (vielleicht noch nicht platzierten) Geräts.
  String _modelOf(String? entityId, FloorKind kind) {
    final old = entityId == null ? null : _plan!.placementOf(entityId);
    return old != null
        ? deviceModelOf(old)
        : defaultDeviceModel(kind, entityId ?? '');
  }

  /// Montage eines Geräts, wenn es in [cell] landet: Was an Decke und Wand
  /// kann (Deckenleuchte, Spot, Bewegungsmelder), rastet an der Wand ein,
  /// wenn [cell] an einer geschlossenen Wand liegt, sonst an der Decke.
  /// Nach oben gestellte Geräte bleiben so.
  h3.DeviceMount? _mountAt(String? entityId, FloorKind kind, GridPoint cell) {
    final spec = h3.deviceSpec(_modelOf(entityId, kind));
    final old = entityId == null ? null : _plan!.placementOf(entityId);
    final cur = old == null ? spec.mountOf(null) : deviceMountOf(old);
    final m = spec.mounts;
    if (cur == h3.DeviceMount.up ||
        !m.contains(h3.DeviceMount.wall) ||
        !m.contains(h3.DeviceMount.ceiling)) {
      return cur;
    }
    return _nearWall(cell) ? h3.DeviceMount.wall : h3.DeviceMount.ceiling;
  }

  /// Liegt die Mitte von [cell] nah an einer geschlossenen Wand ihres Raums?
  bool _nearWall(GridPoint cell) {
    final plan = _plan!;
    final room = plan.room(plan.locationOfCell(cell.x, cell.y));
    if (room == null) return false;
    final c = Offset(cell.x + 0.5, cell.y + 0.5);
    final reach = 0.35 / plan.grid.cellMeters;
    final pts = room.points;
    for (var i = 0; i < pts.length; i++) {
      if (room.isOpen(i)) continue;
      final a = Offset(pts[i].x.toDouble(), pts[i].y.toDouble());
      final q = pts[(i + 1) % pts.length];
      final e = Offset(q.x.toDouble(), q.y.toDouble()) - a;
      final len2 = e.distanceSquared;
      if (len2 == 0) continue;
      final t = (((c - a).dx * e.dx + (c - a).dy * e.dy) / len2).clamp(
        0.0,
        1.0,
      );
      if ((c - (a + e * t)).distance <= reach) return true;
    }
    return false;
  }

  /// Höhe, auf der ein Gerät in [cell] landet: Wand- und Deckengeräte auf
  /// ihrer Höhe (oder der gewählten, solange die Montage bleibt),
  /// Stehlampen auf dem Boden, Tischlampen, Lightbars und Ähnliches auf dem
  /// Möbelstück darunter, sonst auf dem Boden.
  double _placeZ(String? entityId, FloorKind kind, GridPoint cell) {
    final spec = h3.deviceSpec(_modelOf(entityId, kind));
    final how = _mountAt(entityId, kind, cell);
    final old = entityId == null ? null : _plan!.placementOf(entityId);
    final std = spec.heightFor(how);
    final kept = old != null && deviceMountOf(old) == how ? old.height : null;
    if (how != h3.DeviceMount.up && (spec.isWall(how) || std >= 2.0)) {
      return kept ?? std;
    }
    if (how != h3.DeviceMount.up && std == 0) return 0;
    final p = Offset(cell.x + 0.5, cell.y + 0.5);
    var top = 0.0;
    for (final f in _plan!.furniture) {
      final fs = h3.furnitureSpec(f.kind);
      if (fs.wallMounted || f.kind == 'rug' || !f.contains(p)) continue;
      top = math.max(top, fs.elevation + fs.height);
    }
    return top;
  }

  /// Vorschau des Modells beim Ziehen (eingerastet), `null` aus.
  void _showPreview(GridPoint? cell, FloorKind kind, String? entityId) {
    final c = _proj.controller;
    if (c == null || !_view3d) return;
    if (cell == null) return c.setPreview(null);
    final m = _plan!.grid.cellMeters;
    final loc = _plan!.locationOfCell(cell.x, cell.y);
    c.setPreview(
      _modelOf(entityId, kind),
      at: Offset(cell.x + 0.5, cell.y + 0.5) * m,
      z: _placeZ(entityId, kind, cell),
      roomId: loc == kOutsideId ? null : loc,
      mount: _mountAt(entityId, kind, cell),
    );
  }

  /// Höhe, auf der ein Gerät beim Ziehen in 3D liegt.
  double _dragZ(String entityId) => switch (_plan!.placementOf(entityId)) {
    final p? => markerHeightOf(p),
    null => 0,
  };

  void _dragHover(
    Offset global,
    String name,
    FloorKind kind, [
    String? entityId,
  ]) {
    final cell = _dropCell(global, z: entityId == null ? 0 : _dragZ(entityId));
    _showPreview(cell, kind, entityId);
    final loc = cell == null ? null : _plan!.locationOfCell(cell.x, cell.y);
    _dragInfo.value = EditorDragInfo(
      name: name,
      kind: kind,
      target: loc == null ? null : _roomName(loc),
      remove: cell == null && _overPool(global),
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
    final cell = _dropCell(global, z: _dragZ(entityId));
    _dragInfo.value = null;
    setState(() {
      _hover = null;
      _dragCell = null;
    });
    if (cell == null) {
      // Auf die Geräteliste gezogen: die Platzierung fällt weg. Daneben
      // (z. B. knapp über den Rand) passiert nichts, das Gerät bleibt.
      if (old != null && _overPool(global)) {
        Haptics.tap();
        _commit(plan, plan.withoutPlacement(entityId));
        _say('Wieder in der Liste');
      } else if (old != null) {
        _say('Bleibt an seinem Platz');
      }
      return;
    }
    final k = kind ?? old?.resolvedKind ?? FloorKind.ofEntity(entityId);
    final spec = h3.deviceSpec(_modelOf(entityId, k));
    final how = _mountAt(entityId, k, cell);
    final z = _placeZ(entityId, k, cell);
    final std = spec.heightFor(how);
    final p = FloorPlacement(
      entityId: entityId,
      x: cell.x,
      y: cell.y,
      kind: kind ?? old?.kind,
      deviceId: deviceId ?? old?.deviceId,
      // Bauform zieht mit um; Montage und Höhe rasten neu ein (Wand, Decke,
      // Boden oder das Möbelstück darunter) und werden nur gespeichert, wenn
      // sie vom Standard der Bauform abweichen.
      model: old?.model == null ? null : deviceModelOf(old!),
      mount: how == spec.mountOf(null) ? null : how?.name,
      height: (z - std).abs() < 1e-6 ? null : z,
      // Drehung und Licht ziehen mit um.
      rotation: old?.rotation,
      cone: old?.cone,
      spread: old?.spread,
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
    // Nur anzeigen, nicht speichern: Das Öffnen des Editors ist keine
    // Änderung des Nutzers. Gespeichert wird mit der ersten echten Änderung.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _plan != plan) return;
      setState(() => _plan = next);
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
      setState(() => _dragId = entityId);
    }

    void end(DraggableDetails d) {
      setState(() => _dragId = null);
      _proj.controller?.setPreview(null);
      _dropEntity(entityId, d.offset, kind: kind, deviceId: deviceId);
    }

    if (pool) {
      return LongPressDraggable<String>(
        data: entityId,
        delay: const Duration(milliseconds: 150),
        hapticFeedbackOnStart: true,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: feedback(),
        childWhenDragging: Opacity(opacity: 0.35, child: child),
        onDragStarted: start,
        onDragUpdate: (d) =>
            _dragHover(d.globalPosition, label(), kind, entityId),
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
      onDragUpdate: (d) =>
          _dragHover(d.globalPosition, label(), kind, entityId),
      onDragEnd: end,
      // Antippen wählt das Gerät (Bauform und Höhe im Panel).
      // Rechtsklick oder langes Drücken bietet das Entfernen an.
      child: GestureDetector(
        onTap: () {
          Haptics.tick();
          setState(() => _dsel = _dsel == entityId ? null : entityId);
        },
        onSecondaryTapUp: (d) => _deviceMenu(entityId, d.globalPosition),
        child: _dsel == entityId
            ? DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: context.hv.acc, width: 2.5),
                ),
                child: child,
              )
            : child,
      ),
    );
  }

  // ---- Bauform und Höhe der Geräte -----------------------------------------

  /// Nimmt das Gerät von der Karte; es steht danach wieder in der Liste.
  void _removeDevice(String entityId) {
    final plan = _plan!;
    if (plan.placementOf(entityId) == null) return;
    Haptics.tap();
    setState(() {
      if (_dsel == entityId) _dsel = null;
    });
    _commit(plan, plan.withoutPlacement(entityId));
    _say('Von der Karte genommen');
  }

  void _deviceMenu(String entityId, Offset at) {
    showHavenContextMenu(context, at, [
      HavenMenuItem(
        label: 'Bauform, Höhe und Licht',
        icon: Icons.tune_rounded,
        onSelected: () => setState(() => _dsel = entityId),
      ),
      HavenMenuItem(
        label: 'Von der Karte nehmen',
        icon: Icons.delete_outline_rounded,
        shortcut: 'Entf',
        destructive: true,
        onSelected: () => _removeDevice(entityId),
      ),
    ]);
  }

  void _setDevice(FloorPlacement p) {
    final plan = _plan!;
    _commit(plan, plan.withPlacement(p));
  }

  /// Gewähltes Gerät: Bauform als Auswahl, Höhe als Regler.
  Widget _deviceDetails(HavenFloorPlan plan, FloorPlacement p) {
    final hv = context.hv;
    final kind = p.resolvedKind;
    final model = deviceModelOf(p);
    final spec = h3.deviceSpec(model);
    final how = deviceMountOf(p);
    final std = spec.heightFor(how);
    final height = p.height ?? std;
    final name = ref.read(entityProvider(p.entityId))?.name ?? p.entityId;
    String meters(double v) => '${v.toStringAsFixed(2).replaceAll('.', ',')} m';
    Widget chip(String label, bool on, VoidCallback tap, {Key? key}) =>
        PressScale(
          key: key,
          onTap: () {
            Haptics.tick();
            tap();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: on ? hv.acc : hv.s1,
              borderRadius: BorderRadius.circular(HavenRadii.pill),
              border: Border.all(color: on ? hv.acc : hv.ln2),
            ),
            child: Text(
              label,
              style: HavenText.caption.copyWith(
                color: on ? hv.ai : hv.tx,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        );
    // Lichtkegel (ganzer Winkel in Grad) und Streuung nur bei Lampen mit
    // Kegel, die nicht nach oben strahlen (dort kommt das Licht von der
    // Decke zurück, ohne Kegel).
    final stdCone = spec.lamp?.cone;
    final cone = how == h3.DeviceMount.up ? null : stdCone;
    final stdConeDeg = (stdCone ?? 0) * 2 * 180 / math.pi;
    final coneDeg = p.cone ?? stdConeDeg;
    final spread = p.spread ?? h3.kConeSoftness;

    /// Regler mit Beschriftung und „Standard“: ändert den Plan beim Ziehen,
    /// ein Schritt zum Rückgängigmachen beim Loslassen.
    List<Widget> slider({
      required String key,
      required String label,
      required double value,
      required double min,
      required double max,
      required int divisions,
      required String Function(double) show,
      required bool isDefault,
      required String reset,
      required VoidCallback onReset,
      required FloorPlacement Function(FloorPlacement, double) apply,
    }) => [
      const SizedBox(height: 6),
      Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HavenText.caption.copyWith(color: hv.tx2),
            ),
          ),
          if (!isDefault)
            Flexible(
              child: TextButton(
                onPressed: onReset,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(
                  reset,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
      ),
      Slider(
        key: ValueKey(key),
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        label: show(value),
        onChangeStart: (_) => _heightBase = _plan,
        onChanged: (v) => setState(
          () => _plan = _plan!.withPlacement(
            apply(_plan!.placementOf(p.entityId)!, v),
          ),
        ),
        onChangeEnd: (_) {
          final base = _heightBase;
          _heightBase = null;
          if (base != null) _commit(base, _plan!);
        },
      ),
    ];

    return Container(
      key: ValueKey('dsel-${p.entityId}'),
      margin: const EdgeInsets.only(bottom: 10, right: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 6),
      decoration: BoxDecoration(
        color: hv.s2,
        borderRadius: BorderRadius.circular(HavenRadii.m),
        border: Border.all(color: hv.ln),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              MapMarker(entityId: p.entityId, kind: kind),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HavenText.label.copyWith(color: hv.tx),
                ),
              ),
              RoundIconButton(
                icon: Icons.close_rounded,
                label: 'Auswahl aufheben',
                onTap: () => setState(() => _dsel = null),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('device-remove'),
              onPressed: () => _removeDevice(p.entityId),
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('Von der Karte nehmen'),
              style: TextButton.styleFrom(foregroundColor: hv.bad),
            ),
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final d in deviceModelsFor(kind))
                // Neue Bauform: deren Standardmontage und -höhe.
                chip(
                  d.label,
                  d.id == model,
                  () => _setDevice(
                    p.copyWith(
                      model: d.id,
                      clearHeight: true,
                      clearMount: true,
                    ),
                  ),
                ),
            ],
          ),
          if (spec.mounts.length > 1) ...[
            const SizedBox(height: 10),
            Text('Montage', style: HavenText.caption.copyWith(color: hv.tx2)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final m in spec.mounts)
                  chip(
                    m.label,
                    m == how,
                    key: ValueKey('mount-${m.name}'),
                    () => _setDevice(
                      p.copyWith(
                        // Gespeichert wird nur, was vom Standard abweicht.
                        mount: m.name,
                        clearMount: m == spec.mountOf(null),
                        clearHeight: true,
                        model: model,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          ...slider(
            key: 'device-height',
            label: 'Höhe ${meters(height)}',
            value: height,
            min: 0,
            max: 2.6,
            divisions: 52,
            show: meters,
            isDefault: p.height == null,
            reset: 'Standard (${meters(std)})',
            onReset: () => _setDevice(p.copyWith(clearHeight: true)),
            apply: (q, v) => q.copyWith(height: v),
          ),
          if (spec.canRotate(how))
            ...slider(
              key: 'device-rotation',
              label: 'Drehung ${(p.rotation ?? 0).round()}°',
              value: p.rotation ?? 0,
              min: 0,
              max: 345,
              divisions: 23,
              show: (v) => '${v.round()}°',
              isDefault: (p.rotation ?? 0) == 0,
              reset: '0°',
              onReset: () => _setDevice(p.copyWith(clearRotation: true)),
              apply: (q, v) => q.copyWith(rotation: v),
            ),
          if (cone != null) ...[
            ...slider(
              key: 'device-cone',
              label: 'Lichtkegel ${coneDeg.round()}°',
              value: coneDeg,
              min: 10,
              max: 170,
              divisions: 32,
              show: (v) => '${v.round()}°',
              isDefault: p.cone == null,
              reset: 'Standard (${stdConeDeg.round()}°)',
              onReset: () => _setDevice(p.copyWith(clearCone: true)),
              apply: (q, v) => q.copyWith(cone: v),
            ),
            ...slider(
              key: 'device-spread',
              label: 'Streuung ${(spread * 100).round()} %',
              value: spread,
              min: 0.05,
              max: 1,
              divisions: 19,
              show: (v) => '${(v * 100).round()} %',
              isDefault: p.spread == null,
              reset: 'Standard (${(h3.kConeSoftness * 100).round()} %)',
              onReset: () => _setDevice(p.copyWith(clearSpread: true)),
              apply: (q, v) => q.copyWith(spread: v),
            ),
          ],
        ],
      ),
    );
  }

  // ---- Einrichten (Möbel) ----------------------------------------------------

  FloorFurniture? get _selFurniture =>
      _fsel == null ? null : _plan?.furnitureById(_fsel!);

  Offset _cellOf(Offset px) => _geo!.pxToCell(px);

  /// Treffer-Toleranz in Zellen (etwa 6 px), damit Fenster greifbar sind.
  double get _furnTolerance => 6 / (_geo?.scale ?? 20);

  /// Griffe sind am Touchscreen größer.
  double get _handleRadius => context.isDesktopLayout ? 11 : 22;

  bool get _shift => HardwareKeyboard.instance.isShiftPressed;

  List<(FurnitureHandle, Offset)> _handlesOf(FloorFurniture f) =>
      furnitureHandlePoints(
        f,
        _geo!.cellToPx,
        rotateGap: context.isDesktopLayout ? 24 : 32,
      );

  FurnitureHandle? _furnHandleAt(Offset px) {
    final sel = _selFurniture;
    if (sel == null || _geo == null) return null;
    return furnitureHandleAt(_handlesOf(sel), px, radius: _handleRadius);
  }

  void _fPanStart(DragStartDetails d) {
    final plan = _plan!;
    final p = d.localPosition;
    final cell = _cellOf(p);
    final sel = _selFurniture;
    final h = _furnHandleAt(p);
    if (sel != null && h != null) {
      Haptics.tick();
      _fop = _FurnOp(
        h.isRotate ? _FurnOpKind.rotate : _FurnOpKind.resize,
        plan,
        sel,
        cell,
        handle: h,
      );
      setState(() => _cursor = SystemMouseCursors.grabbing);
      return;
    }
    final hit = furnitureAt(plan.furniture, cell, tolerance: _furnTolerance);
    if (hit != null) {
      Haptics.tick();
      _fop = _FurnOp(_FurnOpKind.move, plan, hit, cell);
      setState(() {
        _fsel = hit.id;
        _cursor = SystemMouseCursors.grabbing;
      });
      return;
    }
    if (_fsel != null) setState(() => _fsel = null);
  }

  void _fPanUpdate(DragUpdateDetails d) {
    final op = _fop;
    if (op == null) return;
    final cell = _cellOf(d.localPosition);
    final snap = !_shift;
    var next = switch (op.kind) {
      _FurnOpKind.move => moveFurniture(
        op.item,
        cell - op.start,
        op.base.grid,
        snap: snap,
      ),
      _FurnOpKind.resize => resizeFurniture(
        op.item,
        op.handle!,
        cell,
        snap: snap,
      ),
      _FurnOpKind.rotate => rotateFurnitureTo(op.item, cell, snap: snap),
    };
    // Türen rasten beim Verschieben an der nächsten Wand ein.
    if (snap && op.kind == _FurnOpKind.move) {
      next = snapDoorToWall(next, op.base.rooms);
    }
    final cur = _plan!.furnitureById(next.id);
    if (cur == next) return;
    if (snap) Haptics.tick();
    op.changed = true;
    setState(() => _plan = op.base.withFurniture(next));
  }

  void _fPanEnd([Object? _]) {
    final op = _fop;
    _fop = null;
    if (op == null) return;
    setState(() => _cursor = MouseCursor.defer);
    if (op.changed) _record(op.base);
  }

  void _fTap(TapUpDetails d) {
    if (_furnHandleAt(d.localPosition) != null) return;
    final hit = furnitureAt(
      _plan!.furniture,
      _cellOf(d.localPosition),
      tolerance: _furnTolerance,
    );
    Haptics.tick();
    setState(() => _fsel = hit?.id);
  }

  /// Rechtsklick: auf einem Möbelstück dessen Menü, auf einem Raum (Modus
  /// Räume) Zuordnen und Löschen.
  void _secondaryTap(TapUpDetails d) {
    final plan = _plan!;
    final ctrl = ctrlLabel(context);
    if (_mode == _Mode.furniture) {
      final hit = furnitureAt(
        plan.furniture,
        _cellOf(d.localPosition),
        tolerance: _furnTolerance,
      );
      if (hit == null) {
        setState(() => _fsel = null);
        return;
      }
      setState(() => _fsel = hit.id);
      unawaited(
        showHavenContextMenu(context, d.globalPosition, [
          HavenMenuItem(
            label: 'Um 90° drehen',
            icon: Icons.rotate_right_rounded,
            shortcut: 'R',
            onSelected: () => _rotateSel(90),
          ),
          if (hit.canHaveSensor)
            HavenMenuItem(
              label: hit.sensor == null ? 'Sensor verknüpfen' : 'Sensor ändern',
              icon: Icons.sensors_rounded,
              onSelected: () => _linkSensor(hit),
            ),
          HavenMenuItem(
            label: 'Duplizieren',
            icon: Icons.copy_all_rounded,
            shortcut: '${ctrl}D',
            onSelected: _duplicateSel,
          ),
          HavenMenuItem(
            label: 'Löschen',
            icon: Icons.delete_outline_rounded,
            shortcut: 'Entf',
            destructive: true,
            onSelected: _deleteFurnitureSel,
          ),
        ]),
      );
      return;
    }
    if (_mode == _Mode.rooms) {
      final h = _handle(d.localPosition);
      if (h is EdgeHandle) {
        final open = plan.room(_sel!)!.isOpen(h.index);
        unawaited(
          showHavenContextMenu(context, d.globalPosition, [
            HavenMenuItem(
              label: open ? 'Wand schließen' : 'Wand öffnen',
              icon: open
                  ? Icons.border_outer_rounded
                  : Icons.border_clear_rounded,
              onSelected: () => _toggleWall(h.index),
            ),
          ]),
        );
        return;
      }
      final id = _geo!.roomAt(d.localPosition);
      if (id == null) return;
      setState(() => _sel = id);
      unawaited(
        showHavenContextMenu(context, d.globalPosition, [
          HavenMenuItem(
            label: 'Bereich zuordnen',
            icon: Icons.label_outline_rounded,
            onSelected: () => _assign(id),
          ),
          HavenMenuItem(
            label: 'Raum löschen',
            icon: Icons.delete_outline_rounded,
            shortcut: 'Entf',
            destructive: true,
            onSelected: _deleteSelected,
          ),
        ]),
      );
    }
  }

  /// Mausform je nach Ort: Griffe, Möbel, Räume, leere Fläche.
  void _hoverAt(Offset p) {
    if (_geo == null || _fop != null || _op != null) return;
    MouseCursor c = MouseCursor.defer;
    switch (_mode) {
      case _Mode.furniture:
        final h = _furnHandleAt(p);
        if (h != null) {
          c = h.isRotate
              ? SystemMouseCursors.grab
              : switch (resizeAxisOf(h, _selFurniture!.rotation)) {
                  ResizeAxis.horizontal => SystemMouseCursors.resizeLeftRight,
                  ResizeAxis.vertical => SystemMouseCursors.resizeUpDown,
                  ResizeAxis.diagonalDown =>
                    SystemMouseCursors.resizeUpLeftDownRight,
                  ResizeAxis.diagonalUp =>
                    SystemMouseCursors.resizeUpRightDownLeft,
                };
        } else if (furnitureAt(
              _plan!.furniture,
              _cellOf(p),
              tolerance: _furnTolerance,
            ) !=
            null) {
          c = SystemMouseCursors.move;
        }
      case _Mode.rooms:
        final h = _handle(p);
        if (h is VertexHandle) {
          c = SystemMouseCursors.move;
        } else if (h is EdgeHandle) {
          c = SystemMouseCursors.click;
        } else if (_geo!.roomAt(p) != null) {
          c = SystemMouseCursors.move;
        } else {
          c = SystemMouseCursors.precise;
        }
      case _Mode.devices:
    }
    if (c != _cursor) setState(() => _cursor = c);
  }

  /// Mitte für neue Möbel: gewählter Raum, sonst die Wohnung.
  Offset _defaultSpot(HavenFloorPlan plan) {
    final room = _sel == null ? null : plan.room(_sel!);
    if (room != null) return room.anchor;
    if (plan.rooms.isNotEmpty) return plan.houseBounds.center;
    return plan.grid.rect.center;
  }

  void _addFurniture(FurnitureType t, {Offset? at}) {
    final plan = _plan!;
    var spot = at ?? _defaultSpot(plan);
    // Mehrfach hinzufügen stapelt nicht genau übereinander.
    if (at == null) {
      for (var i = 0; i < 8; i++) {
        final taken = plan.furniture.any(
          (f) => f.kind == t.id && (f.center - spot).distance < 0.6,
        );
        if (!taken) break;
        spot += const Offset(1, 1);
      }
    }
    var f = placeFurniture(
      t,
      spot,
      plan.grid,
      id: newFurnitureId(),
      snap: !_shift,
    );
    if (!_shift) f = snapDoorToWall(f, plan.rooms);
    _commit(plan, plan.withFurniture(f));
    setState(() => _fsel = f.id);
  }

  void _dropFurniture(FurnitureType t, Offset globalCenter) {
    final local = _toLocal(globalCenter);
    if (local == null || _geo == null) return;
    if (local.dx < 0 ||
        local.dy < 0 ||
        local.dx > _size.width ||
        local.dy > _size.height) {
      return;
    }
    Haptics.tap();
    _addFurniture(t, at: _cellOf(local));
  }

  void _rotateSel(double deg) {
    final f = _selFurniture;
    if (f == null) return;
    Haptics.tick();
    final plan = _plan!;
    _commit(plan, plan.withFurniture(rotateFurnitureBy(f, deg)));
  }

  /// Tür oder Fenster mit einem Kontaktsensor verknüpfen (oder lösen).
  Future<void> _linkSensor(FloorFurniture f) async {
    final snap = ref.read(snapshotProvider);
    final plan = _plan!;
    final contacts = {
      for (final p in plan.placements)
        if (p.resolvedKind == FloorKind.contact) p.entityId,
    };
    final candidates = [
      for (final e in snap.entities.values)
        if (e.entityId.startsWith('binary_sensor.') &&
            (contacts.contains(e.entityId) ||
                const {
                  'door',
                  'window',
                  'opening',
                  'garage_door',
                }.contains(e.deviceClass)))
          e,
    ]..sort((a, b) => a.name.compareTo(b.name));
    final what = switch (f.kind) {
      'door' => 'die Tür',
      'fridge' => 'den Kühlschrank',
      _ => 'das Fenster',
    };
    final picked = await showZbSheet<String>(
      context,
      builder: (ctx) {
        final hv = ctx.hv;
        Widget row(String? id, String title, String? sub) {
          final on = id == f.sensor;
          return PressScale(
            onTap: () => Navigator.of(ctx).pop(id ?? ''),
            child: Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: on ? hv.acc.withValues(alpha: 0.12) : hv.s2,
                borderRadius: BorderRadius.circular(HavenRadii.m),
                border: Border.all(color: on ? hv.acc : hv.ln),
              ),
              child: Row(
                children: [
                  Icon(
                    id == null
                        ? Icons.link_off_rounded
                        : Icons.sensor_door_outlined,
                    size: 20,
                    color: on ? hv.acc : hv.tx2,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: HavenText.label.copyWith(color: hv.tx),
                        ),
                        if (sub != null)
                          Text(
                            sub,
                            style: HavenText.caption.copyWith(color: hv.tx2),
                          ),
                      ],
                    ),
                  ),
                  if (on) Icon(Icons.check_rounded, size: 18, color: hv.acc),
                ],
              ),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Sensor für $what',
              style: HavenText.section.copyWith(color: hv.tx),
            ),
            const SizedBox(height: 4),
            Text(
              'Die Karte zeigt $what dann offen oder geschlossen.',
              style: HavenText.caption.copyWith(color: hv.tx2),
            ),
            const SizedBox(height: 14),
            row(null, 'Kein Sensor', null),
            for (final e in candidates)
              row(e.entityId, e.name, e.isOn ? 'gerade offen' : 'gerade zu'),
            if (candidates.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Keine Tür- oder Fensterkontakte gefunden.',
                  style: HavenText.body.copyWith(color: hv.tx2),
                ),
              ),
          ],
        );
      },
    );
    if (picked == null || !mounted) return;
    final cur = _plan!;
    final now = cur.furnitureById(f.id);
    if (now == null) return;
    final next = picked.isEmpty
        ? now.copyWith(clearSensor: true)
        : now.copyWith(sensor: picked);
    if (next == now) return;
    _commit(cur, cur.withFurniture(next));
    _say(
      picked.isEmpty
          ? 'Sensor gelöst'
          : 'Verknüpft mit ${snap.entity(picked)?.name ?? picked}',
    );
  }

  void _duplicateSel() {
    final f = _selFurniture;
    if (f == null) return;
    Haptics.tap();
    final plan = _plan!;
    final copy = duplicateFurniture(f, plan.grid, id: newFurnitureId());
    _commit(plan, plan.withFurniture(copy));
    setState(() => _fsel = copy.id);
  }

  void _deleteFurnitureSel() {
    final f = _selFurniture;
    if (f == null) return;
    Haptics.tap();
    final plan = _plan!;
    _commit(plan, plan.withoutFurniture(f.id));
    setState(() => _fsel = null);
    _say('${f.type?.name ?? 'Möbelstück'} entfernt');
  }

  void _nudgeSel(Offset d) {
    final f = _selFurniture;
    if (f == null) return;
    final plan = _plan!;
    _commit(
      plan,
      plan.withFurniture(moveFurniture(f, d, plan.grid, snap: false)),
    );
  }

  /// Tastatur: Esc, Strg/Cmd+Z, Entf, Strg/Cmd+D, R, Pfeile.
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    final hk = HardwareKeyboard.instance;
    final ctrl = hk.isControlPressed || hk.isMetaPressed;
    if (ctrl && k == LogicalKeyboardKey.keyZ) {
      _undoLast();
      return KeyEventResult.handled;
    }
    if (e is KeyRepeatEvent &&
        !(k == LogicalKeyboardKey.arrowLeft ||
            k == LogicalKeyboardKey.arrowRight ||
            k == LogicalKeyboardKey.arrowUp ||
            k == LogicalKeyboardKey.arrowDown)) {
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      if (_fsel != null || _sel != null || _dsel != null) {
        setState(() {
          _fsel = null;
          _sel = null;
          _dsel = null;
        });
      } else {
        _close();
      }
      return KeyEventResult.handled;
    }
    final furniture = _mode == _Mode.furniture;
    if (k == LogicalKeyboardKey.delete || k == LogicalKeyboardKey.backspace) {
      if (furniture && _fsel != null) {
        _deleteFurnitureSel();
      } else if (_mode == _Mode.rooms && _sel != null) {
        _deleteSelected();
      } else if (_mode == _Mode.devices && _dsel != null) {
        _removeDevice(_dsel!);
      }
      return KeyEventResult.handled;
    }
    if (!furniture || _fsel == null) return KeyEventResult.ignored;
    if (ctrl && k == LogicalKeyboardKey.keyD) {
      _duplicateSel();
      return KeyEventResult.handled;
    }
    if (!ctrl && k == LogicalKeyboardKey.keyR) {
      _rotateSel(hk.isShiftPressed ? -kFurnitureRotationStep : 90);
      return KeyEventResult.handled;
    }
    final step = hk.isShiftPressed ? 0.1 : kFurnitureSnap;
    final d = switch (k) {
      LogicalKeyboardKey.arrowLeft => Offset(-step, 0),
      LogicalKeyboardKey.arrowRight => Offset(step, 0),
      LogicalKeyboardKey.arrowUp => Offset(0, -step),
      LogicalKeyboardKey.arrowDown => Offset(0, step),
      _ => null,
    };
    if (d == null) return KeyEventResult.ignored;
    _nudgeSel(d);
    return KeyEventResult.handled;
  }

  /// Bibliotheks-Element ziehbar: Vorschau in echter Größe unter dem Zeiger.
  Widget _furnitureDrag(FurnitureType t, Widget child) {
    final scale = _geo?.scale ?? 20;
    final size = Size(t.w * scale, t.h * scale);
    final hv = context.hv;
    final feedback = Material(
      type: MaterialType.transparency,
      child: SizedBox.fromSize(
        size: size,
        child: CustomPaint(
          painter: _ShapePainter(t.id, FurnitureInk.accent(hv)),
        ),
      ),
    );
    Offset anchor(Draggable<Object> d, BuildContext c, Offset p) =>
        Offset(size.width / 2, size.height / 2);
    void end(DraggableDetails d) =>
        _dropFurniture(t, d.offset + Offset(size.width / 2, size.height / 2));
    if (!context.isDesktopLayout) {
      return LongPressDraggable<String>(
        data: t.id,
        delay: const Duration(milliseconds: 150),
        hapticFeedbackOnStart: true,
        dragAnchorStrategy: anchor,
        feedback: feedback,
        onDragEnd: end,
        child: child,
      );
    }
    return Draggable<String>(
      data: t.id,
      dragAnchorStrategy: anchor,
      feedback: feedback,
      onDragEnd: end,
      child: child,
    );
  }

  String _furnInfo(FloorFurniture f) {
    final r = f.rotation.round();
    final s = f.sensor == null
        ? null
        : ref.read(snapshotProvider).entity(f.sensor!)?.name ?? f.sensor;
    return '${furnitureSizeText(f, _plan!.grid.cellMeters)}'
        '${r == 0 ? '' : ' · $r°'}'
        '${s == null ? '' : ' · Sensor $s'}';
  }

  /// Gewähltes Möbelstück: Name, Maße, Drehen, Duplizieren, Löschen.
  Widget _furnitureSelection(FloorFurniture f, {bool vertical = false}) {
    final hv = context.hv;
    final ctrl = ctrlLabel(context);
    final tools = [
      _ToolButton(
        label: 'Um 90° drehen',
        shortcut: 'R',
        icon: Icons.rotate_right_rounded,
        onTap: () => _rotateSel(90),
      ),
      const SizedBox(width: 4),
      if (f.canHaveSensor) ...[
        _ToolButton(
          label: f.sensor == null ? 'Sensor verknüpfen' : 'Sensor ändern',
          icon: f.sensor == null
              ? Icons.sensors_rounded
              : Icons.sensor_door_rounded,
          onTap: () => _linkSensor(f),
        ),
        const SizedBox(width: 4),
      ],
      _ToolButton(
        label: 'Duplizieren',
        shortcut: '${ctrl}D',
        icon: Icons.copy_all_rounded,
        onTap: _duplicateSel,
      ),
      const SizedBox(width: 4),
      _ToolButton(
        label: 'Löschen',
        shortcut: 'Entf',
        icon: Icons.delete_outline_rounded,
        destructive: true,
        onTap: _deleteFurnitureSel,
      ),
    ];
    final title = Row(
      children: [
        FurnitureThumb(kind: f.kind, size: 40),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                f.type?.name ?? 'Möbelstück',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HavenText.headline.copyWith(color: hv.tx, fontSize: 16),
              ),
              Text(
                _furnInfo(f),
                style: HavenText.caption.copyWith(color: hv.tx2),
              ),
            ],
          ),
        ),
      ],
    );
    if (!vertical) {
      return Row(
        key: ValueKey('fsel${f.id}'),
        children: [
          Expanded(child: title),
          ...tools,
        ],
      );
    }
    return Column(
      key: ValueKey('fsel${f.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        title,
        const SizedBox(height: 10),
        Row(children: tools),
        const SizedBox(height: 8),
        Text(
          'Ziehen verschiebt im Halbraster, mit Shift frei. Die Griffe '
          'ändern die Größe, der runde Griff dreht in 15°-Schritten.',
          style: HavenText.caption.copyWith(color: hv.tx3),
        ),
      ],
    );
  }

  /// Handy: Auswahl oder Hinweis oben, darunter die Bibliothek.
  Widget _furniturePanel(HavenFloorPlan plan) {
    final hv = context.hv;
    final sel = _selFurniture;
    return HavenCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
      radius: HavenRadii.m,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 52,
            child: AnimatedSwitcher(
              duration: context.motion(HavenMotion.d2),
              child: sel != null
                  ? _furnitureSelection(sel)
                  : Align(
                      key: ValueKey('fh${_hint ?? ''}'),
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _hint ??
                            'Antippen setzt in die Mitte, halten und ziehen '
                                'legt es genau ab. Möbel sind nur Deko.',
                        maxLines: 2,
                        style: HavenText.caption.copyWith(
                          color: _hint == null ? hv.tx2 : hv.tx,
                          fontSize: 13,
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: FurnitureLibrary(
              onAdd: _addFurniture,
              dragWrap: _furnitureDrag,
              cellMeters: plan.grid.cellMeters,
            ),
          ),
        ],
      ),
    );
  }

  /// Desktop: rechte Spalte je Modus.
  Widget _sidePanel(HavenFloorPlan plan) {
    final hv = context.hv;
    switch (_mode) {
      case _Mode.rooms:
        return Align(alignment: Alignment.topCenter, child: _roomTools(plan));
      case _Mode.devices:
        return _pool(plan);
      case _Mode.furniture:
        final sel = _selFurniture;
        return HavenCard(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          radius: HavenRadii.m,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedSize(
                duration: context.motion(HavenMotion.d2),
                curve: HavenMotion.out,
                alignment: Alignment.topCenter,
                child: sel != null
                    ? Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _furnitureSelection(sel, vertical: true),
                      )
                    : Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Einrichten',
                              style: HavenText.headline.copyWith(color: hv.tx),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _hint ??
                                  'Möbel in den Grundriss ziehen oder '
                                      'anklicken. Sie sind nur Deko und '
                                      'liegen auf der Karte unter dem Licht.',
                              style: HavenText.caption.copyWith(
                                color: _hint == null ? hv.tx2 : hv.tx,
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
              Container(height: 1, color: hv.ln),
              Expanded(
                child: FurnitureLibrary(
                  grid: true,
                  onAdd: _addFurniture,
                  dragWrap: _furnitureDrag,
                  cellMeters: plan.grid.cellMeters,
                ),
              ),
            ],
          ),
        );
    }
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
    final furniture = _mode == _Mode.furniture;
    final desktop = context.isDesktopLayout;
    final ctrl = ctrlLabel(context);

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Row(
        children: [
          RoundIconButton(
            icon: Icons.arrow_back_rounded,
            label: 'Zurück',
            onTap: _close,
          ),
          Expanded(
            child: Text(
              'Grundriss',
              textAlign: TextAlign.center,
              style: HavenText.headline.copyWith(color: hv.tx, fontSize: 22),
            ),
          ),
          DesktopTooltip(
            message: 'Rückgängig',
            shortcut: '${ctrl}Z',
            child: Opacity(
              opacity: _undo.isEmpty ? 0.4 : 1,
              child: RoundIconButton(
                icon: Icons.undo_rounded,
                label: 'Rückgängig',
                onTap: _undoLast,
              ),
            ),
          ),
        ],
      ),
    );
    final modes = Padding(
      padding: const EdgeInsets.symmetric(horizontal: HavenSpace.page),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: HavenSegmented<_Mode>(
          options: const [
            (_Mode.rooms, 'Räume zeichnen'),
            (_Mode.devices, 'Geräte setzen'),
            (_Mode.furniture, 'Einrichten'),
          ],
          selected: _mode,
          onChanged: (m) => setState(() {
            _mode = m;
            _hover = null;
            _dragCell = null;
            _cursor = MouseCursor.defer;
            if (m != _Mode.furniture) _fsel = null;
          }),
        ),
      ),
    );
    final canvas = Expanded(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: LayoutBuilder(
          builder: (context, cons) {
            final geo = _geometry(Size(cons.maxWidth, cons.maxHeight));
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(child: _canvas(context, plan, geo)),
                if (_previewInfo != null) _previewOverlay(geo, _previewInfo!),
                if (_mode == _Mode.devices)
                  Positioned(top: 6, right: 6, child: _lightToggle()),
                if (_mode == _Mode.rooms)
                  Positioned(top: 6, right: 6, child: _northControl(plan)),
              ],
            );
          },
        ),
      ),
    );

    final Widget body;
    if (desktop) {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: Column(children: [header, modes, canvas])),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 14, 16, 16),
            child: SizedBox(
              width: DesktopMetrics.sideColumn,
              child: _sidePanel(plan),
            ),
          ),
        ],
      );
    } else {
      body = Column(
        children: [
          header,
          modes,
          canvas,
          AnimatedContainer(
            duration: context.motion(HavenMotion.d2),
            curve: HavenMotion.out,
            height: devices ? 300 : (furniture ? 252 : 132),
            padding: const EdgeInsets.fromLTRB(
              HavenSpace.page,
              0,
              HavenSpace.page,
              14,
            ),
            child: devices
                ? _pool(plan)
                : (furniture ? _furniturePanel(plan) : _roomTools(plan)),
          ),
        ],
      );
    }

    return Scaffold(
      backgroundColor: hv.bg,
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: SafeArea(child: body),
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
    // Geräte gibt es nur im Modus „Geräte setzen“. Beim Zeichnen der Räume
    // und beim Einrichten stören sie nur.
    final nodes = _mode != _Mode.devices
        ? const <FloorNode>[]
        : [
            for (final p in plan.placements)
              FloorNode(id: p.entityId, point: plan.pointOfCell(p.cell)),
          ];

    // Größe beim Ziehen: aktuelle Zielfläche in Zellen.
    final active = _draft;
    final selected = rooms && _sel != null ? plan.room(_sel!) : null;
    final furniture = _mode == _Mode.furniture;
    final fsel = furniture ? _selFurniture : null;
    // Während einer Geste zeigt die 3D-Szene den Stand davor (sie baut sich
    // erst nach dem Loslassen neu auf); das gezogene Möbel zeichnet das
    // Overlay. Möbel erscheinen nur im Modus „Einrichten“.
    final stable = _fop?.base ?? _op?.base ?? plan;
    final lit = _mode == _Mode.devices && _light != _EditorLight.off;
    final view = _EditorScene(
      plan: stable,
      lit: lit,
      lamps: lit ? _lampsFor(stable) : const {},
      sun: ref.watch(map3dSettingsProvider).environment
          ? mapSunOf(ref, stable.north)
          : null,
      transparentWalls: ref.watch(map3dSettingsProvider).transparentWalls,
      geo: geo,
      tilt: _view3d,
      projection: _proj,
      nodes: nodes,
      nodeBuilder: (context, n) {
        final kind = plan.placementOf(n.id)!.resolvedKind;
        final marker = MapMarker(entityId: n.id, kind: kind);
        if (rooms) return marker;
        return _drag(n.id, kind, marker);
      },
      interactiveMarkers: _mode == _Mode.devices,
      highlightRoomId: !rooms ? _hover : null,
      hiddenObjects: {
        // Räume zeichnen ohne Möbel; Geräte setzen mit Möbeln (Tischlampe
        // auf den Tisch), das gezogene Gerät weicht der Vorschau.
        if (rooms)
          for (final f in stable.furniture) f.id,
        if (furniture && _fop != null && fsel != null) fsel.id,
        if (_dragId != null) 'device:$_dragId',
      },
      overlay: _EditorOverlay(
        hv: hv,
        selected: selected,
        active: active,
        valid: _draftValid,
        invalid: _invalid,
        activeVertex: _activeVertex,
        cellMeters: plan.grid.cellMeters,
        dragCell: _mode == _Mode.devices ? _dragCell : null,
        outsideHover: _mode == _Mode.devices && _hover == kOutsideId,
        furniture: fsel,
        handles: fsel == null ? null : _handlesOf(fsel),
        handleRadius: context.isDesktopLayout ? 5.5 : 7.5,
        furnitureLabel: fsel != null && _fop != null
            ? (_fop!.kind == _FurnOpKind.rotate
                  ? '${fsel.rotation.round()}°'
                  : furnitureSizeText(fsel, plan.grid.cellMeters))
            : null,
      ),
    );

    final Widget child;
    if (rooms) {
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onPanStart: _panStart,
        onPanUpdate: _panUpdate,
        onPanEnd: _panEnd,
        onPanCancel: _panEnd,
        onTapUp: _tap,
        onLongPressStart: _longPress,
        onSecondaryTapUp: _secondaryTap,
        child: IgnorePointer(child: view),
      );
    } else if (furniture) {
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onPanStart: _fPanStart,
        onPanUpdate: _fPanUpdate,
        onPanEnd: _fPanEnd,
        onPanCancel: _fPanEnd,
        onTapUp: _fTap,
        onSecondaryTapUp: _secondaryTap,
        child: IgnorePointer(child: view),
      );
    } else {
      child = view;
    }

    return KeyedSubtree(
      key: _canvasKey,
      child: Listener(
        // Klick in die Fläche holt den Tastaturfokus zurück (Esc, Entf ...).
        onPointerDown: (_) {
          if (!_focus.hasFocus) _focus.requestFocus();
        },
        child: MouseRegion(
          cursor: _cursor,
          onHover: (e) => _hoverAt(e.localPosition),
          onExit: (_) {
            if (_cursor != MouseCursor.defer) {
              setState(() => _cursor = MouseCursor.defer);
            }
          },
          child: child,
        ),
      ),
    );
  }

  // ---- Nordrichtung --------------------------------------------------------

  /// Norden drehen (15°-Schritte): danach stellt die 3D-Karte die Sonne.
  void _turnNorth(HavenFloorPlan plan, double by) {
    Haptics.tick();
    final n = ((plan.north + by) % 360 + 360) % 360;
    _commit(plan, plan.copyWith(north: n));
  }

  Widget _northControl(HavenFloorPlan plan) {
    final hv = context.hv;
    return Container(
      key: const ValueKey('editor-north'),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: hv.s1.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(HavenRadii.pill),
        border: Border.all(color: hv.ln),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Norden nach links drehen',
            icon: const Icon(Icons.rotate_left_rounded, size: 20),
            onPressed: () => _turnNorth(plan, -15),
          ),
          Semantics(
            label: 'Norden ${plan.north.round()} Grad',
            child: SizedBox(
              width: 44,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Transform.rotate(
                    angle: plan.north * math.pi / 180,
                    child: Icon(
                      Icons.navigation_rounded,
                      size: 20,
                      color: hv.acc,
                    ),
                  ),
                  Text(
                    'N ${plan.north.round()}°',
                    style: HavenText.caption.copyWith(
                      color: hv.tx2,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'Norden nach rechts drehen',
            icon: const Icon(Icons.rotate_right_rounded, size: 20),
            onPressed: () => _turnNorth(plan, 15),
          ),
        ],
      ),
    );
  }

  // ---- Licht beim Geräte setzen -------------------------------------------

  /// Lampenzustand für die Szene: live wie zu Hause oder alle warmweiß.
  Map<String, h3.LampState> _lampsFor(HavenFloorPlan plan) {
    final ids = [
      for (final p in plan.placements)
        if (p.resolvedKind == FloorKind.light) p.entityId,
    ];
    if (_light == _EditorLight.on) {
      return {for (final id in ids) id: kEditorWarmWhite};
    }
    // Nur die platzierten Lampen beobachten (Wertgleichheit: baut nur neu,
    // wenn sich eine davon ändert).
    final live = ref.watch(
      snapshotProvider.select(
        (s) => MapLights({for (final id in ids) id: ?s.lamp(id)}, const {}),
      ),
    );
    return {for (final e in live.lamps.entries) e.key: lampStateOf(e.value)};
  }

  Widget _lightToggle() {
    final hv = context.hv;
    return Container(
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(
        color: hv.s1.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(HavenRadii.pill),
        border: Border.all(color: hv.ln),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _light == _EditorLight.off
                ? Icons.lightbulb_outline_rounded
                : Icons.lightbulb_rounded,
            size: 18,
            color: _light == _EditorLight.off ? hv.tx2 : hv.acc,
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 186,
            child: HavenSegmented<_EditorLight>(
              key: const ValueKey('editor-light'),
              neutral: true,
              options: const [
                (_EditorLight.off, 'Aus'),
                (_EditorLight.live, 'Live'),
                (_EditorLight.on, 'An'),
              ],
              selected: _light,
              onChanged: (v) => setState(() => _light = v),
            ),
          ),
        ],
      ),
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
                          'antippen für eine neue Ecke, lange drücken öffnet '
                          'die Wand dort (nur Raumgrenze).',
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

  /// Geräteliste (Ablegen dort nimmt ein Gerät von der Karte).
  final _poolKey = GlobalKey();

  bool _overPool(Offset global) {
    final box = _poolKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    return (box.localToGlobal(Offset.zero) & box.size).contains(global);
  }

  Widget _pool(HavenFloorPlan plan) =>
      KeyedSubtree(key: _poolKey, child: _poolCard(plan));

  Widget _poolCard(HavenFloorPlan plan) {
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
    final dsel = _dsel == null ? null : plan.placementOf(_dsel!);
    // Am Handy ist das Panel niedrig: das gewählte Gerät bekommt es ganz
    // (scrollbar), die Liste kommt nach dem Abwählen zurück.
    if (dsel != null && !context.isDesktopLayout) {
      return HavenCard(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
        radius: HavenRadii.m,
        child: SingleChildScrollView(child: _deviceDetails(plan, dsel)),
      );
    }
    return HavenCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
      radius: HavenRadii.m,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (dsel != null)
            Flexible(
              flex: 3,
              child: SingleChildScrollView(child: _deviceDetails(plan, dsel)),
            ),
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
    this.shortcut,
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool destructive;
  final String? shortcut;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return DesktopTooltip(
      message: label,
      shortcut: shortcut,
      child: Semantics(
        button: true,
        label: label,
        child: HoverBuilder(
          builder: (context, hover) => PressScale(
            onTap: onTap,
            child: SizedBox(
              width: HavenSpace.touch,
              height: HavenSpace.touch,
              child: Center(
                child: AnimatedContainer(
                  duration: context.motion(HavenMotion.d1),
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color.alphaBlend(hoverOverlay(hv, hover), hv.s2),
                    border: Border.all(
                      color: hover
                          ? (destructive ? hv.bad : hv.acc).withValues(
                              alpha: 0.6,
                            )
                          : hv.ln2,
                    ),
                  ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: destructive ? hv.bad : hv.tx,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Form eines Möbeltyps in der eigenen Größe (Vorschau beim Ziehen).
class _ShapePainter extends CustomPainter {
  _ShapePainter(this.kind, this.ink);
  final String kind;
  final FurnitureInk ink;

  @override
  void paint(Canvas canvas, Size size) =>
      paintFurnitureShape(canvas, kind, size, ink);

  @override
  bool shouldRepaint(_ShapePainter old) => old.kind != kind || old.ink != ink;
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
    final remove = info.remove;
    final stays = !remove && info.target == null;
    final target = remove
        ? 'Zurück in die Liste'
        : (stays ? 'Bleibt an seinem Platz' : info.target!);
    final outside = info.target == kOutsideName;
    final accent = remove || stays ? hv.tx3 : (outside ? hv.ok : hv.acc);
    return Container(
      constraints: const BoxConstraints(maxWidth: 236),
      padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
      decoration: BoxDecoration(
        color: hv.s1,
        borderRadius: BorderRadius.circular(HavenRadii.pill),
        border: Border.all(color: hv.ln2),
        boxShadow: [
          BoxShadow(
            color: const Color(
              0xFF000000,
            ).withValues(alpha: hv.isDark ? 0.5 : 0.16),
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
    this.furniture,
    this.handles,
    this.handleRadius = 6,
    this.furnitureLabel,
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

  /// Gewähltes Möbelstück mit seinen Griffen (Pixel).
  final FloorFurniture? furniture;
  final List<(FurnitureHandle, Offset)>? handles;
  final double handleRadius;

  /// Maße bzw. Winkel während der Geste.
  final String? furnitureLabel;

  String _m(double v) =>
      (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1))
          .replaceAll('.', ',');

  void _paintFurnitureSelection(Canvas canvas, Size size, FloorGeometry geo) {
    final f = furniture!;
    paintFurniture(
      canvas,
      f,
      geo.cellToPx(f.center),
      geo.scale,
      FurnitureInk.accent(hv),
    );
    final pts = [for (final c in f.corners) geo.cellToPx(c)];
    final frame = Path()..addPolygon(pts, true);
    canvas.drawPath(
      frame,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = hv.acc.withValues(alpha: 0.9),
    );
    final hs = handles ?? const [];
    final top = geo.cellToPx(f.toWorld(Offset(0, -f.h / 2)));
    for (final (h, at) in hs) {
      if (h.isRotate) {
        canvas.drawLine(
          top,
          at,
          Paint()
            ..strokeWidth = 1.2
            ..color = hv.acc.withValues(alpha: 0.8),
        );
        final r = handleRadius + 3;
        canvas.drawCircle(at, r, Paint()..color = hv.acc);
        // Kleiner Drehpfeil.
        final arc = Rect.fromCircle(center: at, radius: r * 0.5);
        final ink = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round
          ..color = hv.ai;
        canvas.drawArc(arc, -math.pi * 0.9, math.pi * 1.5, false, ink);
        final tip = at + Offset(r * 0.5, 0);
        canvas.drawLine(tip, tip + Offset(-r * 0.28, -r * 0.22), ink);
        canvas.drawLine(tip, tip + Offset(r * 0.22, -r * 0.26), ink);
        continue;
      }
      final r = h.isCorner ? handleRadius : handleRadius * 0.8;
      canvas.drawCircle(at, r, Paint()..color = hv.s1);
      canvas.drawCircle(
        at,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..color = hv.acc,
      );
    }
    final label = furnitureLabel;
    if (label != null) {
      final b = Rect.fromPoints(
        geo.cellToPx(f.bounds.topLeft),
        geo.cellToPx(f.bounds.bottomRight),
      );
      _label(canvas, size, b.bottomCenter + const Offset(0, 22), label, hv.acc);
    }
  }

  @override
  void paint(Canvas canvas, Size size, FloorGeometry geo) {
    if (furniture != null) _paintFurnitureSelection(canvas, size, geo);
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
      old.outsideHover != outsideHover ||
      old.furniture != furniture ||
      old.handleRadius != handleRadius ||
      old.furnitureLabel != furnitureLabel;
}

/// Grundriss des Editors in 3D: Draufsicht, die Kamera folgt genau [geo]
/// (Zellen ↔ Pixel), damit Griffe, Raster und Gesten des Editors passen.
/// Ohne Baking ([h3.SceneQuality.draft]): ein Neuaufbau nach jeder Änderung
/// kostet nur einige Millisekunden.
class _EditorScene extends StatefulWidget {
  const _EditorScene({
    required this.plan,
    required this.geo,
    required this.overlay,
    this.nodes = const [],
    this.nodeBuilder,
    this.interactiveMarkers = false,
    this.highlightRoomId,
    this.hiddenObjects = const {},
    this.tilt = false,
    this.projection,
    this.lit = false,
    this.lamps = const {},
    this.sun,
    this.transparentWalls = false,
  });

  /// Sonnenrichtung (siehe `mapSunOf`), `null`: Standard.
  final h3.V3? sun;

  /// Wände halbdurchsichtig statt deckend (Einstellungen).
  final bool transparentWalls;

  /// Lampen leuchten in Echtzeit (Zustand aus [lamps], fehlende sind aus).
  final bool lit;
  final Map<String, h3.LampState> lamps;

  final HavenFloorPlan plan;
  final FloorGeometry geo;

  /// Schräg (Geräte in 3D): eigene Kamera zum Drehen, keine 2D-Ebenen.
  final bool tilt;

  /// Bekommt die Projektion jedes Bildes (Ablegen in 3D).
  final _EditorProjection? projection;
  final FloorOverlayPainter overlay;
  final List<FloorNode> nodes;
  final FloorNodeBuilder? nodeBuilder;
  final bool interactiveMarkers;
  final String? highlightRoomId;
  final Set<String> hiddenObjects;

  @override
  State<_EditorScene> createState() => _EditorSceneState();
}

class _EditorSceneState extends State<_EditorScene> {
  final _c = h3.SceneController();
  (h3.OrbitCamera, bool)? _camKey;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Draufsicht, die [g] genau trifft: Bildmitte und Pixel je Meter.
  h3.OrbitCamera _cameraFor(FloorGeometry g, double m) {
    final mid = g.pxToCell(g.size.center(Offset.zero)) * m;
    return h3.OrbitCamera(target: h3.V3(mid.dx, mid.dy, 0), scale: g.scale / m);
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final w = widget;
    final m = w.plan.grid.cellMeters;
    w.projection?.controller = _c;
    final top = _cameraFor(w.geo, m);
    final key = (top, w.tilt);
    if (key != _camKey) {
      // Neue Fläche oder Ansicht: Kamera setzen (schräg: von dort aus
      // frei drehbar, bis sich etwas ändert).
      _camKey = key;
      _c.preset(
        w.tilt
            ? top.copyWith(yaw: -0.35, pitch: 0.85, scale: top.scale * 0.9)
            : top,
      );
    }
    final byId = {for (final n in w.nodes) n.id: n};
    // Wie die Karte ohne Himmel: im dunklen Design dieselben Farben mit
    // gedämpftem Licht; Wände deckend, wenn nicht anders eingestellt.
    final style = (hv.isDark ? h3.SceneStyle.evening() : h3.SceneStyle.light())
        .copyWith(
          accent: hv.acc,
          wallOpacity: widget.transparentWalls ? null : 1,
          floorOpacity: widget.transparentWalls ? null : 1,
        );
    final scene = sceneOfPlan(w.plan);
    // Lampen nach dem Bild setzen (nur geänderte rechnen neu).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final mk in scene.markers) {
        if (mk.lamp == null) continue;
        _c.setLamp(mk.id, widget.lamps[mk.id] ?? h3.LampState.off);
      }
      if (widget.sun case final s?) _c.setSun(s);
    });
    return h3.Scene3DView(
      scene: scene,
      controller: _c,
      style: style,
      quality: w.lit ? h3.SceneQuality.draftLit : h3.SceneQuality.draft,
      gestures: w.tilt ? h3.SceneGestures.orbit : h3.SceneGestures.none,
      fitOnStart: false,
      // Schräg stehen die Räume (Wandgeräte sitzen an ihren Wänden).
      raisedRooms: w.tilt ? null : const {},
      selectedRoomId: w.highlightRoomId,
      hiddenObjects: w.hiddenObjects,
      interactiveMarkers: w.interactiveMarkers,
      markerHitRadius: 22,
      markers: [
        for (final (n, at) in spreadNodes(w.nodes))
          h3.SceneMarker(
            id: n.id,
            at: at * m,
            roomId: n.point.isOutside || n.point.roomId.isEmpty
                ? null
                : n.point.roomId,
            // Auf der Höhe des Geräts (Bauform, gewählte Höhe).
            height: switch (w.plan.placementOf(n.id)) {
              final p? => markerHeightOf(p),
              null => null,
            },
          ),
      ],
      markerBuilder: w.nodeBuilder == null
          ? null
          : (context, mk) => switch (byId[mk.id]) {
              final n? => SizedBox.square(
                dimension: n.size,
                child: Center(child: w.nodeBuilder!(context, n)),
              ),
              null => const SizedBox.shrink(),
            },
      overlayBuilder: (context, p) {
        w.projection?.current = p;
        // Schräg passen Raster und Griffe der Draufsicht nicht.
        if (w.tilt) return const SizedBox.shrink();
        return RepaintBoundary(
          child: CustomPaint(
            painter: _GeoPainter(geo: w.geo, overlay: w.overlay, hv: hv),
          ),
        );
      },
    );
  }
}

/// Projektion des letzten Bildes der Editor-Szene (Ablegen in 3D).
class _EditorProjection {
  h3.SceneProjection? current;

  /// Steuerung der Editor-Szene (Vorschau beim Platzieren).
  h3.SceneController? controller;
}

/// Raster, „Draußen“ und das Overlay des Editors über der 3D-Szene.
class _GeoPainter extends CustomPainter {
  _GeoPainter({required this.geo, required this.overlay, required this.hv})
    : super(repaint: overlay.repaint);
  final FloorGeometry geo;
  final FloorOverlayPainter overlay;
  final HavenColors hv;

  @override
  void paint(Canvas canvas, Size size) {
    final o = geo.outside;
    if (o != null) {
      final green = hv.ok;
      final rr = RRect.fromRectAndRadius(o, const Radius.circular(22));
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = green.withValues(alpha: hv.isDark ? 0.32 : 0.38),
      );
      final tp = TextPainter(
        text: TextSpan(
          text: kOutsideName,
          style: HavenText.caption.copyWith(
            color: Color.alphaBlend(green.withValues(alpha: 0.55), hv.tx3),
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, o.topLeft + const Offset(12, 7));
    }
    final g = geo.plan.grid;
    final dots = <Offset>[
      for (var y = 0; y <= g.rows; y++)
        for (var x = 0; x <= g.cols; x++)
          geo.cellToPx(Offset(x.toDouble(), y.toDouble())),
    ];
    canvas.drawPoints(
      PointMode.points,
      dots,
      Paint()
        ..color = hv.tx3.withValues(alpha: 0.35)
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round,
    );
    // Offene Wände: gestrichelte Raumgrenze.
    final dash = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = hv.acc.withValues(alpha: 0.8);
    for (final r in geo.plan.rooms) {
      final pts = geo.polygons[r.id];
      if (pts == null || r.open.isEmpty) continue;
      for (final i in r.open) {
        if (i >= pts.length) continue;
        final a = pts[i], b = pts[(i + 1) % pts.length];
        final len = (b - a).distance;
        for (var t = 0.0; t < len; t += 9) {
          canvas.drawLine(
            Offset.lerp(a, b, t / len)!,
            Offset.lerp(a, b, math.min(len, t + 4.5) / len)!,
            dash,
          );
        }
      }
    }
    overlay.paint(canvas, size, geo);
  }

  @override
  bool shouldRepaint(_GeoPainter old) =>
      old.geo != geo || old.hv != hv || overlay.shouldRepaint(old.overlay);
}
