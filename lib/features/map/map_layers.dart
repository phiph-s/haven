import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/adaptive/hover.dart';
import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';

/// Kartenarten. Die gewählte Art merkt sich die App lokal.
enum MapLayer {
  combo('Kombi', Icons.layers_rounded, 'combo'),
  light('Licht', Icons.lightbulb_rounded, 'lamps'),
  temperature('Klima', Icons.thermostat_rounded, 'temperature'),
  humidity('Luftfeuchte', Icons.water_drop_rounded, 'humidity'),
  presence('Bewegung', Icons.directions_walk_rounded, 'presence'),
  network('Funknetz', Icons.hub_rounded, 'network'),
  battery('Batterie', Icons.battery_5_bar_rounded, 'battery');

  const MapLayer(this.label, this.icon, this.storeName);
  final String label;
  final IconData icon;

  /// Schlüssel im lokalen Speicher. „light“ stand früher für die Kartenart,
  /// die jetzt „Kombi“ heißt. Das neue „Licht“ speichert deshalb als „lamps“,
  /// ein alter Eintrag „light“ wird zu Kombi.
  final String storeName;

  static MapLayer fromName(String? name) {
    if (name == 'light') return combo;
    for (final l in values) {
      if (l.storeName == name) return l;
    }
    return combo;
  }
}

class MapLayerNotifier extends Notifier<MapLayer> {
  @override
  MapLayer build() =>
      MapLayer.fromName(ref.read(settingsStoreProvider).mapLayer);

  void set(MapLayer layer) {
    if (layer == state) return;
    state = layer;
    unawaited(ref.read(settingsStoreProvider).setMapLayer(layer.storeName));
  }
}

final mapLayerProvider = NotifierProvider<MapLayerNotifier, MapLayer>(
  MapLayerNotifier.new,
);

/// Auswahl der Kartenart als Tab-Leiste: ein Tipp wechselt die Art.
///
/// Die Leiste ist immer so breit wie ihr Platz, ein Wechsel ändert nur die
/// Aufteilung. [compact] (Handy): die anderen Tabs zeigen nur ihr Symbol, der
/// aktive bekommt den Rest mit Namen. Sonst sind alle Tabs gleich breit und
/// tragen Symbol und Namen.
class MapLayerTabs extends StatelessWidget {
  const MapLayerTabs({
    super.key,
    required this.layer,
    required this.onChanged,
    this.compact = false,
  });

  final MapLayer layer;
  final ValueChanged<MapLayer> onChanged;
  final bool compact;

  /// Breite eines Tabs nur mit Symbol.
  static const double iconTab = 32;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final n = MapLayer.values.length;
    return Container(
      height: 44,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: hv.s1.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: hv.ln),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          final active = compact
              ? math.max(iconTab, w - (n - 1) * iconTab)
              : w / n;
          final other = compact ? iconTab : w / n;
          return Row(
            children: [
              for (final l in MapLayer.values)
                _Tab(
                  layer: l,
                  width: l == layer ? active : other,
                  active: l == layer,
                  showLabel: !compact || l == layer,
                  onTap: () {
                    if (l == layer) return;
                    Haptics.tick();
                    onChanged(l);
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.layer,
    required this.width,
    required this.active,
    required this.showLabel,
    required this.onTap,
  });
  final MapLayer layer;
  final double width;
  final bool active;
  final bool showLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final fg = active ? _on(hv.acc) : hv.tx2;
    return DesktopTooltip(
      message: layer.label,
      child: Semantics(
        button: true,
        selected: active,
        label: 'Kartenart ${layer.label}',
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: context.motion(HavenMotion.d2),
            curve: HavenMotion.out,
            width: width,
            height: 38,
            decoration: BoxDecoration(
              color: active ? hv.acc : const Color(0x00000000),
              borderRadius: BorderRadius.circular(19),
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: hv.acc.withValues(alpha: hv.isDark ? 0.4 : 0.3),
                        blurRadius: 12,
                      ),
                    ]
                  : null,
            ),
            child: ClipRect(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(layer.icon, size: 20, color: fg),
                  if (showLabel)
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 5),
                        child: Text(
                          layer.label,
                          maxLines: 1,
                          overflow: TextOverflow.fade,
                          softWrap: false,
                          style: HavenText.label.copyWith(
                            color: fg,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Color _on(Color c) => c.computeLuminance() > 0.45
    ? const Color(0xFF17121F)
    : const Color(0xFFFFFFFF);
