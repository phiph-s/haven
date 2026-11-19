import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven_3d/haven_3d.dart' as h3;
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../data/models/lamp.dart';
import '../../data/models/room_heating.dart';
import '../../data/render_api.dart';
import '../climate/heating_providers.dart';
import '../climate/thermostat_providers.dart';
import '../map/floor_plan_store.dart';
import '../map/map_3d.dart' show lampStateOf;
import '../map/map_data.dart' show snapshotRoomFor;

// Raumkacheln der Startseite mit dem Render ihres Raums (Lichtebenen aus
// Home Assistant, live auf der GPU zusammengesetzt) und dem Thermometer am
// Rand für Räume mit Heizungsregelung oder genau einem Thermostat.

/// Stand der Bilder in Home Assistant, neu nach jedem Upload (auch von
/// anderen Geräten). `null`: keine Bilder möglich.
final renderStatusProvider = StreamProvider<RenderStatus?>((ref) async* {
  final repo = ref.watch(sessionProvider.select((s) => s.repo));
  if (repo == null) {
    yield null;
    return;
  }
  Future<RenderStatus?> load() async {
    try {
      return await repo.renderStatus();
    } catch (_) {
      return null;
    }
  }

  yield await load();
  await for (final _ in repo.renderChanges) {
    yield await load();
  }
});

/// Gibt es Bilder für Raumkacheln? Dann sind alle Kacheln etwas höher.
final roomRendersAvailableProvider = Provider<bool>((ref) {
  final s = ref.watch(renderStatusProvider).value;
  return s != null && s.files && s.info.values.any((i) => i.room != null);
});

typedef RoomRenderKey = ({String roomId, bool dark});

/// Woher die Ebenen eines Raums kommen: Plan-Raum, Satz und Stand der
/// Bilder in HA. Ändert sich nur mit neuen Bildern (Vergleich nach Wert),
/// nicht mit jedem Zustand aus HA.
typedef _LayerSource = ({String planRoom, String set, String? key});

final _layerSourceProvider = Provider.family<_LayerSource?, RoomRenderKey>((
  ref,
  k,
) {
  final status = ref.watch(renderStatusProvider).value;
  if (status == null || !status.files) return null;
  final plan = ref.watch(floorPlanProvider).value;
  if (plan == null) return null;
  final snap = ref.watch(snapshotProvider);
  final room = plan.rooms
      .where((r) => snapshotRoomFor(snap, r)?.id == k.roomId)
      .firstOrNull;
  if (room == null) return null;
  final set = status.setFor(room.id, k.dark ? 'dark' : 'light');
  if (set == null) return null;
  return (planRoom: room.id, set: set, key: status.key);
});

/// Ersetzte Ebenen je Raum: erst freigeben, wenn die neuen da sind (bis
/// dahin zeigt die Kachel die alten weiter) und sicher gezeichnet wurden.
final Map<RoomRenderKey, h3.LayerImages> _retired = {};

void _retire(RoomRenderKey k) {
  final old = _retired.remove(k);
  if (old != null) Timer(const Duration(seconds: 2), old.dispose);
}

/// Ebenen des Raums [RoomRenderKey.roomId] im Design, `null`: keine.
final roomLayersProvider =
    FutureProvider.family<h3.LayerImages?, RoomRenderKey>((ref, k) async {
      final src = ref.watch(_layerSourceProvider(k));
      if (src == null) {
        _retire(k);
        return null;
      }
      final planRoom = src.planRoom;
      final set = src.set;
      final repo = ref.read(repositoryProvider);
      final meta =
          jsonDecode(utf8.decode(await repo.renderFile(set, 'meta.json')))
              as Map<String, dynamic>;
      final rooms = (meta['rooms'] as Map?) ?? const {};
      final lamps = (meta['lamps'] as Map?) ?? const {};
      final images = await h3.LayerImages.decode(
        meta: meta,
        base: await repo.renderFile(set, 'base.png'),
        rooms: {
          if (rooms.containsKey(planRoom))
            planRoom: await repo.renderFile(set, 'room_$planRoom.png'),
        },
        lamps: {
          for (final e in lamps.entries)
            if ((e.value as Map)['x'] != null)
              '${e.key}': await repo.renderFile(set, 'lamp_${e.key}.png'),
        },
      );
      if (!ref.mounted) {
        // Inzwischen neu geladen: diese Bilder hat nie jemand gesehen.
        images.dispose();
        return null;
      }
      _retire(k);
      ref.onDispose(() {
        _retired.remove(k)?.dispose();
        _retired[k] = images;
      });
      return images;
    });

/// Der Shader (einmal geladen), `null` wenn er fehlt.
final layerShaderProvider = FutureProvider<ui.FragmentProgram?>((ref) async {
  try {
    return await h3.LayerShader.program();
  } catch (_) {
    return null;
  }
});

