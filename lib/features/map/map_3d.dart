import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven_3d/haven_3d.dart' as h3;
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../data/models/floor_plan.dart';
import '../../data/models/lamp.dart';
import '../../data/models/snapshot.dart';
import 'floor_geometry.dart';
import 'floor_plan_store.dart';
import 'heatmap.dart';
import 'map_data.dart';
import 'map_readings.dart';
import 'map_sky.dart';
import 'map_weather.dart';

// ---- Einstellungen und Zustand ---------------------------------------------

/// Kann dieses Gerät die 3D-Karte zeigen (Flutter GPU, WebGL2)? In Tests
/// ohne GPU: die Ansicht läuft dort ohne Bild weiter (Treffertest auf der CPU).
final map3dSupportedProvider = FutureProvider<bool>(
  (ref) async =>
      await h3.Scene3DSupport.available() || h3.Scene3DSupport.headlessTest,
);

/// Einstellungen der 3D-Karte (lokal gemerkt).
@immutable
class Map3DSettings {
  const Map3DSettings({
    this.quality = h3.SceneQuality.medium,
    this.perspective = false,
    this.tilt = false,
    this.transparentWalls = false,
    this.environment = true,
    this.lightReach = h3.LightReach.doors,
  });

  final h3.SceneQuality quality;

  /// Wie weit Lampenlicht reicht: durch Türen, nur offene Wände oder nur
  /// im Raum. Weniger lädt schneller (weniger Baking).
  final h3.LightReach lightReach;

  /// Wände halbdurchsichtig statt deckend (Nachbarräume scheinen durch).
  final bool transparentWalls;

  /// Umgebung: Himmel mit Sonne, Mond, Tageszeit und Wetter, Sonnenstand
  /// nach draußen. Aus: ruhiges Kartenlicht wie früher.
  final bool environment;

  /// Perspektive in der Schrägansicht.
  final bool perspective;

  /// Schrägansicht (Puppenhaus) statt Draufsicht.
  final bool tilt;

  Map3DSettings copyWith({
    h3.SceneQuality? quality,
    bool? perspective,
    bool? tilt,
    bool? transparentWalls,
    bool? environment,
    h3.LightReach? lightReach,
  }) => Map3DSettings(
    quality: quality ?? this.quality,
    perspective: perspective ?? this.perspective,
    tilt: tilt ?? this.tilt,
    transparentWalls: transparentWalls ?? this.transparentWalls,
    environment: environment ?? this.environment,
    lightReach: lightReach ?? this.lightReach,
  );

  @override
  bool operator ==(Object other) =>
      other is Map3DSettings &&
      other.quality == quality &&
      other.perspective == perspective &&
      other.tilt == tilt &&
      other.transparentWalls == transparentWalls &&
      other.environment == environment &&
      other.lightReach == lightReach;

  @override
  int get hashCode => Object.hash(
    quality,
    perspective,
    tilt,
    transparentWalls,
    environment,
    lightReach,
  );
}

class Map3DSettingsNotifier extends Notifier<Map3DSettings> {
  @override
  Map3DSettings build() {
    final s = ref.read(settingsStoreProvider);
    return Map3DSettings(
      quality: h3.SceneQuality.values.firstWhere(
        (q) => q.name == s.map3dQuality,
        orElse: () => const Map3DSettings().quality,
      ),
      perspective: s.map3dPerspective,
      tilt: s.map3dTilt,
      transparentWalls: s.map3dTransparentWalls,
      environment: s.map3dEnvironment,
      lightReach: h3.LightReach.values.firstWhere(
        (r) => r.name == s.map3dLightReach,
        orElse: () => h3.LightReach.doors,
      ),
    );
  }

  void setLightReach(h3.LightReach v) {
    state = state.copyWith(lightReach: v);
    unawaited(ref.read(settingsStoreProvider).setMap3dLightReach(v.name));
  }

  void setTransparentWalls(bool v) {
    state = state.copyWith(transparentWalls: v);
    unawaited(ref.read(settingsStoreProvider).setMap3dTransparentWalls(v));
  }

  void setEnvironment(bool v) {
    state = state.copyWith(environment: v);
    unawaited(ref.read(settingsStoreProvider).setMap3dEnvironment(v));
  }

  void setQuality(h3.SceneQuality q) {
    state = state.copyWith(quality: q);
    unawaited(ref.read(settingsStoreProvider).setMap3dQuality(q.name));
  }

  void setPerspective(bool v) {
    state = state.copyWith(perspective: v);
    unawaited(ref.read(settingsStoreProvider).setMap3dPerspective(v));
  }

  void setTilt(bool v) {
    state = state.copyWith(tilt: v);
    unawaited(ref.read(settingsStoreProvider).setMap3dTilt(v));
  }
}

final map3dSettingsProvider =
    NotifierProvider<Map3DSettingsNotifier, Map3DSettings>(
      Map3DSettingsNotifier.new,
    );

/// Die eine 3D-Karte der App: Szene, Licht-Baking und Kamera bleiben hier,
/// auch wenn die Karte die Seite wechselt (Handy, Desktop, Rückkehr).
final map3dControllerProvider = Provider<h3.SceneController>((ref) {
  final c = h3.SceneController();
  ref.onDispose(c.dispose);
  return c;
});

