import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';
import 'breakpoints.dart';

/// Seitenpanel am Desktop: kommt von rechts über die App, darunter ein
/// leichter Schleier. Esc, Klick daneben und Zurück schließen. Ersetzt am
/// Desktop das Sheet von unten (z. B. für den Raum).
class SidePanelPage<T> extends Page<T> {
  const SidePanelPage({
    super.key,
    super.name,
    super.arguments,
    required this.child,
    this.width = DesktopMetrics.roomPanel,
    this.barrierLabel = 'Schließen',
  });

  final Widget child;
  final double width;
  final String barrierLabel;

  @override
  Route<T> createRoute(BuildContext context) => SidePanelRoute<T>(
    settings: this,
    width: width,
    label: barrierLabel,
    builder: (_) => child,
  );
}

class SidePanelRoute<T> extends PopupRoute<T> {
  SidePanelRoute({
    super.settings,
    required this.builder,
    this.width = DesktopMetrics.roomPanel,
    this.label = 'Schließen',
  });

  final WidgetBuilder builder;
  final double width;
  final String label;

  @override
  Color? get barrierColor => const Color(0x52000000);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => label;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 320);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 220);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final media = MediaQuery.of(context);
    final w = width.clamp(320.0, media.size.width - 120);
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          0,
          12 + media.padding.top,
          12,
          12 + media.padding.bottom,
        ),
        child: SizedBox(
          width: w,
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            removeBottom: true,
            child: RepaintBoundary(
              child: Material(
                type: MaterialType.transparency,
                // Esc schließt, auch wenn der Fokus noch nirgends liegt.
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.escape): () =>
                        Navigator.of(context).maybePop(),
                  },
                  child: Focus(autofocus: true, child: builder(context)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (context.reduceMotion) return child;
    final curve = CurvedAnimation(
      parent: animation,
      curve: HavenMotion.out,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: Tween(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: animation, curve: const Interval(0, 0.6)),
      ),
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0.12, 0),
          end: Offset.zero,
        ).animate(curve),
        child: child,
      ),
    );
  }
}
