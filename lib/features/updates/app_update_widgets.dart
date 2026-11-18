import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/haven_card.dart';
import '../../core/widgets/simple_markdown.dart';
import '../../data/models/ha_update.dart';
import 'app_update_provider.dart';
import 'ha_updates_provider.dart';
import 'update_widgets.dart';

/// Dezente Hinweise auf der Übersicht: neue App-Version und anstehende
/// Updates in Home Assistant. Ohne Updates ist nichts zu sehen.
class UpdateNotices extends ConsumerWidget {
  const UpdateNotices({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appUpdateProvider);
    final ha = ref.watch(haUpdatesProvider);
    final haven = ha.items.any((u) => u.isHaven);
    final cards = <Widget>[
      if (app.showCard) const _AppUpdateBanner(),
      if (!ha.isEmpty) _HaUpdatesBanner(updates: ha, haven: haven),
    ];
    if (cards.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HavenSpace.page,
        10,
        HavenSpace.page,
        0,
      ),
      child: Column(
        children: [
          for (final c in cards)
            Padding(padding: const EdgeInsets.only(bottom: 8), child: c),
        ],
      ),
    );
  }
}

class _AppUpdateBanner extends ConsumerWidget {
  const _AppUpdateBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final r = ref.watch(appUpdateProvider.select((s) => s.release))!;
    return HavenCard(
      radius: HavenRadii.m,
      padding: const EdgeInsets.only(left: 14),
      onTap: () => context.push('/settings'),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: hv.acc.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(HavenRadii.s),
            ),
            child: Icon(
              Icons.system_update_alt_rounded,
              size: 20,
              color: hv.acc,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Haven ${r.version} ist da',
                  style: HavenText.label.copyWith(color: hv.tx, fontSize: 14.5),
                ),
                Text(
                  'Neue Version der App',
                  style: HavenText.caption.copyWith(color: hv.tx2),
                ),
              ],
            ),
          ),
          Semantics(
            button: true,
            label: 'Hinweis schließen',
            excludeSemantics: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: ref.read(appUpdateProvider.notifier).dismiss,
              child: SizedBox(
                width: HavenSpace.touch,
                height: HavenSpace.touch,
                child: Icon(Icons.close_rounded, size: 20, color: hv.tx3),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HaUpdatesBanner extends StatelessWidget {
  const _HaUpdatesBanner({required this.updates, required this.haven});
  final HaUpdates updates;
  final bool haven;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final n = updates.count;
    final groups = updates.byGroup.keys.map((g) => g.label).join(', ');
    final color = haven ? hv.acc : hv.warn;
    return HavenCard(
      radius: HavenRadii.m,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      onTap: () => context.push('/settings/updates'),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(HavenRadii.s),
            ),
            child: Icon(
              Icons.system_update_alt_rounded,
              size: 20,
              color: color,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  n == 1 ? 'Ein Update verfügbar' : '$n Updates verfügbar',
                  style: HavenText.label.copyWith(color: hv.tx, fontSize: 14.5),
                ),
                Text(
                  groups,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HavenText.caption.copyWith(color: hv.tx2),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: hv.tx3),
        ],
      ),
    );
  }
}

/// Karte in den Einstellungen mit Release-Notes und dem Knopf zum Laden und
/// Installieren. Ohne neue Version ist sie leer.
class AppUpdatePanel extends ConsumerWidget {
  const AppUpdatePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final s = ref.watch(appUpdateProvider);
    final r = s.release;
    if (r == null) return const SizedBox.shrink();
    final ctl = ref.read(appUpdateProvider.notifier);
    final installer = ref.watch(appInstallerProvider);
    final native = installer.supported && r.hasApk;
    final downloading = s.phase == AppUpdatePhase.downloading;
    final installing = s.phase == AppUpdatePhase.installing;
    final pct = s.progress == null ? null : (s.progress! * 100).round();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Color.alphaBlend(hv.acc.withValues(alpha: 0.07), hv.s1),
          borderRadius: BorderRadius.circular(HavenRadii.l),
          border: Border.all(color: hv.acc.withValues(alpha: 0.4)),
          boxShadow: hv.shadowSmall,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                native
                    ? 'Haven ${r.version} ist verfügbar'
                    : 'Neue Version ${r.version} verfügbar',
                style: HavenText.headline.copyWith(color: hv.tx),
              ),
              const SizedBox(height: 2),
              Text(
                'Du hast ${s.current}.',
                style: HavenText.caption.copyWith(color: hv.tx2),
              ),
              if (r.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Neu in dieser Version',
                  style: HavenText.label.copyWith(color: hv.tx),
                ),
                const SizedBox(height: 6),
                SimpleMarkdown(r.notes, maxBlocks: 24),
              ],
              if (s.needsPermission) ...[
                const SizedBox(height: 8),
                _Note(
                  icon: Icons.shield_outlined,
                  text:
                      'Android fragt vor der ersten Installation, ob Haven Apps installieren darf. Erlaube es in den Einstellungen und tippe danach nochmal auf „Herunterladen und installieren“.',
                  color: hv.warn,
                ),
                const SizedBox(height: 10),
                HavenButton(
                  label: 'Einstellungen öffnen',
                  icon: Icons.settings_outlined,
                  onTap: ctl.openInstallSettings,
                ),
              ],
              if (s.error != null) ...[
                const SizedBox(height: 8),
                _Note(
                  icon: Icons.error_outline_rounded,
                  text: s.error!,
                  color: hv.bad,
                ),
              ],
              if (downloading || installing) ...[
                const SizedBox(height: 12),
                UpdateProgressBar(value: installing ? 1 : s.progress),
                const SizedBox(height: 6),
                Text(
                  installing
                      ? 'Android öffnet die Installation'
                      : (pct == null ? 'Lädt' : 'Lädt $pct %'),
                  style: HavenText.caption.copyWith(color: hv.tx2),
                ),
              ] else ...[
                const SizedBox(height: 14),
                HavenButton(
                  primary: true,
                  icon: native
                      ? Icons.download_rounded
                      : Icons.open_in_new_rounded,
                  label: native
                      ? 'Herunterladen und installieren'
                      : 'Release-Seite öffnen',
                  onTap: ctl.downloadAndInstall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: HavenText.caption.copyWith(color: hv.tx, fontSize: 12.5),
          ),
        ),
      ],
    );
  }
}
