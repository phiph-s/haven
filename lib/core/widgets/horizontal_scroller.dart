import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// Horizontale Liste, die sich auch am Desktop bedienen lässt.
///
/// Flutter scrollt horizontale Listen nur mit Touch, Trackpad oder
/// Shift+Mausrad. Hier gilt zusätzlich:
/// - Mausrad (vertikal) scrollt die Liste, solange sie noch Platz hat. Am Ende
///   bekommt die äußere Liste das Rad wieder, die Seite bleibt also bedienbar.
/// - Mit [mouseDrag] lässt sich die Liste mit gedrückter Maus ziehen. Aus, wenn
///   die Einträge selbst gezogen werden (z. B. Möbel in den Grundriss).
class HorizontalScroller extends StatefulWidget {
  const HorizontalScroller({
    super.key,
    required this.builder,
    this.mouseDrag = true,
  });

  /// Baut die Liste. Sie muss [ScrollController] verwenden.
  final Widget Function(BuildContext context, ScrollController controller)
  builder;
  final bool mouseDrag;

  @override
  State<HorizontalScroller> createState() => _HorizontalScrollerState();
}

class _HorizontalScrollerState extends State<HorizontalScroller> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_controller.hasClients) return;
    final d = event.scrollDelta;
    // Echte horizontale Bewegung (Trackpad, Shift) erledigt die Liste selbst.
    if (d.dy == 0 || d.dx.abs() > d.dy.abs()) return;
    final p = _controller.position;
    final target = (p.pixels + d.dy).clamp(
      p.minScrollExtent,
      p.maxScrollExtent,
    );
    if (target == p.pixels) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (_controller.hasClients) _controller.jumpTo(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    final behavior = ScrollConfiguration.of(context);
    return Listener(
      onPointerSignal: _onSignal,
      child: ScrollConfiguration(
        behavior: widget.mouseDrag
            ? behavior.copyWith(
                dragDevices: {...behavior.dragDevices, PointerDeviceKind.mouse},
              )
            : behavior,
        child: widget.builder(context, _controller),
      ),
    );
  }
}
