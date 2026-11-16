import 'package:material_ui/material_ui.dart';

import '../../core/adaptive/hover.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../data/models/floor_plan.dart';
import 'furniture_painter.dart';

/// Möbel-Bibliothek des Editors: Kategorien und Elemente als Skizze.
///
/// [grid]: Desktop, alle Kategorien untereinander als Raster. Sonst (Handy)
/// Kategorie-Chips und eine waagerechte Leiste.
/// [onAdd] setzt das Element in die Mitte (Tippen, Klick), [dragWrap] macht
/// es ziehbar (der Editor kennt die Zeichenfläche).
class FurnitureLibrary extends StatefulWidget {
  const FurnitureLibrary({
    super.key,
    required this.onAdd,
    required this.dragWrap,
    this.grid = false,
    this.cellMeters = 0.5,
  });

  final ValueChanged<FurnitureType> onAdd;
  final Widget Function(FurnitureType type, Widget child) dragWrap;
  final bool grid;
  final double cellMeters;

  @override
  State<FurnitureLibrary> createState() => _FurnitureLibraryState();
}

class _FurnitureLibraryState extends State<FurnitureLibrary> {
  FurnitureCategory _cat = FurnitureCategory.living;

  List<FurnitureType> _of(FurnitureCategory c) => [
    for (final t in kFurnitureCatalog)
      if (t.category == c) t,
  ];

  Widget _tile(FurnitureType t, {double width = 84}) => widget.dragWrap(
    t,
    LibraryTile(
      type: t,
      width: width,
      cellMeters: widget.cellMeters,
      onTap: () {
        Haptics.tap();
        widget.onAdd(t);
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    if (widget.grid) {
      return LayoutBuilder(
        builder: (context, c) {
          const gap = 8.0;
          final cols = c.maxWidth > 300 ? 3 : 2;
          final w = (c.maxWidth - gap * (cols - 1)) / cols;
          return ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              for (final cat in FurnitureCategory.values) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(2, 14, 0, 8),
                  child: Text(
                    cat.label.toUpperCase(),
                    style: HavenText.caption.copyWith(
                      color: hv.tx3,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                      fontSize: 11,
                    ),
                  ),
                ),
                Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [for (final t in _of(cat)) _tile(t, width: w)],
                ),
              ],
            ],
          );
        },
      );
    }
    final items = _of(_cat);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final cat in FurnitureCategory.values)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _CategoryChip(
                    label: cat.label,
                    selected: cat == _cat,
                    onTap: () {
                      Haptics.tick();
                      setState(() => _cat = cat);
                    },
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.separated(
            key: ValueKey(_cat),
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) => _tile(items[i]),
          ),
        ),
      ],
    );
  }
}

/// Element der Bibliothek: Skizze und Name, Hover und Tooltip am Desktop.
class LibraryTile extends StatelessWidget {
  const LibraryTile({
    super.key,
    required this.type,
    required this.onTap,
    this.width = 84,
    this.cellMeters = 0.5,
  });

  final FurnitureType type;
  final VoidCallback onTap;
  final double width;
  final double cellMeters;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    String m(double v) {
      final x = (v * cellMeters * 10).round() / 10;
      return (x == x.roundToDouble()
              ? x.toStringAsFixed(0)
              : x.toStringAsFixed(1))
          .replaceAll('.', ',');
    }

    return DesktopTooltip(
      message: '${type.name} · ${m(type.w)} × ${m(type.h)} m',
      shortcut: 'Ziehen oder klicken',
      child: Semantics(
        button: true,
        label: '${type.name} hinzufügen',
        excludeSemantics: true,
        child: HoverBuilder(
          cursor: SystemMouseCursors.grab,
          builder: (context, hover) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: AnimatedContainer(
              duration: context.motion(HavenMotion.d1),
              width: width,
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
              decoration: BoxDecoration(
                color: Color.alphaBlend(hoverOverlay(hv, hover), hv.s2),
                borderRadius: BorderRadius.circular(HavenRadii.s),
                border: Border.all(
                  color: hover ? hv.acc.withValues(alpha: 0.5) : hv.ln,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FurnitureThumb(kind: type.id, size: 46),
                  const SizedBox(height: 4),
                  Text(
                    type.name,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: HavenText.caption.copyWith(
                      color: hv.tx2,
                      fontSize: 11.5,
                      height: 1.15,
                      fontWeight: FontWeight.w600,
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

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
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
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: context.motion(HavenMotion.d2),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? hv.acc : hv.s2,
            borderRadius: BorderRadius.circular(HavenRadii.pill),
            border: Border.all(color: selected ? hv.acc : hv.ln),
          ),
          child: Text(
            label,
            style: HavenText.label.copyWith(
              color: selected ? hv.ai : hv.tx2,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}
