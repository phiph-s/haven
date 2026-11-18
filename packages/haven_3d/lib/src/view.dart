import 'dart:math' as math;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_scene/scene.dart' as fs;

import 'camera.dart';
import 'gpu_scene.dart';
import 'heatmap.dart';
import 'model.dart';
import 'picking.dart';
import 'quality.dart';
import 'scene.dart';
import 'style.dart';
import 'support.dart';

/// Blickrichtungen für [SceneController.show].
class SceneViews {
  SceneViews._();

  /// Draufsicht wie der 2D-Plan.
  static const top = (yaw: 0.0, pitch: 0.0);

  /// Schräg von oben (Puppenhaus).
  static const iso = (yaw: -math.pi / 6, pitch: 0.95);

  /// Waagerecht von der Seite.
  static const side = (yaw: 0.0, pitch: math.pi / 2);
}

/// Wie ein Finger (oder die linke Maustaste) die Kamera bewegt.
enum SceneGestures {
  /// Ziehen dreht die Kamera, mit Umschalt verschiebt es.
  orbit,

  /// Wie eine Karte: in der Draufsicht verschiebt Ziehen, geneigt dreht es.
  /// Rechte oder mittlere Maustaste (oder Strg) dreht immer.
  map,

  /// Keine eigenen Gesten (z. B. ein Editor mit eigener Bedienung darüber).
  /// Tippen, Halten und Rechtsklick melden trotzdem ihre Treffer.
  none,
}

/// Projektion der Szene für Overlays: Weltpunkte (Meter) → Bildschirm.
@immutable
class SceneProjection {
  const SceneProjection(this.camera, this.size, this.markers);
  final OrbitCamera camera;
  final Size size;

  /// Bildpunkte der angezeigten Geräte (auf der Höhe ihres Raums).
  final Map<String, Offset> markers;

  /// Punkt auf dem Boden (Meter) → Bildschirm.
  Offset floor(Offset m) => camera.project(V3(m.dx, m.dy, 0), size).offset;

  /// Weltpunkt → Bildschirm.
  Offset project(V3 p) => camera.project(p, size).offset;

  /// Bildschirm → Punkt auf dem Boden (Meter), `null` ohne Treffer.
  Offset? toFloor(Offset screen) => camera.unprojectOnPlane(screen, size)?.xy;

  /// Pixel je Meter (auf Höhe des Ziels).
  double get scale => camera.scale;
}

/// Rückmeldung mit Bildschirmposition (lange drücken, Rechtsklick).
typedef SceneHitCallback = void Function(SceneHit? hit, Offset globalPosition);

/// Steuert die Kamera eines [Scene3DView] von außen und hält die
/// aufgebaute 3D-Szene.
///
/// Weil die Szene (samt Baking) hier liegt und nicht im Widget, kann die App
/// eine einzige Karte überall zeigen: Ein [Scene3DView] an anderer Stelle
/// mit demselben Controller übernimmt Szene und Kamera ohne Neuaufbau. Es
/// sollte immer nur ein [Scene3DView] gleichzeitig am Controller hängen.
class SceneController extends ChangeNotifier {
  SceneController([OrbitCamera camera = const OrbitCamera()])
    : _camera = camera;

  OrbitCamera _camera;
  _Scene3DViewState? _view;

  // --- Szene (bleibt beim Umhängen des Widgets erhalten) ------------------

  (Scene, double, double)? _fittedKey;
  Scene? _fitted;
  (Scene, double, double, SceneQuality)? _gpuKey;
  GpuScene? _gpu;

  Scene _fittedFor(Scene scene, SceneStyle style) {
    final key = (scene, style.roomGap, style.roomRadius);
    if (_fittedKey != key) {
      _fittedKey = key;
      _fitted = scene.fittedToRooms(
        inset: style.roomGap / 2,
        radius: style.roomRadius,
      );
    }
    return _fitted!;
  }

  GpuScene _gpuFor(Scene scene, SceneStyle style, SceneQuality quality) {
    final key = (scene, style.roomGap, style.roomRadius, quality);
    if (_gpuKey != key || _gpu == null) {
      _gpuKey = key;
      _gpu = GpuScene(_fittedFor(scene, style), style, quality: quality);
      // Zustände aus [setLamp] gelten auch nach einem Neuaufbau.
      for (final e in _lamps.entries) {
        _gpu!.setLamp(e.key, e.value);
      }
    } else {
      _gpu!.restyle(style);
    }
    return _gpu!;
  }