// ---- Raumbild -------------------------------------------------------------

/// Der Render eines Raums mit dem aktuellen Licht. Wechsel blenden weich
/// über; [dimPercent] setzt beim Ziehen die Helligkeit der Lampen des Raums
/// sofort (ohne Überblendung). [preview] zeigt andere Lampenzustände (etwa
/// eine Szene, solange man sie hält), [glow] den Lichtschein der Lampen
/// hinter dem Bild (0 … 1).
class RoomRenderView extends ConsumerStatefulWidget {
  const RoomRenderView({
    super.key,
    required this.images,
    this.dimPercent,
    this.preview,
    this.alignY = -0.6,
    this.glow = 0,
  });

  final h3.LayerImages images;
  final int? dimPercent;
  final Map<String, h3.LampState>? preview;
  final double alignY;
  final double glow;

  @override
  ConsumerState<RoomRenderView> createState() => _RoomRenderViewState();
}

class _RoomRenderViewState extends ConsumerState<RoomRenderView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  )..addListener(() => setState(() {}));
  Map<String, h3.LayerFactor> _from = const {};
  Map<String, h3.LayerFactor> _to = const {};
  bool _first = true;

  /// Ein Shader je Ansicht: Werte gelten je Zeichnung, alte Bilder behalten
  /// ihre.
  ui.FragmentProgram? _program;
  ui.FragmentShader? _shader;

  @override
  void dispose() {
    _t.dispose();
    _shader?.dispose();
    super.dispose();
  }

  ui.FragmentShader _shaderOf(ui.FragmentProgram p) {
    if (!identical(p, _program) || _shader == null) {
      _shader?.dispose();
      _program = p;
      _shader = p.fragmentShader();
    }
    return _shader!;
  }

  Map<String, h3.LayerFactor> _targets() {
    final img = widget.images;
    final snap = ref.watch(snapshotProvider);
    final out = <String, h3.LayerFactor>{};
    for (final id in img.lampRooms.keys) {
      final e = snap.entity(id);
      final shown = widget.preview?[id];
      if (e == null && shown == null) continue;
      var s = shown ?? lampStateOf(Lamp.fromEntity(e!));
      final dim = widget.dimPercent;
      if (dim != null && img.lampRooms[id] == img.viewRoom) {
        s = h3.LampState(
          brightness: (dim / 100).clamp(0.05, 1.0),
          color: s.on ? s.color : const Color(0xFFFFC98A),
        );
      }
      out[id] = h3.layerFactor(s, img.gain);
    }
    return out;
  }

  Map<String, h3.LayerFactor> get _now {
    final k = Curves.easeOutCubic.transform(_t.value);
    return {
      for (final id in {..._from.keys, ..._to.keys})
        id: () {
          const zero = (r: 0.0, g: 0.0, b: 0.0);
          final a = _from[id] ?? zero, b = _to[id] ?? zero;
          return (
            r: a.r + (b.r - a.r) * k,
            g: a.g + (b.g - a.g) * k,
            b: a.b + (b.b - a.b) * k,
          );
        }(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final target = _targets();
    if (!_sameFactors(target, _to)) {
      if (_first ||
          widget.dimPercent != null ||
          MediaQuery.disableAnimationsOf(context)) {
        _from = target;
        _to = target;
        _t.value = 1;
      } else {
        _from = _now;
        _to = target;
        _t.forward(from: 0);
      }
    }
    _first = false;
    final program = ref.watch(layerShaderProvider).value;
    if (program == null) return const SizedBox.expand();
    return CustomPaint(
      size: Size.infinite,
      painter: _LayerPainter(
        widget.images,
        _shaderOf(program),
        _now,
        widget.alignY,
        widget.glow,
      ),
    );
  }

  static bool _sameFactors(
    Map<String, h3.LayerFactor> a,
    Map<String, h3.LayerFactor> b,
  ) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      final o = b[e.key];
      if (o == null || o != e.value) return false;
    }
    return true;
  }
}

class _LayerPainter extends CustomPainter {
  _LayerPainter(this.images, this.shader, this.factors, this.alignY, this.glow);
  final h3.LayerImages images;
  final ui.FragmentShader shader;
  final Map<String, h3.LayerFactor> factors;
  final double alignY;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    final dst = h3.containRect(
      Offset.zero & size,
      images.aspect,
      alignY: alignY,
    );
    h3.paintLampGlows(canvas, dst, images, factors, strength: glow);
    h3.paintLayers(canvas, dst, images, shader, factors);
  }

  @override
  bool shouldRepaint(_LayerPainter old) =>
      old.images != images ||
      old.shader != shader ||
      old.alignY != alignY ||
      old.glow != glow ||
      !_RoomRenderViewState._sameFactors(old.factors, factors);
}

