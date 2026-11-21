import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// Strecke, ab der ein Mausklick auf einen Marker zum Ziehen wird.
///
/// [Draggable] zieht mit der Maus schon ab 1 px. Ein normaler Klick wackelt
/// oft um ein, zwei Pixel (Touchpad erst recht), dann gewinnt das Ziehen
/// und der Klick wählt nichts aus. Finger behalten die übliche Schwelle.
const double kMarkerMouseDragSlop = 6;

/// [Draggable] mit [kMarkerMouseDragSlop] für Maus und Touchpad.
class MarkerDraggable<T extends Object> extends Draggable<T> {
  const MarkerDraggable({
    super.key,
    required super.child,
    required super.feedback,
    super.data,
    super.childWhenDragging,
    super.dragAnchorStrategy,
    super.onDragStarted,
    super.onDragUpdate,
    super.onDragEnd,
  });

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) =>
      _SlopDragRecognizer(allowedButtonsFilter: allowedButtonsFilter)
        ..onStart = onStart;
}

class _SlopDragRecognizer extends MultiDragGestureRecognizer {
  _SlopDragRecognizer({super.allowedButtonsFilter}) : super(debugOwner: null);

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) =>
      _SlopPointerState(event.position, event.kind, gestureSettings);

  @override
  String get debugDescription => 'marker drag';
}

class _SlopPointerState extends MultiDragPointerState {
  _SlopPointerState(super.initialPosition, super.kind, super.gestureSettings);

  @override
  void checkForResolutionAfterMove() {
    final slop = switch (kind) {
      PointerDeviceKind.mouse ||
      PointerDeviceKind.trackpad => kMarkerMouseDragSlop,
      _ => computeHitSlop(kind, gestureSettings),
    };
    if (pendingDelta!.distance > slop) resolve(GestureDisposition.accepted);
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) =>
      starter(initialPosition);
}