  // --- Kamera-Verlauf (Zurück) --------------------------------------------

  final List<OrbitCamera> _history = [];

  /// Gibt es eine frühere Kamera für [back]?
  bool get canGoBack => _history.isNotEmpty;

  /// Zum Gerät [markerId], Möbelstück [objectId] oder Raum [roomId] fahren:
  /// der Raum wird in den Bereich ohne [insets] eingepasst (z. B. das obere
  /// Drittel über einem Panel). Die bisherige Kamera merkt sich [back];
  /// mehrere `focus` hintereinander merken nur die erste.
  Future<void> focus({
    String? roomId,
    String? markerId,
    String? objectId,
    double? yaw,
    double? pitch,
    double? fov,
    EdgeInsets insets = EdgeInsets.zero,
    Duration duration = const Duration(milliseconds: 650),
  }) async {
    final v = _view;
    if (v == null) return;
    final scene = v._scene;
    final room =
        roomId ??
        (markerId != null ? scene.markerRoom[markerId] : null) ??
        (objectId != null ? scene.objectRoom[objectId] : null);
    if (_history.isEmpty) _history.add(_camera);
    await v._show(
      room,
      yaw ?? _camera.yaw,
      pitch ?? _camera.pitch,
      duration,
      insets: insets,
      fov: fov,
    );
  }

  /// Zur Kamera vor dem ersten [focus] zurück. `false`, wenn es keine gab.
  Future<bool> back({
    Duration duration = const Duration(milliseconds: 650),
  }) async {
    if (_history.isEmpty) return false;
    final target = _history.first;
    _history.clear();
    final v = _view;
    if (v == null) {
      camera = target;
    } else {
      await v._animateTo(target, duration);
    }
    return true;
  }

  /// Kamera setzen, ohne Zuhörer zu wecken: für eine Ansicht, die gleich
  /// (neu) erscheint und mit dieser Blickrichtung einpasst.
  void preset(OrbitCamera c) => _camera = c;

  OrbitCamera get camera => _camera;
  set camera(OrbitCamera c) {
    if (c == _camera) return;
    _camera = c;
    notifyListeners();
  }

  /// Raum [roomId] (oder alles) mit Blick [yaw]/[pitch] einpassen, animiert.
  /// [fov] wechselt dabei die Projektion (0 orthographisch). Vergisst einen
  /// gemerkten [focus].
  Future<void> show({
    String? roomId,
    double? yaw,
    double? pitch,
    double? fov,
    EdgeInsets insets = EdgeInsets.zero,
    Duration duration = const Duration(milliseconds: 650),
  }) async {
    _history.clear();
    final v = _view;
    if (v == null) return;
    await v._show(
      roomId,
      yaw ?? _camera.yaw,
      pitch ?? _camera.pitch,
      duration,
      insets: insets,
      fov: fov,
    );
  }

  /// Gemerkte Kamera aus [focus] vergessen (ohne zurückzufahren).
  void forgetFocus() => _history.clear();

  final Map<String, LampState> _lamps = {};

  /// Leuchte [id] umschalten, ohne die Szene neu aufzubauen. Der Zustand
  /// bleibt gemerkt und gilt auch, wenn die Szene später (neu) entsteht.
  void setLamp(String id, LampState state) {
    if (_lamps[id] == state) return;
    _lamps[id] = state;
    _gpu?.setLamp(id, state);
    _view?._wake();
  }

  /// Perspektive ein- oder ausblenden (animiert, Maßstab bleibt).
  Future<void> setPerspective(
    bool on, {
    Duration duration = const Duration(milliseconds: 500),
  }) async {
    final v = _view;
    final target = _camera.copyWith(fov: on ? OrbitCamera.perspectiveFov : 0);
    if (v == null) {
      camera = target;
      return;
    }
    await v._animateTo(target, duration);
  }
}

