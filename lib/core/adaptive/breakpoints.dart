import 'package:material_ui/material_ui.dart';

/// Fensterklassen nach Breite (logische Pixel). Eine Stelle für alle
/// Entscheidungen „Handy oder Desktop“.
///
/// - [compact] unter 600: Handy hochkant.
/// - [medium] 600 bis unter 1000: Tablet, Handy quer. Noch das Handy-Layout
///   (untere Leiste, Sheets), nur breiter.
/// - [expanded] ab 1000: Desktop-Layout mit Seitenleiste, mehrspaltig, Raum
///   als Seitenpanel, Inspektor rechts.
/// - [large] ab 1360: wie [expanded], die Seitenleiste zeigt Beschriftungen.
enum WindowClass {
  compact,
  medium,
  expanded,
  large;

  static const double mediumMin = 600;
  static const double expandedMin = 1000;
  static const double largeMin = 1360;

  static WindowClass of(double width) {
    if (width >= largeMin) return large;
    if (width >= expandedMin) return expanded;
    if (width >= mediumMin) return medium;
    return compact;
  }

  /// Desktop-Layout (Seitenleiste, Spalten, Seitenpanels).
  bool get isDesktop => index >= expanded.index;
}

/// Feste Maße des Desktop-Layouts.
abstract final class DesktopMetrics {
  /// Seitenleiste ohne bzw. mit Beschriftung.
  static const double railWidth = 96;
  static const double sidebarWidth = 232;

  /// Rechte Spalte (Widgets, Inspektor, Editor-Bibliothek).
  static const double sideColumn = 360;

  /// Raum als Seitenpanel.
  static const double roomPanel = 480;

  /// Listen in Master-Detail.
  static const double masterWidth = 420;

  /// Inhalte, die nicht über die ganze Breite laufen sollen (Einstellungen,
  /// Sheets).
  static const double readableWidth = 720;

  /// Mindestbreite einer Raumkachel im Raster.
  static const double roomTileMin = 236;
}

extension AdaptiveContext on BuildContext {
  WindowClass get windowClass => WindowClass.of(MediaQuery.sizeOf(this).width);

  /// `true` ab [WindowClass.expanded].
  bool get isDesktopLayout => windowClass.isDesktop;

  /// Platz unten für die schwebende Navigation. Auf dem Desktop gibt es sie
  /// nicht, dort reicht ein normaler Rand.
  double get navClearance => isDesktopLayout ? 28 : 120;
}

/// Spaltenzahl für ein Raster mit Elementen von mindestens [minItem] Breite.
int gridColumns(
  double width, {
  required double minItem,
  double spacing = 12,
  int min = 1,
  int max = 6,
}) {
  if (width <= 0) return min;
  final n = ((width + spacing) / (minItem + spacing)).floor();
  return n.clamp(min, max);
}

/// Baut je nach Fensterklasse ein anderes Widget, ohne zweites App-Gerüst:
/// Die Features geben ihre Handy-Fassung als [compact] und die Desktop-Fassung
/// als [desktop], beide teilen Provider und Logik.
class AdaptiveLayout extends StatelessWidget {
  const AdaptiveLayout({super.key, required this.compact, this.desktop});

  final WidgetBuilder compact;
  final WidgetBuilder? desktop;

  @override
  Widget build(BuildContext context) {
    final d = desktop;
    if (d != null && context.isDesktopLayout) return d(context);
    return compact(context);
  }
}

/// Am Desktop mittig auf lesbare Breite begrenzt (Einstellungen, Updates),
/// auf dem Handy unverändert.
class ReadableWidth extends StatelessWidget {
  const ReadableWidth({
    super.key,
    required this.child,
    this.maxWidth = DesktopMetrics.readableWidth,
    this.background,
  });

  final Widget child;
  final double maxWidth;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    if (!context.isDesktopLayout) return child;
    return ColoredBox(
      color: background ?? Theme.of(context).scaffoldBackgroundColor,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      ),
    );
  }
}
