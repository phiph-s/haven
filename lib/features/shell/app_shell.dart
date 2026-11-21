import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/adaptive/breakpoints.dart';
import '../../core/adaptive/desktop_sidebar.dart';
import '../../core/adaptive/hover.dart';
import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/accent_scope.dart';

/// Hülle mit schwebender Navigation: Zuhause, Karte, Netzwerk, Abläufe.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  static const tabs = <(IconData, IconData, String)>[
    (Icons.home_outlined, Icons.home_rounded, 'Zuhause'),
    (Icons.map_outlined, Icons.map_rounded, 'Karte'),
    (Icons.hub_outlined, Icons.hub_rounded, 'Netzwerk'),
    (Icons.auto_awesome_outlined, Icons.auto_awesome_rounded, 'Abläufe'),
  ];

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    // Desktop: Seitenleiste statt schwebender Leiste, sonst unverändert.
    if (context.isDesktopLayout) return _DesktopShell(shell: shell);
    return Scaffold(
      backgroundColor: hv.bg,
      body: Stack(
        children: [
          // Kein SafeArea hier: Jeder Tab legt seinen Inhalt selbst in die
          // sicheren Abstände (Router `_page`), Zuhause lässt den Glow
          // hinter der Statusleiste weiterlaufen.
          Positioned.fill(child: shell),
          Positioned(
            left: 14,
            right: 14,
            bottom: 18 + MediaQuery.of(context).padding.bottom,
            child: HavenNavBar(
              index: shell.currentIndex,
              onSelect: (i) {
                if (i != shell.currentIndex) HapticFeedback.selectionClick();
                shell.goBranch(i, initialLocation: i == shell.currentIndex);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Container für die Zweige: Der aktive blendet mit 14 px Versatz ein.
class BranchContainer extends StatefulWidget {
  const BranchContainer({
    super.key,
    required this.currentIndex,
    required this.children,
  });
  final int currentIndex;
  final List<Widget> children;

  @override
  State<BranchContainer> createState() => _BranchContainerState();
}

class _BranchContainerState extends State<BranchContainer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: HavenMotion.tabSwitch,
    value: 1,
  );

  @override
  void didUpdateWidget(BranchContainer old) {
    super.didUpdateWidget(old);
    if (old.currentIndex != widget.currentIndex) {
      if (context.reduceMotion) {
        _c.value = 1;
      } else {
        _c.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _c, curve: HavenMotion.out);
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          Offstage(
            offstage: i != widget.currentIndex,
            child: TickerMode(
              enabled: i == widget.currentIndex,
              child: i == widget.currentIndex
                  ? FadeTransition(
                      opacity: curve,
                      child: AnimatedBuilder(
                        animation: curve,
                        child: RepaintBoundary(child: widget.children[i]),
                        builder: (context, child) => Transform.translate(
                          offset: Offset(
                            0,
                            HavenMotion.tabOffset * (1 - curve.value),
                          ),
                          child: child,
                        ),
                      ),
                    )
                  : widget.children[i],
            ),
          ),
      ],
    );
  }
}

/// Schwebende Pille. Die Blase gleitet per Translation, die Farbe kommt aus
/// dem Akzent des aktiven Bildschirms.
class HavenNavBar extends StatelessWidget {
  const HavenNavBar({super.key, required this.index, required this.onSelect});
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final n = AppShell.tabs.length;
    return Container(
      height: 66,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: hv.s1.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(33),
        border: Border.all(color: hv.ln),
        boxShadow: hv.shadow,
      ),
      child: Stack(
        children: [
          FractionallySizedBox(
            widthFactor: 1 / n,
            child: AnimatedSlide(
              offset: Offset(index.toDouble(), 0),
              duration: context.motion(HavenMotion.d3),
              curve: HavenMotion.spring,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: hv.s3,
                  borderRadius: BorderRadius.circular(27),
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          Row(
            children: [
              for (var i = 0; i < n; i++)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: i == index,
                    label: AppShell.tabs[i].$3,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onSelect(i),
                      child: _NavItem(
                        icon: i == index
                            ? AppShell.tabs[i].$2
                            : AppShell.tabs[i].$1,
                        label: AppShell.tabs[i].$3,
                        selected: i == index,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
  });
  final IconData icon;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final color = selected ? hv.acc : hv.tx3;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AnimatedScale(
          scale: selected ? 1.08 : 1,
          duration: context.motion(HavenMotion.d3),
          curve: HavenMotion.spring,
          child: Icon(icon, size: 23, color: color),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: HavenText.caption.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
            fontSize: 10.5,
          ),
        ),
      ],
    );
  }
}

/// Desktop-Hülle: Seitenleiste links (ab [WindowClass.large] mit
/// Beschriftung), Inhalt rechts. Strg+1 bis 4 wechselt die Bereiche. Die
/// Seitenleiste trägt die Lichtfarbe der Wohnung.
class _DesktopShell extends ConsumerWidget {
  const _DesktopShell({required this.shell});
  final StatefulNavigationShell shell;

  void _go(int i) {
    if (i < 0 || i >= AppShell.tabs.length) return;
    shell.goBranch(i, initialLocation: i == shell.currentIndex);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final palette = ref.watch(houseViewProvider).palette(dark: hv.isDark);
    final ctrl = ctrlLabel(context);
    final digits = [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
    ];
    return CallbackShortcuts(
      bindings: {
        for (var i = 0; i < digits.length; i++) ...{
          SingleActivator(digits[i], control: true): () => _go(i),
          SingleActivator(digits[i], meta: true): () => _go(i),
        },
      },
      child: Scaffold(
        backgroundColor: hv.bg,
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AccentScope(
              palette: palette,
              child: DesktopSidebar(
                extended: context.windowClass == WindowClass.large,
                index: shell.currentIndex,
                onSelect: _go,
                items: [
                  for (var i = 0; i < AppShell.tabs.length; i++)
                    SidebarItem(
                      icon: AppShell.tabs[i].$1,
                      selectedIcon: AppShell.tabs[i].$2,
                      label: AppShell.tabs[i].$3,
                      shortcut: '$ctrl${i + 1}',
                    ),
                ],
                footer: [
                  Builder(
                    builder: (context) => SidebarButton(
                      icon: Icons.settings_outlined,
                      label: 'Einstellungen',
                      extended: context.windowClass == WindowClass.large,
                      onTap: () => context.push('/settings'),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: shell),
          ],
        ),
      ),
    );
  }
}