/// Die Wohnungskarte schon beim Start der App aufbauen und backen (kurz
/// nachdem Zuhause steht), nicht erst beim Öffnen der Karte. In `app.dart`
/// beobachtet.
final mapPreloadProvider = Provider<void>((ref) {
  final plan = ref.watch(floorPlanProvider).value;
  final supported = ref.watch(map3dSupportedProvider).value ?? false;
  if (plan == null || !supported || h3.Scene3DSupport.headlessTest) return;
  final quality = ref.watch(map3dSettingsProvider.select((s) => s.quality));
  final reach = ref.watch(map3dSettingsProvider.select((s) => s.lightReach));
  final c = ref.read(map3dControllerProvider);
  final scene = sceneOfPlan(plan);
  final t = Timer(const Duration(milliseconds: 800), () {
    // Türen und Fenster wie in HA: das Baking passt dann gleich.
    syncMapOpenings(c, scene, ref.read(snapshotProvider));
    unawaited(c.prepare(scene, h3.SceneStyle.light(), quality, reach: reach));
  });
  ref.onDispose(t.cancel);
});

/// Kamera und Szene der Netzkarte (Vollbild und Kartenart Funknetz): eigene
/// Szene, weil der Netzplan den Bereich „Ohne Raum“ enthält.
final meshControllerProvider = Provider<h3.SceneController>((ref) {
  final c = h3.SceneController();
  ref.onDispose(c.dispose);
  return c;
});

/// Kann die Karte erscheinen? `null`: die Prüfung läuft noch (dann
/// [Map3DLoader] zeigen), `false`: das Gerät kann kein 3D
/// ([Map3DUnsupported]).
bool? watchMap3d(WidgetRef ref) {
  final supported = ref.watch(map3dSupportedProvider);
  if (supported.hasError) return false;
  return supported.hasValue ? supported.value! : null;
}

// ---- Blickwinkel -------------------------------------------------------------

/// Schrägansicht der Übersicht (leicht von links unten).
const double kMapTiltPitch = 0.92;

/// Zeigt die Kamera schräg (3D) statt von oben? Ab etwa 9° Neigung.
bool isTiltedCamera(h3.OrbitCamera c) => c.pitch > 0.15;
const double kMapTiltYaw = -0.42;

/// Blick beim Fokus auf einen Raum oder ein Gerät aus der Draufsicht.
const double kMapFocusPitch = 0.82;
const double kMapFocusYaw = -0.3;

/// Übersicht in der gewählten Ansicht einpassen, animiert.
Future<void> showMapOverview(
  h3.SceneController c,
  Map3DSettings s, {
  EdgeInsets insets = EdgeInsets.zero,
}) => c.show(
  yaw: s.tilt ? kMapTiltYaw : 0,
  pitch: s.tilt ? kMapTiltPitch : 0,
  fov: s.tilt && s.perspective ? h3.OrbitCamera.perspectiveFov : 0,
  insets: insets,
);

// ---- Grundriss → Szene -------------------------------------------------------

final _scenes = Expando<h3.Scene>('scene');

/// 3D-Szene zum Grundriss (Meter statt Zellen). Leuchten sind Lichtquellen
/// (Zustand über [syncMapLamps]), alle übrigen Geräte legt die Karte als
/// Overlay darüber. Gemerkt, solange sich der Plan nicht ändert, damit die
/// gebackene Beleuchtung bleibt.
h3.Scene sceneOfPlan(HavenFloorPlan plan) {
  final cached = _scenes[plan];
  if (cached != null) return cached;
  final m = plan.grid.cellMeters;
  final scene = h3.Scene(
    rooms: [
      for (final r in plan.rooms)
        h3.SceneRoom(
          id: r.id,
          outline: [for (final o in r.offsets) o * m],
          // Wie in 2D oben links in der Innenfläche.
          label: r.innerRect.topLeft * m + const Offset(0.24, 0.2),
          // „Ohne Raum“ (Netzkarte) ist nur eine Fläche ohne Wände.
          openEdges: r.detached
              ? {for (var i = 0; i < r.points.length; i++) i}
              : r.open,
        ),
    ],
    objects: [
      for (final f in plan.furniture)
        h3.SceneObject.furniture(
          id: f.id,
          kind: f.kind,
          center: f.center * m,
          w: f.w * m,
          d: f.h * m,
          rotation: f.rotation,
          sensor: f.sensor,
        ),
    ],
    // Alle platzierten Geräte stehen als Modell in der Welt, Lampen
    // leuchten (Zustand über [syncMapLamps]).
    markers: [
      for (final p in plan.placements)
        h3.SceneMarker(
          id: p.entityId,
          at: p.center * m,
          kind: markerKindOf(p.resolvedKind),
          model: deviceModelOf(p),
          mount: deviceMountOf(p),
          height: p.height,
          lamp: p.resolvedKind == FloorKind.light ? h3.LampState.off : null,
          rotation: p.rotation ?? 0,
          // Gespeichert als ganzer Winkel in Grad, die Szene rechnet mit dem
          // halben im Bogenmaß.
          cone: p.cone == null ? null : p.cone! / 2 * math.pi / 180,
          coneSoftness: p.spread,
        ),
    ],
  );
  _scenes[plan] = scene;
  return scene;
}

