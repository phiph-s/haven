import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';
import 'breakpoints.dart';

/// Hover-Zustand für Maus und Trackpad. Auf Touch passiert nichts, Mobile
/// bleibt also unverändert. [cursor] ist die Mausform über dem Element.
class HoverBuilder extends StatefulWidget {
  const HoverBuilder({
    super.key,
    required this.builder,
    this.cursor = SystemMouseCursors.click,
    this.onHover,
  });

  final Widget Function(BuildContext context, bool hovered) builder;
  final MouseCursor cursor;
  final ValueChanged<bool>? onHover;

  @override
  State<HoverBuilder> createState() => _HoverBuilderState();
}

class _HoverBuilderState extends State<HoverBuilder> {
  bool _hover = false;

  void _set(bool v) {
    if (_hover == v) return;
    setState(() => _hover = v);
    widget.onHover?.call(v);
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.cursor,
    onEnter: (_) => _set(true),
    onExit: (_) => _set(false),
    child: widget.builder(context, _hover),
  );
}

/// Leichter Schleier über einer Fläche beim Hovern (Textfarbe, 5 bzw. 7 %).
Color hoverOverlay(HavenColors hv, bool hovered) => hovered
    ? hv.tx.withValues(alpha: hv.isDark ? 0.07 : 0.05)
    : const Color(0x00000000);

/// Tooltip im Haven-Stil, nur im Desktop-Layout (auf dem Handy würde er beim
/// langen Drücken mit anderen Gesten konkurrieren).
class DesktopTooltip extends StatelessWidget {
  const DesktopTooltip({
    super.key,
    required this.message,
    required this.child,
    this.shortcut,
    this.preferBelow,
  });

  final String message;

  /// Tastenkürzel, z. B. `Strg+Z`, erscheint leiser hinter dem Text.
  final String? shortcut;
  final bool? preferBelow;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!context.isDesktopLayout || message.isEmpty) return child;
    final hv = context.hv;
    final style = HavenText.caption.copyWith(
      color: hv.bg,
      fontWeight: FontWeight.w700,
      fontSize: 12,
    );
    return Tooltip(
      richMessage: TextSpan(
        children: [
          TextSpan(text: message, style: style),
          if (shortcut != null)
            TextSpan(
              text: '   $shortcut',
              style: style.copyWith(
                color: hv.bg.withValues(alpha: 0.62),
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
      waitDuration: const Duration(milliseconds: 450),
      preferBelow: preferBelow,
      excludeFromSemantics: true,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: hv.tx.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(HavenRadii.s - 4),
      ),
      child: child,
    );
  }
}

/// Plattformgerechte Bezeichnung der Strg-Taste (`⌘` auf Apple).
String ctrlLabel(BuildContext context) {
  final p = Theme.of(context).platform;
  return p == TargetPlatform.macOS || p == TargetPlatform.iOS ? '⌘' : 'Strg+';
}
