import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/haven_switch.dart';
import '../../core/widgets/press_scale.dart';
import '../../core/widgets/screen_header.dart';
import '../../core/widgets/segmented.dart';
import '../ha_web/ha_web_screen.dart';
import '../settings/settings_widgets.dart';
import 'automation_logic.dart';
import 'automations_provider.dart';

enum _Filter { all, on, off }

IconData _iconFor(String kind) => switch (kind) {
  'motion' => Icons.sensors_rounded,
  'knob' => Icons.radio_button_checked_rounded,
  'fan' => Icons.air_rounded,
  'humidity' => Icons.water_drop_outlined,
  'sun' => Icons.wb_sunny_outlined,
  'restart' => Icons.restart_alt_rounded,
  'screen' => Icons.tv_rounded,
  'warning' => Icons.warning_amber_rounded,
  _ => Icons.auto_awesome_outlined,
};

/// Abläufe: Automationen auflisten, schalten, auslösen.
class AutomationsScreen extends ConsumerStatefulWidget {
  const AutomationsScreen({super.key});

  @override
  ConsumerState<AutomationsScreen> createState() => _AutomationsScreenState();
}

class _AutomationsScreenState extends ConsumerState<AutomationsScreen> {
  _Filter _filter = _Filter.all;
  String _query = '';

  void _open(String path, String title) =>
      context.push(haWebLocation(path, title: title));

  Future<void> _run(AutomationItem a) async {
    Haptics.tap();
    await ref.read(automationActionsProvider).run(a.entityId);
    if (mounted) showHavenToast(context, '${a.name} ausgeführt');
  }