/// Interaktive 3D-Ansicht auf flutter_scene: ein Finger (oder linke
/// Maustaste) dreht, zwei Finger zoomen und verschieben, mit Umschalt
/// verschiebt auch die Maus, das Mausrad zoomt. Tippen meldet den Treffer
/// über [onTap]. Der Hintergrund bleibt durchsichtig.
///
/// [markerBuilder] legt Widgets auf die Geräte (sonst einfache Punkte); die
/// Position kommt aus [OrbitCamera.project], also genau aus derselben
/// Projektion wie das 3D-Bild.
class Scene3DView extends StatefulWidget {
  const Scene3DView({
    super.key,
    required this.scene,
    required this.controller,
    required this.style,
    this.selected = const {},
    this.focusRoomId,
    this.onTap,
    this.fitOnStart = true,
    this.markerBuilder,
    this.raisedRooms,
    this.stretchDuration = const Duration(milliseconds: 700),
    this.quality = SceneQuality.high,
    this.showStats = false,
    this.selectedRoomId,
    this.heatmap,
    this.markers,
    this.markerHitRadius = kMarkerHitRadius,
    this.onLongPress,
    this.onSecondaryTap,
    this.gestures = SceneGestures.orbit,
    this.roomLabelBuilder,
    this.insets = EdgeInsets.zero,
    this.placeholder,
    this.overlayBuilder,
    this.foregroundBuilder,
    this.interactiveMarkers = false,
    this.hiddenObjects = const {},
    this.revealRoomId,
  });

  final Scene scene;
  final SceneController controller;
  final SceneStyle style;
  final Set<String> selected;
  final String? focusRoomId;
  final ValueChanged<SceneHit?>? onTap;
  final bool fitOnStart;
  final Widget Function(BuildContext context, SceneMarker marker)?
  markerBuilder;

  /// Räume, die in 3D stehen; alle übrigen liegen flach wie die 2D-Karte
  /// (mit Linien, Licht und geschätzten Schatten). `null`: alle in 3D.
  /// Wechsel animieren: der Raum streckt sich vom Boden nach oben.
  final Set<String>? raisedRooms;
  final Duration stretchDuration;

  /// Qualitätsstufe (siehe [SceneQuality]). Ein Wechsel baut die Szene neu.
  final SceneQuality quality;

  /// Bildrate und Renderzeiten oben links einblenden.
  final bool showStats;

  /// Gewählter Raum: Akzent-Umrandung, in jeder Neigung sichtbar.
  final String? selectedRoomId;

  /// Heatmap über den Böden (Temperatur, Luftfeuchte …) oder `null`.
  final SceneHeatmap? heatmap;

  /// Geräte über der Szene (Widgets aus [markerBuilder], Treffertest). `null`:
  /// die Geräte der Szene. Leuchten für das Licht bleiben in [scene].
  final List<SceneMarker>? markers;

  /// Trefferradius der Geräte in logischen Pixeln.
  final double markerHitRadius;

  final SceneHitCallback? onLongPress;
  final SceneHitCallback? onSecondaryTap;
  final SceneGestures gestures;

  /// Beschriftung je Raum, oben links an [SceneRoom.labelAt] auf dem Boden.
  final Widget Function(BuildContext context, SceneRoom room, OrbitCamera cam)?
  roomLabelBuilder;

  /// Verdeckte Ränder (Kopfzeile, Leisten): das erste Einpassen nutzt nur
  /// die freie Fläche.
  final EdgeInsets insets;

  /// Solange die 3D-Szene noch entsteht (Flutter GPU startet, Licht wird
  /// gebacken), steht dieses Widget an ihrer Stelle, z. B. die 2D-Karte.
  /// Danach blendet die Szene über. Ohne: bis dahin leer.
  final Widget? placeholder;

  /// Zeichnet über der Szene, unter den Geräten (z. B. Verbindungslinien).
  final Widget Function(BuildContext context, SceneProjection p)?
  overlayBuilder;

  /// Gerät-Widgets bekommen selbst Zeiger-Ereignisse (z. B. zum Ziehen).
  /// Sonst gehen alle Gesten an die Ansicht (Treffertest über die Szene).
  final bool interactiveMarkers;

  /// Möbel, die nicht gezeichnet werden (z. B. während ein Editor sie zieht).
  final Set<String> hiddenObjects;

