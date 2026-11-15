import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';

/// Platzhalter beim Laden statt Spinner: Flächen in der Form des späteren
/// Inhalts, die sanft pulsieren. Ein Controller für alle Kinder
/// ([Skeleton] sucht den nächsten), nur FadeTransition, kein Neubau pro
/// Frame. Mit Bewegungsreduzierung steht das Pulsieren still.
class SkeletonScope extends StatefulWidget {
  const SkeletonScope({super.key, required this.child, this.label = 'Lädt'});
  final Widget child;

  /// Für Screenreader.
  final String label;

  @override
  State<SkeletonScope> createState() => _SkeletonScopeState();
}

class _SkeletonScopeState extends State<SkeletonScope>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    lowerBound: 0.45,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.reduceMotion) {
      _c.value = 0.7;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.label,
      liveRegion: true,
      excludeSemantics: true,
      child: FadeTransition(
        opacity: _c,
        child: RepaintBoundary(child: widget.child),
      ),
    );
  }
}

/// Eine graue Fläche im Skeleton.
class Skeleton extends StatelessWidget {
  const Skeleton({
    super.key,
    this.width,
    this.height = 14,
    this.radius = HavenRadii.s,
    this.circle = false,
  });

  final double? width;
  final double height;
  final double radius;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Container(
      width: circle ? height : width,
      height: height,
      decoration: BoxDecoration(
        color: hv.s3,
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : BorderRadius.circular(radius),
      ),
    );
  }
}

/// Zeile wie ein Listeneintrag: Symbol, zwei Textzeilen.
class SkeletonRow extends StatelessWidget {
  const SkeletonRow({super.key, this.titleWidth = 160});
  final double titleWidth;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          const Skeleton(height: 40, circle: true),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Skeleton(width: titleWidth, height: 14),
              const SizedBox(height: 8),
              const Skeleton(width: 90, height: 11),
            ],
          ),
        ],
      ),
    );
  }
}
