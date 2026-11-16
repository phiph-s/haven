import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';
import 'system_bars.dart';

/// Sheets, die von unten kommen (Raum, Lampenfarbe, Gerät, Auswahl).
///
/// Eine eigene Route statt `showModalBottomSheet`, damit sich alle Sheets
/// gleich anfühlen:
/// - Öffnen und Schließen mit Feder (`SpringSimulation`), beim Loslassen mit
///   der Geschwindigkeit des Fingers. Keine feste Kurve, deshalb folgt das
///   Sheet beim Ziehen exakt dem Finger.
/// - Ziehen am Griff (oder bei [HavenSheetSize.fit] überall) und am oberen
///   Ende des inneren Scrollens ([HavenSheetScope.scrollController]) bewegt
///   das Sheet. Schneller Wisch nach unten schließt, langsames Ziehen über
///   die Hälfte auch, sonst federt es zurück.
/// - Android-Zurück und Tippen auf den Schleier schließen ([PopupRoute]).
/// - [scalesBackground]: Die App dahinter rückt etwas zurück
///   ([SheetBackdrop]), wie bei Apple Home.
///
/// Der Wert der Route (`animation`) ist zugleich der Anteil der sichtbaren
/// Höhe: 0 zu, 1 offen. Pro Frame ändert sich nur eine Verschiebung.
enum HavenSheetSize {
  /// So hoch wie der Inhalt, höchstens bis knapp unter die Statusleiste.
  fit,

  /// Groß: etwa 92 % der Bildschirmhöhe (Raum).
  large,
}

/// Anteil, um den die App hinter einem großen Sheet zurückrückt (0 bis 1).
/// Nur ein großes Sheet treibt den Wert, verschachtelte Sheets nicht.
final ValueNotifier<double> sheetBackdropDepth = ValueNotifier(0);

/// Federn: Öffnen in etwa 300 ms mit leichtem Nachgeben, Schließen ohne
/// Überschwingen.
abstract final class SheetMotion {
  static final open = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 300,
    ratio: 0.9,
  );
  static final close = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 360,
    ratio: 1,
  );

  /// Ab dieser Geschwindigkeit (dp/s) entscheidet die Richtung.
  static const flingVelocity = 700.0;

  /// Unter diesem Anteil schließt das Loslassen.
  static const closeBelow = 0.5;

  /// Abstand nach oben bei [HavenSheetSize.large]: 8 % der Höhe, mindestens
  /// die Statusleiste plus 10 dp.
  static double largeTopGap(double height, double statusBar) =>
      (height * 0.08).clamp(statusBar + 10, double.infinity).toDouble();
}

/// Entscheidung beim Loslassen. [extent] 0 bis 1, [velocity] in dp/s, positiv
/// nach unten. Öffentlich für Tests.
bool sheetShouldClose(double extent, double velocity) {
  if (velocity > SheetMotion.flingVelocity) return true;
  if (velocity < -SheetMotion.flingVelocity) return false;
  return extent < SheetMotion.closeBelow;
}

/// Seite für go_router (Raum).
class HavenSheetPage<T> extends Page<T> {
  const HavenSheetPage({
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
    required this.child,
    this.size = HavenSheetSize.large,
    this.scalesBackground = false,
    this.initialExtent = 1,
  });

  final Widget child;
  final HavenSheetSize size;
  final bool scalesBackground;

  /// Nur für Screenshots (halb gezogen), sonst 1.
  final double initialExtent;

  @override
  Route<T> createRoute(BuildContext context) => HavenSheetRoute<T>(
    settings: this,
    builder: (_) => child,
    size: size,
    scalesBackground: scalesBackground,
    initialExtent: initialExtent,
  );
}

/// Öffnet ein Sheet über der ganzen App (Root-Navigator). Ersetzt
/// `showModalBottomSheet`: Theme und Akzentfarbe des Aufrufers kommen mit.
Future<T?> showHavenModalSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  HavenSheetSize size = HavenSheetSize.fit,
}) {
  final nav = Navigator.of(context, rootNavigator: true);
  final themes = InheritedTheme.capture(from: context, to: nav.context);
  return nav.push(
    HavenSheetRoute<T>(
      builder: (ctx) => themes.wrap(Builder(builder: builder)),
      size: size,
    ),
  );
}

class HavenSheetRoute<T> extends PopupRoute<T> {
  HavenSheetRoute({
    super.settings,
    required this.builder,
    this.size = HavenSheetSize.fit,
    this.scalesBackground = false,
    this.initialExtent = 1,
  });

  final WidgetBuilder builder;
  final HavenSheetSize size;
  final bool scalesBackground;
  final double initialExtent;

  /// Geschwindigkeit (Anteil pro Sekunde, negativ = zu) für das nächste
  /// Schließen, gesetzt beim Loslassen.
  double _closeVelocity = 0;

  @override
  Color? get barrierColor =>
      scalesBackground ? const Color(0x66000000) : const Color(0x80000000);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Schließen';

  @override
  Duration get transitionDuration => HavenMotion.d3;

