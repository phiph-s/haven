import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/haven_card.dart';
import '../../core/widgets/haven_switch.dart';
import '../../core/widgets/simple_markdown.dart';
import '../../data/models/ha_update.dart';
import '../settings/settings_widgets.dart';
import 'app_update_provider.dart';
import 'ha_updates_provider.dart';
import 'update_widgets.dart';

IconData _groupIcon(UpdateGroup g) => switch (g) {
  UpdateGroup.haven => Icons.home_rounded,
  UpdateGroup.homeAssistant => Icons.home_outlined,
  UpdateGroup.addons => Icons.extension_outlined,
  UpdateGroup.integrations => Icons.hub_outlined,
  UpdateGroup.devices => Icons.memory_rounded,
};

/// Alle anstehenden Updates aus Home Assistant, nach Gruppen.
class UpdatesScreen extends ConsumerWidget {
  const UpdatesScreen({super.key});

  Future<void> _installOne(
    BuildContext context,
    WidgetRef ref,
    HaUpdate u,
  ) async {
    // Core, OS und Supervisor immer bestätigen, andere nur mit Backup-Option.
    if (!u.restartsHa && !u.canBackup) {
      unawaited(ref.read(updatesControllerProvider.notifier).install(u));
      return;
    }
    final res = await showHavenSheet<bool?>(
      context,
      builder: (_) => _InstallSheet(update: u),
    );
    if (res == null) return;
    unawaited(
      ref.read(updatesControllerProvider.notifier).install(u, backup: res),
    );
  }

  Future<void> _installAll(
    BuildContext context,
    WidgetRef ref,
    HaUpdates all,
  ) async {
    final targets = all.bulkTargets;
    final skipped = all.items.where((u) => u.restartsHa).length;
    final ok = await showHavenSheet<bool>(
      context,
      builder: (_) => _BulkSheet(targets: targets, skippedCore: skipped),
    );
    if (ok == true) {
      unawaited(
        ref.read(updatesControllerProvider.notifier).installAll(targets),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final all = ref.watch(haUpdatesProvider);
    final ui = ref.watch(updatesControllerProvider);
    final snap = ref.watch(snapshotProvider);
    final ctl = ref.read(updatesControllerProvider.notifier);
    final restarting = ctl.restarting(snap);
    final groups = all.byGroup;
    final targets = all.bulkTargets;

    return Scaffold(
      backgroundColor: hv.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 40),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
              child: Row(
                children: [
                  RoundIconButton(
                    icon: Icons.arrow_back_rounded,
                    label: 'Zurück',
                    onTap: () => context.pop(),
                  ),
                  Expanded(
                    child: Text(
                      'Updates',
                      textAlign: TextAlign.center,
                      style: HavenText.headline.copyWith(
                        color: hv.tx,
                        fontSize: 22,
                      ),
                    ),
                  ),
                  const SizedBox(width: HavenSpace.touch),
                ],
              ),
            ),
            if (restarting)
              _Banner(
                icon: Icons.restart_alt_rounded,
                color: hv.warn,
                text: 'Home Assistant startet neu. Haven verbindet sich danach von selbst wieder.',
                busy: true,
              ),
            if (ui.error != null)
              _Banner(
                icon: Icons.error_outline_rounded,
                color: hv.bad,
                text: ui.error!,
                onClose: ctl.clearError,
              ),
            const _IntegrationHint(),
            if (all.isEmpty && !restarting)
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 56, 32, 0),
                child: Column(
                  children: [
                    Icon(
                      Icons.check_circle_outline_rounded,
                      size: 48,
                      color: hv.ok,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Alles aktuell',
                      style: HavenText.section.copyWith(color: hv.tx),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Home Assistant meldet keine offenen Updates.',
                      textAlign: TextAlign.center,
                      style: HavenText.body.copyWith(color: hv.tx2),
                    ),
                  ],
                ),
              )
            else if (!all.isEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 20, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        all.count == 1
                            ? 'Ein Update verfügbar'
                            : '${all.count} Updates verfügbar',
                        style: HavenText.label.copyWith(color: hv.tx2),
                      ),
                    ),
                    if (targets.length > 1)
                      SmallButton(
                        label: 'Alle aktualisieren',
                        icon: Icons.download_rounded,
                        onTap: ui.installing.isNotEmpty
                            ? null
                            : () => _installAll(context, ref, all),
                      ),
                  ],
                ),
              ),
              for (final g in UpdateGroup.values)
                if (groups[g] != null) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 22, 20, 10),
                    child: Text(
                      g.label,
                      style: HavenText.section.copyWith(color: hv.tx),
                    ),
                  ),
                  for (final u in groups[g]!)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                      child: _UpdateTile(
                        update: u,
                        running:
                            u.inProgress || ui.installing.contains(u.entityId),
                        onInstall: () => _installOne(context, ref, u),
                        onSkip: () => ctl.skip(u),
                      ),
                    ),
                ],
            ],
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.color,
    required this.text,
    this.busy = false,
    this.onClose,
  });
  final IconData icon;
  final Color color;
  final String text;
  final bool busy;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: HavenCard(
        radius: HavenRadii.m,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            busy
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: color,
                    ),
                  )
                : Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: HavenText.caption.copyWith(color: hv.tx, fontSize: 12.5),
              ),
            ),
            if (onClose != null)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onClose,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(Icons.close_rounded, size: 18, color: hv.tx3),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Hinweis, wenn Haven in HA nicht über HACS kommt, plus neue Version der