/// Knoten mit Punkt in Zellen. Mehrere Knoten auf derselben Zelle rücken
/// im Kreis auseinander (statt sich zu decken).
List<(FloorNode, Offset)> spreadNodes(List<FloorNode> nodes) {
  final byCell = <GridPoint, List<FloorNode>>{};
  for (final n in nodes) {
    (byCell[n.point.cell] ??= []).add(n);
  }
  return [
    for (final n in nodes)
      switch (byCell[n.point.cell]!) {
        final same when same.length > 1 => (
          n,
          n.point.offset +
              Offset.fromDirection(
                    -math.pi / 2 + 2 * math.pi * same.indexOf(n) / same.length,
                  ) *
                  0.8,
        ),
        _ => (n, n.point.offset),
      },
  ];
}

/// Bauform eines Geräts: gewählt oder passend zur Art.
String deviceModelOf(FloorPlacement p) => switch (p.model) {
  // Früher eigene Bauform, heute Bewegungsmelder mit Montage an der Wand.
  'motion_wall' => 'motion',
  final m? => m,
  null => defaultDeviceModel(p.resolvedKind, p.entityId),
};

/// Montage eines Geräts (Decke, Wand, nach oben) oder `null` bei fester
/// Bauform.
h3.DeviceMount? deviceMountOf(FloorPlacement p) => h3
    .deviceSpec(deviceModelOf(p))
    .mountOf(
      p.model == 'motion_wall' && p.mount == null
          ? h3.DeviceMount.wall
          : h3.DeviceMount.byName(p.mount),
    );

/// Standard-Bauform je Art (Thermostate als Heizkörperthermostat).
String defaultDeviceModel(FloorKind kind, String entityId) => switch (kind) {
  FloorKind.light => 'ceiling',
  FloorKind.temperature => entityId.startsWith('climate.') ? 'trv' : 'sensor',
  FloorKind.presence => 'motion',
  FloorKind.remote => 'switch',
  FloorKind.contact => 'contact',
  FloorKind.media => 'speaker',
  FloorKind.switchKind => 'plug',
  FloorKind.device => 'device',
};

/// Bauformen, die für ein Gerät der Art [kind] in Frage kommen.
List<h3.DeviceSpec> deviceModelsFor(FloorKind kind) => [
  for (final d in h3.kDeviceModels.values)
    if (!d.legacy && (kind == FloorKind.light ? d.isLamp : !d.isLamp)) d,
];

/// Höhe des Markers über dem Gerät: an der Lichtquelle bzw. knapp über dem
/// Montagepunkt.
double markerHeightOf(FloorPlacement p) {
  final spec = h3.deviceSpec(deviceModelOf(p));
  final how = deviceMountOf(p);
  final mount = p.height ?? spec.heightFor(how);
  return mount + (spec.isLamp ? spec.lightOffset(how).z : 0.08);
}

/// Höhe und Farbe eines Geräts in 3D nach seiner Art.
h3.MarkerKind markerKindOf(FloorKind k) => switch (k) {
  FloorKind.light => h3.MarkerKind.light,
  FloorKind.temperature => h3.MarkerKind.temperature,
  FloorKind.presence => h3.MarkerKind.presence,
  FloorKind.remote => h3.MarkerKind.remote,
  FloorKind.contact => h3.MarkerKind.contact,
  FloorKind.media => h3.MarkerKind.media,
  FloorKind.switchKind || FloorKind.device => h3.MarkerKind.device,
};

/// Sonnenrichtung für die 3D-Karte aus `sun.sun` (Azimut, Höhe; gerundet
/// auf 5° bzw. 3°, damit die Schatten nicht ständig neu entstehen) und der
/// Nordrichtung [north] des Plans. `null` ohne `sun.sun`.
h3.V3? mapSunOf(WidgetRef ref, double north) {
  final pos = ref.watch(
    snapshotProvider.select((s) {
      final a = s.entity('sun.sun')?.attributes;
      final az = a?['azimuth'], el = a?['elevation'];
      if (az is! num || el is! num) return null;
      return ((az / 5).round() * 5.0, (el / 3).round() * 3.0);
    }),
  );
  if (pos == null) return null;
  return h3.sunDirectionOf(pos.$1, pos.$2, north: north);
}

/// Aktive Sensoren leuchten auf der Karte (nur Eigenleuchten in ihrer
/// Farbe, keine Lichtquelle, also kein Licht und keine Schatten im Raum):
/// Alarm (Rauch, Wasser, Gas …) rot pulsierend, Bewegung und Anwesenheit
/// in [accent] pulsierend, offene Kontakte ruhig blau, sonst ruhig [accent].
Map<String, h3.DeviceTint> sensorTintsOf(
  HavenFloorPlan plan,
  HavenSnapshot snap,
  Color accent,
) {
  const alarm = {
    'smoke',
    'moisture',
    'gas',
    'carbon_monoxide',
    'safety',
    'problem',
    'tamper',
    'heat',
  };
  const motion = {
    'motion',
    'occupancy',
    'presence',
    'moving',
    'vibration',
    'sound',
  };
  const opening = {'door', 'window', 'opening', 'garage_door'};
  return {
    for (final p in plan.placements)
      if (snap.entity(p.entityId) case final e?
          when e.entityId.startsWith('binary_sensor.') && e.state == 'on')
        p.entityId: switch (e.deviceClass) {
          final c? when alarm.contains(c) => const h3.DeviceTint(
            Color(0xFFE5484D),
            pulse: true,
            glow: 1,
          ),
          final c? when motion.contains(c) => h3.DeviceTint(
            accent,
            pulse: true,
            glow: 0.8,
          ),
          final c? when opening.contains(c) => const h3.DeviceTint(
            Color(0xFF5AB0FF),
            glow: 0.6,
          ),
          _ => h3.DeviceTint(accent, glow: 0.5),
        },
  };
}

