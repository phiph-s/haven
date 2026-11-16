import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/press_scale.dart';

/// Kartenarten. Die gewählte Art merkt sich die App lokal.
enum MapLayer {
  combo('Kombi', Icons.layers_rounded, 'combo'),
  light('Licht', Icons.lightbulb_rounded, 'lamps'),
  temperature('Temperatur', Icons.thermostat_rounded, 'temperature'),
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

/// Schwebende Auswahl der Kartenart: zugeklappt ein runder Knopf mit dem
/// Symbol der aktiven Art, aufgeklappt fächern die Arten darunter auf
/// (Feder, versetzt). Ein Tippen daneben klappt wieder zu.
class MapLayerPicker extends StatefulWidget {
  const MapLayerPicker({
    super.key,
    required this.layer,
    required this.onChanged,
    this.accent,
    this.startOpen = false,
    this.onOpenChanged,
  });

  final MapLayer layer;
  final ValueChanged<MapLayer> onChanged;

  /// Farbe der aktiven Art (Lichtfarbe der Wohnung), sonst Akzent.
  final Color? accent;
  final bool startOpen;
  final ValueChanged<bool>? onOpenChanged;

  @override
  State<MapLayerPicker> createState() => MapLayerPickerState();
}

class MapLayerPickerState extends State<MapLayerPicker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    reverseDuration: const Duration(milliseconds: 220),
    value: widget.startOpen ? 1 : 0,
  );

  bool get open => _c.value > 0 && _c.status != AnimationStatus.reverse;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void toggle() {
    Haptics.tick();
    if (open) {
      close();
    } else {
      _c.duration = context.motion(const Duration(milliseconds: 420));
      if (_c.duration == Duration.zero) {
        _c.value = 1;
      } else {
        _c.forward();
      }
      setState(() {});
      widget.onOpenChanged?.call(true);
    }
  }

  void close() {
    _c.reverseDuration = context.motion(const Duration(milliseconds: 220));
    if (_c.reverseDuration == Duration.zero) {
      _c.value = 0;
    } else {
      _c.reverse();
    }
    setState(() {});
    widget.onOpenChanged?.call(false);
  }

  void _pick(MapLayer l) {
    Haptics.tap();
    widget.onChanged(l);
    close();
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final acc = widget.accent ?? hv.acc;
    final items = [
      for (final l in MapLayer.values)
        if (l != widget.layer) l,
    ];
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _MainButton(
              layer: widget.layer,
              accent: acc,
              t: HavenMotion.out.transform(t),
              onTap: toggle,
            ),
            if (t > 0)
              for (var i = 0; i < items.length; i++)
                _staggered(
                  i,
                  items.length,
                  t,
                  _Item(layer: items[i], onTap: () => _pick(items[i])),
                ),
          ],
        );
      },
    );
  }

  Widget _staggered(int i, int n, double t, Widget child) {
    // Jede Zeile startet etwas später, Federkurve mit leichtem Überschwingen.
    final start = i / (n + 2) * 0.55;
    final local = ((t - start) / (1 - start)).clamp(0.0, 1.0);
    final v =
        (_c.status == AnimationStatus.reverse
                ? HavenMotion.out
                : HavenMotion.spring)
            .transform(local);
    return IgnorePointer(
      ignoring: !open,
      child: Opacity(
        opacity: local.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, -18 * (1 - v) * (i + 1)),
          child: Transform.scale(
            scale: 0.6 + 0.4 * v,
            alignment: Alignment.centerRight,
            child: child,
          ),
        ),
      ),
    );
  }
}

class _MainButton extends StatelessWidget {
  const _MainButton({
    required this.layer,
    required this.accent,
    required this.t,
    required this.onTap,
  });
  final MapLayer layer;
  final Color accent;
  final double t;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      button: true,
      expanded: t > 0.5,
      label: 'Kartenart: ${layer.label}',
      excludeSemantics: true,
      child: PressScale(
        onTap: onTap,
        child: SizedBox(
          height: 56,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Name der aktiven Art erscheint beim Aufklappen.
              ClipRect(
                child: Align(
                  alignment: Alignment.centerRight,
                  widthFactor: t,
                  child: Opacity(
                    opacity: t,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _Label(text: layer.label, strong: true),
                    ),
                  ),
                ),
              ),
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent,
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: hv.isDark ? 0.45 : 0.35),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Opacity(
                      opacity: 1 - t,
                      child: Icon(layer.icon, size: 24, color: _on(accent)),
                    ),
                    Opacity(
                      opacity: t,
                      child: Transform.rotate(
                        angle: (1 - t) * -1.2,
                        child: Icon(
                          Icons.close_rounded,
                          size: 24,
                          color: _on(accent),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Color _on(Color c) => c.computeLuminance() > 0.45
    ? const Color(0xFF17121F)
    : const Color(0xFFFFFFFF);

class _Item extends StatelessWidget {
  const _Item({required this.layer, required this.onTap});
  final MapLayer layer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      button: true,
      label: layer.label,
      excludeSemantics: true,
      child: PressScale(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Label(text: layer.label),
              const SizedBox(width: 8),
              Container(
                width: 46,
                height: 46,
                margin: const EdgeInsets.only(right: 3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: hv.s1,
                  border: Border.all(color: hv.ln2),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF000000)
                          .withValues(alpha: hv.isDark ? 0.4 : 0.1),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Icon(layer.icon, size: 21, color: hv.tx),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label({required this.text, this.strong = false});
  final String text;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: hv.s1,
        borderRadius: BorderRadius.circular(HavenRadii.pill),
        border: Border.all(color: hv.ln2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF000000)
                .withValues(alpha: hv.isDark ? 0.35 : 0.08),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Text(
        text,
        maxLines: 1,
        style: HavenText.label.copyWith(
          color: strong ? hv.tx : hv.tx2,
          fontSize: 13,
        ),
      ),
    );
  }
}
