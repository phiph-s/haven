import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven_3d/haven_3d.dart' as h3;
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../data/haven_repository.dart';
import '../../data/models/floor_plan.dart';
import '../../data/render_api.dart';
import 'map_3d.dart';

// Bilder der Wohnung für Widgets und Displays: Nach einer Kartenänderung
// rendert die App je Perspektive und Design Lichtebenen (h3.LayerRenderer)
// und lädt sie zu Home Assistant hoch. Die Integration setzt daraus Bilder im
// aktuellen Lichtzustand zusammen (Image-Entities), ohne GPU.

/// Größe der Bilder.
const int kMapRenderWidth = 1024;
const int kMapRenderHeight = 768;

/// Erlaubte Zeichen in Satznamen (wie in der Integration).
final _unsafe = RegExp(r'[^A-Za-z0-9_\-]');

/// Standard-Perspektiven: Übersicht flach (wie die 2D-Karte), Übersicht in
/// 3D und je Raum eine 3D-Aufnahme.
List<h3.LayerView> mapLayerViews(HavenFloorPlan plan) => [
  const h3.LayerView(
    id: 'uebersicht_2d',
    name: 'Übersicht 2D',
    flat: true,
    width: kMapRenderWidth,
    height: kMapRenderHeight,
  ),
  const h3.LayerView(
    id: 'uebersicht_3d',
    name: 'Übersicht 3D',
    yaw: kMapTiltYaw,
    pitch: kMapTiltPitch,
    width: kMapRenderWidth,
    height: kMapRenderHeight,
  ),
  for (final r in plan.rooms)
    if (!r.detached)
      h3.LayerView(
        id: 'raum_${r.id.replaceAll(_unsafe, '_')}',
        name: r.name,
        roomId: r.id,
        yaw: kMapFocusYaw,
        pitch: kMapTiltPitch,
        width: kMapRenderWidth,
        height: kMapRenderHeight,
      ),
];

/// Render-Schlüssel: ändert sich mit Plan, Perspektiven und Format. HA merkt
/// ihn sich mit den Bildern, so sieht jedes Gerät, ob sie aktuell sind.
String mapRenderKey(HavenFloorPlan plan, List<h3.LayerView> views) {
  final text = jsonEncode({
    'format': h3.kLayerFormat,
    'plan': plan.toJson(),
    'views': [for (final v in views) v.toJson()],
  });
  return '${h3.kLayerFormat}-${_fnv(utf8.encode(text))}';
}

/// Zwei FNV-1a-Hashes (32 Bit, im Web wie nativ gleich gerechnet).
String _fnv(List<int> bytes) {
  var a = 0x811c9dc5, b = 0x01000193 ^ 0x5bd1e995;
  int mul(int h) => (((h << 24) & 0xFFFFFFFF) + h * 403) & 0xFFFFFFFF;
  for (final x in bytes) {
    a = mul(a ^ x);
    b = mul(b ^ ((x * 31 + 7) & 0xFF));
  }
  String hex(int v) => v.toRadixString(16).padLeft(8, '0');
  return '${hex(a)}${hex(b)}${bytes.length.toRadixString(16)}';
}

/// Abschnitt der Arbeit für den Dialog.
enum MapRenderPhase { prepare, render, upload, done }

/// Fortschritt: [fraction] 0 … 1 über alles, [roomId] der Raum, der gerade
/// beleuchtet wird.
typedef MapRenderProgress = ({
  MapRenderPhase phase,
  double fraction,
  String? roomId,
});

/// Rendert alle Perspektiven zu [plan] und lädt sie hoch.
class MapRenderJob {
  MapRenderJob(this.repo, this.plan, {List<h3.LayerView>? views})
    : views = views ?? mapLayerViews(plan);

  final HavenRepository repo;
  final HavenFloorPlan plan;
  final List<h3.LayerView> views;

