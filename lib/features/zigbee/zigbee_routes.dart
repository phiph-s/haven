import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/router/router.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/system_bars.dart';
import 'mesh/mesh_screen.dart';
import 'zigbee_device_screen.dart';
import 'zigbee_pair_screen.dart';

/// Von rechts hereinschieben, die Seite darunter bleibt stehen.
Page<void> _slide(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      transitionDuration: HavenMotion.pageIn,
      reverseTransitionDuration: HavenMotion.pageOut,
      child: _Bg(child: child),
      transitionsBuilder: (context, animation, secondary, child) =>
          SlideTransition(
            position: Tween(begin: const Offset(1, 0), end: Offset.zero)
                .animate(
                  CurvedAnimation(parent: animation, curve: HavenMotion.out),
                ),
            child: SystemBars(child: child),
          ),
    );

/// Unterseiten von Zigbee (Gerät, Anlernen). Werden unter `/zigbee` eingehängt.
/// Beide ohne Navigation, deshalb im Root-Navigator.
final List<RouteBase> zigbeeRoutes = <RouteBase>[
  GoRoute(
    path: 'device/:ieee',
    parentNavigatorKey: rootNavigatorKey,
    pageBuilder: (context, state) =>
        _slide(state, ZigbeeDeviceScreen(ieee: state.pathParameters['ieee']!)),
  ),
  GoRoute(
    path: 'mesh',
    parentNavigatorKey: rootNavigatorKey,
    pageBuilder: (context, state) => _slide(
      state,
      ZigbeeMeshScreen(select: state.uri.queryParameters['select']),
    ),
  ),
  GoRoute(
    path: 'pair',
    parentNavigatorKey: rootNavigatorKey,
    pageBuilder: (context, state) => _slide(state, const ZigbeePairScreen()),
  ),
];

class _Bg extends StatelessWidget {
  const _Bg({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: context.hv.bg, child: child);
}
