import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';
import 'press_scale.dart';

/// Breiter Knopf, 56 dp hoch. Primär mit Akzent, sonst neutral.
class HavenButton extends StatelessWidget {
  const HavenButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.primary = false,
    this.busy = false,
    this.destructive = false,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool primary;
  final bool busy;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final bg = primary ? hv.acc : hv.s2;
    final fg = primary ? hv.ai : (destructive ? hv.bad : hv.tx);
    return Semantics(
      button: true,
      enabled: onTap != null && !busy,
      label: label,
      child: PressScale(
        onTap: busy ? null : onTap,
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: onTap == null ? hv.s3 : bg,
            borderRadius: BorderRadius.circular(HavenRadii.m),
            border: primary ? null : Border.all(color: hv.ln2),
            boxShadow: primary ? hv.shadowSmall : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.5, color: fg),
                )
              else ...[
                if (icon != null) ...[
                  Icon(icon, size: 20, color: fg),
                  const SizedBox(width: 10),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HavenText.label.copyWith(color: fg, fontSize: 15.5),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
