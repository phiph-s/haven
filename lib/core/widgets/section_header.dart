import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';

/// Abschnittstitel (Section 21/800) mit optionalem Link rechts.
class SectionHeader extends StatelessWidget {
  const SectionHeader(
    this.title, {
    super.key,
    this.trailing,
    this.padding = EdgeInsets.zero,
  });

  final String title;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(title, style: HavenText.section.copyWith(color: hv.tx)),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Textknopf mit 48-dp-Zielgröße.
class TextLink extends StatelessWidget {
  const TextLink(this.label, {super.key, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: HavenSpace.touch,
          minWidth: HavenSpace.touch,
        ),
        child: Center(
          child: Text(
            label,
            style: HavenText.label.copyWith(color: context.hv.tx2),
          ),
        ),
      ),
    );
  }
}