/// Lichtzustand einer Lampe für die Szene.
h3.LampState lampStateOf(Lamp l) {
  if (!l.on || !l.available) return h3.LampState.off;
  final (r, g, b) = l.color;
  return h3.LampState(
    brightness: (l.brightness / 100).clamp(0.05, 1.0),
    color: Color.fromARGB(255, r, g, b),
  );
}

/// Alle Leuchten der Szene auf den Stand von [lights] bringen (nur
/// geänderte werden neu gerechnet).
void syncMapLamps(h3.SceneController c, h3.Scene scene, MapLights lights) {
  for (final m in scene.markers) {
    if (m.lamp == null) continue;
    final l = lights.lamps[m.id];
    c.setLamp(m.id, l == null ? h3.LampState.off : lampStateOf(l));
  }
}

/// Türen und Fenster mit Sensor auf den Stand der Kontakte bringen: `on`
/// heißt offen, unbekannt oder nicht erreichbar zeigt den Normalzustand.
void syncMapOpenings(h3.SceneController c, h3.Scene scene, HavenSnapshot snap) {
  for (final o in scene.objects) {
    final id = o.sensor;
    if (id == null) continue;
    final e = snap.entity(id);
    final st = e?.state;
    c.setObjectOpen(
      o.id,
      st == 'on'
          ? true
          : st == 'off'
          ? false
          : null,
    );
  }
}

/// Heatmap (Temperatur, Feuchte) aus den Messwerten der Karte.
h3.SceneHeatmap? heatmapOf(HeatData d, double cellMeters) {
  final s = d.scale;
  if (s == null) return null;
  return h3.SceneHeatmap(
    byRoom: {
      for (final e in d.rooms.entries)
        e.key: [
          for (final x in e.value) h3.HeatPoint(x.at * cellMeters, x.value),
        ],
    },
    ramp: d.kind.ramp.colors,
    lo: s.lo,
    hi: s.hi,
    opacity: 0.62,
  );
}

/// Bewegung als Färbung der Räume: je kürzer her, desto kräftiger.
h3.SceneHeatmap presenceHeatmapOf(
  HavenFloorPlan plan,
  Map<String, RoomPresence> levels,
  Color color,
) {
  final m = plan.grid.cellMeters;
  return h3.SceneHeatmap(
    byRoom: {
      for (final r in plan.rooms)
        if ((levels[r.id]?.level ?? 0) > 0.01)
          r.id: [h3.HeatPoint(r.centroid * m, levels[r.id]!.level)],
    },
    ramp: [color.withValues(alpha: 0.14), color.withValues(alpha: 0.5)],
    lo: 0,
    hi: 1,
    opacity: 1,
  );
}

// ---- Karte -----------------------------------------------------------------

/// Die 3D-Karte mit den Knoten einer Kartenart darüber. Nimmt dieselben
/// Knoten, Builder und Rückrufe wie früher die 2D-Karte, so bleibt jede
/// Kartenart unverändert und bekommt zusätzlich Licht, Höhe und Fokus.
class Map3DView extends ConsumerStatefulWidget {
  const Map3DView({
    super.key,
    required this.plan,
    this.nodes = const [],
    this.nodeBuilder,
    this.heatmap,
    this.deviceTints = const {},
    this.onNodeTap,
    this.onNodeLongPress,
    this.onNodeSecondaryTap,
    this.onRoomTap,
    this.onOutsideTap,
    this.onRoomSecondaryTap,
    this.selectedRoomId,
    this.raisedRoomId,
    this.insets = EdgeInsets.zero,
    this.controller,
    this.overlayBuilder,
    this.foregroundBuilder,
    this.interactive = true,
    this.interactiveMarkers = false,
    this.quality,
    this.followSettings = true,
    this.markerKind,
    this.sky = false,
    this.skyBackdrop = true,
  });

  final HavenFloorPlan plan;
  final List<FloorNode> nodes;
  final FloorNodeBuilder? nodeBuilder;
  final h3.SceneHeatmap? heatmap;

  /// Geräte eingefärbt (Marker-ID → Tönung), z. B. Heizkörper rot beim
  /// Heizen, sonst blau (Klima).
  final Map<String, h3.DeviceTint> deviceTints;
  final ValueChanged<FloorNode>? onNodeTap;
  final ValueChanged<FloorNode>? onNodeLongPress;
  final ValueChanged<FloorNode>? onNodeSecondaryTap;
  final ValueChanged<FloorRoom>? onRoomTap;
  final VoidCallback? onOutsideTap;
  final void Function(FloorRoom? room, Offset globalPosition)?
  onRoomSecondaryTap;

  /// Umrandeter Raum (Auswahl).
  final String? selectedRoomId;

