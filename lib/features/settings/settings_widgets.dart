import 'package:material_ui/material_ui.dart';

import '../../core/widgets/haven_sheet.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/press_scale.dart';

/// Gruppierte, abgerundete Liste im Stil des Entwurfs: eine Karte, Zeilen
/// durch Haarlinien getrennt.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: hv.s1,
        borderRadius: BorderRadius.circular(HavenRadii.l),
        border: Border.all(color: hv.ln),
        boxShadow: hv.shadowSmall,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(HavenRadii.l),
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 66),
                  child: SizedBox(height: 1, child: ColoredBox(color: hv.ln)),
                ),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// Zeile einer [SettingsGroup]: Symbolkachel, Titel, Untertitel, rechts
/// Chevron oder eigenes Widget. Mindesthöhe 56 dp.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.destructive = false,
    this.iconColor,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool destructive;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final fg = destructive ? hv.bad : hv.tx;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 60),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: hv.s2,
                borderRadius: BorderRadius.circular(HavenRadii.s),
              ),
              child: Icon(
                icon,
                size: 20,
                color: iconColor ?? (destructive ? hv.bad : hv.tx2),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: HavenText.label.copyWith(color: fg, fontSize: 15),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: HavenText.caption.copyWith(color: hv.tx2),
                    ),
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else if (onTap != null)
              Icon(Icons.chevron_right_rounded, color: hv.tx3),
          ],
        ),
      ),
    );
    if (onTap == null) return row;
    return Semantics(
      button: true,
      label: subtitle == null ? title : '$title, $subtitle',
      excludeSemantics: true,
      child: PressScale(onTap: onTap, pressedScale: 0.985, child: row),
    );
  }
}

/// Bottom-Sheet im Haven-Stil (Radius xl, s1, Haarlinie).
Future<T?> showHavenSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  return showHavenModalSheet<T>(
    context,
    builder: (ctx) {
      final hv = ctx.hv;
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.9,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: hv.s1,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(HavenRadii.xl),
            ),
            border: Border.all(color: hv.ln),
          ),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              // Am oberen Ende übernimmt das Sheet das Ziehen.
              controller: HavenSheetScope.maybeOf(ctx)?.scrollController,
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: hv.s3,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  builder(ctx),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Kleine Meldung unten, ohne Material-Snackbar-Optik.
void showHavenToast(BuildContext context, String message) {
  final hv = context.hv;
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: hv.tx,
        elevation: 0,
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 100),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HavenRadii.m),
        ),
        duration: const Duration(milliseconds: 2200),
        content: Text(
          message,
          style: HavenText.label.copyWith(color: hv.bg, fontSize: 14),
        ),
      ),
    );
}
