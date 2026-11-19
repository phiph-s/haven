import 'package:material_ui/material_ui.dart';

import '../../../core/light/color_math.dart';
import '../../../core/light/room_palette.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/press_scale.dart';
import '../../../data/models/room.dart';

/// Szene als farbige Karte. Aktiv: angehoben mit Häkchen. Braucht die
/// Szene einen Abgleich ([RoomScene.needsSync]), steht oben links ein Punkt.
class SceneCard extends StatelessWidget {
  const SceneCard({
    super.key,
    required this.scene,
    required this.active,
    required this.onTap,
    this.onEdit,
  });

  final RoomScene scene;
  final bool active;
  final VoidCallback onTap;

  /// Langes Drücken und Rechtsklick: Szene bearbeiten.
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final c = scene.colors.map(colorOf).toList();
    final mid = (
      (scene.colors[0].$1 + scene.colors[1].$1) ~/ 2,
      (scene.colors[0].$2 + scene.colors[1].$2) ~/ 2,
      (scene.colors[0].$3 + scene.colors[1].$3) ~/ 2,
    );
    final fg = colorOf(onColorFor(mid));
    final sub = scene.brightness == 0
        ? 'Aus'
        : scene.kelvin != null
        ? '${scene.kelvin} K'
        : '${scene.brightness} %';
    return Semantics(
      button: true,
      selected: active,
      label: 'Szene ${scene.name}',
      value: scene.needsSync ? 'Abgleich nötig' : null,
      onLongPressHint: onEdit == null ? null : 'Bearbeiten',
      child: GestureDetector(
        onSecondaryTap: onEdit,
        child: PressScale(
          onTap: onTap,
          onLongPress: onEdit,
          pressedScale: 0.9,
          child: AnimatedSlide(
            offset: Offset(0, active ? -0.04 : 0),
            duration: context.motion(HavenMotion.d3),
            curve: HavenMotion.spring,
            child: Container(
              width: 132,
              height: 92,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(HavenRadii.m),
                gradient: LinearGradient(
                  begin: const Alignment(-0.7, -1),
                  end: const Alignment(0.7, 1),
                  colors: [c[0], c[1], c[2]],
                  stops: const [0, 0.62, 1],
                ),
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: c[0].withValues(alpha: 0.45),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                      ]
                    : context.hv.shadowSmall,
              ),
              child: DefaultTextStyle.merge(
                style: TextStyle(color: fg),
                child: Stack(
                  children: [
                    if (scene.needsSync)
                      Align(
                        alignment: Alignment.topLeft,
                        child: SceneSyncDot(ring: fg.withValues(alpha: 0.85)),
                      ),
                    Align(
                      alignment: Alignment.topRight,
                      child: AnimatedScale(
                        scale: active ? 1 : 0,
                        duration: context.motion(HavenMotion.d3),
                        curve: HavenMotion.spring,
                        child: Icon(
                          Icons.check_circle_rounded,
                          size: 22,
                          color: fg,
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.bottomLeft,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            scene.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HavenText.label.copyWith(
                              color: fg,
                              fontSize: 15,
                            ),
                          ),
                          Text(
                            sub,
                            style: HavenText.caption.copyWith(
                              color: fg.withValues(alpha: 0.8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Hinweispunkt: Szene neu abgleichen (Karte, Knopf).
class SceneSyncDot extends StatelessWidget {
  const SceneSyncDot({super.key, this.size = 10, this.ring});
  final double size;
  final Color? ring;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: context.hv.warn,
      shape: BoxShape.circle,
      border: ring == null ? null : Border.all(color: ring!, width: 1.5),
    ),
  );
}
