import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/tokens.dart';

import 'map_layers.dart';

/// Auftrag an die Karte, etwa aus der Suche: ein Gerät ([nodeId], Entity
/// der Platzierung) oder einen Raum ([roomId], Plan-Raum) zeigen, optional
/// in einer bestimmten Kartenart. Die offene Karte führt ihn aus und leert
/// ihn wieder.
class MapJump {
  const MapJump({this.nodeId, this.roomId, this.layer});
  final String? nodeId;
  final String? roomId;
  final MapLayer? layer;
}

class MapJumpNotifier extends Notifier<MapJump?> {
  @override
  MapJump? build() => null;

  void request(MapJump j) => state = j;

  /// Erledigt (nur, wenn es noch derselbe Auftrag ist).
  void done(MapJump j) {
    if (identical(state, j)) state = null;
  }
}

final mapJumpProvider = NotifierProvider<MapJumpNotifier, MapJump?>(
  MapJumpNotifier.new,
);

/// Ring um einen Gerätepunkt, der ein paar Mal nach außen läuft: „hier“.
class PulseRing extends StatefulWidget {
  const PulseRing({super.key, required this.child});
  final Widget child;

  @override
  State<PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<PulseRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.hv.acc;
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        IgnorePointer(
          child: AnimatedBuilder(
            animation: _t,
            builder: (context, _) {
              final k = Curves.easeOutCubic.transform(_t.value);
              return Container(
                width: 28 + 44 * k,
                height: 28 + 44 * k,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: c.withValues(alpha: 0.9 * (1 - k)),
                    width: 3,
                  ),
                  color: c.withValues(alpha: 0.18 * (1 - k)),
                ),
              );
            },
          ),
        ),
        widget.child,
      ],
    );
  }
}
