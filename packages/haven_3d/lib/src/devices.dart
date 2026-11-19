import 'dart:math' as math;

import 'model.dart';

/// Lichtverteilung einer Leuchte.
///
/// [cone] ist der halbe Öffnungswinkel des Lichtkegels nach unten in
/// Bogenmaß, `null` strahlt in alle Richtungen (Glühbirne, Stehlampe).
/// [lightZ] ist die Höhe der Lichtquelle relativ zum Montagepunkt.
class LampProfile {
  const LampProfile({this.cone, this.lightZ = 0, this.range = 7});
  final double? cone;
  final double lightZ;
  final double range;
}

/// Wie ein Gerät montiert ist. Bauformen, die nach unten zeigend gebaut
/// sind (Deckenleuchte, Spot, Bewegungsmelder, Lightbar), lassen sich auch
/// an die Wand (Vorderseite in den Raum) oder nach oben zeigend aufstellen.
enum DeviceMount {
  /// An der Decke oder unter einem Regal, zeigt nach unten.
  ceiling('Decke'),

  /// An der Wand, zeigt in den Raum.
  wall('Wand'),

  /// Steht auf Boden oder Möbel und zeigt nach oben (Uplight).
  up('Nach oben');

  const DeviceMount(this.label);
  final String label;

  static DeviceMount? byName(String? name) {
    for (final m in values) {
      if (m.name == name) return m;
    }
    return null;
  }
}

/// Ein Gerät in der 3D-Welt: Bauform, Standardhöhe und Modell.
///
/// Lokale Koordinaten: Ursprung ist der Montagepunkt ([height] über dem
/// Boden: Decke, Wand oder Boden). Geräte an der Wand ([wall]) liegen mit der
/// Rückseite auf `y = 0` und ragen nach `-y` in den Raum. [glow] baut die
/// leuchtenden Teile einer Lampe (eigenes Material, hell wenn an).
class DeviceSpec {
  const DeviceSpec(
    this.id,
    this.label, {
    required this.height,
    required this.build,
    this.wall = false,
    this.lamp,
    this.glow,
    this.mounts = const [],
    this.legacy = false,
    this.rotatable = false,
  });

  final String id;
  final String label;
  final double height;
  final bool wall;
  final LampProfile? lamp;
  final void Function(ModelBuilder b) build;
  final void Function(ModelBuilder b)? glow;

  /// Mögliche Montagen, die erste ist der Standard. Leer: fest (so wie
  /// gebaut). Nur für nach unten gebaute Bauformen.
  final List<DeviceMount> mounts;

  /// Alte Bauform: wird noch gezeigt, aber nicht mehr angeboten.
  final bool legacy;

  /// Lässt sich um die Hochachse drehen (nicht rund, z. B. Lightbar). An
  /// der Wand richtet die Wand das Gerät aus.
  final bool rotatable;

  /// Drehbar in der Montage [m]?
  bool canRotate(DeviceMount? m) => rotatable && !isWall(m);

  bool get isLamp => lamp != null;

  /// Gültige Montage: [m], wenn möglich, sonst der Standard (oder `null`
  /// bei fester Bauform).
  DeviceMount? mountOf(DeviceMount? m) =>
      mounts.isEmpty ? null : (mounts.contains(m) ? m : mounts.first);

  /// Hängt an einer Wand (eingerastet, mit der Wand durchscheinend)?
  bool isWall(DeviceMount? m) => wall || mountOf(m) == DeviceMount.wall;

  /// Standardhöhe des Montagepunkts für die Montage [m].
  double heightFor(DeviceMount? m) => switch (mountOf(m)) {
    DeviceMount.wall => isLamp ? 1.8 : 2.2,
    DeviceMount.up => 0,
    _ => height,
  };

  /// Lokaler Punkt [v] der Bauform in der Montage [m] (die Bauform ist nach
  /// unten zeigend gebaut): Wand dreht `-z` nach `-y` (in den Raum), nach
  /// oben stellt sie auf den Kopf.
  V3 orient(V3 v, DeviceMount? m) => switch (mountOf(m)) {
    DeviceMount.wall => v.rotateX(-math.pi / 2),
    DeviceMount.up => v.rotateX(math.pi),
    _ => v,
  };

  /// Richtung des Lichts (lokal, vor dem Drehen zur Wand).
  V3 lightAxis(DeviceMount? m) => orient(const V3(0, 0, -1), m);

  /// Versatz der Lichtquelle zum Montagepunkt (lokal).
  V3 lightOffset(DeviceMount? m) => orient(V3(0, 0, lamp?.lightZ ?? 0), m);

  Model3 model([DeviceMount? m]) {
    final b = ModelBuilder();
    build(b);
    return _oriented(b.build(), m);
  }

