import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/router/router.dart' show rootNavigatorKey;
import '../../core/theme/tokens.dart';
import '../../core/widgets/system_bars.dart';
import '../ha_web/ha_web_screen.dart';
import 'ha_automations_screen.dart';
import 'knob_dashboard_screen.dart';
import 'knob_editor_screen.dart';
import 'motion_dashboard_screen.dart';
import 'motion_editor_screen.dart';

/// Von rechts hereinschieben (Vollbild ohne Navigation).
Page<void> _slide(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      transitionDuration: HavenMotion.pageIn,
      reverseTransitionDuration: HavenMotion.pageOut,
      child: child,
      transitionsBuilder: (context, animation, secondary, child) =>
          SlideTransition(
            position: Tween(begin: const Offset(1, 0), end: Offset.zero)
                .animate(
                  CurvedAnimation(parent: animation, curve: HavenMotion.out),
                ),
            child: SystemBars(child: child),
          ),
    );

/// Unterseiten der Abläufe. Werden unter `/automations` eingehängt.
///
/// - `/automations/ha?path=/config/automation/edit/<id>&title=...` öffnet die
///   eingebettete HA-Oberfläche im Vollbild (auch aus den Einstellungen).
/// - `/automations/home-assistant`: Liste der HA-Automationen.
/// - `/automations/knob/new?room=<area>&step=<0..6>`: Drehregler-Assistent
///   (`demo=1` füllt den Live-Test für Screenshots).
/// - `/automations/knob/<id>?step=`: Dashboard der bestehenden Automation,
///   `step` öffnet gleich den Abschnitt (0 bis 4) bzw. den Live-Test (5).
///   Mit `wizard=1` stattdessen alle Schritte im Assistenten.
/// - `/automations/motion/new?room=&step=` bzw. `/automations/motion/<id>`:
///   Bewegungslicht-Assistent bzw. -Dashboard, sonst wie beim Drehregler.
final List<RouteBase> automationsRoutes = <RouteBase>[
  GoRoute(
    path: 'ha',
    parentNavigatorKey: rootNavigatorKey,
    pageBuilder: (context, state) {
      final q = state.uri.queryParameters;
      return _slide(
        state,
        HaWebScreen(path: q['path'] ?? '/', title: q['title']),
      );
    },
  ),
  GoRoute(
    path: 'home-assistant',
    parentNavigatorKey: rootNavigatorKey,
    pageBuilder: (context, state) => _slide(state, const HaAutomationsScreen()),
  ),
  GoRoute(
    path: 'knob/:id',
    parentNavigatorKey: rootNavigatorKey,
    pageBuilder: (context, state) {
      final id = state.pathParameters['id']!;
      final q = state.uri.queryParameters;
      final step = int.tryParse(q['step'] ?? '');
      if (id != 'new' && q['wizard'] != '1') {
        return _slide(
          state,
          KnobDashboardScreen(
            id: id,
            initialStep: step,
            demo: q['demo'] == '1',
          ),
        );
      }
      return _slide(
        state,
        KnobEditorScreen(
          id: id == 'new' ? null : id,
          initialRoom: q['room'],
          initialStep: step,
          demo: q['demo'] == '1',
        ),
      );
    },
  ),
  GoRoute(
    path: 'motion/:id',
    parentNavigatorKey: rootNavigatorKey,
    pageBuilder: (context, state) {
      final id = state.pathParameters['id']!;
      final q = state.uri.queryParameters;
      final step = int.tryParse(q['step'] ?? '');
      if (id != 'new' && q['wizard'] != '1') {
        return _slide(
          state,
          MotionDashboardScreen(
            id: id,
            initialStep: step,
            demo: q['demo'] == '1',
          ),
        );
      }
      return _slide(
        state,
        MotionEditorScreen(
          id: id == 'new' ? null : id,
          initialRoom: q['room'],
          initialStep: step,
          demo: q['demo'] == '1',
        ),
      );
    },
  ),
];
