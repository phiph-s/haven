import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/router/router.dart' show rootNavigatorKey;
import '../../core/theme/tokens.dart';
import '../../core/widgets/system_bars.dart';
import '../ha_web/ha_web_screen.dart';

/// Unterseiten der Abläufe. Werden unter `/automations` eingehängt.
///
/// `/automations/ha?path=/config/automation/edit/<id>&title=...` öffnet die
/// eingebettete HA-Oberfläche im Vollbild (auch aus den Einstellungen).
final List<RouteBase> automationsRoutes = <RouteBase>[
  GoRoute(
    path: 'ha',
    parentNavigatorKey: rootNavigatorKey,
    pageBuilder: (context, state) {
      final q = state.uri.queryParameters;
      return CustomTransitionPage<void>(
        key: state.pageKey,
        transitionDuration: HavenMotion.pageIn,
        reverseTransitionDuration: HavenMotion.pageOut,
        child: HaWebScreen(path: q['path'] ?? '/', title: q['title']),
        transitionsBuilder: (context, animation, secondary, child) =>
            SlideTransition(
              position: Tween(begin: const Offset(1, 0), end: Offset.zero)
                  .animate(
                    CurvedAnimation(parent: animation, curve: HavenMotion.out),
                  ),
              child: SystemBars(child: child),
            ),
      );
    },
  ),
];