  /// Raum im Blick: alle Räume stehen, nur die, die ihn aus der Sicht der
  /// Kamera verdecken würden, liegen flach. Ersetzt [raisedRooms].
  final String? revealRoomId;

  /// Zeichnet über allem (z. B. Griffe eines Editors).
  final Widget Function(BuildContext context, SceneProjection p)?
  foregroundBuilder;

  @override
  State<Scene3DView> createState() => _Scene3DViewState();
}

class _Scene3DViewState extends State<Scene3DView>
    with TickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this);
  late final AnimationController _stretch = AnimationController(vsync: this);

  /// Aktuelle Raumhöhe (0 flach … 1 voll) und Animation dorthin.
  Map<String, double> _heights = {};
  Map<String, double> _heightFrom = {};
  Map<String, double> _heightTo = {};

  Map<String, double> _targets() => {
    for (final r in _scene.rooms)
      r.id: _raised == null || _raised!.contains(r.id) ? 1.0 : 0.0,
  };

  /// Szene mit eingerückten Möbeln (passend zu Spalt und Eckenradius).
  Scene get _scene => _c._fittedFor(widget.scene, widget.style);

  double _heightOf(String? roomId) =>
      roomId == null ? 1 : _heights[roomId] ?? 1;

  String? _roomOfMarker(SceneMarker m) =>
      m.roomId ?? _scene.markerRoom[m.id] ?? _scene.roomAt(m.position.xy);

  /// Gerät auf der Höhe seines (evtl. flachen) Raums.
  V3 _lifted(SceneMarker m) {
    final h = _heightOf(_roomOfMarker(m));
    return V3(m.position.x, m.position.y, m.position.z * h);
  }

  OrbitCamera? _from, _to;
  Size _size = Size.zero;
  bool _fitted = false;
  bool _ready = false;

  /// Keine GPU (Tests): Geräte, Beschriftungen und Overlays ohne Bild.
  bool _headless = false;
  GpuScene? get _gpu =>
      _ready ? _c._gpuFor(widget.scene, widget.style, widget.quality) : null;

  OrbitCamera? _startCam;
  Offset _startFocal = Offset.zero;

  SceneController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c._view = this;
    _c.addListener(_changed);
    _anim.addListener(() {
      final f = _from, t = _to;
      if (f == null || t == null) return;
      _c.camera = OrbitCamera.lerp(
        f,
        t,
        Curves.easeInOutCubic.transform(_anim.value),
      );
    });
    _raised = widget.raisedRooms;
    _heights = _targets();
    _stretch.addListener(() {
      final t = Curves.easeOutCubic.transform(_stretch.value);
      setState(() {
        _heights = {
          for (final e in _heightTo.entries)
            e.key:
                (_heightFrom[e.key] ?? e.value) +
                (e.value - (_heightFrom[e.key] ?? e.value)) * t,
        };
      });
    });
    Scene3DSupport.available().then((ok) async {
      if (ok) await fs.Scene.initializeStaticResources();
      if (!mounted) return;
      setState(() {
        if (ok) {
          _ready = true;
        } else {
          // Ohne GPU: Geräte, Beschriftungen und Overlays ohne Bild.
          _headless = true;
          _shown = true;
        }
      });
    });
  }

  @override
  void didUpdateWidget(Scene3DView old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      if (old.controller._view == this) old.controller._view = null;
      _c._view = this;
      _c.addListener(_changed);
    }
    if (old.scene != widget.scene) _restretch();
  }

  /// Wirksame aufgerichtete Räume ([Scene3DView.raisedRooms] oder, mit
  /// [Scene3DView.revealRoomId], alle außer den verdeckenden).
  Set<String>? _raised;

  void _restretch() {
    if (!mounted) return;
    _heightFrom = {..._heights};
    _heightTo = _targets();
    _stretch.duration = widget.stretchDuration;
    _stretch.forward(from: 0);
  }

  /// Gewünschte aufgerichtete Räume für [cam].
  Set<String>? _wantRaised(OrbitCamera cam, Size size) {
    final reveal = widget.revealRoomId;
    if (reveal == null || _scene.room(reveal) == null) {
      return widget.raisedRooms;
    }
    final hide = occludersOf(_scene, reveal, cam, size);
    return {
      for (final r in _scene.rooms)
        if (!hide.contains(r.id)) r.id,
    };
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    if (_c._view == this) _c._view = null;
    _anim.dispose();
    _stretch.dispose();
    _idle?.cancel();
    _statsTimer?.cancel();
    if (_timingsHooked) {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    }
    super.dispose();
  }

  // --- Rendern nur bei Bewegung ------------------------------------------

  /// Solange etwas passiert, rendert die Szene jedes Bild; eine Weile danach
  /// (damit Schatten und Texturen fertig werden) bleibt das Bild stehen.
  bool _active = true;
  Timer? _idle;
  static const _settle = Duration(milliseconds: 900);

  void _wake({bool inBuild = false}) {
    _idle?.cancel();
    _idle = Timer(_settle, () {
      if (mounted) setState(() => _active = false);
    });
    if (_active) return;
    // Im Build direkt setzen (setState ist dort verboten), sonst neu bauen.
    if (inBuild) {
      _active = true;
    } else {
      _later(() => _active = true);
    }
  }

  /// setState, auch wenn der Aufruf mitten aus einem Build kommt (etwa aus
  /// einem Provider, der beim Bauen eines anderen Widgets neu rechnet).
  void _later(VoidCallback f) {
    if (!mounted) return;
    final b = SchedulerBinding.instance;
    if (b.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      b.addPostFrameCallback((_) {
        if (mounted) setState(f);
      });
    } else {
      setState(f);
    }
  }

  // --- Statistik ------------------------------------------------------------

  Timer? _statsTimer;
  bool _timingsHooked = false;
  int _lastFrameCount = 0;
  DateTime _lastSample = DateTime.now();
  double _fps = 0;
  double _cpuMs = 0;
  final List<FrameTiming> _timings = [];
  double _rasterMs = 0;

  void _onTimings(List<FrameTiming> t) {
    _timings.addAll(t);
    if (_timings.length > 120) _timings.removeRange(0, _timings.length - 120);
  }

  void _syncStats() {
    if (widget.showStats && _statsTimer == null) {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
      _timingsHooked = true;
      _statsTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        final gpu = _gpu;
        if (gpu == null || !mounted) return;
        final now = DateTime.now();
        final stats = gpu.scene.renderStats;
        final frames = stats.frameCount - _lastFrameCount;
        final dt = now.difference(_lastSample).inMicroseconds / 1e6;
        _lastFrameCount = stats.frameCount;
        _lastSample = now;
        final recent = _timings.length > 30
            ? _timings.sublist(_timings.length - 30)
            : _timings;
        setState(() {
          _fps = dt > 0 ? frames / dt : 0;
          _cpuMs = (stats.latest?.cpuMicros ?? 0) / 1000;
          _rasterMs = recent.isEmpty
              ? 0
              : recent
                        .map((f) => f.rasterDuration.inMicroseconds)
                        .reduce((a, b) => a + b) /
                    recent.length /
                    1000;
        });
      });
    } else if (!widget.showStats && _statsTimer != null) {
      _statsTimer!.cancel();
      _statsTimer = null;
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      _timingsHooked = false;
    }
  }

  static bool _sameSet(Set<String>? a, Set<String>? b) {
    if (a == null || b == null) return a == b;
    return a.length == b.length && a.containsAll(b);
  }

  void _changed() => _later(() {});

  Future<void> _animateTo(OrbitCamera target, Duration d) async {
    _from = _c.camera;
    _to = target;
    _anim.duration = d;
    await _anim.forward(from: 0);
  }

  Future<void> _show(
    String? roomId,
    double yaw,
    double pitch,
    Duration d, {
    EdgeInsets insets = EdgeInsets.zero,
    double? fov,
  }) async {
    if (_size.isEmpty) return;
    final dir = _c.camera.copyWith(yaw: yaw, pitch: pitch, fov: fov);
    // In den freien Bereich einpassen und dorthin verschieben.
    final area = insets.deflateRect(Offset.zero & _size);
    final fitted = dir.fit(
      _scene.points(roomId: roomId),
      area.size,
      padding: 24,
    );
    final target = fitted.copyWith(
      pan: area.center - _size.center(Offset.zero),
    );
    _from = _c.camera;
    _to = target;
    _anim.duration = d;
    await _anim.forward(from: 0);
  }

  void _stop() {
    _anim.stop();
    _from = _to = null;
  }

  void _onScaleStart(ScaleStartDetails d) {
    _stop();
    _startCam = _c.camera;
    _startFocal = d.localFocalPoint;
  }

  int _buttons = 0;

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final s = _startCam;
    if (s == null) return;
    final delta = d.localFocalPoint - _startFocal;
    final keys = HardwareKeyboard.instance;
    if (d.pointerCount > 1) {
      // Um den Mittelpunkt der Finger zoomen, mitschieben, geneigt drehen.
      final scale = (s.scale * d.scale).clamp(4.0, 600.0);
      final k = scale / s.scale;
      final mid = _size.center(Offset.zero);
      _c.camera = s.copyWith(
        scale: scale,
        pan: d.localFocalPoint - mid - (_startFocal - mid - s.pan) * k,
        yaw: s.pitch > 0.05 ? s.yaw + d.rotation : null,
      );
      return;
    }
    final orbitButton =
        _buttons & (kSecondaryMouseButton | kMiddleMouseButton) != 0 ||
        keys.isControlPressed;
    final pan = switch (widget.gestures) {
      SceneGestures.orbit => keys.isShiftPressed,
      SceneGestures.map || SceneGestures.none =>
        keys.isShiftPressed || (!orbitButton && s.pitch < 0.05),
    };
    if (pan) {
      _c.camera = s.copyWith(pan: s.pan + delta);
    } else {
      _c.camera = s.copyWith(
        yaw: s.yaw + delta.dx * 0.008,
        pitch: s.pitch - delta.dy * 0.008,
      );
    }
  }

  void _onScroll(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    _stop();
    final cam = _c.camera;
    final f = math.exp(-e.scrollDelta.dy / 400);
    final scale = (cam.scale * f).clamp(4.0, 600.0);
    // Um den Mauszeiger zoomen.
    final center = _size.center(Offset.zero) + cam.pan;
    final k = scale / cam.scale;
    final pan = cam.pan + (e.localPosition - center) * (1 - k);
    _c.camera = cam.copyWith(scale: scale, pan: pan);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        if (size != _size) {
          _size = size;
          if (widget.fitOnStart && !_fitted && !size.isEmpty) {
            _fitted = true;
            final area = widget.insets.deflateRect(Offset.zero & size);
            _c._camera = _c.camera
                .fit(
                  _scene.points(roomId: widget.focusRoomId),
                  area.size,
                  padding: 24,
                )
                .copyWith(pan: area.center - size.center(Offset.zero));
          }
        }
        final cam = _c.camera;
        // Aufgerichtete Räume: beim Anfahren zählt die Zielkamera (so
        // springt nichts unterwegs), danach die aktuelle (Drehen).
        final want = _wantRaised(_to ?? cam, size);
        if (!_sameSet(want, _raised)) {
          _raised = want;
          WidgetsBinding.instance.addPostFrameCallback((_) => _restretch());
        }
        final gpu = _gpu;
        // Jeder Neuaufbau heißt: Kamera, Animation, Auswahl oder Stil hat
        // sich geändert. Dann rendern, bis es wieder ruhig ist.
        if (!_headless) _wake(inBuild: true);
        _syncStats();
        gpu?.sync(
          cam,
          focusRoomId: widget.focusRoomId,
          selected: widget.selected,
          heights: _heights,
          size: size,
          selectedRoomId: widget.selectedRoomId,
          heatmap: widget.heatmap,
          hiddenObjects: widget.hiddenObjects,
        );
        // Gebakenes Licht in Scheiben mischen; was übrig bleibt, im
        // nächsten Bild.
        if (gpu != null && (gpu.flushLight() | gpu.fading)) _later(() {});
        final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
        final maxDpr = widget.quality.maxPixelRatio;
        final markers = [
          for (final m in widget.markers ?? _scene.markers)
            if (widget.focusRoomId == null ||
                _roomOfMarker(m) == widget.focusRoomId)
              m,
        ];
        SceneHit? hit(Offset p) => hitTestScene(
          _scene,
          cam,
          _size,
          p,
          focusRoomId: widget.focusRoomId,
          hidden: gpu?.hidden ?? widget.hiddenObjects,
          heightOf: _heightOf,
          markers: widget.markers,
          markerRadius: widget.markerHitRadius,
        );
        final labels = widget.roomLabelBuilder;
        if (gpu != null && !_shown) _showSoon();
        final lifted = {for (final m in markers) m.id: _lifted(m)};
        final proj = SceneProjection(cam, size, {
          for (final e in lifted.entries)
            e.key: cam.project(e.value, size).offset,
        });
        final own = widget.gestures != SceneGestures.none;
        final view = Listener(
          onPointerSignal: own ? _onScroll : null,
          onPointerDown: (e) => _buttons = e.buttons,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: own ? _onScaleStart : null,
            onScaleUpdate: own ? _onScaleUpdate : null,
            onScaleEnd: own ? (_) => _startCam = null : null,
            onTapUp: widget.onTap == null
                ? null
                : (d) => widget.onTap!(hit(d.localPosition)),
            onLongPressStart: widget.onLongPress == null
                ? null
                : (d) => widget.onLongPress!(
                    hit(d.localPosition),
                    d.globalPosition,
                  ),
            onSecondaryTapUp: widget.onSecondaryTap == null
                ? null
                : (d) => widget.onSecondaryTap!(
                    hit(d.localPosition),
                    d.globalPosition,
                  ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (gpu != null)
                  fs.SceneView(
                    gpu.scene,
                    cameraBuilder: (_) => fsCamera(_c.camera, _size),
                    autoTick: _active,
                    maxFrameRate: widget.quality.maxFrameRate,
                    pixelRatio: maxDpr == null
                        ? dpr
                        : (dpr < maxDpr ? dpr : maxDpr),
                  ),
                if (labels != null)
                  for (final r in _scene.rooms)
                    if (widget.focusRoomId == null ||
                        r.id == widget.focusRoomId)
                      _at(
                        cam.project(V3(r.labelAt.dx, r.labelAt.dy, 0), size),
                        labels(context, r, cam),
                        center: false,
                      ),
                if (widget.overlayBuilder != null)
                  Positioned.fill(child: widget.overlayBuilder!(context, proj)),
                CustomPaint(
                  painter: _MarkerStems(
                    lifted.values.toList(),
                    cam,
                    widget.style,
                  ),
                ),
                for (final m in markers)
                  _place(context, m, proj.markers[m.id]!),
                if (widget.foregroundBuilder != null)
                  Positioned.fill(
                    child: widget.foregroundBuilder!(context, proj),
                  ),
                if (widget.showStats)
                  Positioned(
                    left: 8,
                    top: 8,
                    child: IgnorePointer(
                      child: _Stats(
                        fps: _fps,
                        cpuMs: _cpuMs,
                        rasterMs: _rasterMs,
                        quality: widget.quality,
                        active: _active,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
        // Bis die Szene ihre ersten Bilder hat, liegt [placeholder] darüber
        // (bedienbar), dann blendet die 3D-Ansicht samt Geräten über.
        final ph = widget.placeholder;
        const fade = Duration(milliseconds: 380);
        return Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              ignoring: !_shown,
              child: AnimatedOpacity(
                // Knapp über 0, damit die Szene schon zeichnet (und
                // Shader und Texturen warm werden).
                opacity: _shown ? 1 : 0.01,
                duration: fade,
                curve: Curves.easeOut,
                child: view,
              ),
            ),
            if (ph != null && !_placeholderGone)
              IgnorePointer(
                ignoring: _shown,
                child: AnimatedOpacity(
                  opacity: _shown ? 0 : 1,
                  duration: fade,
                  curve: Curves.easeIn,
                  onEnd: () {
                    if (_shown && mounted) {
                      setState(() => _placeholderGone = true);
                    }
                  },
                  child: ph,
                ),
              ),
          ],
        );
      },
    );
  }

  /// Sichtbar ist die Szene erst nach ein paar gezeichneten Bildern: der
  /// erste Frame kompiliert Shader und lädt Texturen, das soll niemand sehen.
  bool _shown = false;
  bool _showing = false;
  bool _placeholderGone = false;

  void _showSoon() {
    if (_showing) return;
    _showing = true;
    var frames = 3;
    void next(Duration _) {
      if (!mounted) return;
      if (--frames > 0) {
        SchedulerBinding.instance
          ..addPostFrameCallback(next)
          ..scheduleFrame();
        return;
      }
      setState(() => _shown = true);
    }

    SchedulerBinding.instance.addPostFrameCallback(next);
  }

  /// Widget an einem Bildpunkt: mittig oder mit der oberen linken Ecke.
  Widget _at(
    ViewPoint p,
    Widget child, {
    bool center = true,
    Key? key,
    bool interactive = false,
  }) => Positioned(
    key: key,
    left: p.x,
    top: p.y,
    child: IgnorePointer(
      ignoring: !interactive,
      child: center
          ? FractionalTranslation(
              translation: const Offset(-0.5, -0.5),
              child: child,
            )
          : child,
    ),
  );

  Widget _place(BuildContext context, SceneMarker m, Offset at) {
    final b = widget.markerBuilder;
    return _at(
      ViewPoint(at.dx, at.dy, 0),
      key: ValueKey('m:${m.id}'),
      interactive: widget.interactiveMarkers,
      b != null
          ? b(context, m)
          : SizedBox.square(
              dimension: 14,
              child: _Dot(
                color: switch (m.lamp) {
                  final l? when l.on => l.color,
                  final _? => const Color(0xFF8A9099),
                  null => markerColors[m.kind]!,
                },
                ring: widget.selected.contains(m.id)
                    ? widget.style.accent
                    : const Color(0xFFFFFFFF),
              ),
            ),
    );
  }
}