  @override
  Duration get reverseTransitionDuration => HavenMotion.roomClose;

  @override
  bool get maintainState => true;

  /// Der Controller der Route, das Sheet zieht direkt daran.
  AnimationController get sheetController => controller!;

  bool get _reduceMotion {
    final ctx = navigator?.context;
    return ctx != null && (MediaQuery.maybeDisableAnimationsOf(ctx) ?? false);
  }

  @override
  AnimationController createAnimationController() {
    final c = super.createAnimationController();
    if (scalesBackground) {
      c.addListener(() => sheetBackdropDepth.value = c.value);
    }
    return c;
  }

  SpringSimulation _spring(
    SpringDescription d,
    double from,
    double to,
    double velocity,
  ) => SpringSimulation(
    d,
    from,
    to,
    velocity,
    tolerance: const Tolerance(distance: 0.0015, velocity: 0.02),
  );

  /// Öffnen und Schließen per Feder (Hook von [TransitionRoute]). Beim
  /// Schließen nach einem Wisch mit dessen Geschwindigkeit. Mit
  /// Bewegungsreduzierung die normale, kurze Dauer ohne Feder.
  @override
  Simulation? createSimulation({required bool forward}) {
    if (_reduceMotion) return null;
    final c = sheetController;
    if (forward) {
      return _spring(
        SheetMotion.open,
        c.value,
        initialExtent.clamp(0.05, 1.0),
        0,
      );
    }
    final v = _closeVelocity;
    _closeVelocity = 0;
    return _spring(SheetMotion.close, c.value, 0, v);
  }

  /// Startseite (Deep Link, Screenshot): ohne Animation, aber mit
  /// [initialExtent].
  @override
  void didAdd() {
    super.didAdd();
    if (initialExtent < 1) {
      sheetController.value = initialExtent.clamp(0.05, 1.0);
    }
  }

  /// Zurückfedern auf ganz offen.
  void settleOpen(double velocity) {
    final c = sheetController;
    if (_reduceMotion) {
      c.value = 1;
      return;
    }
    c.animateWith(_spring(SheetMotion.open, c.value, 1, velocity));
  }

  /// Schließen mit [velocity] (Anteil pro Sekunde, negativ = zu).
  void closeWith(double velocity) {
    if (!isActive) return;
    _closeVelocity = velocity.clamp(-12.0, 0.0);
    navigator?.pop();
  }