  /// Raum im Fokus: alle Räume richten sich auf, nur die, die ihn verdecken
  /// würden, bleiben flach. Ohne Fokus stehen in der Schrägansicht alle,
  /// in der Draufsicht keiner.
  final String? raisedRoomId;

  /// Verdeckte Ränder (Kopf, Leisten) fürs erste Einpassen.
  final EdgeInsets insets;

  /// Eigene Kamera und Szene (z. B. Funknetz, Miniatur). Sonst die eine
  /// Karte der App ([map3dControllerProvider]).
  final h3.SceneController? controller;

  /// Zeichenebenen über der Szene (unter bzw. über den Geräten).
  final Widget Function(BuildContext context, h3.SceneProjection p)?
  overlayBuilder;
  final Widget Function(BuildContext context, h3.SceneProjection p)?
  foregroundBuilder;

  /// Ohne eigene Gesten und Treffer (Miniatur, Editor mit eigener
  /// Bedienung).
  final bool interactive;

  /// Gerät-Widgets bekommen selbst Zeiger-Ereignisse (Ziehen).
  final bool interactiveMarkers;

  /// Qualität, sonst die aus den Einstellungen.
  final h3.SceneQuality? quality;

  /// Blickwinkel und aufgerichtete Räume folgen der Einstellung
  /// Draufsicht/Schrägansicht. Sonst immer Draufsicht, alles flach.
  final bool followSettings;

  /// Art (Höhe) eines Knotens, sonst aus der Platzierung im Plan.
  final h3.MarkerKind Function(FloorNode node)? markerKind;

  /// Himmel mit Tag und Nacht, Wetter und Schnee (live oder eigene Werte,
  /// siehe [mapWeatherProvider]): Licht und Schatten in Echtzeit, Sonne und
  /// Mond durch die Fenster, Hintergrund als Himmelsverlauf.
  final bool sky;

  /// Mit [sky]: den Verlauf des Himmels selbst malen. Die Karte malt ihn
  /// lieber selbst ([MapSkyBackdrop]) außerhalb ihrer Ausblendung oben, damit
  /// er bis unter die Statusleiste reicht.
  final bool skyBackdrop;

  @override
  ConsumerState<Map3DView> createState() => _Map3DViewState();
}

class _Map3DViewState extends ConsumerState<Map3DView> {
  h3.V3? _sun;

  HavenFloorPlan? _synced;

  @override
  void initState() {
    super.initState();
    // Neu auf der Seite: Übersicht in der gemerkten Ansicht (das erste
    // Einpassen übernimmt die Blickrichtung der Kamera).
    final c = _c;
    final tilt = widget.followSettings && ref.read(map3dSettingsProvider).tilt;
    final persp = ref.read(map3dSettingsProvider).perspective;
    c.forgetFocus();
    c.preset(
      c.camera.copyWith(
        yaw: tilt ? kMapTiltYaw : 0,
        pitch: tilt ? kMapTiltPitch : 0,
        fov: tilt && persp ? h3.OrbitCamera.perspectiveFov : 0,
      ),
    );
  }

  h3.SceneController get _c =>
      widget.controller ?? ref.read(map3dControllerProvider);

