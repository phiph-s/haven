import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';
import 'hover.dart';
import '../widgets/haven_logo.dart';

/// Eintrag der Seitenleiste.
@immutable
class SidebarItem {
  const SidebarItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.shortcut,
  });
  final IconData icon;
  final IconData selectedIcon;
  final String label;

  /// Tastenkürzel als Hinweis im Tooltip.
  final String? shortcut;
}

/// Navigation am Desktop: schmale Leiste mit Symbolen ([extended] `false`)
/// oder breite Seitenleiste mit Beschriftung. Die aktive Seite trägt den
/// Akzent (Lichtfarbe der Wohnung, wenn die Hülle sie setzt).
class DesktopSidebar extends StatelessWidget {
  const DesktopSidebar({
    super.key,
    required this.items,
    required this.index,
    required this.onSelect,
    this.extended = false,
    this.footer = const [],
  });

  final List<SidebarItem> items;
  final int index;
  final ValueChanged<int> onSelect;
  final bool extended;

  /// Unten, z. B. Einstellungen.
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Container(
      width: extended ? 232 : 96,
      decoration: BoxDecoration(
        color: hv.s1.withValues(alpha: hv.isDark ? 0.55 : 0.7),
        border: Border(right: BorderSide(color: hv.ln)),
      ),
      child: SafeArea(
        right: false,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: extended ? 14 : 12,
            vertical: 18,
          ),
          child: Column(
            crossAxisAlignment: extended
                ? CrossAxisAlignment.stretch
                : CrossAxisAlignment.center,
            children: [
              _Brand(extended: extended),
              const SizedBox(height: 26),
              for (var i = 0; i < items.length; i++) ...[
                SidebarButton(
                  icon: i == index ? items[i].selectedIcon : items[i].icon,
                  label: items[i].label,
                  shortcut: items[i].shortcut,
                  selected: i == index,
                  extended: extended,
                  onTap: () => onSelect(i),
                ),
                const SizedBox(height: 6),
              ],
              const Spacer(),
              ...footer,
            ],
          ),
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.extended});
  final bool extended;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    const mark = HavenLogo(size: 40);
    if (!extended) return mark;
    return Row(
      children: [
        mark,
        const SizedBox(width: 12),
        Text(
          'Haven',
          style: HavenText.headline.copyWith(color: hv.tx, fontSize: 20),
        ),
      ],
    );
  }
}

/// Knopf der Seitenleiste mit Hover, Tooltip (schmal) und Auswahl.
class SidebarButton extends StatelessWidget {
  const SidebarButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.extended = false,
    this.shortcut,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final bool extended;
  final String? shortcut;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final color = selected ? hv.acc : hv.tx2;
    Widget child = HoverBuilder(
      builder: (context, hover) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: context.motion(HavenMotion.d2),
          curve: HavenMotion.out,
          height: extended ? 46 : 56,
          width: extended ? double.infinity : 78,
          padding: EdgeInsets.symmetric(horizontal: extended ? 14 : 0),
          decoration: BoxDecoration(
            color: selected
                ? hv.s3
                : (hover ? hoverOverlay(hv, true) : hv.s3.withValues(alpha: 0)),
            borderRadius: BorderRadius.circular(HavenRadii.s + 2),
          ),
          child: extended
              ? Row(
                  children: [
                    Icon(icon, size: 22, color: color),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        label,
                        style: HavenText.label.copyWith(
                          color: selected ? hv.tx : hv.tx2,
                          fontSize: 14.5,
                        ),
                      ),
                    ),
                  ],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 23, color: color),
                    const SizedBox(height: 3),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: HavenText.caption.copyWith(
                        color: color,
                        fontWeight: FontWeight.w700,
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
    child = Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: child,
    );
    if (extended && shortcut == null) return child;
    return DesktopTooltip(
      message: label,
      shortcut: shortcut,
      preferBelow: false,
      child: child,
    );
  }
}
