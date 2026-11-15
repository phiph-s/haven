import 'package:material_ui/material_ui.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/press_scale.dart';

/// Schmaler Fortschrittsbalken. [value] `null` zeigt einen laufenden Balken
/// ohne Wert.
class UpdateProgressBar extends StatelessWidget {
  const UpdateProgressBar({super.key, this.value, this.color});
  final double? value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 6,
        child: LinearProgressIndicator(
          value: value?.clamp(0.0, 1.0),
          minHeight: 6,
          backgroundColor: hv.s3,
          color: color ?? hv.acc,
        ),
      ),
    );
  }
}

/// Kompakter Knopf für Karten: 40 dp sichtbar, 48 dp Trefferfläche.
class SmallButton extends StatelessWidget {
  const SmallButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.primary = false,
    this.accent,
    this.onAccent,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool primary;

  /// Akzentfarben, sonst die des Themes.
  final Color? accent;
  final Color? onAccent;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final enabled = onTap != null;
    final bg = primary ? (accent ?? hv.acc) : hv.s2;
    final fg = primary ? (onAccent ?? hv.ai) : hv.tx;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: PressScale(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: HavenSpace.touch),
          child: Center(
            widthFactor: 1,
            child: Opacity(
              opacity: enabled ? 1 : 0.5,
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(HavenRadii.pill),
                  border: primary ? null : Border.all(color: hv.ln2),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 18, color: fg),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      label,
                      style: HavenText.label.copyWith(color: fg, fontSize: 14),
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