  @override
  void didUpdateWidget(Map3DView old) {
    super.didUpdateWidget(old);
    // Andere Szene (Karte ↔ Funknetz): Übersicht in der gewählten Ansicht.
    if (old.controller != widget.controller && widget.followSettings) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(
          showMapOverview(
            _c,
            ref.read(map3dSettingsProvider),
            insets: widget.insets,
          ),
        );
      });
    }
  }

  FloorRoom? _roomOfHit(h3.SceneHit? hit) {
    if (hit == null) return null;
    final plan = widget.plan;
    return switch (hit.kind) {
      h3.HitKind.room => plan.room(hit.id),
      h3.HitKind.object => switch (plan.furniture
          .where((f) => f.id == hit.id)
          .firstOrNull) {
        final f? => plan.room(plan.locationOfFurniture(f)),
        null => null,
      },
      h3.HitKind.marker => null,
    };
  }

  FloorNode? _node(h3.SceneHit? hit) => hit?.kind == h3.HitKind.marker
      ? widget.nodes.where((n) => n.id == hit!.id).firstOrNull
      : null;

  void _tap(h3.SceneHit? hit) {
    final n = _node(hit);
    if (n != null) return widget.onNodeTap?.call(n);
    final r = _roomOfHit(hit);
    if (r != null) return widget.onRoomTap?.call(r);
    widget.onOutsideTap?.call();
  }

  void _hold(h3.SceneHit? hit, Offset at) {
    final n = _node(hit);
    if (n != null) return widget.onNodeLongPress?.call(n);
    widget.onRoomSecondaryTap?.call(_roomOfHit(hit), at);
  }

  void _secondary(h3.SceneHit? hit, Offset at) {
    final n = _node(hit);
    if (n != null) return widget.onNodeSecondaryTap?.call(n);
    widget.onRoomSecondaryTap?.call(_roomOfHit(hit), at);
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final plan = widget.plan;
    final scene = sceneOfPlan(plan);
    final settings = ref.watch(map3dSettingsProvider);
    final h3.SceneController c =
        widget.controller ?? ref.watch(map3dControllerProvider);
    final tilt = widget.followSettings && settings.tilt;
    // Lichtzustand live in die Szene (gebackenes Licht wird nur für die
    // geänderte Lampe neu gemischt).
    ref.listen(mapLightsProvider(plan), (_, l) => syncMapLamps(_c, scene, l));
    // Türen und Fenster mit Kontakt: gleich im Aufbau (die Szene backt dann
    // schon mit dem richtigen Stand), danach bei jeder Änderung.
    ref.listen(snapshotProvider, (_, s) => syncMapOpenings(c, scene, s));
    syncMapOpenings(c, scene, ref.read(snapshotProvider));
    // Geräte färben (Klima: Heizkörper), nur Änderungen.
    final tints = widget.deviceTints;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final id in c.deviceTints.keys.toList()) {
        if (!tints.containsKey(id)) c.setDeviceTint(id, null);
      }
      for (final e in tints.entries) {
        c.setDeviceTint(e.key, e.value);
      }
    });
    // Sonne wie draußen: Stand aus `sun.sun`, gedreht nach Norden des Plans.
    // Ohne Umgebung die feste Kartensonne.
    final env = settings.environment;
    final sun = env ? mapSunOf(ref, plan.north) : h3.kSunDirection;
    if (sun != null && sun != _sun) {
      _sun = sun;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) c.setSun(sun);
      });
    }
    if (!identical(_synced, plan)) {
      _synced = plan;
      final l = ref.read(mapLightsProvider(plan));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) syncMapLamps(_c, scene, l);
      });
    }
    final m = plan.grid.cellMeters;
    // Himmel: Licht und Schnee in die Szene (Änderungen nach dem Bild).
    final weather = widget.sky && env
        ? ref.watch(mapWeatherProvider(plan.north))
        : null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      c.setSky(weather?.sky);
      c.setGround(
        weather == null
            ? null
            : h3.SceneGround(
                color: const Color(0x00FFFFFF),
                // Ab etwa 25 cm liegt eine geschlossene Decke.
                snow: (weather.snowCm / 25).clamp(0.0, 1.0),
              ),
      );
    });
    final byId = {for (final n in widget.nodes) n.id: n};
    // Mit Himmel in hell und dunkel dasselbe Licht und dieselben Farben,
    // nur der Hintergrund unterscheidet sich. Im dunklen Design werden die
    // Linien mit der Nacht hell wie im dunklen Stil (tagsüber blieben helle
    // Linien auf hellen Böden unsichtbar). In Stufen, damit die Szene nicht
    // bei jeder Minute neu einfärbt.
    final night = weather != null && hv.isDark
        ? 1 - (mapSkyDaylight(weather.sky) * 20).round() / 20
        : 0.0;
    final light = h3.SceneStyle.light();
    final dark = h3.SceneStyle.dark();
    // Ohne Himmel im dunklen Design: dieselben Farben, nur gedämpftes Licht.
    final style = (weather != null || !hv.isDark ? light : h3.SceneStyle.evening())
        .copyWith(
          accent: hv.acc,
          ink: night > 0 ? Color.lerp(light.ink, dark.ink, night) : null,
          roomEdgeOpacity: night > 0
              ? lerpDouble(light.roomEdgeOpacity, dark.roomEdgeOpacity, night)
              : null,
          // Standard: deckende Wände und Böden (Wände zur Kamera schneidet die
          // Szene weg). Durchsichtig nur auf Wunsch (Einstellungen).
          wallOpacity: settings.transparentWalls ? null : 1,
          floorOpacity: settings.transparentWalls ? null : 1,
        );
    final view = h3.Scene3DView(
      scene: scene,
      controller: c,
      style: style,
      quality: widget.quality ?? settings.quality,
      lightReach: settings.lightReach,
      gestures: widget.interactive
          ? h3.SceneGestures.map
          : h3.SceneGestures.none,
      insets: widget.insets,
      placeholder: Map3DLoader(plan: plan, insets: widget.insets),
      // Neuer Grundriss (Nordung, Abgleich mit HA): Aufbau und Licht im
      // Hintergrund, solange steht der Lader dort.
      buildBehindPlaceholder: true,
      // Fokus: alle Räume stehen, nur die davor liegen flach. Sonst je nach
      // Ansicht alle (schräg) oder keiner (Draufsicht).
      revealRoomId: widget.raisedRoomId,
      raisedRooms: tilt ? null : const {},
      overlayBuilder: widget.overlayBuilder,
      foregroundBuilder: widget.foregroundBuilder,
      interactiveMarkers: widget.interactiveMarkers,
      selectedRoomId: widget.selectedRoomId,
      heatmap: widget.heatmap,
      // Heatmaps zeigen Werte, kein Licht: Wände und Böden bleiben grau.
      lightsOn: widget.heatmap == null,
      markerHitRadius: 22,
      markers: [
        for (final (n, at) in spreadNodes(widget.nodes))
          h3.SceneMarker(
            id: n.id,
            at: at * m,
            roomId: n.point.isOutside || n.point.roomId.isEmpty
                ? null
                : n.point.roomId,
            kind:
                widget.markerKind?.call(n) ??
                markerKindOf(
                  plan.placementOf(n.id)?.resolvedKind ??
                      FloorKind.ofEntity(n.id),
                ),
            // Über dem Gerät (Bauform und gewählte Höhe).
            height: widget.markerKind == null && plan.placementOf(n.id) != null
                ? markerHeightOf(plan.placementOf(n.id)!)
                : null,
          ),
      ],
      markerBuilder: widget.nodeBuilder == null
          ? null
          : (context, mk) => switch (byId[mk.id]) {
              // Wie in 2D: das Widget mittig in seiner Trefferfläche.
              final n? => SizedBox.square(
                dimension: n.size,
                child: Center(child: widget.nodeBuilder!(context, n)),
              ),
              null => const SizedBox.shrink(),
            },
      onTap: widget.interactive ? _tap : null,
      onLongPress: widget.interactive ? _hold : null,
      onSecondaryTap: widget.interactive ? _secondary : null,
    );
    if (weather == null) return view;
    final bounds = planBoundsMeters(plan);
    final layers = h3.SkyLayers(
      sky: weather.sky,
      // Dunkles Design: immer Nachthimmel mit Sternen.
      dark: context.hv.isDark,
      // „Bewegung reduzieren“ im System: Himmel steht still.
      animate: mapSkyAnimations && !MediaQuery.disableAnimationsOf(context),
      controller: c,
      center: h3.V3(bounds.center.dx, bounds.center.dy, 0),
      extent: bounds,
      // Sonne und Mond nicht unter Kopf, Leisten, Inspektor oder der
      // Kartenleiste am rechten Rand.
      insets: widget.insets + const EdgeInsets.only(right: 56),
      child: view,
    );
    // Wolken und Regen nicht über den Rand hinaus (sonst z. B. in der
    // Statusleiste, außerhalb jeder Ausblendung).
    final clipped = ClipRect(child: layers);
    if (!widget.skyBackdrop) return clipped;
    return MapSkyBackdrop(north: plan.north, child: clipped);
  }
}