  void _showActions(AutomationItem a) {
    showHavenSheet<void>(
      context,
      builder: (ctx) => _ActionSheet(
        item: a,
        onRun: () {
          Navigator.of(ctx).pop();
          _run(a);
        },
        onEdit: () {
          Navigator.of(ctx).pop();
          _open(a.editPath, a.name);
        },
        onTrace: () {
          Navigator.of(ctx).pop();
          _open(a.tracePath, 'Verlauf');
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final list = ref.watch(automationsProvider);
    final active = list.items.where((a) => a.on).length;
    final q = foldText(_query.trim());
    final shown = [
      for (final a in list.items)
        if (switch (_filter) {
              _Filter.all => true,
              _Filter.on => a.on,
              _Filter.off => !a.on,
            } &&
            (q.isEmpty ||
                foldText(a.name).contains(q) ||
                foldText(a.room ?? 'allgemein').contains(q)))
          a,
    ];
    final groups = groupByRoom(shown, roomOrder: list.roomNames);
    final now = DateTime.now();

    // Flache Liste: Kopf (String) oder Ablauf.
    final entries = <Object>[
      for (final g in groups) ...[g.$1, ...g.$2],
    ];

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: HavenSpace.navClearance),
      itemCount: entries.length + 2,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenHeader(
                title: 'Abläufe',
                subtitle: list.items.isEmpty
                    ? 'Noch keine Abläufe'
                    : '$active von ${list.items.length} aktiv',
                actions: const [SettingsButton()],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                child: HavenButton(
                  label: 'Neuer Ablauf',
                  icon: Icons.add_rounded,
                  primary: true,
                  onTap: () =>
                      _open('/config/automation/edit/new', 'Neuer Ablauf'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: _SearchField(
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                child: HavenSegmented<_Filter>(
                  options: const [
                    (_Filter.all, 'Alle'),
                    (_Filter.on, 'Aktiv'),
                    (_Filter.off, 'Aus'),
                  ],
                  selected: _filter,
                  neutral: true,
                  onChanged: (f) => setState(() => _filter = f),
                ),
              ),
            ],
          );
        }
        if (i == entries.length + 1) {
          if (entries.isNotEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.fromLTRB(32, 48, 32, 0),
            child: Text(
              list.items.isEmpty
                  ? 'Sobald Home Assistant Automationen hat, erscheinen sie hier.'
                  : 'Nichts gefunden.',
              textAlign: TextAlign.center,
              style: HavenText.body.copyWith(color: hv.tx2),
            ),
          );
        }
        final e = entries[i - 1];
        if (e is String) {
          final n = groups.firstWhere((g) => g.$1 == e).$2.length;
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 20, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    e,
                    style: HavenText.headline.copyWith(color: hv.tx),
                  ),
                ),
                Text('$n', style: HavenText.label.copyWith(color: hv.tx3)),
              ],
            ),
          );
        }
        final a = e as AutomationItem;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: _AutomationRow(
            key: ValueKey(a.entityId),
            item: a,
            subtitle: a.on
                ? 'zuletzt ${relativeTime(a.lastTriggered, now)}'
                : 'ausgeschaltet',
            onToggle: (v) => unawaited(
              ref.read(automationActionsProvider).setEnabled(a.entityId, v),
            ),
            onRun: () => _run(a),
            onEdit: () => _open(a.editPath, a.name),
            onMore: () => _showActions(a),
          ),
        );
      },
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.onChanged});
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: hv.s1,
        borderRadius: BorderRadius.circular(HavenRadii.m),
        border: Border.all(color: hv.ln),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 20, color: hv.tx3),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              onChanged: onChanged,
              style: HavenText.body.copyWith(color: hv.tx),
              cursorColor: hv.acc,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration.collapsed(
                hintText: 'Abläufe suchen',
                hintStyle: HavenText.body.copyWith(color: hv.tx3),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AutomationRow extends StatelessWidget {
  const _AutomationRow({
    super.key,
    required this.item,
    required this.subtitle,
    required this.onToggle,
    required this.onRun,
    required this.onEdit,
    required this.onMore,
  });

  final AutomationItem item;
  final String subtitle;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRun;
  final VoidCallback onEdit;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Dismissible(
      key: ValueKey('dismiss-${item.entityId}'),
      // Aktion auslösen, Zeile bleibt: confirmDismiss gibt immer false zurück.
      confirmDismiss: (dir) async {
        if (dir == DismissDirection.startToEnd) {
          onRun();
        } else {
          onEdit();
        }
        return false;
      },
      background: _SwipeBg(
        color: hv.acc,
        fg: hv.ai,
        icon: Icons.play_arrow_rounded,
        label: 'Jetzt ausführen',
        alignLeft: true,
      ),
      secondaryBackground: _SwipeBg(
        color: hv.s3,
        fg: hv.tx,
        icon: Icons.open_in_new_rounded,
        label: 'Bearbeiten',
        alignLeft: false,
      ),
      child: AnimatedOpacity(
        opacity: item.on ? 1 : 0.62,
        duration: context.motion(HavenMotion.d2),
        child: PressScale(
          onTap: onMore,
          onLongPress: onMore,
          pressedScale: 0.98,
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            decoration: BoxDecoration(
              color: hv.s1,
              borderRadius: BorderRadius.circular(HavenRadii.m),
              border: Border.all(color: hv.ln),
            ),
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
                    _iconFor(automationKind(item.name)),
                    size: 20,
                    color: hv.tx2,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: HavenText.label.copyWith(
                          color: hv.tx,
                          fontSize: 14.5,
                        ),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HavenText.caption.copyWith(color: hv.tx2),
                      ),
                    ],
                  ),
                ),
                _RunButton(onTap: item.available ? onRun : null),
                HavenSwitch(
                  value: item.on,
                  semanticLabel: item.name,
                  onChanged: item.available ? onToggle : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SwipeBg extends StatelessWidget {
  const _SwipeBg({
    required this.color,
    required this.fg,
    required this.icon,
    required this.label,
    required this.alignLeft,
  });
  final Color color;
  final Color fg;
  final IconData icon;
  final String label;
  final bool alignLeft;

  @override
  Widget build(BuildContext context) {
    final children = [
      Icon(icon, color: fg, size: 22),
      const SizedBox(width: 8),
      Text(label, style: HavenText.label.copyWith(color: fg)),
    ];
    return Container(
      alignment: alignLeft ? Alignment.centerLeft : Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(HavenRadii.m),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: alignLeft ? children : children.reversed.toList(),
      ),
    );
  }
}

/// Play-Knopf, zeigt nach dem Auslösen kurz ein Häkchen.
class _RunButton extends StatefulWidget {
  const _RunButton({required this.onTap});
  final VoidCallback? onTap;

  @override
  State<_RunButton> createState() => _RunButtonState();
}

class _RunButtonState extends State<_RunButton> {
  bool _ok = false;
  Timer? _t;

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  void _tap() {
    widget.onTap!();
    setState(() => _ok = true);
    _t?.cancel();
    _t = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _ok = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      button: true,
      label: 'Jetzt ausführen',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap == null ? null : _tap,
        child: SizedBox(
          width: HavenSpace.touch,
          height: HavenSpace.touch,
          child: Center(
            child: AnimatedContainer(
              duration: context.motion(HavenMotion.d2),
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _ok ? hv.ok.withValues(alpha: 0.18) : hv.s2,
              ),
              child: Icon(
                _ok ? Icons.check_rounded : Icons.play_arrow_rounded,
                size: 22,
                color: _ok ? hv.ok : hv.tx,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionSheet extends StatelessWidget {
  const _ActionSheet({
    required this.item,
    required this.onRun,
    required this.onEdit,
    required this.onTrace,
  });
  final AutomationItem item;
  final VoidCallback onRun;
  final VoidCallback onEdit;
  final VoidCallback onTrace;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(item.name, style: HavenText.section.copyWith(color: hv.tx)),
        const SizedBox(height: 2),
        Text(
          '${item.on ? 'Aktiv' : 'Ausgeschaltet'} · zuletzt ${relativeTime(item.lastTriggered, DateTime.now())}',
          style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
        ),
        const SizedBox(height: 16),
        HavenButton(
          label: 'Jetzt ausführen',
          icon: Icons.play_arrow_rounded,
          primary: true,
          onTap: item.available ? onRun : null,
        ),
        const SizedBox(height: 10),
        HavenButton(
          label: 'In Home Assistant bearbeiten',
          icon: Icons.open_in_new_rounded,
          onTap: onEdit,
        ),
        const SizedBox(height: 10),
        HavenButton(
          label: 'Verlauf',
          icon: Icons.history_rounded,
          onTap: onTrace,
        ),
      ],
    );
  }
}
