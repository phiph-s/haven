import 'package:material_ui/material_ui.dart';

import '../adaptive/hover.dart';
import '../theme/tokens.dart';

/// Karte auf s1 mit Haarlinie und weichem Schatten.
class HavenCard extends StatelessWidget {
  const HavenCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.radius = HavenRadii.l,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final box = DecoratedBox(
      decoration: BoxDecoration(
        color: hv.s1,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: hv.ln),
        boxShadow: hv.shadowSmall,
      ),
      child: Padding(padding: padding, child: child),
    );
    if (onTap == null) return box;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: box,
    );
  }
}

/// Runder 48-dp-Knopf mit 42 dp sichtbarer Fläche (Kopfzeile).
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    required this.label,
    this.active = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    // Desktop: Tooltip mit der Beschriftung, Hover hebt den Rand an. Auf
    // Touch bleibt alles wie bisher.
    return DesktopTooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: HoverBuilder(
          builder: (context, hover) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: SizedBox(
              width: HavenSpace.touch,
              height: HavenSpace.touch,
              child: Center(
                child: AnimatedContainer(
                  duration: context.motion(HavenMotion.d2),
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: active
                        ? hv.acc
                        : Color.alphaBlend(hoverOverlay(hv, hover), hv.s1),
                    border: Border.all(color: hover ? hv.ln2 : hv.ln),
                    boxShadow: hv.shadowSmall,
                  ),
                  child: Icon(icon, size: 21, color: active ? hv.ai : hv.tx),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