/// Hintergrund des Himmels: Verlauf aus Tageszeit und Wetter, im hellen
/// Design nach Weiß, im dunklen nach Schwarz.
class MapSkyBackdrop extends ConsumerWidget {
  const MapSkyBackdrop({super.key, required this.north, this.child});
  final double north;
  final Widget? child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = ref.watch(mapWeatherProvider(north));
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: mapSkyGradient(w.sky, dark: context.hv.isDark),
        ),
      ),
      child: child ?? const SizedBox.expand(),
    );
  }
}

/// Wolken, Regen und Schnee bewegen sich; Tests schalten das ab, damit
/// `pumpAndSettle` zur Ruhe kommt (siehe `test/flutter_test_config.dart`).
@visibleForTesting
bool mapSkyAnimations = true;

/// Grundfläche aller Räume eines Plans in Metern.
Rect planBoundsMeters(HavenFloorPlan plan) {
  final m = plan.grid.cellMeters;
  Rect? r;
  for (final room in plan.rooms) {
    for (final p in room.points) {
      final q = Offset(p.x * m, p.y * m);
      r = r == null
          ? Rect.fromPoints(q, q)
          : r.expandToInclude(Rect.fromPoints(q, q));
    }
  }
  return r ?? Rect.zero;
}

// ---- Bedienelemente ----------------------------------------------------------

/// Schwebende Leiste der 3D-Karte: Draufsicht oder Schrägansicht und
/// zurück zur Übersicht.
class Map3DControls extends ConsumerWidget {
  const Map3DControls({
    super.key,
    required this.insets,
    this.onRecenter,
    this.axis = Axis.vertical,
    this.controller,
    this.weather = false,
  });

  /// Mit Knopf für das Wetter der Karte (Live oder eigene Werte).
  final bool weather;

  /// Kamera, die die Leiste steuert (Funknetz), sonst die Karte der App.
  final h3.SceneController? controller;

  /// Freie Fläche der Karte für das Einpassen.
  final EdgeInsets insets;

  /// Vor dem Zurückfahren (z. B. Fokus aufheben).
  final VoidCallback? onRecenter;
  final Axis axis;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(map3dSettingsProvider);
    final h3.SceneController c =
        controller ?? ref.watch(map3dControllerProvider);
    // Der Schalter zeigt, was die Kamera gerade tut: Ein angetippter Raum
    // kippt die Ansicht, auch wenn die Einstellung Draufsicht ist.
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) =>
          _build(context, ref, s, c, tilted: isTiltedCamera(c.camera)),
    );
  }

  Widget _build(
    BuildContext context,
    WidgetRef ref,
    Map3DSettings s,
    h3.SceneController c, {
    required bool tilted,
  }) {
    final hv = context.hv;
    void setTilt(bool tilt) {
      if (tilt == tilted && tilt == s.tilt) return;
      Haptics.tick();
      ref.read(map3dSettingsProvider.notifier).setTilt(tilt);
      onRecenter?.call();
      unawaited(showMapOverview(c, s.copyWith(tilt: tilt), insets: insets));
    }

    Widget seg(String label, bool on, VoidCallback tap, String hint) =>
        Semantics(
          button: true,
          selected: on,
          label: hint,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: tap,
            child: AnimatedContainer(
              duration: context.motion(HavenMotion.d2),
              curve: HavenMotion.out,
              width: 40,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? hv.acc : const Color(0x00000000),
                borderRadius: BorderRadius.circular(HavenRadii.s),
              ),
              child: Text(
                label,
                style: HavenText.label.copyWith(
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                  color: on ? hv.ai : hv.tx2,
                ),
              ),
            ),
          ),
        );

    final children = [
      seg('2D', !tilted, () => setTilt(false), 'Draufsicht'),
      seg('3D', tilted, () => setTilt(true), 'Schrägansicht'),
      SizedBox(
        width: axis == Axis.vertical ? 24 : 1,
        height: axis == Axis.vertical ? 1 : 24,
        child: ColoredBox(color: hv.ln),
      ),
      Tooltip(
        message: 'Ganze Wohnung zeigen',
        child: Semantics(
          button: true,
          label: 'Ganze Wohnung zeigen',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              Haptics.tick();
              onRecenter?.call();
              unawaited(showMapOverview(c, s, insets: insets));
            },
            child: SizedBox(
              width: 40,
              height: 36,
              child: Icon(
                Icons.center_focus_strong_rounded,
                size: 19,
                color: hv.tx2,
              ),
            ),
          ),
        ),
      ),
      if (weather && ref.watch(map3dSettingsProvider).environment)
        const MapWeatherButton(),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: hv.s1.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(HavenRadii.m),
        border: Border.all(color: hv.ln),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF000000).withValues(alpha: 0.12),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Flex(
          direction: axis,
          mainAxisSize: MainAxisSize.min,
          spacing: 2,
          children: children,
        ),
      ),
    );
  }
}

