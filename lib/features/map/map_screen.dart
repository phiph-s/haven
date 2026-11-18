import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/rendering.dart';
import 'package:go_router/go_router.dart';
import 'package:haven_3d/haven_3d.dart'
    as h3
    show SceneController, SceneHeatmap, SceneProjection, SceneQuality;
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
import '../../data/models/zigbee.dart';
import '../room/widgets/lamp_sheet.dart';
import '../zigbee/mesh/mesh_graph.dart';
import '../zigbee/mesh/mesh_painter.dart';
import '../zigbee/mesh/mesh_providers.dart';
import '../zigbee/mesh/mesh_scene.dart';
import '../zigbee/mesh/mesh_screen.dart' show zigbeeMeshPath;
import '../zigbee/zigbee_providers.dart';
import '../zigbee/zigbee_screen.dart' show zigbeeDevicePath;
import 'floor_plan_store.dart';
import 'floor_geometry.dart';
import 'heatmap.dart';
import 'map_data.dart';
import 'map_actions.dart';
import 'map_layer_widgets.dart';
import 'map_inspector.dart';
import 'map_info.dart';
import 'map_layers.dart';
import 'map_3d.dart';
import 'map_light_controls.dart';
import 'map_markers.dart';
import 'map_panels.dart';
import 'map_readings.dart';
import 'map_thermostat.dart';
import 'map_routes.dart';

/// Karte: Grundriss mit Kartenarten (Licht, Temperatur, Luftfeuchte,
/// Bewegung, Funknetz, Batterie). Die Lichtfarbe der Wohnung färbt Akzent
/// und Glow.
class MapScreen extends ConsumerWidget {
  const MapScreen({
    super.key,
    this.startMinutes,
    this.startInspect,
    this.startTap,
  });