  late final String key = mapRenderKey(plan, views);
  h3.LayerRenderer? _renderer;
  bool _cancelled = false;

  /// Anteil des Renderns am Fortschritt (der Rest ist der Upload).
  static const _renderShare = 0.88;

  void cancel() {
    _cancelled = true;
    _renderer?.cancel();
  }

  Future<void> run(void Function(MapRenderProgress p) onProgress) async {
    onProgress((phase: MapRenderPhase.prepare, fraction: 0, roomId: null));
    final renderer = _renderer = h3.LayerRenderer(
      sceneOfPlan(plan),
      quality: h3.SceneQuality.high,
    );
    final sets = await renderer.render(
      views,
      onProgress: (done, total, room) => onProgress((
        phase: done == 0 ? MapRenderPhase.prepare : MapRenderPhase.render,
        fraction: _renderShare * done / math.max(total, 1),
        roomId: room,
      )),
    );
    if (_cancelled) throw const h3.LayerCancelled();
    final files = <RenderFile>[];
    for (final s in sets) {
      final dir = '${s.view.id}_${s.theme}';
      Uint8List json(Object o) =>
          Uint8List.fromList(utf8.encode(jsonEncode(o)));
      files.add((path: '$dir/meta.json', bytes: json(s.meta())));
      files.add((path: '$dir/base.png', bytes: s.base));
      for (final e in s.rooms.entries) {
        files.add((path: '$dir/room_${e.key}.png', bytes: e.value.png));
      }
      for (final e in s.lamps.entries) {
        files.add((path: '$dir/lamp_${e.key}.png', bytes: e.value.png));
      }
    }
    await repo.uploadRenders(
      key,
      files,
      cancelled: () => _cancelled,
      onProgress: (sent, total) => onProgress((
        phase: MapRenderPhase.upload,
        fraction: _renderShare + (1 - _renderShare) * sent / math.max(total, 1),
        roomId: null,
      )),
    );
    onProgress((phase: MapRenderPhase.done, fraction: 1, roomId: null));
  }
}

/// Render-Schlüssel, die in dieser Sitzung schon erledigt oder abgelehnt
/// wurden (nicht noch einmal fragen).
class _HandledKeys extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void add(String key) => state = {...state, key};
}

final mapRenderHandledProvider = NotifierProvider<_HandledKeys, Set<String>>(
  _HandledKeys.new,
);

/// Unsichtbar in der Karte: Hat Home Assistant keine oder veraltete Bilder
/// zum Plan, bietet sie das Rendern an (einmal je Plan und Sitzung). Erst,
/// wenn die Karte oben liegt, also nach dem Verlassen des Editors.
class MapRenderGate extends ConsumerStatefulWidget {
  const MapRenderGate({super.key, required this.plan});

  final HavenFloorPlan plan;

  @override
  ConsumerState<MapRenderGate> createState() => _MapRenderGateState();
}

class _MapRenderGateState extends ConsumerState<MapRenderGate> {
  bool _checking = false;

  @override
  Widget build(BuildContext context) {
    final current = ModalRoute.of(context)?.isCurrent ?? true;
    final supported = ref.watch(map3dSupportedProvider).value ?? false;
    final repo = ref.watch(sessionProvider.select((s) => s.repo));
    if (current && supported && repo != null && !repo.isFake) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _check(repo));
    }
    return const SizedBox.shrink();
  }

  Future<void> _check(HavenRepository repo) async {
    if (_checking || !mounted) return;
    final plan = widget.plan;
    final views = mapLayerViews(plan);
    final key = mapRenderKey(plan, views);
    if (ref.read(mapRenderHandledProvider).contains(key)) return;
    _checking = true;
    try {
      final status = await repo.renderStatus();
      if (!mounted) return;
      // Ohne Unterstützung oder schon aktuell: nicht wieder fragen.
      if (status == null || status.key == key) {
        ref.read(mapRenderHandledProvider.notifier).add(key);
        return;
      }
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
      if (widget.plan != plan) return;
      ref.read(mapRenderHandledProvider.notifier).add(key);
      await showMapRenderDialog(
        context,
        MapRenderJob(repo, plan, views: views),
      );
    } catch (e) {
      // Kein Admin, keine Verbindung: diesmal nicht.
      debugPrint('Bilder für Widgets: $e');
      if (mounted) ref.read(mapRenderHandledProvider.notifier).add(key);
    } finally {
      _checking = false;
    }
  }
}