/// Standardfarben der Gerätepunkte.
const Map<MarkerKind, Color> markerColors = {
  MarkerKind.light: Color(0xFFF2B53A),
  MarkerKind.temperature: Color(0xFFE8734A),
  MarkerKind.presence: Color(0xFF9B6CE0),
  MarkerKind.remote: Color(0xFF3F8CE8),
  MarkerKind.contact: Color(0xFF2FA89A),
  MarkerKind.media: Color(0xFFD9578F),
  MarkerKind.device: Color(0xFF8A9099),
};

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.ring});
  final Color color;
  final Color ring;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: ring, width: 2),
      boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 4)],
    ),
  );
}

/// Gestricheltes Lot von jedem Gerät auf den Boden.
class _MarkerStems extends CustomPainter {
  _MarkerStems(this.points, this.camera, this.style);
  final List<V3> points;
  final OrbitCamera camera;
  final SceneStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    final stem = Paint()
      ..color = style.ink.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    final foot = Paint()..color = style.ink.withValues(alpha: 0.5);
    for (final p in points) {
      final top = camera.project(p, size).offset;
      final bottom = camera.project(V3(p.x, p.y, 0), size).offset;
      final len = (top - bottom).distance;
      if (len < 3) continue;
      const dash = 4.0;
      for (var s = 0.0; s < len; s += dash * 2) {
        canvas.drawLine(
          Offset.lerp(bottom, top, s / len)!,
          Offset.lerp(bottom, top, math.min(len, s + dash) / len)!,
          stem,
        );
      }
      canvas.drawCircle(bottom, 2, foot);
    }
  }

  @override
  bool shouldRepaint(_MarkerStems old) =>
      old.camera != camera || old.points != points || old.style != style;
}

/// Kleine Anzeige für Bildrate und Renderzeiten.
class _Stats extends StatelessWidget {
  const _Stats({
    required this.fps,
    required this.cpuMs,
    required this.rasterMs,
    required this.quality,
    required this.active,
  });
  final double fps;
  final double cpuMs;
  final double rasterMs;
  final SceneQuality quality;
  final bool active;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xB0101114),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: Text(
        '${fps.toStringAsFixed(0)} fps${active ? '' : ' (Ruhe)'}\n'
        'CPU ${cpuMs.toStringAsFixed(1)} ms · Raster ${rasterMs.toStringAsFixed(1)} ms\n'
        'Qualität ${quality.label}',
        style: const TextStyle(
          color: Color(0xFFE6E8EB),
          fontSize: 11,
          height: 1.35,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    ),
  );
}
