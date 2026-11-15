import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../features/automations/automations_routes.dart';
import '../../features/automations/automations_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/map/map_routes.dart';
import '../../features/map/map_screen.dart';
import '../../features/onboarding/onboarding_screen.dart';
import '../../features/room/room_hero.dart';
import '../../features/room/room_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/shell/app_shell.dart';
import '../../features/zigbee/zigbee_routes.dart';
import '../../features/zigbee/zigbee_screen.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/system_bars.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'root',
);

/// Seitenpfade. Debug-Parameter (`?theme=`, `?screen=`) stehen in debug_launch.dart.
abstract final class Routes {
  static const onboarding = '/onboarding';
  static const home = '/home';
  static const map = '/map';
  static const zigbee = '/zigbee';
  static const automations = '/automations';
  static const settings = '/settings';
  static String room(String id) => '/room/$id';
}

/// Raum: Der Übergang steckt in `RoomReveal` (RoomScreen), die Seite wächst
/// aus der Kachel. `opaque`: Nach dem Öffnen baut und malt Zuhause nicht mehr
/// mit, während des Übergangs bleibt es sichtbar.
Page<void> _roomPage(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      transitionDuration: HavenMotion.roomOpen,
      reverseTransitionDuration: HavenMotion.roomClose,
      child: child,
      transitionsBuilder: (context, animation, secondary, child) =>
          SystemBars(child: child),
    );

/// Push-Seiten kommen von rechts, die alte Seite rückt ein Stück mit.
Page<void> _slidePage(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      transitionDuration: HavenMotion.pageIn,
      reverseTransitionDuration: HavenMotion.pageOut,
      child: child,
      transitionsBuilder: (context, animation, secondary, child) =>
          SlideTransition(
            position: Tween(begin: const Offset(1, 0), end: Offset.zero)
                .animate(
                  CurvedAnimation(
                    parent: animation,
                    curve: HavenMotion.out,
                    reverseCurve: Curves.easeInCubic,
                  ),
                ),
            child: SystemBars(child: child),
          ),
    );

/// Tab-Seite: Hintergrund bis unter die Statusleiste, Inhalt im sicheren
/// Bereich. Mit [safeTop] `false` kümmert sich der Bildschirm selbst darum
/// (Zuhause: Glow läuft hinter der Statusleiste weiter).
Widget _page(BuildContext context, Widget child, {bool safeTop = true}) =>
    SystemBars(
      child: ColoredBox(
        color: context.hv.bg,
        child: safeTop ? SafeArea(bottom: false, child: child) : child,
      ),
    );

GoRouter buildRouter(Ref ref, {String? initialLocation}) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(sessionProvider.select((s) => s.mode), (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: initialLocation ?? Routes.home,
    refreshListenable: refresh,
    redirect: (context, state) {
      final mode = ref.read(sessionProvider).mode;
      final onboarding = state.matchedLocation == Routes.onboarding;
      if (mode == SessionMode.none) {
        return onboarding ? null : Routes.onboarding;
      }
      if (onboarding) return Routes.home;
      return null;
    },
    routes: [
      GoRoute(
        path: Routes.onboarding,
        builder: (context, state) => const OnboardingScreen(),
      ),
      StatefulShellRoute(
        builder: (context, state, shell) => AppShell(shell: shell),
        navigatorContainerBuilder: (context, shell, children) =>
            BranchContainer(
              currentIndex: shell.currentIndex,
              children: children,
            ),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.home,
                builder: (c, s) => _page(c, const HomeScreen(), safeTop: false),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.map,
                builder: (c, s) => _page(c, const MapScreen()),
                routes: mapRoutes,
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.zigbee,
                builder: (c, s) => _page(c, const ZigbeeScreen()),
                routes: zigbeeRoutes,
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.automations,
                builder: (c, s) => _page(c, const AutomationsScreen()),
                routes: automationsRoutes,
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/room/:id',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => _roomPage(
          state,
          Material(
            type: MaterialType.transparency,
            child: RoomScreen(
              roomId: state.pathParameters['id']!,
              origin: originFromExtra(state.extra),
              // Nur für Screenshots mit den Entwicklungsdaten (siehe debug_launch.dart).
              autoSheet:
                  state.uri.queryParameters['sheet'] == '1' &&
                  ref.read(sessionProvider).mode == SessionMode.fake,
            ),
          ),
        ),
      ),
      GoRoute(
        path: Routes.settings,
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) =>
            _slidePage(state, const SettingsScreen()),
      ),
    ],
  );
}

/// Der Router hängt an der Sitzung: ohne Modus geht es ins Onboarding.
final routerProvider = Provider.family<GoRouter, String?>(
  (ref, initial) => buildRouter(ref, initialLocation: initial),
);
