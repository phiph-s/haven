import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../features/automations/automations_routes.dart';
import '../../features/automations/automations_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/map/map_routes.dart';
import '../../features/map/map_screen.dart';
import '../../features/onboarding/onboarding_screen.dart';
import '../../features/room/room_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/shell/app_shell.dart';
import '../../features/updates/updates_screen.dart';
import '../../features/zigbee/zigbee_routes.dart';
import '../../features/zigbee/zigbee_screen.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/haven_sheet.dart';
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
  static const updates = '/settings/updates';

  /// Raum als Sheet über der aktuellen Seite. Unter Zuhause eingehängt,
  /// damit ein Deep Link Zuhause dahinter hat. `/room/<id>` leitet um.
  static String room(String id) => '/home/room/$id';
}

/// Raum: Sheet von unten (`HavenSheetPage`), die App dahinter rückt zurück.
/// `extent` (nur Entwicklungsdaten) öffnet halb gezogen für Screenshots.
Page<void> _roomPage(Ref ref, GoRouterState state) {
  final fake = ref.read(sessionProvider).mode == SessionMode.fake;
  final q = state.uri.queryParameters;
  return HavenSheetPage<void>(
    key: state.pageKey,
    name: state.name,
    scalesBackground: true,
    initialExtent: fake ? (double.tryParse(q['extent'] ?? '') ?? 1) : 1,
    child: RoomScreen(
      roomId: state.pathParameters['id']!,
      // Nur für Screenshots mit den Entwicklungsdaten (siehe debug_launch.dart).
      autoSheet: q['sheet'] == '1' && fake,
    ),
  );
}

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
        builder: (context, state, shell) =>
            SheetBackdrop(child: AppShell(shell: shell)),
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
                routes: [
                  GoRoute(
                    path: 'room/:id',
                    parentNavigatorKey: rootNavigatorKey,
                    pageBuilder: (context, state) => _roomPage(ref, state),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.map,
                builder: (c, s) => _page(
                  c,
                  MapScreen(
                    // Nur für Screenshots (debug_launch.dart).
                    startMenu: s.uri.queryParameters['menu'] == '1',
                    startMinutes: double.tryParse(
                      s.uri.queryParameters['t'] ?? '',
                    ),
                  ),
                ),
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
      // Alte Adresse des Raums (Links, Screenshots).
      GoRoute(
        path: '/room/:id',
        redirect: (context, state) => Uri(
          path: Routes.room(state.pathParameters['id']!),
          queryParameters: state.uri.queryParameters.isEmpty
              ? null
              : state.uri.queryParameters,
        ).toString(),
      ),
      GoRoute(
        path: Routes.settings,
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) =>
            _slidePage(state, const SettingsScreen()),
        routes: [
          GoRoute(
            path: 'updates',
            parentNavigatorKey: rootNavigatorKey,
            pageBuilder: (context, state) =>
                _slidePage(state, const UpdatesScreen()),
          ),
        ],
      ),
    ],
  );
}

/// Der Router hängt an der Sitzung: ohne Modus geht es ins Onboarding.
final routerProvider = Provider.family<GoRouter, String?>(
  (ref, initial) => buildRouter(ref, initialLocation: initial),
);