// ---- Laden -----------------------------------------------------------------

/// Solange die 3D-Karte entsteht: die Raumumrisse als feine Linien, auf
/// denen ein Lichtstreif umläuft, darunter ein kurzer Hinweis. Die Szene
/// blendet darüber ein, sobald sie ihre ersten Bilder hat.
class Map3DLoader extends StatefulWidget {
  const Map3DLoader({
    super.key,
    required this.plan,
    this.insets = EdgeInsets.zero,
  });

  final HavenFloorPlan plan;

  /// Verdeckte Ränder: die Umrisse liegen dort, wo gleich die Szene steht.
  final EdgeInsets insets;

  @override
  State<Map3DLoader> createState() => _Map3DLoaderState();
}

class _Map3DLoaderState extends State<Map3DLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

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

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      label: '3D-Karte wird vorbereitet',
      child: LayoutBuilder(
        builder: (context, box) {
          final area = widget.insets.deflateRect(Offset.zero & box.biggest);
          return Stack(
            children: [
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _TracePainter(
                      plan: widget.plan,
                      area: area,
                      t: _t,
                      line: hv.tx3,
                      glow: hv.acc,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: area.left,
                right: box.maxWidth - area.right,
                bottom: box.maxHeight - area.bottom + 8,
                child: Text(
                  '3D-Karte wird vorbereitet …',
                  textAlign: TextAlign.center,
                  style: HavenText.caption.copyWith(color: hv.tx2),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TracePainter extends CustomPainter {
  _TracePainter({
    required this.plan,
    required this.area,
    required this.t,
    required this.line,
    required this.glow,
  }) : super(repaint: t);

  final HavenFloorPlan plan;
  final Rect area;
  final Animation<double> t;
  final Color line;
  final Color glow;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = [for (final r in plan.rooms) ...r.offsets];
    if (pts.isEmpty || area.isEmpty) return;
    var b = Rect.fromPoints(pts.first, pts.first);
    for (final p in pts) {
      b = b.expandToInclude(Rect.fromPoints(p, p));
    }
    final box = area.deflate(28);
    final k = math.min(
      box.width / math.max(b.width, 1e-6),
      box.height / math.max(b.height, 1e-6),
    );
    final o = box.center - b.center * k;
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeJoin = StrokeJoin.round
      ..color = line.withValues(alpha: 0.28);
    final streak = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = glow.withValues(alpha: 0.9);
    for (var i = 0; i < plan.rooms.length; i++) {
      final r = plan.rooms[i];
      final path = Path()
        ..addPolygon([for (final p in r.offsets) o + p * k], true);
      canvas.drawPath(path, base);
      // Je Raum versetzt, damit die Streifen nicht im Gleichschritt laufen.
      final phase = (t.value + i * 0.37) % 1.0;
      for (final m in path.computeMetrics()) {
        final len = m.length * 0.28;
        final start = phase * m.length;
        final end = start + len;
        canvas.drawPath(m.extractPath(start, math.min(end, m.length)), streak);
        if (end > m.length) {
          canvas.drawPath(m.extractPath(0, end - m.length), streak);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_TracePainter old) =>
      old.plan != plan ||
      old.area != area ||
      old.line != line ||
      old.glow != glow;
}

/// Statt der Karte, wenn das Gerät kein 3D kann (kein WebGL2 im Browser,
/// kein Flutter GPU).
class Map3DUnsupported extends StatelessWidget {
  const Map3DUnsupported({super.key});

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.view_in_ar_rounded, size: 40, color: hv.tx3),
              const SizedBox(height: 14),
              Text(
                'Die Karte braucht 3D',
                textAlign: TextAlign.center,
                style: HavenText.section.copyWith(color: hv.tx),
              ),
              const SizedBox(height: 6),
              Text(
                'Dieses Gerät oder dieser Browser kann keine 3D-Grafik '
                'anzeigen. Im Browser hilft es meist, WebGL bzw. die '
                'Hardwarebeschleunigung einzuschalten.',
                textAlign: TextAlign.center,
                style: HavenText.body.copyWith(color: hv.tx2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
