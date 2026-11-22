import 'dart:math' as math;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_scene/scene.dart' as fs;

import 'camera.dart';
import 'devices.dart';
import 'gpu_scene.dart';
import 'heatmap.dart';
import 'model.dart';
import 'picking.dart';
import 'quality.dart';
import 'scene.dart';
import 'sky.dart';
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

/// Ein Editor übernimmt einzelne Zeiger, statt dass sie die Kamera bewegen
/// (z. B. ein Möbelstück ziehen und drehen).
///
/// [start] bekommt den Punkt, an dem ein Finger (oder die linke Maustaste)
/// aufsetzte, sobald er sich bewegt, und sagt, ob der Editor ihn übernimmt.
/// Danach meldet [update] die Position (lokal, ab dem Aufsetzpunkt; kommt
/// ein zweiter Finger dazu, bleibt sie stehen) und die Drehung zweier Finger
/// in Bogenmaß seit dem Start (im Uhrzeigersinn positiv). [end] am Schluss.
/// Zwei Finger ohne übernommenen Zeiger bewegen wie immer die Kamera.
@immutable
class SceneGrab {
  const SceneGrab({required this.start, required this.update, this.end});
  final bool Function(Offset localPosition) start;
  final void Function(Offset localPosition, double rotation) update;
  final VoidCallback? end;
}

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
  (Scene, double, double, SceneQuality, LightReach)? _gpuKey;
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

  /// Szene im Aufbau hinter dem Platzhalter: Schlüssel und Zähler (ein
  /// neuer Aufbau macht einen laufenden ungültig).
  Object? _buildingKey;
  int _buildToken = 0;
  bool _disposed = false;

  GpuScene _makeGpu(
    Scene scene,
    SceneStyle style,
    SceneQuality quality,
    LightReach reach,
  ) {
    final g = GpuScene(
      _fittedFor(scene, style),
      style,
      quality: quality,
      open: _open,
      sun: _sun,
      deferBake: true,
      reach: reach,
    );
    _applyStates(g);
    return g;
  }

  /// Zustände aus [setLamp] und Co. gelten auch nach einem Neuaufbau.
  void _applyStates(GpuScene g) {
    for (final e in _lamps.entries) {
      g.setLamp(e.key, e.value);
    }
    if (_sky != null) g.setSky(_sky);
    if (_ground != null) g.setGround(_ground);
    g.scene.exposure = _exposure;
    for (final e in _tints.entries) {
      g.setDeviceTint(e.key, e.value);
    }
    if (_objectPreview != null) g.setObjectPreview(_objectPreview);
  }

  /// GPU-Szene zu [scene]. Das Licht wird immer im Hintergrund gebacken
  /// (in Scheiben zwischen den Bildern). Mit [background] entsteht auch die Geometrie erst
  /// nach dem nächsten Bild und die Szene erscheint fertig: bis dahin
  /// `null` (der Platzhalter steht dort). Ohne: sofort, das Licht kommt nach.
  GpuScene? _gpuFor(
    Scene scene,
    SceneStyle style,
    SceneQuality quality, {
    LightReach reach = LightReach.doors,
    bool background = false,
  }) {
    final key = (scene, style.roomGap, style.roomRadius, quality, reach);
    if (_gpuKey == key && _gpu != null) {
      _gpu!.restyle(style);
      return _gpu;
    }
    if (!background) {
      _buildingKey = null;
      _buildToken++;
      _gpuKey = key;
      final g = _gpu = _makeGpu(scene, style, quality, reach);
      g.bakeInBackground().then((_) {
        if (!_disposed) notifyListeners();
      });
      return g;
    }
    if (_buildingKey == key) return null;
    _buildingKey = key;
    final token = ++_buildToken;
    _gpu = null;
    _gpuKey = null;
    Future<void> build() async {
      if (token != _buildToken || _disposed) return;
      final g = _makeGpu(scene, style, quality, reach);
      await g.bakeInBackground();
      if (token != _buildToken || _disposed) return;
      _applyStates(g);
      _gpu = g;
      _gpuKey = key;
      _buildingKey = null;
      notifyListeners();
    }

    // Erst ein Bild mit Platzhalter (z. B. Seitenwechsel), dann bauen.
    SchedulerBinding.instance
      ..addPostFrameCallback((_) => Timer.run(build))
      ..scheduleFrame();
    return null;
  }

  /// Szene schon vorab aufbauen und backen (etwa beim Start der App), ohne
  /// dass ein [Scene3DView] sie zeigt. Erscheint die Karte später mit
  /// derselben Szene, Qualität und Reichweite, steht sie sofort.
  Future<void> prepare(
    Scene scene,
    SceneStyle style,
    SceneQuality quality, {
    LightReach reach = LightReach.doors,
  }) async {
    if (!await Scene3DSupport.available()) return;
    await fs.Scene.initializeStaticResources();
    // Eine sichtbare Karte baut selbst.
    if (_disposed || _view != null) return;
    _gpuFor(scene, style, quality, reach: reach, background: true);
  }

  @override
  void dispose() {
    _disposed = true;
    _buildToken++;
    super.dispose();
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
    _view?._lightChanged();
  }

  double _exposure = 1;

  /// Belichtung vor dem Tone-Mapping (1 = normal). Unter 1 brennen helle
  /// Flächen nicht aus, etwa für Lichtebenen, die später außerhalb der GPU
  /// zusammengesetzt und wieder aufgehellt werden.
  double get exposure => _exposure;
  set exposure(double v) {
    if (_exposure == v) return;
    _exposure = v;
    _gpu?.scene.exposure = v;
    _view?._wake();
  }

  V3? _sun;
  SceneSky? _sky;
  final Map<String, DeviceTint> _tints = {};
  SceneGround? _ground;

  /// Boden um die Wohnung (siehe [SceneGround]), `null`: keiner. Gilt auch
  /// für eine später gebaute Szene.
  void setGround(SceneGround? ground) {
    if (_ground == ground) return;
    _ground = ground;
    _gpu?.setGround(ground);
    _view?._lightChanged();
  }

  /// Gerät [id] (Marker-ID) einfärben und leuchten lassen, z. B. einen
  /// Heizkörper rot pulsierend, solange er heizt. `null` hebt das auf. Gilt
  /// auch für eine später gebaute Szene.
  void setDeviceTint(String id, DeviceTint? tint) {
    if (_tints[id] == tint) return;
    if (tint == null) {
      _tints.remove(id);
    } else {
      _tints[id] = tint;
    }
    _gpu?.setDeviceTint(id, tint);
    _view?._wake();
  }

  /// Aktuelle Tönungen (Marker-ID → Tönung).
  Map<String, DeviceTint> get deviceTints => Map.unmodifiable(_tints);

  /// Himmel mit Tag und Nacht, Mond und Wetter (siehe [SceneSky]): Licht und
  /// Schatten in Echtzeit, Sonne und Mond scheinen durch die Fenster.
  /// `null`: Kartenlicht. Gilt auch für eine später gebaute Szene.
  void setSky(SceneSky? sky) {
    if (_sky == sky) return;
    _sky = sky;
    _gpu?.setSky(sky);
    _view?._lightChanged();
  }

  /// Richtung des Sonnenlichts (von der Sonne zum Boden, Weltkoordinaten),
  /// z. B. nach Tageszeit und Lage der Wohnung. Gilt auch für eine später
  /// gebaute Szene. Siehe `sunDirectionOf` für Azimut und Höhe.
  void setSun(V3 direction) {
    if (_sun == direction) return;
    _sun = direction;
    _gpu?.setSunDirection(direction);
    _view?._lightChanged();
  }

  /// Vorschau eines Geräts beim Platzieren (siehe `GpuScene.setPreview`).
  void setPreview(
    String? model, {
    Offset at = Offset.zero,
    double z = 0,
    String? roomId,
    DeviceMount? mount,
  }) {
    _gpu?.setPreview(model, at: at, z: z, roomId: roomId, mount: mount);
    _view?._wake();
  }

  SceneObject? _objectPreview;

  /// Möbelstück als Vorschau beim Platzieren oder Ziehen (siehe
  /// `GpuScene.setObjectPreview`), `null` aus. Gilt auch für eine später
  /// gebaute Szene.
  void setObjectPreview(SceneObject? object) {
    if (identical(object, _objectPreview)) return;
    _objectPreview = object;
    _gpu?.setObjectPreview(object);
    _view?._wake();
  }

  final Map<String, bool?> _open = {};

  /// Tür oder Fenster [id] offen, zu oder unbekannt (`null`) zeigen, etwa
  /// nach einem Kontaktsensor. Gilt auch für eine später gebaute Szene.
  void setObjectOpen(String id, bool? open) {
    if (_open.containsKey(id) && _open[id] == open) return;
    _open[id] = open;
    _gpu?.setObjectOpen(id, open);
    _view?._lightChanged();
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
    this.onTiltGesture,
    this.fitOnStart = true,
    this.markerBuilder,
    this.raisedRooms,
    this.stretchDuration = const Duration(milliseconds: 700),
    this.quality = SceneQuality.high,
    this.lightReach = LightReach.doors,
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
    this.buildBehindPlaceholder = false,
    this.overlayBuilder,
    this.foregroundBuilder,
    this.interactiveMarkers = false,
    this.hiddenObjects = const {},
    this.revealRoomId,
    this.lightsOn = true,
    this.grab,
    this.onTapAt,
    this.onScroll,
  });

  final Scene scene;
  final SceneController controller;
  final SceneStyle style;
  final Set<String> selected;
  final String? focusRoomId;
  final ValueChanged<SceneHit?>? onTap;

  /// Neigung (pitch) nach einer Geste des Nutzers, die die Kamera kippt
  /// (zwei Finger senkrecht, Drehen mit der Maus). Nicht bei Kamerafahrten
  /// der App.
  final ValueChanged<double>? onTiltGesture;
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

  /// Wie weit Lampenlicht reicht (weniger: schneller fertig gebaken).
  final LightReach lightReach;

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

  /// Neue Szenen (anderer Grundriss, Qualität) hinter dem [placeholder]
  /// aufbauen und erst fertig zeigen, statt die Oberfläche anzuhalten.
  /// Sonst entsteht die Geometrie sofort und das Licht kommt nach.
  final bool buildBehindPlaceholder;

  /// Zeichnet über der Szene, unter den Geräten (z. B. Verbindungslinien).
  final Widget Function(BuildContext context, SceneProjection p)?
  overlayBuilder;

  /// Gerät-Widgets bekommen selbst Zeiger-Ereignisse (z. B. zum Ziehen).
  /// Sonst gehen alle Gesten an die Ansicht (Treffertest über die Szene).
  final bool interactiveMarkers;

  /// Möbel, die nicht gezeichnet werden (z. B. während ein Editor sie zieht).
  final Set<String> hiddenObjects;

  /// Lampenlicht zeigen. Aus (z. B. bei Heatmaps) bleiben Wände und Böden
  /// neutral, nur Sonne und Umgebung leuchten; der Wechsel mischt nur neu.
  final bool lightsOn;

  /// Raum im Blick: alle Räume stehen, nur die, die ihn aus der Sicht der
  /// Kamera verdecken würden, liegen flach. Ersetzt [raisedRooms].
  final String? revealRoomId;

  /// Zeichnet über allem (z. B. Griffe eines Editors).
  final Widget Function(BuildContext context, SceneProjection p)?
  foregroundBuilder;

  /// Zeiger, die ein Editor statt der Kamera bedient (siehe [SceneGrab]).
  final SceneGrab? grab;

  /// Wie [onTap], mit der Stelle (global) des Tippens.
  final SceneHitCallback? onTapAt;

  /// Mausrad zuerst an den Editor: `true` heißt erledigt (dann zoomt die
  /// Kamera nicht), z. B. Drehen mit gedrückter Umschalttaste.
  final bool Function(PointerScrollEvent event)? onScroll;

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
  GpuScene? get _gpu => _ready
      ? _c._gpuFor(
          widget.scene,
          widget.style,
          widget.quality,
          reach: widget.lightReach,
          background:
              widget.placeholder != null && widget.buildBehindPlaceholder,
        )
      : null;

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
    // Neue Builder oder Geräte: Widgets neu bauen.
    _markerCache.clear();
  }

  /// Gebaute Geräte-Widgets je ID. Beim Bewegen der Kamera baut nur diese
  /// Ansicht neu, nicht ihr Elternteil: dieselben Widgets wiederverwenden,
  /// statt bei jedem Bild alle (bei der Netzkarte oft Dutzende) neu zu bauen.
  final Map<String, Widget> _markerCache = {};

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

  /// Der nächste Neuaufbau zählt nicht als Bewegung und weckt die Ansicht
  /// nicht: der, mit dem sie zur Ruhe geht, und die der Statistik. (Sonst
  /// hielte sich die Ansicht selbst wach und renderte jedes Bild, auch wenn
  /// nichts geschieht.)
  bool _quiet = false;

  void _wake({bool inBuild = false}) {
    if (inBuild && _quiet) {
      _quiet = false;
      return;
    }
    _quiet = false;
    _idle?.cancel();
    _idle = Timer(_settle, () {
      if (!mounted) return;
      _quiet = true;
      setState(() => _active = false);
    });
    if (_active) return;
    // Im Build direkt setzen (setState ist dort verboten), sonst neu bauen.
    if (inBuild) {
      _active = true;
      _wakes++;
    } else {
      _later(() {
        if (!_active) _wakes++;
        _active = true;
      });
    }
  }

  /// Wie oft die Ansicht aus der Ruhe geweckt wurde. Schlüssel der
  /// `SceneView`: sie bekommt nach jeder Ruhe einen neuen Zustand, weil ihr
  /// Zustand (flutter_scene 0.24.3) nur einen Ticker je Lebenszeit anlegen
  /// darf; `autoTick` wieder einzuschalten bräche sonst im Debug-Modus ab.
  /// Die Szene selbst hängt nicht an diesem Zustand.
  int _wakes = 0;

  /// Licht hat sich geändert: neu bauen, damit [GpuScene.flushLight] die
  /// gebakenen Flächen (Böden, Oberseiten) gleich mischt. [_wake] allein
  /// baut nicht neu, solange die Ansicht schon läuft; dann käme das Licht
  /// erst nach der Ruhezeit.
  void _lightChanged() {
    _wake();
    _later(() {});
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
        _quiet = true;
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

  /// Aufsetzpunkt des ersten Fingers (für [SceneGrab.start]).
  Offset? _down;
  int _downCount = 0;

  /// Übernommener Zeiger (siehe [SceneGrab]): virtuelle Position, letzter
  /// Mittelpunkt der Finger, Drehung bis zum letzten Fingerwechsel.
  bool _grabbing = false;
  Offset _grabAt = Offset.zero;
  Offset _grabFocal = Offset.zero;
  double _grabTurn = 0;
  double _grabTurn0 = 0;
  double _grabTurnNow = 0;

  bool _startGrab(ScaleStartDetails d) {
    final g = widget.grab;
    if (g == null || d.pointerCount != 1) return false;
    final mouseOther =
        _buttons & (kSecondaryMouseButton | kMiddleMouseButton) != 0;
    if (mouseOther || HardwareKeyboard.instance.isControlPressed) return false;
    final at = _down ?? d.localFocalPoint;
    if (!g.start(at)) return false;
    _grabbing = true;
    _grabAt = at;
    _grabFocal = at;
    _grabTurn = 0;
    _grabTurn0 = 0;
    _grabTurnNow = 0;
    _pointers = 1;
    return true;
  }

  void _updateGrab(ScaleUpdateDetails d) {
    if (d.pointerCount != _pointers) {
      // Finger dazu oder weg: Position und Drehung neu verankern.
      _pointers = d.pointerCount;
      _grabTurn += _grabTurnNow;
      _grabTurnNow = 0;
      _grabTurn0 = d.rotation;
      _grabFocal = d.localFocalPoint;
      return;
    }
    if (d.pointerCount == 1) {
      _grabAt += d.localFocalPoint - _grabFocal;
    } else {
      _grabTurnNow = math.atan2(
        math.sin(d.rotation - _grabTurn0),
        math.cos(d.rotation - _grabTurn0),
      );
    }
    _grabFocal = d.localFocalPoint;
    widget.grab?.update(_grabAt, _grabTurn + _grabTurnNow);
  }

  void _endGrab() {
    if (!_grabbing) return;
    _grabbing = false;
    widget.grab?.end?.call();
  }

  void _onScaleStart(ScaleStartDetails d) {
    _stop();
    if (_startGrab(d)) return;
    _startCam = _c.camera;
    _startFocal = d.localFocalPoint;
    _tilting = null;
    _pointers = d.pointerCount;
    _rotation0 = 0;
    _scale0 = 1;
  }

  int _pointers = 0;
  double _rotation0 = 0;
  double _scale0 = 1;

  /// Zwei Finger: nach etwas Bewegung entschieden, ob sie kippen (beide
  /// senkrecht in dieselbe Richtung) oder zoomen, schieben und drehen.
  bool? _tilting;

  int _buttons = 0;

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_grabbing) return _updateGrab(d);
    if (widget.gestures == SceneGestures.none) return;
    if (d.pointerCount != _pointers) {
      // Finger dazu oder weg: neu verankern (der Mittelpunkt springt).
      _pointers = d.pointerCount;
      _startCam = _c.camera;
      _startFocal = d.localFocalPoint;
      _rotation0 = d.rotation;
      _scale0 = d.scale;
      return;
    }
    final s = _startCam;
    if (s == null) return;
    final delta = d.localFocalPoint - _startFocal;
    final keys = HardwareKeyboard.instance;
    if (d.pointerCount > 1) {
      // Drehung seit dem Verankern, auf ±π (Flutter meldet 0 … 2π).
      final rotation = math.atan2(
        math.sin(d.rotation - _rotation0),
        math.cos(d.rotation - _rotation0),
      );
      final scaleBy = _scale0 > 0 ? d.scale / _scale0 : d.scale;
      if (_tilting == null) {
        // Bewegungen vergleichbar machen (Pixel): Finger kommen nicht
        // gleichzeitig, das sieht kurz nach Drehen oder Zoomen aus.
        final zoomed = (scaleBy - 1).abs() * 200;
        final turned = rotation.abs() * 100;
        if (math.max(delta.distance, math.max(zoomed, turned)) < 14) return;
        final dy = delta.dy.abs();
        _tilting =
            widget.gestures == SceneGestures.map &&
            dy > 1.6 * delta.dx.abs() &&
            dy > 1.2 * turned &&
            dy > 1.2 * zoomed;
        if (_tilting!) {
          // Ab hier kippen, ohne Sprung.
          _startCam = _c.camera;
          _startFocal = d.localFocalPoint;
          _rotation0 = d.rotation;
          _scale0 = d.scale;
          return;
        }
      }
      if (_tilting!) {
        // Nach oben ziehen kippt in die Schrägansicht (wie in Karten-Apps).
        final pitch = (s.pitch - delta.dy * 0.006).clamp(0.0, 1.2);
        _c.camera = s.copyWith(pitch: pitch);
        widget.onTiltGesture?.call(pitch);
        return;
      }
      // Um den Mittelpunkt der Finger zoomen, mitschieben und drehen.
      final scale = (s.scale * scaleBy).clamp(4.0, 600.0);
      final k = scale / s.scale;
      final mid = _size.center(Offset.zero);
      var rel = (_startFocal - mid - s.pan) * k;
      if (s.pitch < 0.05) {
        // Draufsicht: das Bild dreht sich um die Kamera-Mitte; so
        // verschieben, dass der Punkt unter den Fingern bleibt.
        final c = math.cos(rotation), si = math.sin(rotation);
        rel = Offset(rel.dx * c - rel.dy * si, rel.dx * si + rel.dy * c);
      }
      _c.camera = s.copyWith(
        scale: scale,
        pan: d.localFocalPoint - mid - rel,
        yaw: s.yaw + rotation,
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
      widget.onTiltGesture?.call(_c.camera.pitch);
    }
  }

  void _onScroll(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    if (widget.onScroll?.call(e) ?? false) return;
    if (widget.gestures == SceneGestures.none) return;
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
        // Neue Szene entsteht hinter dem Platzhalter: der kommt zurück.
        if (gpu == null && _ready && _shown && widget.buildBehindPlaceholder) {
          _shown = false;
          _showing = false;
          _placeholderGone = false;
        }
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
          lightsOn: widget.lightsOn,
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
        final scales = own || widget.grab != null;
        _markerSpots = widget.interactiveMarkers ? proj.markers : const {};
        final listener = Listener(
          onPointerSignal: own || widget.onScroll != null ? _onScroll : null,
          onPointerDown: (e) {
            _buttons = e.buttons;
            if (_downCount++ == 0) _down = e.localPosition;
          },
          onPointerUp: (_) => _downCount = math.max(0, _downCount - 1),
          onPointerCancel: (_) => _downCount = math.max(0, _downCount - 1),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: widget.onTap == null && widget.onTapAt == null
                ? null
                : (d) {
                    final h = hit(d.localPosition);
                    widget.onTap?.call(h);
                    widget.onTapAt?.call(h, d.globalPosition);
                  },
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
                    key: ValueKey(_wakes),
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
                    if ((widget.focusRoomId == null ||
                            r.id == widget.focusRoomId) &&
                        !_selectedIn3d(r, cam))
                      _at(
                        cam.project(V3(r.labelAt.dx, r.labelAt.dy, 0), size),
                        labels(context, r, cam),
                        center: false,
                      ),
                if (widget.overlayBuilder != null)
                  Positioned.fill(child: widget.overlayBuilder!(context, proj)),
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
        // Drehen, Schieben, Zoomen und Greifen. Nicht auf bedienbaren Geräten:
        // Die Kamera gewinnt mit der Maus schon ab 2 px und nähme dem Gerät
        // sonst Klick und Ziehen weg.
        final view = RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            if (scales)
              _SceneScaleRecognizer:
                  GestureRecognizerFactoryWithHandlers<_SceneScaleRecognizer>(
                    () => _SceneScaleRecognizer(_allowsCamera),
                    (r) => r
                      ..onStart = _onScaleStart
                      ..onUpdate = _onScaleUpdate
                      ..onEnd = (_) {
                        _startCam = null;
                        _endGrab();
                      },
                  ),
          },
          child: listener,
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

  /// Lage der bedienbaren Geräte im letzten Bild (lokal).
  Map<String, Offset> _markerSpots = const {};

  /// `false`, wenn der Zeiger auf einem bedienbaren Gerät landet.
  bool _allowsCamera(PointerDownEvent e) {
    if (_markerSpots.isEmpty || widget.markerBuilder == null) return true;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return true;
    final local = box.globalToLocal(e.position);
    final r = widget.markerHitRadius;
    for (final at in _markerSpots.values) {
      if ((at - local).distance <= r) return false;
    }
    return true;
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

  /// Gewählter, aufgerichteter Raum in einer geneigten Ansicht: ohne
  /// Beschriftung (sein Name steht im Panel, auf dem Modell stört sie).
  bool _selectedIn3d(SceneRoom r, OrbitCamera cam) =>
      r.id == widget.selectedRoomId &&
      cam.pitch >= 0.3 &&
      _heightOf(r.id) >= 0.5;

  /// Widget an einem Bildpunkt: mittig oder mit der oberen linken Ecke.
  Widget _at(
    ViewPoint p,
    Widget child, {
    bool center = true,
    Key? key,
    bool interactive = false,
  }) {
    final inner = IgnorePointer(ignoring: !interactive, child: child);
    return Positioned(
      key: key,
      left: p.x,
      top: p.y,
      // Die Verschiebung außen: Sie prüft beim Treffertest nicht die eigene
      // Größe. Innen (unter IgnorePointer, das seine Größe prüft) war nur
      // das rechte untere Viertel eines mittigen Geräts klickbar.
      child: center
          ? FractionalTranslation(
              translation: const Offset(-0.5, -0.5),
              child: inner,
            )
          : inner,
    );
  }

  Widget _place(BuildContext context, SceneMarker m, Offset at) {
    final b = widget.markerBuilder;
    return _at(
      ViewPoint(at.dx, at.dy, 0),
      key: ValueKey('m:${m.id}'),
      interactive: widget.interactiveMarkers,
      b != null
          ? (_markerCache[m.id] ??= b(context, m))
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

/// Kamera-Geste, die Zeiger auf Geräten auslässt.
class _SceneScaleRecognizer extends ScaleGestureRecognizer {
  _SceneScaleRecognizer(this._allow);
  final bool Function(PointerDownEvent) _allow;

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      _allow(event) && super.isPointerAllowed(event);
}
