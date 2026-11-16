import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';

/// Eintrag im Kontextmenü (Rechtsklick).
@immutable
class HavenMenuItem {
  const HavenMenuItem({
    required this.label,
    required this.icon,
    required this.onSelected,
    this.shortcut,
    this.destructive = false,
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final VoidCallback onSelected;

  /// Tastenkürzel als Hinweis, z. B. `Entf`.
  final String? shortcut;
  final bool destructive;
  final bool enabled;
}

/// Kontextmenü an der globalen Position [at]. Leere Liste: nichts.
Future<void> showHavenContextMenu(
  BuildContext context,
  Offset at,
  List<HavenMenuItem> items,
) async {
  if (items.isEmpty) return;
  final hv = context.hv;
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final local = overlay.globalToLocal(at);
  final i = await showMenu<int>(
    context: context,
    position: RelativeRect.fromRect(
      local & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    color: hv.s1,
    surfaceTintColor: const Color(0x00000000),
    elevation: 10,
    shadowColor: const Color(0xFF000000).withValues(alpha: 0.5),
    menuPadding: const EdgeInsets.symmetric(vertical: 6),
    constraints: const BoxConstraints(minWidth: 210, maxWidth: 300),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(HavenRadii.s),
      side: BorderSide(color: hv.ln2),
    ),
    items: [
      for (var n = 0; n < items.length; n++)
        PopupMenuItem<int>(
          value: n,
          enabled: items[n].enabled,
          height: 40,
          mouseCursor: SystemMouseCursors.click,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: _MenuRow(item: items[n]),
        ),
    ],
  );
  if (i != null) {
    // Nach dem Schließen des Menüs, damit Fokus und Route stimmen.
    scheduleMicrotask(items[i].onSelected);
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.item});
  final HavenMenuItem item;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final color = !item.enabled ? hv.tx3 : (item.destructive ? hv.bad : hv.tx);
    return Row(
      children: [
        Icon(item.icon, size: 18, color: item.destructive ? hv.bad : hv.tx2),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            item.label,
            style: HavenText.label.copyWith(color: color, fontSize: 13.5),
          ),
        ),
        if (item.shortcut != null) ...[
          const SizedBox(width: 16),
          Text(
            item.shortcut!,
            style: HavenText.caption.copyWith(color: hv.tx3, fontSize: 12),
          ),
        ],
      ],
    );
  }
}
