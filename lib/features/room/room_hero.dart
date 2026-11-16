import 'package:material_ui/material_ui.dart';

import '../../core/light/room_palette.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/animated_palette.dart';

/// Kachel-Look: Fläche s1, Haarlinie, Glow über die ganze Fläche.
class TileSurface extends StatelessWidget {
  const TileSurface({
    super.key,
    required this.palette,
    this.radius = HavenRadii.l,
    this.shadow = true,
  });

  final RoomPalette palette;
  final double radius;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final r = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: hv.s1,
        borderRadius: r,
        border: Border.all(color: hv.ln),
        boxShadow: shadow ? hv.shadowSmall : null,
      ),
      child: MeshGlow(palette: palette, borderRadius: r),
    );
  }
}

/// Seiten-Look: Hintergrund mit weichem Licht oben.
class RoomPageBackdrop extends StatelessWidget {
  const RoomPageBackdrop({super.key, required this.palette});
  final RoomPalette palette;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return ColoredBox(
      color: hv.bg,
      child: Align(
        alignment: Alignment.topCenter,
        child: FractionallySizedBox(
          heightFactor: 0.6,
          widthFactor: 1,
          child: MeshGlow(palette: palette, style: MeshStyle.ambient),
        ),
      ),
    );
  }
}
