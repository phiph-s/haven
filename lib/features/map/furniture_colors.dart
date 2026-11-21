import 'package:haven_3d/haven_3d.dart' as h3;
import 'package:material_ui/material_ui.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';

/// Eine Farbe der Möbelpalette.
@immutable
class FurnitureColor {
  const FurnitureColor(this.name, this.color);
  final String name;
  final Color color;
}

/// Möbelfarben: gedämpfte Töne, die hell und dunkel, bei Tag, Nacht und
/// Lampenlicht ruhig bleiben (keine reinen, gesättigten Farben). Eigene
/// Farben sind trotzdem möglich (`FloorFurniture.withColor`).
const List<FurnitureColor> kFurniturePalette = [
  FurnitureColor('Kreide', Color(0xFFF2EFE8)),
  FurnitureColor('Creme', Color(0xFFE6DCC8)),
  FurnitureColor('Leinen', Color(0xFFD4C8B4)),
  FurnitureColor('Sand', Color(0xFFC8B596)),
  FurnitureColor('Eiche', Color(0xFFC49A6C)),
  FurnitureColor('Nussbaum', Color(0xFF7B5B45)),
  FurnitureColor('Terrakotta', Color(0xFFB86B4F)),
  FurnitureColor('Altrosa', Color(0xFFC79A96)),
  FurnitureColor('Senf', Color(0xFFC9A04A)),
  FurnitureColor('Salbei', Color(0xFF93A68A)),
  FurnitureColor('Olive', Color(0xFF6F7A4E)),
  FurnitureColor('Petrol', Color(0xFF3F6B70)),
  FurnitureColor('Rauchblau', Color(0xFF61758A)),
  FurnitureColor('Nachtblau', Color(0xFF2F3E56)),
  FurnitureColor('Steingrau', Color(0xFF8E9096)),
  FurnitureColor('Anthrazit', Color(0xFF3B3F45)),
];

/// Einfärbbare Teile eines Möbelstücks der Art [kind] (aus dem 3D-Katalog).
List<h3.ColorZone> furnitureZones(String kind) => h3.furnitureSpec(kind).zones;

/// Einfärbbare Teile einer Gerätebauform (z. B. Fernseher).
List<h3.ColorZone> deviceZones(String model) => h3.deviceSpec(model).zones;

/// Standardfarbe einer Zone (wie ohne eigene Farbe, heller Stil).
Color defaultZoneColor(h3.ColorZone zone) =>
    h3.SceneStyle.light().base(zone.mat);

/// Name einer Palettenfarbe oder `null` (eigene Farbe).
String? furnitureColorName(Color c) {
  for (final p in kFurniturePalette) {
    if (p.color.toARGB32() == c.toARGB32()) return p.name;
  }
  return null;
}

/// Kleine Farbwahl für den Inspektor: Zonen als Chips, darunter die Palette
/// und „Standard“. [onChanged] bekommt Zone und Farbe (`null`: Standard).
class FurnitureColorPicker extends StatefulWidget {
  const FurnitureColorPicker({
    super.key,
    required this.zones,
    required this.colors,
    required this.onChanged,
  });

  final List<h3.ColorZone> zones;
  final Map<String, Color> colors;
  final void Function(String zone, Color? color) onChanged;

  @override
  State<FurnitureColorPicker> createState() => _FurnitureColorPickerState();
}

class _FurnitureColorPickerState extends State<FurnitureColorPicker> {
  String? _zone;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    if (widget.zones.isEmpty) return const SizedBox.shrink();
    final zone = widget.zones.firstWhere(
      (z) => z.id == _zone,
      orElse: () => widget.zones.first,
    );
    final current = widget.colors[zone.id];
    Widget swatch(Color c, {required bool selected, String? tooltip}) =>
        Tooltip(
          message: tooltip ?? '',
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? hv.acc : hv.tx3.withValues(alpha: 0.35),
                width: selected ? 2.5 : 1,
              ),
            ),
          ),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.zones.length > 1)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final z in widget.zones)
                _ZoneChip(
                  label: z.label,
                  color: widget.colors[z.id] ?? defaultZoneColor(z),
                  selected: z.id == zone.id,
                  onTap: () => setState(() => _zone = z.id),
                ),
            ],
          ),
        if (widget.zones.length > 1) const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            InkResponse(
              onTap: () {
                Haptics.tap();
                widget.onChanged(zone.id, null);
              },
              child: swatch(
                defaultZoneColor(zone),
                selected: current == null,
                tooltip: 'Standard',
              ),
            ),
            for (final p in kFurniturePalette)
              InkResponse(
                onTap: () {
                  Haptics.tap();
                  widget.onChanged(zone.id, p.color);
                },
                child: swatch(
                  p.color,
                  selected: current?.toARGB32() == p.color.toARGB32(),
                  tooltip: p.name,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Teil eines Möbelstücks als Pille mit seiner aktuellen Farbe.
class _ZoneChip extends StatelessWidget {
  const _ZoneChip({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          Haptics.tick();
          onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.fromLTRB(6, 5, 12, 5),
          decoration: BoxDecoration(
            color: selected ? hv.acc.withValues(alpha: 0.12) : hv.s1,
            borderRadius: BorderRadius.circular(HavenRadii.pill),
            border: Border.all(
              color: selected ? hv.acc : hv.ln2,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: hv.tx3.withValues(alpha: 0.35)),
                ),
              ),
              const SizedBox(width: 7),
              Text(
                label,
                style: HavenText.caption.copyWith(
                  color: hv.tx,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