// ---- Temperatur der Kachel ------------------------------------------------

/// Was das Thermometer einer Kachel zeigt und wohin es schreibt.
class TileClimate {
  const TileClimate({
    required this.current,
    required this.target,
    required this.heating,
    required this.off,
    required this.min,
    required this.max,
    required this.label,
    required this.set,
  });

  /// Raumtemperatur, `null`: unbekannt.
  final double? current;
  final double target;
  final bool heating;
  final bool off;
  final double min;
  final double max;

  /// „Raumregelung · Komfort“ oder „Thermostat“.
  final String label;

  /// Ziel setzen; gibt eine Fehlermeldung zurück oder `null`.
  final Future<String?> Function(double v) set;
}

/// Klima der Kachel: Haven-Raumregelung oder genau ein Thermostat, sonst
/// `null` (kein Regler, nur der Wert oben).
TileClimate? tileClimateOf(WidgetRef ref, String roomId, double? roomTemp) {
  final rh = ref.watch(roomHeatingProvider(roomId));
  if (rh != null) {
    final s = rh.status;
    return TileClimate(
      current: s.roomTemperature ?? roomTemp,
      target: s.effectiveTarget ?? s.target,
      heating: s.heating ?? false,
      off: s.mode == HeatingMode.off,
      min: 5,
      max: 30,
      label: 'Raumregelung · ${s.mode.label}',
      set: (v) => ref
          .read(heatingProvider.notifier)
          .control(ref.read(roomAreaProvider(roomId)), target: v),
    );
  }
  final refs = ref.watch(roomThermostatsProvider(roomId));
  if (refs.length != 1) return null;
  final t = ref.watch(thermostatProvider(refs.single));
  final target = t?.shownTarget ?? t?.target;
  if (t == null || target == null) return null;
  return TileClimate(
    current: roomTemp ?? t.current,
    target: target,
    heating: t.heating ?? false,
    off: t.isOff,
    min: t.minTarget,
    max: t.maxTarget,
    label: 'Thermostat',
    set: (v) => ThermostatWriter(ref).setTarget(t, v),
  );
}

/// Thermometer am rechten Rand der Kachel über die volle Höhe: Füllung =
/// Raumtemperatur (Zahl an der Füllkante), Pfeil mit Wert = Ziel.
/// Senkrecht ziehen oder am PC scrollen ändert das Ziel in halben Grad.
class ThermoEdge extends StatefulWidget {
  const ThermoEdge({super.key, required this.climate, required this.name});

  final TileClimate climate;
  final String name;

  /// Breite der Fläche am Rand (Regler plus Rand).
  static const double width = 36;

  /// Skala des Thermometers.
  static const double lo = 15, hi = 26;

  @override
  State<ThermoEdge> createState() => _ThermoEdgeState();
}

class _ThermoEdgeState extends State<ThermoEdge> {
  /// Ziel während und kurz nach der Bedienung (bis HA es bestätigt).
  double? _pending;
  double? _dragStart;
  double _dragDy = 0;
  bool _active = false;
  Timer? _commit;
  Timer? _forget;
  double _wheel = 0;

  TileClimate get c => widget.climate;
  double get _target => _pending ?? c.target;

  @override
  void didUpdateWidget(ThermoEdge old) {
    super.didUpdateWidget(old);
    // HA hat das Ziel übernommen: wieder den echten Wert zeigen.
    if (_pending != null && (c.target - _pending!).abs() < 0.05) {
      _pending = null;
    }
  }

  @override
  void dispose() {
    _commit?.cancel();
    _forget?.cancel();
    super.dispose();
  }

  double _clamp(double v) {
    final lo = c.min > ThermoEdge.lo ? c.min : ThermoEdge.lo;
    final hi = c.max < ThermoEdge.hi ? c.max : ThermoEdge.hi;
    return ((v * 2).round() / 2).clamp(lo, hi);
  }

  void _set(double v, {Duration delay = Duration.zero}) {
    final n = _clamp(v);
    setState(() => _pending = n);
    _commit?.cancel();
    _commit = Timer(delay, () => _send(n));
  }