/// Integration.
class _IntegrationHint extends ConsumerWidget {
  const _IntegrationHint();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final hasEntity = ref.watch(havenUpdateEntityProvider);
    if (hasEntity) return const SizedBox.shrink();
    final info = ref.watch(integrationInfoProvider).value;
    if (info == null || info.installed == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: HavenCard(
        radius: HavenRadii.m,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 18, color: hv.tx2),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Haven-Integration nicht über HACS installiert',
                    style: HavenText.label.copyWith(color: hv.tx, fontSize: 14),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Updates der Integration erscheinen hier erst, wenn du sie über HACS installierst. Installiert ist Version ${info.installed}.',
              style: HavenText.caption.copyWith(color: hv.tx2, fontSize: 12.5),
            ),
            if (info.newerAvailable) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    Icons.system_update_alt_rounded,
                    size: 18,
                    color: hv.acc,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Integration ${info.latest} verfügbar',
                      style: HavenText.label.copyWith(
                        color: hv.acc,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  if (info.releaseUrl != null)
                    SmallButton(
                      label: 'Ansehen',
                      onTap: () => ref.read(urlOpenerProvider)(
                        Uri.parse(info.releaseUrl!),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _UpdateTile extends ConsumerWidget {
  const _UpdateTile({
    required this.update,
    required this.running,
    required this.onInstall,
    required this.onSkip,
  });
  final HaUpdate update;
  final bool running;
  final VoidCallback onInstall;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final u = update;
    final haven = u.isHaven;
    final pct = u.percentage;
    final hasNotes =
        u.hasReleaseNotes || u.summary != null || u.releaseUrl != null;
    final versions = [
      if (u.installed != null) u.installed!,
      if (u.latest != null) u.latest!,
    ].join('  →  ');
    return DecoratedBox(
      decoration: BoxDecoration(
        color: haven
            ? Color.alphaBlend(hv.acc.withValues(alpha: 0.07), hv.s1)
            : hv.s1,
        borderRadius: BorderRadius.circular(HavenRadii.l),
        border: Border.all(
          color: haven ? hv.acc.withValues(alpha: 0.45) : hv.ln,
        ),
        boxShadow: hv.shadowSmall,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: haven ? hv.acc.withValues(alpha: 0.18) : hv.s2,
                    borderRadius: BorderRadius.circular(HavenRadii.s),
                  ),
                  child: Icon(
                    _groupIcon(u.group),
                    size: 20,
                    color: haven ? hv.acc : hv.tx2,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        u.displayName,
                        style: HavenText.label.copyWith(
                          color: hv.tx,
                          fontSize: 15.5,
                        ),
                      ),
                      if (versions.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            versions,
                            style: HavenText.caption.copyWith(
                              color: hv.tx2,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (u.restartsHa)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 2),
                    child: Icon(
                      Icons.restart_alt_rounded,
                      size: 18,
                      color: hv.warn,
                    ),
                  ),
              ],
            ),
            if (u.summary != null) ...[
              const SizedBox(height: 10),
              Text(
                u.summary!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: HavenText.body.copyWith(color: hv.tx2, fontSize: 13.5),
              ),
            ],
            if (running) ...[
              const SizedBox(height: 12),
              UpdateProgressBar(value: pct == null ? null : pct / 100),
              const SizedBox(height: 6),
              Text(
                pct == null
                    ? 'Wird installiert'
                    : 'Wird installiert, ${pct.round()} %',
                style: HavenText.caption.copyWith(color: hv.tx2),
              ),
              const SizedBox(height: 10),
            ] else
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (u.canInstall)
                      SmallButton(
                        label: 'Aktualisieren',
                        primary: true,
                        onTap: onInstall,
                      ),
                    SmallButton(label: 'Überspringen', onTap: onSkip),
                    if (hasNotes)
                      SmallButton(
                        label: 'Versionshinweise',
                        onTap: () => showHavenSheet<void>(
                          context,
                          builder: (_) => _NotesSheet(update: u),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _InstallSheet extends StatefulWidget {
  const _InstallSheet({required this.update});
  final HaUpdate update;

  @override
  State<_InstallSheet> createState() => _InstallSheetState();
}

class _InstallSheetState extends State<_InstallSheet> {
  late bool _backup = widget.update.canBackup && widget.update.restartsHa;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final u = widget.update;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${u.displayName} aktualisieren',
          style: HavenText.section.copyWith(color: hv.tx),
        ),
        if (u.installed != null && u.latest != null)
          Text(
            '${u.installed}  →  ${u.latest}',
            style: HavenText.caption.copyWith(color: hv.tx2),
          ),
        if (u.restartsHa) ...[
          const SizedBox(height: 12),
          Text(
            'HA startet neu. Haven ist kurz getrennt und verbindet sich danach von selbst wieder.',
            style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
          ),
        ],
        if (u.canBackup) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Vorher Backup',
                  style: HavenText.label.copyWith(color: hv.tx, fontSize: 15),
                ),
              ),
              HavenSwitch(
                value: _backup,
                semanticLabel: 'Vorher Backup',
                onChanged: (v) => setState(() => _backup = v),
              ),
            ],
          ),
        ],
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: HavenButton(
                label: 'Abbrechen',
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: HavenButton(
                label: 'Aktualisieren',
                primary: true,
                onTap: () => Navigator.of(context).pop(_backup),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _BulkSheet extends StatelessWidget {
  const _BulkSheet({required this.targets, required this.skippedCore});
  final List<HaUpdate> targets;
  final int skippedCore;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          targets.length == 1
              ? 'Ein Update installieren?'
              : '${targets.length} Updates installieren?',
          style: HavenText.section.copyWith(color: hv.tx),
        ),
        const SizedBox(height: 10),
        for (final u in targets)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '${u.displayName}${u.latest == null ? '' : '  ${u.latest}'}',
              style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
            ),
          ),
        if (skippedCore > 0) ...[
          const SizedBox(height: 10),
          Text(
            'Core, OS und Supervisor sind ausgenommen. HA startet dabei neu, bestätige sie einzeln.',
            style: HavenText.caption.copyWith(color: hv.tx2, fontSize: 12.5),
          ),
        ],
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: HavenButton(
                label: 'Abbrechen',
                onTap: () => Navigator.of(context).pop(false),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: HavenButton(
                label: 'Alle aktualisieren',
                primary: true,
                onTap: () => Navigator.of(context).pop(true),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _NotesSheet extends ConsumerWidget {
  const _NotesSheet({required this.update});
  final HaUpdate update;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final u = update;
    final notes = u.hasReleaseNotes
        ? ref.watch(releaseNotesProvider(u.entityId))
        : const AsyncData<String?>(null);
    final text = notes.value ?? u.summary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Versionshinweise',
          style: HavenText.section.copyWith(color: hv.tx),
        ),
        Text(
          '${u.displayName}${u.latest == null ? '' : ' ${u.latest}'}',
          style: HavenText.caption.copyWith(color: hv.tx2),
        ),
        const SizedBox(height: 12),
        if (notes.isLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
          )
        else if (text != null)
          SimpleMarkdown(text)
        else
          Text(
            u.releaseUrl != null
                ? 'Home Assistant liefert hier keinen Text. Die Hinweise stehen auf der Release-Seite.'
                : 'Keine Versionshinweise vorhanden.',
            style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
          ),
        if (u.releaseUrl != null) ...[
          const SizedBox(height: 16),
          HavenButton(
            label: 'Im Browser öffnen',
            icon: Icons.open_in_new_rounded,
            onTap: () => ref.read(urlOpenerProvider)(Uri.parse(u.releaseUrl!)),
          ),
        ],
      ],
    );
  }
}
