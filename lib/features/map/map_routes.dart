import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/router/router.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/system_bars.dart';
import 'floor_editor_screen.dart';

/// Pfad des Grundriss-Editors (Vollbild, ohne Navigation).
const String mapEditorPath = '/map/editor';

/// Unterseiten der Karte. Werden unter `/map` eingehängt.
final List<RouteBase> mapRoutes = <RouteBase>[
  GoRoute(
    path: 'editor',
    parentNavigatorKey: rootNavigatorKey,
    pageBuilder: (context, state) => CustomTransitionPage<void>(
      key: state.pageKey,
      transitionDuration: HavenMotion.pageIn,
      reverseTransitionDuration: HavenMotion.pageOut,
      child: FloorEditorScreen(
        // Nur für Screenshots (debug_launch.dart): mode=devices, sel=<Raum>.
        startInDevices: state.uri.queryParameters['mode'] == 'devices',
        startSelected: state.uri.queryParameters['sel'],
      ),
      transitionsBuilder: (context, animation, secondary, child) =>
          SlideTransition(
            position: Tween(begin: const Offset(1, 0), end: Offset.zero)
                .animate(
                  CurvedAnimation(parent: animation, curve: HavenMotion.out),
                ),
            child: SystemBars(child: child),
          ),
    ),
  ),
];