  @override
  void dispose() {
    if (scalesBackground) sheetBackdropDepth.value = 0;
    super.dispose();
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => _HavenSheetFrame(route: this);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

/// Zugriff aus dem Inhalt: Scroll-Controller (koordiniert mit dem Ziehen),
/// Schließen.
class HavenSheetScope extends InheritedWidget {
  const HavenSheetScope({
    super.key,
    required this.scrollController,
    required this.dragBy,
    required this.release,
    required this.close,
    required super.child,
  });

  /// Für das Scrollen im Sheet. Am oberen Ende übernimmt das Sheet.
  final ScrollController scrollController;

  /// Verschiebt das Sheet um dy (dp, positiv nach unten). Gibt zurück, was
  /// nicht verbraucht wurde (Sheet schon ganz offen).
  final double Function(double dy) dragBy;

  /// Loslassen mit Geschwindigkeit in dp/s (positiv nach unten).
  final void Function(double velocity) release;
  final VoidCallback close;

  static HavenSheetScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HavenSheetScope>();

  @override
  bool updateShouldNotify(HavenSheetScope old) =>
      old.scrollController != scrollController;
}

class _HavenSheetFrame extends StatefulWidget {
  const _HavenSheetFrame({required this.route});
  final HavenSheetRoute<dynamic> route;

  @override
  State<_HavenSheetFrame> createState() => _HavenSheetFrameState();
}

class _HavenSheetFrameState extends State<_HavenSheetFrame> {
  final _sheetKey = GlobalKey();
  late final SheetScrollController _scroll = SheetScrollController(
    extent: () => widget.route.sheetController.value,
    dragBy: _dragBy,
    release: _release,
  );
  bool _dragging = false;

  HavenSheetRoute<dynamic> get route => widget.route;

  double get _height {
    final s = _sheetKey.currentContext?.size?.height;
    return s == null || s < 1 ? 1 : s;
  }

  double _dragBy(double dy) {
    if (!route.isCurrent) return 0;
    final c = route.sheetController;
    if (!_dragging) {
      _dragging = true;
      c.stop();
    }
    final next = c.value - dy / _height;
    if (next > 1) {
      c.value = 1;
      return (next - 1) * _height * -1;
    }
    c.value = next.clamp(0.0, 1.0);
    return 0;
  }

  void _release(double velocity) {
    if (!_dragging) return;
    _dragging = false;
    if (!route.isCurrent) return;
    final c = route.sheetController;
    final v = -velocity / _height;
    if (sheetShouldClose(c.value, velocity)) {
      HapticFeedback.lightImpact();
      route.closeWith(v);
    } else if (c.value < 1) {
      route.settleOpen(v);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final large = route.size == HavenSheetSize.large;
    Widget sheet = KeyedSubtree(
      key: _sheetKey,
      child: RepaintBoundary(
        child: Material(
          type: MaterialType.transparency,
          child: HavenSheetScope(
            scrollController: _scroll,
            dragBy: _dragBy,
            release: _release,
            close: () => route.closeWith(0),
            child: Builder(builder: route.builder),
          ),
        ),
      ),
    );
    if (!large) {
      // Ziehen überall auf dem Sheet. Scrollbare Inhalte gewinnen die
      // Geste selbst und geben am oberen Ende über den Controller ab.
      sheet = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragUpdate: (d) => _dragBy(d.delta.dy),
        onVerticalDragEnd: (d) => _release(d.primaryVelocity ?? 0),
        onVerticalDragCancel: () => _release(0),
        child: sheet,
      );
    }
    return SystemBars(
      child: LayoutBuilder(
        builder: (context, cons) {
          final h = cons.maxHeight;
          final top = large
              ? SheetMotion.largeTopGap(h, media.padding.top)
              : media.padding.top + 24;
          return Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: h - top),
              child: AnimatedBuilder(
                animation: route.animation!,
                builder: (context, child) => FractionalTranslation(
                  translation: Offset(0, 1 - route.animation!.value),
                  child: child,
                ),
                child: large ? SizedBox(height: h - top, child: sheet) : sheet,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Griff oben im Sheet. Ziehen bewegt das Sheet, Tippen schließt nicht
/// (dafür gibt es den Schleier und Zurück).
class SheetGrabber extends StatelessWidget {
  const SheetGrabber({super.key, this.color});
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scope = HavenSheetScope.maybeOf(context);
    final hv = context.hv;
    return Semantics(
      label: 'Sheet ziehen zum Schließen',
      onDismiss: scope?.close,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: scope == null
            ? null
            : (d) => scope.dragBy(d.delta.dy),
        onVerticalDragEnd: scope == null
            ? null
            : (d) => scope.release(d.primaryVelocity ?? 0),
        onVerticalDragCancel: scope == null ? null : () => scope.release(0),
        child: SizedBox(
          height: 26,
          width: double.infinity,
          child: Center(
            child: Container(
              width: 40,
              height: 5,
              decoration: BoxDecoration(
                color: color ?? hv.tx3.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// App hinter einem großen Sheet: rückt leicht zurück und rundet die Ecken.
/// Der Baum bleibt immer gleich (kein Zustandsverlust), bei 0 ist es eine
/// Identität ohne Clip.
class SheetBackdrop extends StatelessWidget {
  const SheetBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: sheetBackdropDepth,
      child: child,
      builder: (context, v, child) {
        final t = v.clamp(0.0, 1.0);
        return Transform.scale(
          scale: 1 - 0.06 * t,
          alignment: const Alignment(0, 0.2),
          child: ClipRRect(
            clipBehavior: t == 0 ? Clip.none : Clip.antiAlias,
            borderRadius: BorderRadius.circular(30 * t),
            child: child,
          ),
        );
      },
    );
  }
}

/// Scroll-Controller für Inhalte im Sheet: Ziehen nach unten am oberen Ende
/// bewegt das Sheet, Ziehen nach oben bei nicht ganz offenem Sheet auch.
/// Das Prinzip wie bei `DraggableScrollableSheet`, nur dass das Sheet eine
/// Route ist.
class SheetScrollController extends ScrollController {
  SheetScrollController({
    required this.extent,
    required this.dragBy,
    required this.release,
  });

  final double Function() extent;
  final double Function(double dy) dragBy;
  final void Function(double velocity) release;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _SheetScrollPosition(
    owner: this,
    physics: physics.applyTo(const AlwaysScrollableScrollPhysics()),
    context: context,
    oldPosition: oldPosition,
  );
}

class _SheetScrollPosition extends ScrollPositionWithSingleContext {
  _SheetScrollPosition({
    required this.owner,
    required super.physics,
    required super.context,
    super.oldPosition,
  });

  final SheetScrollController owner;
  bool _sheetDrag = false;

  @override
  void applyUserOffset(double delta) {
    // delta > 0: Finger nach unten.
    final atTop = pixels <= minScrollExtent;
    if (_sheetDrag ||
        (delta > 0 && atTop) ||
        (delta < 0 && owner.extent() < 1)) {
      _sheetDrag = true;
      final rest = owner.dragBy(delta);
      if (rest != 0) {
        // Ganz offen: der Rest scrollt den Inhalt.
        _sheetDrag = false;
        owner.release(0);
        super.applyUserOffset(rest);
      }
      return;
    }
    super.applyUserOffset(delta);
  }

  @override
  void goBallistic(double velocity) {
    if (_sheetDrag) {
      _sheetDrag = false;
      // velocity: positiv = Inhalt nach oben (Finger nach oben).
      owner.release(-velocity);
      super.goBallistic(0);
      return;
    }
    super.goBallistic(velocity);
  }

  @override
  void dispose() {
    if (_sheetDrag) owner.release(0);
    super.dispose();
  }
}