  /// Nur für Screenshots: Zeitstrahl verschoben,
  /// Raum im Inspektor (Desktop), angetippter Knoten oder Raum (`room:<ID>`).
  final double? startMinutes;
  final String? startInspect;
  final String? startTap;

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
          if (has)
            // Die Karte nutzt die ganze Fläche bis zum Rand (am Handy auch
            // unter der Navigation), Kopf und Leisten liegen über ihr.
            Positioned.fill(
              child: _MapBody(
                plan: p,
                header: _MapHeader(plan: p),
                startMinutes: startMinutes,
                startInspect: startInspect,
                startTap: startTap,
              ),
            )
          else
            Column(
              children: [
                _MapHeader(plan: has ? p : null),
                Expanded(
                  child: !plan.hasValue
                      ? const SizedBox.shrink()
                      : has
                      ? _MapBody(
                          plan: p,
                          startMinutes: startMinutes,
                          startInspect: startInspect,
                          startTap: startTap,
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

  String _lampsSub(WidgetRef ref) {
    final n = ref.watch(mapLightsProvider(plan!)).onCount;
    return n == 0
        ? 'Alle Lichter aus'
        : n == 1
        ? 'Ein Licht an'
        : '$n Lichter an';
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
        MapLayer.combo => _lightSub(ref),
        MapLayer.light => _lampsSub(ref),
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
    this.header,
    this.startMinutes,
    this.startInspect,
    this.startTap,
  });
  final HavenFloorPlan plan;
  final double? startMinutes;
  final String? startInspect;
  final String? startTap;

  /// Handy: Kopf der Seite, liegt über der Karte.
  final Widget? header;

  @override
  ConsumerState<_MapBody> createState() => _MapBodyState();
}

class _MapBodyState extends ConsumerState<_MapBody> {
  String? _info;
  Timer? _infoTimer;
  final _mesh = ValueNotifier(const MeshViewState());
  String? _meshSel;

  /// Raum im Inspektor (nur Desktop).
  late String? _inspect = widget.startInspect;

  /// Info-Panel im Inspektor (nur Desktop), auf dem Handy öffnet ein Sheet.
  MapPanelSpec? _panel;
  Timer? _powerTimer;
  Timer? _startTapTimer;

  /// Handy: Höhe von Kopf und unterer Leiste (Legende plus Navigation). Der
  /// Grundriss wird dazwischen eingepasst, gezeichnet wird bis an den Rand.
  double _topH = 96;
  double _bottomH = 200;

  // ---- 3D --------------------------------------------------------------------

  /// Handy: Raum im Fokus (die Karte unten zeigt ihn, Kamera fährt hin).
  String? _focusRoom;

  /// Raum, der sich aufrichtet (Fokus auf Raum oder Gerät).
  String? _raised;

  /// Zählt Fokuswechsel: ein spät geschlossenes Panel stellt nichts zurück,
  /// wenn inzwischen etwas anderes passiert ist.
  int _focusTick = 0;

  /// Desktop: Raum des offenen Geräte-Panels und zuletzt angefahrener Raum.
  String? _panelRoom;
  String? _deskFocus;

  // Bewegung: Zeitstrahl und Takt fürs Abklingen.
  late double _minutes = widget.startMinutes ?? 0;
  Timer? _clock;
  Timer? _measureClock;
  Map<String, List<StateChange>> _history = const {};
  DateTime _historyAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _loadingHistory = false;

  @override
  void initState() {
    super.initState();
    final tap = widget.startTap;
    if (tap != null) {
      // Nur für Screenshots: nach dem Einblenden antippen.
      _startTapTimer = Timer(const Duration(milliseconds: 900), () {
        if (!mounted) return;
        if (tap.startsWith('room:')) {
          final r = widget.plan.room(tap.substring(5));
          if (r != null) _tapRoom(r);
        } else {
          _tapNode(FloorNode(id: tap, point: const PlanPoint(0, 0, '')));
        }
      });
    }
  }

  @override
  void dispose() {
    _startTapTimer?.cancel();
    _infoTimer?.cancel();
    _powerTimer?.cancel();
    _clock?.cancel();
    _measureClock?.cancel();
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

  /// Zieltyp eines Knotens. Lichtschalter der Kartenart Licht sind Regler,
  /// sonst entscheiden Zigbee-Typ und Art der Platzierung.
  MapTarget _targetOf(String id) {
    final layer = ref.read(mapLayerProvider);
    if (layer == MapLayer.network) return MapTarget.otherDevice;
    if (layer == MapLayer.light &&
        ref.read(mapLightControlsProvider(widget.plan)).rooms.containsKey(id)) {
      return MapTarget.control;
    }
    final zb = zbDeviceForEntity(ref.read(zigbeeProvider).devices, id);
    final kind =
        widget.plan.placementOf(id)?.resolvedKind ?? FloorKind.ofEntity(id);
    return mapTargetOf(kind, zbType: zb?.deviceType, entityId: id);
  }

  /// Zeigt ein Panel: auf dem Handy als Sheet, auf dem Desktop im Inspektor
  /// als Details eines Geräts (zweite Ebene, zurück führt zur Raumliste).
  ///
  /// In 3D fährt die Kamera dabei zum Raum [roomId] (er richtet sich auf),
  /// das Panel nimmt unten zwei Drittel ein. Beim Schließen fährt sie zurück.
  void _openPanel(MapPanelSpec spec, {String? roomId}) {
    Haptics.tick();
    if (context.isDesktopLayout) {
      setState(() {
        _panel = spec;
        _inspect = null;
        _panelRoom = roomId;
      });
    } else if (_use3d) {
      unawaited(_panel3d(spec, roomId));
    } else {
      unawaited(showMapPanel(context, spec));
    }
  }

  bool get _use3d =>
      ref.read(mapLayerProvider) != MapLayer.network &&
      (ref.read(map3dSupportedProvider).value ?? false);

  Future<void> _panel3d(MapPanelSpec spec, String? roomId) async {
    final tick = ++_focusTick;
    double? shown;
    // Die Kamera passt den Raum über das Sheet, sobald seine Höhe feststeht:
    // ein kurzes Panel lässt dem Raum mehr Platz, er rückt tiefer und näher.
    await showMapPanel(
      context,
      spec,
      overMap: true,
      onHeight: (h) {
        if (!mounted || tick != _focusTick || roomId == null) return;
        if (shown != null && (h - shown!).abs() < 24) return;
        shown = h;
        _focus3d(roomId, bottom: h + 12);
      },
    );
    if (!mounted || tick != _focusTick) return;
    final room = _focusRoom;
    if (room != null) {
      _focus3d(room);
    } else if (roomId != null) {
      _unfocus3d();
    }
  }

  /// Freie Fläche der Karte (Handy): unter dem Kopf, über der Leiste oder
  /// über dem Panel.
  EdgeInsets _mapInsets({double? bottom}) =>
      EdgeInsets.fromLTRB(8, _topH + 8, 8, bottom ?? _bottomH);

  void _focus3d(String roomId, {double? bottom}) {
    final s = ref.read(map3dSettingsProvider);
    setState(() => _raised = roomId);
    unawaited(
      ref
          .read(map3dControllerProvider)
          .focus(
            roomId: roomId,
            yaw: s.tilt ? null : kMapFocusYaw,
            pitch: s.tilt ? null : kMapFocusPitch,
            insets: _mapInsets(bottom: bottom),
          ),
    );
  }

  /// Fokus aufheben und zur Kamera davor zurückfahren.
  void _unfocus3d() {
    _clearFocus();
    unawaited(ref.read(map3dControllerProvider).back());
  }

  /// Fokus aufheben, ohne die Kamera zu bewegen.
  void _clearFocus() {
    _focusTick++;
    if (_focusRoom == null && _raised == null) return;
    setState(() {
      _focusRoom = null;
      _raised = null;
    });
  }

  String? _roomOf(FloorNode n) =>
      n.point.isOutside || n.point.roomId.isEmpty ? null : n.point.roomId;

  void _closePanel() {
    if (_panel != null) setState(() => _panel = null);
  }

  String _nameOf(String id) {
    final zb = zbDeviceForEntity(ref.read(zigbeeProvider).devices, id);
    return zb?.friendlyName ?? ref.read(entityProvider(id))?.name ?? id;
  }

  void _tapNode(FloorNode n) {
    final layer = ref.read(mapLayerProvider);
    final target = _targetOf(n.id);
    final repo = ref.read(repositoryProvider);
    final e = ref.read(entityProvider(n.id));
    final name = e?.name ?? n.id;
    switch (mapTapAction(layer, target)) {
      case MapTapAction.toggleLamp:
        Haptics.tap();
        unawaited(repo.setLights([n.id], on: !(e?.isOn ?? false)));
      case MapTapAction.togglePlug:
        Haptics.tap();
        final was = e?.isOn ?? false;
        final w = plugPowerOf(ref, n.id);
        unawaited(repo.callService('switch', 'toggle', entityId: n.id));
        _powerTimer?.cancel();
        if (was) {
          _say(
            w != null && w > 0
                ? '$name aus, zuletzt ${w.round()} W'
                : '$name aus',
          );
        } else {
          _say('$name an');
          // Die Steckdose braucht einen Moment, bis sie ihre Leistung meldet.
          _powerTimer = Timer(const Duration(milliseconds: 1500), () {
            if (!mounted) return;
            final now = plugPowerOf(ref, n.id);
            if (now != null) _say('$name an, ${now.round()} W');
          });
        }
      case MapTapAction.openClimateSheet:
        final kind = layer == MapLayer.humidity
            ? HeatKind.humidity
            : HeatKind.temperature;
        _openPanel(
          roomId: _roomOf(n),
          MapPanelSpec(
            key: 'sensor-${kind.name}-${n.id}',
            builder: (_) => SensorPanel(entityId: n.id, kind: kind),
          ),
        );
      case MapTapAction.openThermostat:
        Haptics.tick();
        _openPanel(
          roomId: _roomOf(n),
          MapPanelSpec(
            key: 'thermostat-${n.id}',
            builder: (_) => ThermostatPanel(entityId: n.id),
          ),
        );
      case MapTapAction.openMotionSheet:
        _openPanel(
          roomId: _roomOf(n),
          MapPanelSpec(
            key: 'motion-${n.id}',
            builder: (_) => MotionPanel(entityId: n.id),
          ),
        );
      case MapTapAction.openBatterySheet:
        _openPanel(
          roomId: _roomOf(n),
          MapPanelSpec(
            key: 'battery-${n.id}',
            builder: (_) => BatteryPanel(entityId: n.id),
          ),
        );
      case MapTapAction.showControlInfo:
        final room = ref
            .read(mapLightControlsProvider(widget.plan))
            .rooms[n.id];
        if (room == null) return _say(name);
        _openPanel(
          roomId: _roomOf(n),
          MapPanelSpec(
            key: 'control-${n.id}',
            builder: (_) => ControlPanel(entityId: n.id, room: room),
          ),
        );
      case MapTapAction.selectNetworkNode:
        Haptics.tick();
        setState(() => _meshSel = _meshSel == n.id ? null : n.id);
      case MapTapAction.showStatus:
        Haptics.tick();
        final shown = shortDeviceName(name);
        _say(switch (widget.plan.placementOf(n.id)?.resolvedKind) {
          FloorKind.contact => '$shown, ${(e?.isOn ?? false) ? 'offen' : 'zu'}',
          _ => shown,
        });
      case MapTapAction.openRoomSheet ||
          MapTapAction.openRoomClimate ||
          MapTapAction.openRoomMotion ||
          MapTapAction.openRoomBatteries ||
          MapTapAction.none:
        break;
    }
  }

  /// Langes Drücken: Licht-Sheet (Licht, Lampen), sonst das Gerät-Detail.
  void _holdNode(FloorNode n) {
    final layer = ref.read(mapLayerProvider);
    switch (mapHoldAction(layer, _targetOf(n.id))) {
      case MapHoldAction.openLampSheet:
        Haptics.tick();
        _openLamp(n.id);
      case MapHoldAction.openDevice:
        _openDevice(n.id);
      case MapHoldAction.none:
        break;
    }
  }

  /// Rechtsklick (Desktop) auf ein Gerät.
  void _secondaryNode(FloorNode n) {
    final layer = ref.read(mapLayerProvider);
    if (mapSecondaryAction(layer, _targetOf(n.id)) ==
        MapHoldAction.openDevice) {
      _openDevice(n.id);
    }
  }

  void _openLamp(String id) {
    unawaited(
      showLampSheet(
        context,
        LampTarget(title: _nameOf(id), subtitle: id, lampIds: [id]),
      ),
    );
  }

  /// Volles Gerät-Detail. Im Funknetz ist die Knoten-ID die IEEE-Adresse.
  void _openDevice(String id) {
    final network = ref.read(mapLayerProvider) == MapLayer.network;
    final devices = ref.read(zigbeeProvider).devices;
    final ieee = network ? id : zbDeviceForEntity(devices, id)?.ieee;
    final coordinator =
        ieee != null && devices.any((d) => d.ieee == ieee && d.isCoordinator);
    if (ieee == null || coordinator) {
      // Kein Zigbee-Gerät: Lampen haben wenigstens ihr Sheet.
      if (!network && _targetOf(id) == MapTarget.lamp) {
        Haptics.tick();
        return _openLamp(id);
      }
      return _say('${_nameOf(id)} hat keine Gerätedetails');
    }
    Haptics.tick();
    unawaited(context.push(zigbeeDevicePath(ieee)));
  }

  /// „Identifizieren“ im Funknetz: das Gerät meldet sich mit Licht oder Ton.
  Future<void> _identify(ZbDevice d) async {
    Haptics.tap();
    try {
      await ref.read(repositoryProvider).zigbeeIdentify(d.ieee);
      if (mounted) {
        _say('${d.friendlyName} meldet sich jetzt mit Licht oder Ton');
      }
    } catch (e) {
      if (mounted) _say('$e');
    }
  }

  void _tapRoom(FloorRoom r) {
    final layer = ref.read(mapLayerProvider);
    if (context.isDesktopLayout) {
      // Desktop: zwei Ebenen im Inspektor. Der Raum öffnet seine Details in der
      // aktuellen Kartenart, nochmal Klicken führt zurück zur Raumliste.
      if (layer == MapLayer.network && _meshSel != null) {
        setState(() => _meshSel = null);
      }
      Haptics.tick();
      setState(() {
        _inspect = _inspect == r.id && _panel == null ? null : r.id;
        _panel = null;
      });
      return;
    }
    if (_use3d) {
      // 3D: Klima, Bewegung, Batterie öffnen ihr Panel über dem Raum, sonst
      // fährt die Kamera hin und die Karte unten zeigt den Raum.
      final spec = _roomPanel(layer, r);
      if (spec != null) return _openPanel(spec, roomId: r.id);
      Haptics.tick();
      if (_focusRoom == r.id) return _unfocus3d();
      setState(() => _focusRoom = r.id);
      return _focus3d(r.id);
    }
    final sr = snapshotRoomFor(ref.read(snapshotProvider), r);
    switch (mapTapAction(layer, MapTarget.room)) {
      case MapTapAction.openRoomSheet:
        if (sr != null && sr.lightIds.isNotEmpty) {
          Haptics.tick();
          context.push(Routes.room(sr.id));
        } else {
          _say('${r.name} hat noch keine Lichter');
        }
      case MapTapAction.openRoomClimate ||
          MapTapAction.openRoomMotion ||
          MapTapAction.openRoomBatteries:
        final spec = _roomPanel(layer, r);
        if (spec != null) _openPanel(spec);
      default:
        // Funknetz: Auswahl aufheben.
        if (_meshSel != null) setState(() => _meshSel = null);
    }
  }

  /// Details eines Raums in der Kartenart [layer]. `null`: die Lichtansicht
  /// des Inspektors (Kombi, Licht, Funknetz).
  MapPanelSpec? _roomPanel(MapLayer layer, FloorRoom r) {
    final sr = snapshotRoomFor(ref.read(snapshotProvider), r);
    switch (mapTapAction(layer, MapTarget.room)) {
      case MapTapAction.openRoomClimate:
        final kind = layer == MapLayer.humidity
            ? HeatKind.humidity
            : HeatKind.temperature;
        return MapPanelSpec(
          key: 'room-climate-${kind.name}-${r.id}',
          builder: (_) =>
              RoomClimatePanel(plan: widget.plan, room: r, kind: kind),
        );
      case MapTapAction.openRoomMotion:
        return MapPanelSpec(
          key: 'room-motion-${r.id}',
          builder: (_) =>
              RoomMotionPanel(room: r, areaIds: [r.areaId, sr?.areaId, sr?.id]),
        );
      case MapTapAction.openRoomBatteries:
        return MapPanelSpec(
          key: 'room-battery-${r.id}',
          builder: (_) => RoomBatteriesPanel(plan: widget.plan, room: r),
        );
      default:
        return null;
    }
  }

  /// Rechtsklick auf die Karte (Desktop).
  void _secondaryRoom(FloorRoom? r, Offset at) {
    final items = <HavenMenuItem>[];
    if (r != null) {
      final sr = snapshotRoomFor(ref.read(snapshotProvider), r);
      final view = sr == null ? null : ref.read(roomViewProvider(sr.id));
      setState(() {
        _inspect = r.id;
        _panel = null;
      });
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
    if (_focusRoom != null || _raised != null) _unfocus3d();
    ref.read(mapLayerProvider.notifier).set(l);
    setState(() {
      _meshSel = null;
      _panel = null;
    });
  }

  // ---- Aufbau ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final plan = widget.plan;
    final layer = ref.watch(mapLayerProvider);
    ref.listen(zigbeeMeshProvider.select((d) => d.noticeId), (_, _) {
      // Das Vollbild meldet selbst, solange es oben liegt.
      final n = ref.read(zigbeeMeshProvider).notice;
      if (n != null &&
          mounted &&
          layer == MapLayer.network &&
          (ModalRoute.of(context)?.isCurrent ?? true)) {
        _say(n);
      }
    });
    final readings = ref.watch(mapReadingsProvider(plan));
    _ensureClock(layer == MapLayer.presence);
    final supported = watchMap3d(ref);
    // Fokus, Raumkarte und Panels über der Karte gibt es nicht im Funknetz.
    final use3d = supported == true && layer != MapLayer.network;
    // Die Prüfung auf 3D läuft noch: Ladeanimation.
    final probing = supported == null;

    final _LayerView v = switch (layer) {
      MapLayer.combo => _lightView(plan),
      MapLayer.light => _lampsView(plan),
      MapLayer.temperature => _heatView(plan, readings, HeatKind.temperature),
      MapLayer.humidity => _heatView(plan, readings, HeatKind.humidity),
      MapLayer.presence => _presenceView(plan, readings),
      MapLayer.network => _networkView(plan),
      MapLayer.battery => _batteryView(plan, readings),
    };

    if (context.isDesktopLayout) {
      return _desktop(
        context,
        plan,
        layer,
        v,
        use3d: use3d,
        probing: probing,
        supported: supported,
      );
    }

    final focus = use3d && _focusRoom != null ? plan.room(_focusRoom!) : null;
    return PopScope(
      // Zurück hebt erst den Fokus auf einen Raum auf.
      canPop: focus == null,
      onPopInvokedWithResult: (did, _) {
        if (!did) _unfocus3d();
      },
      child: LayoutBuilder(
        builder: (context, box) {
          final h = box.maxHeight;
          // Oben blendet die Karte hinter dem Kopf aus, unten am Rand.
          final fadeTop = (_topH / h).clamp(0.0, 0.5);
          final fadeBottom = (24 / h).clamp(0.0, 0.2);
          return Stack(
            children: [
              Positioned.fill(
                child: EntryAnimation(
                  index: 1,
                  child: ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (rect) => LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: const [
                        Color(0x00000000),
                        Color(0xFF000000),
                        Color(0xFF000000),
                        Color(0x00000000),
                      ],
                      stops: [fadeTop * 0.55, fadeTop, 1 - fadeBottom, 1],
                    ).createShader(rect),
                    child: supported == false
                        ? const Map3DUnsupported()
                        : probing
                        ? Map3DLoader(plan: v.plan, insets: _mapInsets())
                        : Map3DView(
                            key: const ValueKey('map3d'),
                            plan: v.plan,
                            nodes: v.nodes,
                            nodeBuilder: v.nodeBuilder,
                            subtitle: v.subtitle,
                            heatmap: v.heatmap3d,
                            controller: v.controller,
                            overlayBuilder: v.overlay3d,
                            quality: v.quality,
                            onNodeTap: v.onNodeTap,
                            onNodeLongPress: _holdNode,
                            onNodeSecondaryTap: _secondaryNode,
                            onRoomTap: v.onRoomTap,
                            onOutsideTap: () {
                              if (_focusRoom != null) _unfocus3d();
                              v.onOutsideTap?.call();
                            },
                            selectedRoomId: _focusRoom ?? _raised,
                            raisedRoomId: _raised,
                            insets: _mapInsets(),
                          ),
                  ),
                ),
              ),
              // Kopf und Legende liegen über der Karte. Der leere Raum dazwischen
              // lässt Gesten zur Karte durch.
              Column(
                children: [
                  if (widget.header != null)
                    _SizeReport(
                      onSize: (s) => _setInsets(top: s.height),
                      child: widget.header!,
                    ),
                  const Spacer(),
                  _SizeReport(
                    onSize: (s) => _setInsets(bottom: s.height),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        HavenSpace.page,
                        8,
                        HavenSpace.page,
                        HavenSpace.navClearance,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          MapLayerTabs(
                            layer: layer,
                            compact: true,
                            onChanged: _setLayer,
                          ),
                          const SizedBox(height: 10),
                          HavenCard(
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
                                            style: HavenText.body.copyWith(
                                              color: hv.tx,
                                            ),
                                          ),
                                        ),
                                      )
                                    : focus != null
                                    ? KeyedSubtree(
                                        key: ValueKey('focus-${focus.id}'),
                                        child: _RoomFocusCard(
                                          room: focus,
                                          subtitle: v.subtitle?.call(focus),
                                          onClose: _unfocus3d,
                                        ),
                                      )
                                    : KeyedSubtree(
                                        key: ValueKey('card-${layer.name}'),
                                        child: v.card,
                                      ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              if (supported == true)
                Positioned(
                  right: 12,
                  bottom: _bottomH + 10,
                  child: Map3DControls(
                    insets: _mapInsets(),
                    onRecenter: _clearFocus,
                    controller: v.controller,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  void _setInsets({double? top, double? bottom}) {
    if ((top == null || top == _topH) &&
        (bottom == null || bottom == _bottomH)) {
      return;
    }
    setState(() {
      _topH = top ?? _topH;
      _bottomH = bottom ?? _bottomH;
    });
  }

  /// Desktop: Karte mit viel Fläche (Mausrad zoomt), rechts der Inspektor.
  Widget _desktop(
    BuildContext context,
    HavenFloorPlan plan,
    MapLayer layer,
    _LayerView v, {
    required bool use3d,
    required bool probing,
    required bool? supported,
  }) {
    final inspect = _inspect != null && plan.room(_inspect!) != null
        ? _inspect
        : null;
    // 3D: Kamera zum Raum im Inspektor oder zum Raum des Geräte-Panels.
    final want = _panel != null ? _panelRoom : inspect;
    if (!use3d) {
      _deskFocus = null;
    } else if (want != _deskFocus) {
      _deskFocus = want;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final c = ref.read(map3dControllerProvider);
        final s = ref.read(map3dSettingsProvider);
        if (want == null) {
          unawaited(c.back());
        } else {
          unawaited(
            c.focus(
              roomId: want,
              yaw: s.tilt ? null : kMapFocusYaw,
              pitch: s.tilt ? null : kMapFocusPitch,
              insets: _deskInsets,
            ),
          );
        }
      });
    }
    void outside() {
      if (_inspect != null || _panel != null) {
        setState(() {
          _inspect = null;
          _panel = null;
        });
      }
      v.onOutsideTap?.call();
    }

    const side = DesktopMetrics.sideColumn;
    return LayoutBuilder(
      builder: (context, box) {
        final h = box.maxHeight;
        // Wie am Handy: oben blendet die Karte hinter dem Kopf aus.
        final fadeTop = (_topH / h).clamp(0.0, 0.5);
        final fadeBottom = (24 / h).clamp(0.0, 0.2);
        return Stack(
          children: [
            Positioned.fill(
              child: EntryAnimation(
                index: 1,
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (rect) => LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: const [
                      Color(0x00000000),
                      Color(0xFF000000),
                      Color(0xFF000000),
                      Color(0x00000000),
                    ],
                    stops: [fadeTop * 0.55, fadeTop, 1 - fadeBottom, 1],
                  ).createShader(rect),
                  child: supported == false
                      ? const Map3DUnsupported()
                      : probing
                      ? Map3DLoader(plan: v.plan, insets: _deskInsets)
                      : Map3DView(
                          key: const ValueKey('map3d'),
                          plan: v.plan,
                          nodes: v.nodes,
                          nodeBuilder: v.nodeBuilder,
                          subtitle: v.subtitle,
                          heatmap: v.heatmap3d,
                          controller: v.controller,
                          overlayBuilder: v.overlay3d,
                          quality: v.quality,
                          onNodeTap: v.onNodeTap,
                          onNodeLongPress: _holdNode,
                          onNodeSecondaryTap: _secondaryNode,
                          onRoomTap: v.onRoomTap,
                          onOutsideTap: outside,
                          onRoomSecondaryTap: _secondaryRoom,
                          selectedRoomId: want,
                          raisedRoomId: want,
                          insets: _deskInsets,
                        ),
                ),
              ),
            ),
            if (widget.header != null)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _SizeReport(
                  onSize: (s) => _setInsets(top: s.height),
                  child: widget.header!,
                ),
              ),
            Positioned(
              bottom: 20,
              left: 16,
              right: side + 36,
              child: MapLayerTabs(layer: layer, onChanged: _setLayer),
            ),
            if (supported == true)
              Positioned(
                top: _topH + 4,
                right: side + 40,
                child: Map3DControls(
                  axis: Axis.horizontal,
                  controller: v.controller,
                  insets: _deskInsets,
                  onRecenter: () {
                    _deskFocus = null;
                    if (_inspect != null || _panel != null) {
                      setState(() {
                        _inspect = null;
                        _panel = null;
                      });
                    }
                  },
                ),
              ),
            Positioned(
              top: _topH,
              right: 20,
              bottom: 20,
              width: side,
              child: MapInspector(
                plan: plan,
                layer: layer,
                selected: inspect,
                onSelect: (id) => setState(() {
                  _inspect = id;
                  _panel = null;
                }),
                roomPanel: inspect == null
                    ? null
                    : _roomPanel(layer, plan.room(inspect)!),
                panel: _panel,
                onClosePanel: _closePanel,
                layerCard: KeyedSubtree(
                  key: ValueKey('card-${layer.name}'),
                  child: v.card,
                ),
                info: _info,
              ),
            ),
          ],
        );
      },
    );
  }

  /// Desktop: freie Fläche der Karte zwischen Kopf, Inspektor und Leiste.
  EdgeInsets get _deskInsets =>
      EdgeInsets.fromLTRB(16, _topH + 8, DesktopMetrics.sideColumn + 36, 76);

  // ---- Licht ----------------------------------------------------------------

  _LayerView _lightView(HavenFloorPlan plan) {
    final lights = ref.watch(mapLightsProvider(plan));
    return _LayerView(
      plan: plan,
      nodes: [
        for (final p in plan.placements)
          FloorNode(id: p.entityId, point: plan.pointOfCell(p.cell)),
      ],
      nodeBuilder: (context, n) =>
          MapMarker(entityId: n.id, kind: plan.placementOf(n.id)!.resolvedKind),
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

  // ---- Nur Licht ------------------------------------------------------------

  /// Lampen mit Lichtkegel in ihrer Farbe plus die Schalter, die Licht
  /// steuern. Ausgenommene Lichter bleiben gedimmt sichtbar: Sie leuchten
  /// trotzdem und gehören auf den Grundriss, nur Haven-Abläufe lassen sie aus.
  _LayerView _lampsView(HavenFloorPlan plan) {
    final lights = ref.watch(mapLightsProvider(plan));
    final controls = ref.watch(mapLightControlsProvider(plan)).rooms;
    final excluded = ref.watch(
      snapshotProvider.select((s) => s.excludedLights),
    );
    final ids = [
      for (final p in plan.placements)
        if (lights.lamps.containsKey(p.entityId) ||
            controls.containsKey(p.entityId))
          p,
    ];
    return _LayerView(
      plan: plan,
      nodes: [
        for (final p in ids)
          FloorNode(id: p.entityId, point: plan.pointOfCell(p.cell)),
      ],
      nodeBuilder: (context, n) {
        final isControl = controls.containsKey(n.id);
        final marker = MapMarker(
          entityId: n.id,
          kind: isControl
              ? FloorKind.remote
              : plan.placementOf(n.id)!.resolvedKind,
        );
        return excluded.contains(n.id)
            ? Opacity(opacity: 0.45, child: marker)
            : marker;
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
        if (r.thermostat && kind == HeatKind.temperature) {
          return ThermostatMarker(
            entityId: n.id,
            fill: scale == null ? null : kind.ramp.at(scale.t(v)),
          );
        }
        return HeatValueMarker(
          label: ref.read(entityProvider(n.id))?.name ?? n.id,
          text: text(v),
          outside: r.location == kOutsideId,
          color: scale == null ? hv.s2 : kind.ramp.at(scale.t(v)),
        );
      },
      heatmap3d: heatmapOf(data, plan.grid.cellMeters),
      subtitle: (r) {
        final range = data.roomRange(r.id);
        if (range == null) return null;
        final (a, b) = range;
        if ((a - b).abs() < 0.05) return text(a);
        return '${heatValue(a, kind)} bis ${text(b)}';
      },
      onNodeTap: _tapNode,
      onRoomTap: _tapRoom,
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
      heatmap3d: presenceHeatmapOf(plan, levels, presenceColor(hv)),
      subtitle: (r) {
        final l = levels[r.id];
        if (l == null) return null;
        if (l.active) return past ? 'Bewegung' : 'Bewegung jetzt';
        if (l.since == null) return 'ruhig';
        return agoText(l.since!, at);
      },
      onNodeTap: _tapNode,
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

  /// Lässt die Uhr der Messung in der Karte weiterlaufen.
  void _tickMeasure() {
    if (_measureClock != null) return;
    _measureClock = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || !ref.read(zigbeeMeshProvider).refreshing) {
        t.cancel();
        _measureClock = null;
        return;
      }
      if (ref.read(mapLayerProvider) == MapLayer.network) setState(() {});
    });
  }

  String _measureText(MeshData data) {
    _tickMeasure();
    final s = data.refreshStarted;
    final since = s == null
        ? ''
        : ' seit ${meshElapsedLabel(DateTime.now().difference(s))}';
    return 'Messung läuft$since … das kann mehrere Minuten dauern. '
        'Du kannst weiter zwischen den Ebenen wechseln.';
  }

  _LayerView _networkView(HavenFloorPlan plan) {
    final hv = context.hv;
    final data = ref.watch(zigbeeMeshProvider);
    final scene = ref.watch(meshSceneProvider);
    final map = data.map;
    if (scene == null || map == null) {
      return _LayerView(
        plan: plan,
        card: _NetworkCard(
          text: data.refreshing
              ? _measureText(data)
              : data.loaded
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
    final selDev = _meshSel == null
        ? null
        : ref
              .watch(zigbeeProvider.select((z) => z.devices))
              .where((d) => d.ieee == _meshSel)
              .firstOrNull;
    final lqi = _meshSel == null ? null : map.lqiToParent(_meshSel!);
    return _LayerView(
      plan: scene.plan,
      controller: ref.watch(meshControllerProvider),
      quality: h3.SceneQuality.draft,
      nodes: MeshGraph.floorNodes(scene, map),
      overlay3d: (context, p) => RepaintBoundary(
        child: CustomPaint(
          painter: MeshEdgePainter(
            edges: map.edges,
            scene: scene,
            state: _mesh,
            hv: hv,
            nodes: p.markers,
          ),
        ),
      ),
      nodeBuilder: (context, node) =>
          MeshNodeDot(info: scene.infos[node.id]!, map: map, state: _mesh),
      onNodeTap: _tapNode,
      onRoomTap: _tapRoom,
      onOutsideTap: () {
        if (_meshSel != null) setState(() => _meshSel = null);
      },
      card: _NetworkCard(
        text: data.refreshing
            ? _measureText(data)
            : data.error != null && sel == null
            ? '${data.error!}${map.measuredAt == null ? '' : ' ${meshStandLabel(map.measuredAt!)}.'}'
            : sel == null
            ? '${map.nodes.length - 1} Geräte'
                  '${map.failedCount == 0 ? '' : ', ${map.failedCount} nicht erreichbar'}. '
                  'Tippe ein Gerät für seinen Weg zum Koordinator.'
            : '${sel.name}${sel.roomName == null ? '' : ' · ${sel.roomName}'}'
                  '${lqi == null ? '' : ' · LQI $lqi'}',
        legend: true,
        actions: [
          if (selDev != null && !selDev.isCoordinator) ...[
            _CardAction(
              label: 'Gerät öffnen',
              icon: Icons.open_in_new_rounded,
              onTap: () => _openDevice(selDev.ieee),
            ),
            if ((selDev.isRouter || selDev.deviceType == ZbType.light) &&
                selDev.classified.canIdentify)
              _CardAction(
                label: 'Identifizieren',
                icon: Icons.lightbulb_outline_rounded,
                onTap: () => _identify(selDev),
              ),
          ],
        ],
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
      onNodeTap: _tapNode,
      onRoomTap: _tapRoom,
      card: _BatteryCard(
        total: bats.length,
        weak: [
          for (final w in weak) (shortDeviceName(name(w.entityId)), w.battery!),
        ],
      ),
    );
  }
}

/// Alles, was eine Kartenart der 3D-Karte übergibt.
class _LayerView {
  const _LayerView({
    required this.plan,
    required this.card,
    this.nodes = const [],
    this.nodeBuilder,
    this.subtitle,
    this.onNodeTap,
    this.onRoomTap,
    this.onOutsideTap,
    this.heatmap3d,
    this.controller,
    this.overlay3d,
    this.quality,
  });
  final HavenFloorPlan plan;
  final Widget card;
  final List<FloorNode> nodes;
  final FloorNodeBuilder? nodeBuilder;
  final String? Function(FloorRoom)? subtitle;
  final ValueChanged<FloorNode>? onNodeTap;
  final ValueChanged<FloorRoom>? onRoomTap;
  final VoidCallback? onOutsideTap;

  /// Färbung der Böden (Temperatur, Feuchte, Bewegung).
  final h3.SceneHeatmap? heatmap3d;

  /// Eigene Szene und Kamera (Funknetz), sonst die Karte der App.
  final h3.SceneController? controller;

  /// Qualität (Funknetz: Entwurf ohne Baking), sonst die Einstellung.
  final h3.SceneQuality? quality;

  /// Zeichenebene über der Szene (Funkverbindungen).
  final Widget Function(BuildContext context, h3.SceneProjection p)? overlay3d;
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
    this.actions = const [],
  });
  final String text;
  final VoidCallback onOpen;
  final bool legend;

  /// Aktionen zum gewählten Knoten („Gerät öffnen“, „Identifizieren“).
  final List<_CardAction> actions;

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
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: actions),
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

/// 3D, Handy: Karte unten für den Raum im Fokus mit den wichtigsten
/// Aktionen. Die Kamera steht dabei über dem aufgerichteten Raum.
class _RoomFocusCard extends ConsumerWidget {
  const _RoomFocusCard({
    required this.room,
    required this.subtitle,
    required this.onClose,
  });
  final FloorRoom room;
  final String? subtitle;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final sr = snapshotRoomFor(ref.watch(snapshotProvider), room);
    final view = sr == null ? null : ref.watch(roomViewProvider(sr.id));
    final lit = view?.lamps.where((l) => l.on).length ?? 0;
    final info = [
      if (view != null && view.lamps.isNotEmpty)
        lit == 0
            ? 'Licht aus'
            : lit == 1
            ? 'Ein Licht an'
            : '$lit Lichter an',
      if (subtitle != null && subtitle!.isNotEmpty) subtitle!,
    ].join(' · ');
    return SizedBox(
      width: double.infinity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      room.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HavenText.title.copyWith(
                        color: hv.tx,
                        fontSize: 17,
                      ),
                    ),
                    if (info.isNotEmpty)
                      Text(
                        info,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HavenText.caption.copyWith(color: hv.tx2),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              RoundIconButton(
                icon: Icons.close_rounded,
                label: 'Zurück zur Übersicht',
                onTap: onClose,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (view != null && view.lamps.isNotEmpty)
                _CardAction(
                  label: view.anyOn ? 'Licht aus' : 'Licht an',
                  icon: view.anyOn
                      ? Icons.lightbulb_outline_rounded
                      : Icons.lightbulb_rounded,
                  onTap: () {
                    Haptics.tap();
                    unawaited(ref.read(repositoryProvider).toggleRoom(view.id));
                  },
                ),
              if (sr != null && sr.lightIds.isNotEmpty)
                _CardAction(
                  label: 'Raum öffnen',
                  icon: Icons.open_in_new_rounded,
                  onTap: () => context.push(Routes.room(sr.id)),
                ),
              _CardAction(
                label: 'Einrichten',
                icon: Icons.chair_outlined,
                onTap: () => context.push(
                  '$mapEditorPath?mode=furniture&sel=${room.id}',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Kleine Aktion unter dem Text einer Karte (Pille mit Symbol).
class _CardAction extends StatelessWidget {
  const _CardAction({
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
      label: label,
      child: PressScale(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: hv.s2,
            borderRadius: BorderRadius.circular(HavenRadii.pill),
            border: Border.all(color: hv.ln2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: hv.tx),
              const SizedBox(width: 8),
              Text(
                label,
                style: HavenText.label.copyWith(color: hv.tx, fontSize: 13.5),
              ),
            ],
          ),
        ),
      ),
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
              [
                for (final (n, v) in weak.take(3)) '$n ${v.round()} %',
              ].join(' · '),
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
                  child: CustomPaint(
                    painter: _SamplePlanPainter(_sample, hv.acc),
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

/// Skizze eines Grundrisses für den Leerzustand: Räume mit Abstand,
/// einer davon betont.
class _SamplePlanPainter extends CustomPainter {
  const _SamplePlanPainter(this.plan, this.accent);
  final HavenFloorPlan plan;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    var b = Rect.zero;
    for (final r in plan.rooms) {
      b = b.isEmpty ? r.bounds : b.expandToInclude(r.bounds);
    }
    if (b.isEmpty) return;
    final k = math.min(size.width / b.width, size.height / b.height) * 0.92;
    final o = size.center(Offset.zero) - b.center * k;
    for (final r in plan.rooms) {
      final c = r.bounds.center;
      // Jeder Raum rückt etwas zu seiner Mitte: Spalt wie auf der Karte.
      final pts = [for (final p in r.offsets) o + (c + (p - c) * 0.92) * k];
      final path = Path()..addPolygon(pts, true);
      canvas.drawPath(
        path,
        Paint()..color = accent.withValues(alpha: r.id == 'a' ? 0.28 : 0.12),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..strokeJoin = StrokeJoin.round
          ..color = accent.withValues(alpha: 0.5),
      );
    }
  }

  @override
  bool shouldRepaint(_SamplePlanPainter old) =>
      old.plan != plan || old.accent != accent;
}

/// Meldet die Größe des Kinds nach dem Layout (nur bei Änderung).
class _SizeReport extends SingleChildRenderObjectWidget {
  const _SizeReport({required this.onSize, required super.child});
  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSizeReport(onSize);

  @override
  void updateRenderObject(BuildContext context, _RenderSizeReport r) =>
      r.onSize = onSize;
}

class _RenderSizeReport extends RenderProxyBox {
  _RenderSizeReport(this.onSize);
  ValueChanged<Size> onSize;
  Size? _last;

  @override
  void performLayout() {
    super.performLayout();
    if (size == _last) return;
    _last = size;
    final s = size;
    WidgetsBinding.instance.addPostFrameCallback((_) => onSize(s));
  }
}
