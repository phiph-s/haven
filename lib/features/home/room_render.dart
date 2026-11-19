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
import '../../core/widgets/press_scale.dart';
import '../../data/models/lamp.dart';
import '../../data/models/room_heating.dart';
import '../../data/models/snapshot.dart' show ConnectionStatus;
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
  // Erst verbunden kennt die App die Fähigkeiten der Integration; vorher
  // gäbe es „keine Bilder“ bis zum nächsten Upload (Android: die App
  // startet vor der Verbindung). Nach jedem (Wieder-)Verbinden neu laden.
  final connected = ref.watch(
    snapshotProvider.select((s) => s.status == ConnectionStatus.connected),
  );
  if (repo == null) {
    yield null;
    return;
  }
  // Getrennt: nichts melden, der letzte Stand bleibt sichtbar (Riverpod
  // behält ihn beim Neuladen).
  if (!connected) return;
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

/// Heizung mit Minus und Plus statt Schieber (am Handy verstellte der sich
/// beim Scrollen): Raumtemperatur groß, darunter das Ziel in halben Grad.
/// Am PC ändert auch das Mausrad über dem Ziel. Gesendet wird, wenn die
/// Bedienung kurz ruht.
class TempStepper extends StatefulWidget {
  const TempStepper({super.key, required this.climate, required this.name});

  final TileClimate climate;
  final String name;

  @override
  State<TempStepper> createState() => _TempStepperState();
}

class _TempStepperState extends State<TempStepper> {
  /// Ziel während und kurz nach der Bedienung (bis HA es bestätigt).
  double? _pending;
  Timer? _commit;
  Timer? _forget;
  double _wheel = 0;

  TileClimate get c => widget.climate;
  double get _target => _pending ?? c.target;

  @override
  void didUpdateWidget(TempStepper old) {
    super.didUpdateWidget(old);
    // HA hat das Ziel übernommen: wieder den echten Wert zeigen.
    if (_pending != null &&
        _commit?.isActive != true &&
        (c.target - _pending!).abs() < 0.05) {
      _pending = null;
    }
  }

  @override
  void dispose() {
    _commit?.cancel();
    _forget?.cancel();
    super.dispose();
  }

  double _clamp(double v) => ((v * 2).round() / 2).clamp(c.min, c.max);

  void _step(double by) {
    final n = _clamp(_target + by);
    if (n == _target) return;
    Haptics.tick();
    setState(() => _pending = n);
    _commit?.cancel();
    _commit = Timer(const Duration(milliseconds: 700), () => _send(n));
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

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    String fmt(double v) => v.toStringAsFixed(1).replaceAll('.', ',');
    final heating =
        c.heating || (_pending != null && _target > (c.current ?? 99));
    final cur = c.current;
    const warm = Color(0xFFFF8A3D);
    return Semantics(
      slider: true,
      label: 'Zieltemperatur ${widget.name}',
      value: c.off ? 'aus' : '${fmt(_target)} Grad',
      increasedValue: '${fmt(_clamp(_target + 0.5))} Grad',
      decreasedValue: '${fmt(_clamp(_target - 0.5))} Grad',
      onIncrease: () => _step(0.5),
      onDecrease: () => _step(-0.5),
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
            _step(-steps * 0.5);
          });
        },
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  heating
                      ? Icons.local_fire_department_rounded
                      : Icons.thermostat_rounded,
                  size: 20,
                  color: heating ? warm : hv.tx3,
                ),
                const SizedBox(width: 2),
                Text(
                  cur == null ? '–' : '${fmt(cur)}°',
                  style: HavenText.headline.copyWith(
                    color: hv.tx,
                    fontSize: 22,
                    height: 1.15,
                  ),
                ),
              ],
            ),
            Text(
              c.off ? 'Heizung aus' : (heating ? 'heizt' : 'im Raum'),
              textAlign: TextAlign.center,
              style: HavenText.caption.copyWith(color: heating ? warm : hv.tx3),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                _StepButton(
                  icon: Icons.remove_rounded,
                  label: 'Kälter',
                  onTap: c.off ? null : () => _step(-0.5),
                ),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        c.off ? 'Aus' : '${fmt(_target)}°',
                        style: HavenText.label.copyWith(
                          color: hv.tx,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'Ziel',
                        style: HavenText.caption.copyWith(
                          color: hv.tx3,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                _StepButton(
                  icon: Icons.add_rounded,
                  label: 'Wärmer',
                  onTap: c.off ? null : () => _step(0.5),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.label, this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: PressScale(
        onTap: onTap,
        pressedScale: 0.88,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: hv.s1.withValues(alpha: hv.isDark ? 0.8 : 0.9),
            border: Border.all(color: hv.ln),
          ),
          child: Icon(
            icon,
            size: 20,
            color: onTap == null ? hv.tx3.withValues(alpha: 0.5) : hv.tx,
          ),
        ),
      ),
    );
  }
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