  Model3? glowModel([DeviceMount? m]) {
    final g = glow;
    if (g == null) return null;
    final b = ModelBuilder();
    g(b);
    return _oriented(b.build(), m);
  }

  Model3 _oriented(Model3 model, DeviceMount? m) =>
      mountOf(m) == null || mountOf(m) == DeviceMount.ceiling
      ? model
      : model.rotated((v) => orient(v, m));
}

/// Alle Bauformen. Lampen haben einen [LampProfile] (Lichtkegel).
final Map<String, DeviceSpec> kDeviceModels = {
  for (final d in _devices) d.id: d,
};

/// Bauform zur Kennung, sonst das schlichte Gerät.
DeviceSpec deviceSpec(String? id) =>
    kDeviceModels[id] ?? kDeviceModels['device']!;

/// Bauformen für Lampen (Auswahl im Editor).
List<DeviceSpec> get lampModels => [
  for (final d in _devices)
    if (d.isLamp && !d.legacy) d,
];

const _turnable = [DeviceMount.ceiling, DeviceMount.wall, DeviceMount.up];

final List<DeviceSpec> _devices = [
  // ---- Lampen ----------------------------------------------------------
  DeviceSpec(
    'ceiling',
    'Deckenleuchte',
    height: 2.5,
    lamp: const LampProfile(cone: 1.25, lightZ: -0.1),
    mounts: _turnable,
    build: (b) => b.cylinder(0, 0, 0.05, -0.03, 0, segments: 10),
    glow: (b) => b.cylinder(0, 0, 0.2, -0.09, -0.03, segments: 20),
  ),
  DeviceSpec(
    'pendant',
    'Pendelleuchte',
    height: 2.5,
    lamp: const LampProfile(cone: 0.85, lightZ: -0.78),
    build: (b) {
      b.cylinder(0, 0, 0.05, -0.02, 0, segments: 10);
      b.line(const V3(0, 0, -0.02), const V3(0, 0, -0.62));
      b.cone(0, 0, 0.24, 0.05, -0.8, -0.62, segments: 18);
    },
    glow: (b) => b.cylinder(0, 0, 0.2, -0.81, -0.79, segments: 18),
  ),
  DeviceSpec(
    'spot',
    'Spot',
    height: 2.5,
    lamp: const LampProfile(cone: 0.42, lightZ: -0.1),
    mounts: _turnable,
    build: (b) => b.cylinder(0, 0, 0.06, -0.08, 0, segments: 12),
    glow: (b) => b.cylinder(0, 0, 0.045, -0.095, -0.08, segments: 12),
  ),
  DeviceSpec(
    'floor_lamp',
    'Stehlampe',
    height: 0,
    lamp: const LampProfile(lightZ: 1.45, range: 6),
    build: (b) {
      b.cylinder(0, 0, 0.14, 0, 0.03, segments: 16);
      b.cylinder(0, 0, 0.012, 0.03, 1.35, segments: 6);
    },
    glow: (b) => b.cone(0, 0, 0.2, 0.13, 1.33, 1.6, segments: 18),
  ),
  DeviceSpec(
    'table_lamp',
    'Tischlampe',
    height: 0.75,
    lamp: const LampProfile(lightZ: 0.32, range: 4),
    build: (b) {
      b.cylinder(0, 0, 0.07, 0, 0.03, segments: 14);
      b.cylinder(0, 0, 0.01, 0.03, 0.22, segments: 6);
    },
    glow: (b) => b.cone(0, 0, 0.14, 0.09, 0.22, 0.42, segments: 16),
  ),
  DeviceSpec(
    'wall_lamp',
    'Wandleuchte',
    height: 1.8,
    wall: true,
    lamp: const LampProfile(lightZ: 0.05, range: 5),
    build: (b) => b.box(-0.06, -0.03, -0.08, 0.06, 0, 0.08),
    glow: (b) => b.box(-0.1, -0.13, -0.05, 0.1, -0.03, 0.15),
  ),
  DeviceSpec(
    'bulb',
    'Glühbirne',
    height: 2.4,
    lamp: const LampProfile(lightZ: -0.1),
    build: (b) => b.line(const V3(0, 0, 0.1), const V3(0, 0, -0.04)),
    glow: (b) => b.cylinder(0, 0, 0.05, -0.14, -0.04, segments: 12),
  ),

  DeviceSpec(
    'lightbar',
    'Lightbar',
    height: 2.5,
    // Standard: steht auf Boden oder Möbel und strahlt nach oben an die
    // Wand; unter Regalen oder an der Wand auch nach unten bzw. in den Raum.
    lamp: const LampProfile(cone: 1.05, lightZ: -0.05, range: 5),
    mounts: const [DeviceMount.up, DeviceMount.ceiling, DeviceMount.wall],
    rotatable: true,
    build: (b) {
      b.box(-0.3, -0.025, -0.035, 0.3, 0.025, 0);
      b.line(const V3(-0.3, 0, -0.035), const V3(0.3, 0, -0.035));
    },
    glow: (b) => b.box(-0.29, -0.018, -0.045, 0.29, 0.018, -0.035),
  ),

  // ---- Klima -----------------------------------------------------------
  DeviceSpec(
    'trv',
    'Heizkörperthermostat',
    height: 0.15,
    wall: true,
    build: (b) {
      // Heizkörper flach an der Wand, Thermostatkopf seitlich oben.
      b.box(-0.35, -0.07, 0, 0.35, -0.02, 0.5);
      for (var i = 1; i < 7; i++) {
        final x = -0.35 + 0.7 * i / 7;
        b.line(V3(x, -0.07, 0.03), V3(x, -0.07, 0.47));
      }
      b.cylinder(0.42, -0.06, 0.03, 0.38, 0.5, segments: 12);
      b.box(0.36, -0.07, 0.42, 0.42, -0.02, 0.46, mat: Mat.dark);
    },
  ),
  DeviceSpec(
    'wall_thermostat',
    'Raumthermostat',
    height: 1.5,
    wall: true,
    build: (b) {
      b.box(-0.045, -0.025, -0.045, 0.045, 0, 0.045);
      b.box(-0.03, -0.027, -0.02, 0.03, -0.025, 0.02, mat: Mat.dark);
    },
  ),
  DeviceSpec(
    'sensor',
    'Klimasensor',
    height: 1.5,
    wall: true,
    build: (b) => b.box(-0.025, -0.015, -0.025, 0.025, 0, 0.025),
  ),

  // ---- Sensoren, Schalter, Sonstiges ------------------------------------
  DeviceSpec(
    'motion',
    'Bewegungsmelder',
    height: 2.5,
    mounts: const [DeviceMount.ceiling, DeviceMount.wall],
    build: (b) {
      b.cylinder(0, 0, 0.045, -0.015, 0, segments: 14);
      b.cone(0, 0, 0.035, 0.01, -0.05, -0.015, segments: 14, mat: Mat.soft);
    },
  ),
  DeviceSpec(
    'motion_wall',
    'Bewegungsmelder (Wand)',
    height: 2.2,
    wall: true,
    legacy: true,
    build: (b) {
      b.box(-0.03, -0.03, -0.03, 0.03, 0, 0.03);
      b.box(-0.02, -0.045, -0.02, 0.02, -0.03, 0.015, mat: Mat.soft);
    },
  ),
  DeviceSpec(
    'contact',
    'Kontakt',
    height: 1.4,
    wall: true,
    build: (b) {
      b.box(-0.04, -0.015, -0.015, 0.0, 0, 0.015);
      b.box(0.006, -0.012, -0.012, 0.03, 0, 0.012);
    },
  ),
  DeviceSpec(
    'switch',
    'Schalter',
    height: 1.05,
    wall: true,
    build: (b) {
      b.box(-0.04, -0.012, -0.04, 0.04, 0, 0.04);
      b.box(-0.025, -0.018, -0.025, 0.025, -0.012, 0.025, mat: Mat.soft);
    },
  ),
  DeviceSpec(
    'plug',
    'Steckdose',
    height: 0.3,
    wall: true,
    build: (b) {
      b.box(-0.04, -0.01, -0.04, 0.04, 0, 0.04);
      b.box(-0.025, -0.06, -0.03, 0.025, -0.01, 0.03, mat: Mat.dark);
    },
  ),
  DeviceSpec(
    'speaker',
    'Lautsprecher',
    height: 0.6,
    build: (b) {
      b.box(-0.07, -0.07, 0, 0.07, 0.07, 0.24, mat: Mat.dark);
    },
  ),
  DeviceSpec(
    'device',
    'Gerät',
    height: 0.8,
    build: (b) => b.box(-0.04, -0.04, 0, 0.04, 0.04, 0.06),
  ),
];

/// Standard der Streuung: der Rand des Lichtkegels (Anteil des Winkels),
/// über den das Licht weich ausläuft.
const double kConeSoftness = 0.3;

/// Faktor des Lichtkegels [cone] (halber Winkel) für eine Richtung mit
/// [cosAngle] zur Achse: 1 im Kern, weich bis 0 am Rand. [softness] ist der
/// weiche Anteil am Winkel (0 hart … 1 von der Mitte an gleichmäßig).
double coneFactor(
  double cosAngle,
  double cone, [
  double softness = kConeSoftness,
]) {
  final a = math.acos(cosAngle.clamp(-1.0, 1.0));
  final inner = cone * (1 - softness.clamp(0.02, 1.0));
  if (a <= inner) return 1;
  if (a >= cone) return 0;
  final t = (a - inner) / (cone - inner);
  return 1 - t * t * (3 - 2 * t);
}