  Future<void> _send(double v) async {
    final err = await c.set(v);
    if (!mounted) return;
    if (err != null) {
      setState(() => _pending = null);
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    // Spätestens dann wieder den Wert aus HA zeigen.
    _forget?.cancel();
    _forget = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _pending = null);
    });
  }

  double _perHalf(double h) => (h - 18) / ((ThermoEdge.hi - ThermoEdge.lo) * 2);

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final heating =
        c.heating || (_pending != null && _target > (c.current ?? 99));
    final fill = heating ? const Color(0xFFFF8A3D) : const Color(0xFF5AB0FF);
    double frac(double v) =>
        ((v - ThermoEdge.lo) / (ThermoEdge.hi - ThermoEdge.lo)).clamp(0.0, 1.0);
    String fmt(double v) => v.toStringAsFixed(1).replaceAll('.', ',');
    final cur = c.current;
    return Semantics(
      slider: true,
      label: 'Zieltemperatur ${widget.name}',
      value: c.off ? 'aus' : '${fmt(_target)} Grad',
      increasedValue: '${fmt(_clamp(_target + 0.5))} Grad',
      decreasedValue: '${fmt(_clamp(_target - 0.5))} Grad',
      onIncrease: () => _set(_target + 0.5),
      onDecrease: () => _set(_target - 0.5),
      child: Listener(
        // Am PC: Mausrad, ein halbes Grad je Raststufe (Touchpads in
        // kleinen Schritten gesammelt); die Seite scrollt dabei nicht.
        onPointerSignal: (e) {
          if (e is! PointerScrollEvent) return;
          GestureBinding.instance.pointerSignalResolver.register(e, (e) {
            _wheel += (e as PointerScrollEvent).scrollDelta.dy;
            final steps = (_wheel / 40).truncate();
            if (steps == 0) return;
            _wheel -= steps * 40;
            _set(
              _target - steps * 0.5,
              delay: const Duration(milliseconds: 600),
            );
          });
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Tippen aufs Thermometer schaltet nicht das Licht der Kachel.
          onTap: () {},
          onVerticalDragStart: (_) {
            _dragStart = _target;
            _dragDy = 0;
            setState(() => _active = true);
          },
          onVerticalDragUpdate: (d) {
            _dragDy += d.delta.dy;
            final h = context.size?.height ?? 160;
            final steps = (-_dragDy / _perHalf(h)).round();
            final v = _clamp(_dragStart! + steps * 0.5);
            if (v != _target) {
              Haptics.tick();
              setState(() => _pending = v);
            }
          },
          onVerticalDragEnd: (_) {
            setState(() => _active = false);
            if (_pending != null) _set(_pending!);
          },
          child: LayoutBuilder(
            builder: (context, box) {
              final h = box.maxHeight;
              double y(double v) => 9 + (h - 18) * (1 - frac(v));
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  // Regler
                  Positioned(
                    right: 6,
                    top: 8,
                    bottom: 8,
                    width: 24,
                    child: Container(
                      decoration: BoxDecoration(
                        color: hv.s2.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: hv.ln),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        children: [
                          if (cur != null)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              height: (h - 16) * frac(cur),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 300),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.bottomCenter,
                                    end: Alignment.topCenter,
                                    colors: [
                                      fill.withValues(alpha: 0.95),
                                      fill.withValues(alpha: 0.5),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          if (cur != null)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom:
                                  ((h - 16) * frac(cur) -
                                          (frac(cur) > 0.88 ? 15 : 0))
                                      .clamp(2.0, h),
                              child: Text(
                                fmt(cur),
                                textAlign: TextAlign.center,
                                style: HavenText.caption.copyWith(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                  shadows: const [
                                    Shadow(
                                      blurRadius: 2,
                                      color: Colors.black54,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  // Ziel: Strich über den Regler, Pfeil mit Wert daneben.
                  if (!c.off) ...[
                    Positioned(
                      right: 6,
                      width: 24,
                      top: y(_target) - 1,
                      height: 2,
                      child: ColoredBox(color: hv.tx),
                    ),
                    Positioned(
                      right: 31,
                      top: y(_target) - 10,
                      height: 20,
                      child: AnimatedScale(
                        scale: _active ? 1.15 : 1,
                        duration: const Duration(milliseconds: 150),
                        alignment: Alignment.centerRight,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: hv.tx,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '${fmt(_target)}°',
                                style: HavenText.caption.copyWith(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: hv.s1,
                                ),
                              ),
                            ),
                            CustomPaint(
                              size: const Size(6, 10),
                              painter: _ArrowPainter(hv.tx),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  _ArrowPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..moveTo(0, 0)
        ..lineTo(size.width, size.height / 2)
        ..lineTo(0, size.height)
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.color != color;
}

// ---- Kopf der Raumseite --------------------------------------------------

/// Kopf der Raumseite: der Raum mit seinem Licht.
class RoomRenderHeader extends ConsumerWidget {
  const RoomRenderHeader({super.key, required this.roomId, this.height = 190});

  final String roomId;
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final images = ref
        .watch(roomLayersProvider((roomId: roomId, dark: context.hv.isDark)))
        .value;
    if (images == null) return const SizedBox.shrink();
    return SizedBox(
      height: height,
      child: RoomRenderView(images: images, alignY: 0),
    );
  }
}