/// Ladedialog: rendert [job] und lädt hoch. `true`, wenn fertig.
Future<bool> showMapRenderDialog(BuildContext context, MapRenderJob job) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => MapRenderDialog(job: job),
  );
  return ok ?? false;
}

class MapRenderDialog extends StatefulWidget {
  const MapRenderDialog({super.key, required this.job, this.autoStart = true});

  final MapRenderJob job;

  /// Nur für Screenshots: nicht selbst starten (Fortschritt von außen).
  final bool autoStart;

  @override
  State<MapRenderDialog> createState() => MapRenderDialogState();
}

class MapRenderDialogState extends State<MapRenderDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );
  MapRenderProgress _p = (
    phase: MapRenderPhase.prepare,
    fraction: 0,
    roomId: null,
  );
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.autoStart) unawaited(_run());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.reduceMotion) {
      _t.value = 0.5;
      _t.stop();
    } else if (!_t.isAnimating) {
      _t.repeat();
    }
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  /// Fortschritt setzen (auch für Screenshots).
  void show(MapRenderProgress p) {
    if (mounted) setState(() => _p = p);
  }

  Future<void> _run() async {
    try {
      await widget.job.run(show);
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (mounted) Navigator.of(context).pop(true);
    } on h3.LayerCancelled {
      // „Später“: Dialog ist schon zu.
    } on RenderUploadCancelled {
      // ebenso
    } catch (e) {
      debugPrint('Bilder für Widgets: $e');
      if (mounted) {
        setState(
          () => _error =
              'Das hat nicht geklappt. Haven versucht es beim nächsten '
              'Öffnen der Karte noch einmal.',
        );
      }
    }
  }

  void _later() {
    widget.job.cancel();
    Navigator.of(context).pop(false);
  }

  String get _status {
    final p = _p;
    switch (p.phase) {
      case MapRenderPhase.prepare:
        return 'Die Wohnung wird aufgebaut …';
      case MapRenderPhase.render:
        final room = p.roomId == null
            ? null
            : widget.job.plan.rooms
                  .where((r) => r.id == p.roomId)
                  .firstOrNull
                  ?.name;
        return room == null
            ? 'Die Wohnung wird beleuchtet …'
            : '$room wird beleuchtet …';
      case MapRenderPhase.upload:
        return 'Wird zu Home Assistant gebracht …';
      case MapRenderPhase.done:
        return 'Fertig. Widgets und Displays zeigen jetzt jedes Licht.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final done = _p.phase == MapRenderPhase.done;
    return Dialog(
      backgroundColor: hv.s1,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HavenRadii.xl),
        side: BorderSide(color: hv.ln),
      ),
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Bilder für Widgets',
                style: HavenText.section.copyWith(color: hv.tx, fontSize: 22),
              ),
              const SizedBox(height: 6),
              Text(
                'Haven beleuchtet deine Wohnung einmal Lampe für Lampe. '
                'Daraus entstehen Bilder für Widgets und Displays, die '
                'später jedes Licht zeigen.',
                style: HavenText.caption.copyWith(color: hv.tx2),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 180,
                child: Semantics(
                  label: 'Grundriss, die Lampen gehen nacheinander an',
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _GlowPlanPainter(
                        plan: widget.job.plan,
                        t: _t,
                        progress: _p.fraction,
                        roomId: _p.roomId,
                        line: hv.tx3,
                        accent: hv.acc,
                        warm: const Color(0xFFFFB86B),
                        done: done,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(HavenRadii.pill),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: _p.fraction),
                  duration: context.reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 350),
                  builder: (_, v, _) => LinearProgressIndicator(
                    value: v,
                    minHeight: 8,
                    backgroundColor: hv.s3,
                    color: hv.acc,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _error ?? _status,
                      style: HavenText.caption.copyWith(
                        color: _error != null ? hv.bad : hv.tx2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${(_p.fraction * 100).round()} %',
                    style: HavenText.caption.copyWith(color: hv.tx3),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: done
                      ? null
                      : _error != null
                      ? () => Navigator.of(context).pop(false)
                      : _later,
                  child: Text(_error != null ? 'Schließen' : 'Später'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Grundriss als feine Linien; der Raum, der gerade dran ist, glimmt; die
/// Lampen gehen mit dem Fortschritt nacheinander warm an.
class _GlowPlanPainter extends CustomPainter {
  _GlowPlanPainter({
    required this.plan,
    required this.t,
    required this.progress,
    required this.roomId,
    required this.line,
    required this.accent,
    required this.warm,
    required this.done,
  }) : super(repaint: t);

  final HavenFloorPlan plan;
  final Animation<double> t;
  final double progress;
  final String? roomId;
  final Color line;
  final Color accent;
  final Color warm;
  final bool done;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = [for (final r in plan.rooms) ...r.offsets];
    if (pts.isEmpty || size.isEmpty) return;
    var b = Rect.fromPoints(pts.first, pts.first);
    for (final p in pts) {
      b = b.expandToInclude(Rect.fromPoints(p, p));
    }
    final box = (Offset.zero & size).deflate(8);
    final k = math.min(
      box.width / math.max(b.width, 1e-6),
      box.height / math.max(b.height, 1e-6),
    );
    final o = box.center - b.center * k;
    Offset at(Offset p) => o + p * k;
    // Atmen: 0 … 1 … 0
    final breath = 0.5 - 0.5 * math.cos(t.value * 2 * math.pi);

    for (final r in plan.rooms) {
      final path = Path()..addPolygon([for (final p in r.offsets) at(p)], true);
      final active = r.id == roomId && !done;
      if (active) {
        canvas.drawPath(
          path,
          Paint()..color = accent.withValues(alpha: 0.10 + 0.14 * breath),
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = active ? 1.8 : 1.2
          ..strokeJoin = StrokeJoin.round
          ..color = active
              ? accent.withValues(alpha: 0.85)
              : line.withValues(alpha: 0.35),
      );
    }

    final lamps = [
      for (final p in plan.placements)
        if (p.resolvedKind == FloorKind.light) at(p.center),
    ];
    final r0 = math.max(3.0, k * 0.18);
    for (var i = 0; i < lamps.length; i++) {
      // Lampe i geht an, wenn der Fortschritt ihren Anteil erreicht.
      final on = done
          ? 1.0
          : ((progress * lamps.length - i) * 2).clamp(0.0, 1.0).toDouble();
      final c = lamps[i];
      if (on > 0) {
        final glow = r0 * (4 + 1.2 * breath) * on;
        canvas.drawCircle(
          c,
          glow,
          Paint()
            ..shader = RadialGradient(
              colors: [
                warm.withValues(alpha: 0.55 * on),
                warm.withValues(alpha: 0),
              ],
            ).createShader(Rect.fromCircle(center: c, radius: glow)),
        );
      }
      canvas.drawCircle(
        c,
        r0,
        Paint()..color = Color.lerp(line.withValues(alpha: 0.5), warm, on)!,
      );
    }
  }

  @override
  bool shouldRepaint(_GlowPlanPainter old) =>
      old.plan != plan ||
      old.progress != progress ||
      old.roomId != roomId ||
      old.line != line ||
      old.accent != accent ||
      old.done != done;
}
