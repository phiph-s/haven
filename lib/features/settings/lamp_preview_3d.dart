import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven_3d/haven_3d.dart' as h3;
import 'package:material_ui/material_ui.dart';

import '../../core/light/color_math.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/segmented.dart';
import '../../data/models/lamp.dart';
import '../../data/models/lamp_calibration.dart';
import '../map/map_3d.dart' show lampStateOf, map3dSupportedProvider;

/// Leuchten der Beispielszene.
const List<String> kPreviewLampIds = ['vorschau_decke', 'vorschau_steh'];

/// Kleines Beispielzimmer (3 × 3 m, frei erfunden): Sofa, Sessel, Tisch,
/// Teppich, Deckenleuchte und Stehleuchte. Eine Instanz für die ganze App,
/// damit der Controller die gebackene Szene behält.
final h3.Scene calibrationPreviewScene = () {
  var n = 0;
  h3.SceneObject f(
    String kind,
    double x,
    double y,
    double w,
    double d, [
    double rot = 0,
  ]) => h3.SceneObject.furniture(
    id: '${kind}_${n++}',
    kind: kind,
    center: Offset(x, y),
    w: w,
    d: d,
    rotation: rot,
  );
  return h3.Scene(
    rooms: [
      h3.SceneRoom(
        id: 'vorschau',
        outline: const [Offset(0, 0), Offset(3, 0), Offset(3, 3), Offset(0, 3)],
      ),
    ],
    objects: [
      f('rug', 1.4, 1.6, 2.0, 1.4),
      f('sofa', 1.4, 0.5, 2.0, 0.85),
      f('coffee_table', 1.4, 1.6, 1.0, 0.55),
      f('armchair', 2.45, 2.2, 0.85, 0.85, 270),
      f('plant', 0.35, 2.65, 0.45, 0.45),
    ],
    markers: [
      h3.SceneMarker(
        id: kPreviewLampIds[0],
        model: 'ceiling',
        at: const Offset(1.1, 2.1),
        kind: h3.MarkerKind.light,
        lamp: h3.LampState.off,
      ),
      h3.SceneMarker(
        id: kPreviewLampIds[1],
        model: 'floor_lamp',
        at: const Offset(2.65, 0.4),
        kind: h3.MarkerKind.light,
        lamp: h3.LampState.off,
      ),
    ],
  );
}();

/// Feste Kamera schräg von oben (der Ausschnitt passt sich der Größe an).
const h3.OrbitCamera kPreviewCamera = h3.OrbitCamera(yaw: -0.55, pitch: 0.95);

/// Licht der Beispiellampe bei [kelvin] und [level] Prozent, wie eine Lampe
/// des Typs es meldet: mit [calibration] so, wie Haven es anzeigt
/// ([Lamp.displayColor], [Lamp.displayLevel]), ohne wie bisher.
h3.LampState previewLampState({
  required int kelvin,
  required int level,
  required bool hasKelvin,
  LampCalibration calibration = LampCalibration.none,
}) => lampStateOf(
  Lamp(
    entityId: kPreviewLampIds.first,
    name: '',
    on: true,
    brightness: level.clamp(1, 100),
    color: kelvinToRgb(hasKelvin ? kelvin : assumedWhiteKelvin),
    kelvin: hasKelvin ? kelvin : null,
    supportsKelvin: hasKelvin,
    colorMode: hasKelvin ? 'color_temp' : null,
    calibration: calibration,
  ),
);

/// 3D-Vorschau der Kalibrierung: das Beispielzimmer mit dem gewählten
/// Weißton und der Helligkeit, umschaltbar zwischen gemeldet und
/// korrigiert. Gebacken wird einmal, Wechsel laufen über
/// [h3.SceneController.setLamp]. Ohne 3D (etwa Browser ohne WebGL2) bleibt
/// sie weg.
class LampPreview3D extends ConsumerStatefulWidget {
  const LampPreview3D({
    super.key,
    required this.calibration,
    required this.kelvin,
    required this.level,
    required this.hasKelvin,
    this.height = 210,
  });

  final LampCalibration calibration;
  final int kelvin;
  final int level;
  final bool hasKelvin;
  final double height;

  @override
  ConsumerState<LampPreview3D> createState() => _LampPreview3DState();
}

class _LampPreview3DState extends ConsumerState<LampPreview3D> {
  final h3.SceneController _ctrl = h3.SceneController(kPreviewCamera);
  bool _corrected = true;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _apply() {
    final s = previewLampState(
      kelvin: widget.kelvin,
      level: widget.level,
      hasKelvin: widget.hasKelvin,
      calibration: _corrected ? widget.calibration : LampCalibration.none,
    );
    for (final id in kPreviewLampIds) {
      _ctrl.setLamp(id, s);
    }
  }

  @override
  Widget build(BuildContext context) {
    final supported = ref.watch(map3dSupportedProvider).value ?? false;
    if (!supported) return const SizedBox.shrink();
    _apply();
    final hv = context.hv;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(HavenRadii.m),
          child: ColoredBox(
            color: const Color(0xFF101114),
            child: SizedBox(
              height: widget.height,
              child: Semantics(
                image: true,
                label: _corrected
                    ? 'Beispielzimmer mit Korrektur'
                    : 'Beispielzimmer wie bisher',
                child: h3.Scene3DView(
                  scene: calibrationPreviewScene,
                  controller: _ctrl,
                  style: h3.SceneStyle.evening(),
                  quality: h3.SceneQuality.medium,
                  gestures: h3.SceneGestures.none,
                  lightReach: h3.LightReach.room,
                  // Nur das Licht der Leuchten, keine Gerätepunkte.
                  markers: const [],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        HavenSegmented<bool>(
          options: const [(false, 'Gemeldet'), (true, 'Korrigiert')],
          selected: _corrected,
          onChanged: (v) => setState(() => _corrected = v),
          neutral: true,
        ),
        const SizedBox(height: 6),
        Text(
          widget.hasKelvin
              ? '${widget.kelvin} K, ${widget.level} %. Gemeldet zeigt, was '
                    'Home Assistant meldet, korrigiert, wie Haven es anzeigt.'
              : '${widget.level} %. Gemeldet zeigt, was Home Assistant '
                    'meldet, korrigiert, wie Haven es anzeigt.',
          style: HavenText.caption.copyWith(color: hv.tx2),
        ),
      ],
    );
  }
}
