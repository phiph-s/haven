import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/light/room_palette.dart';
import '../../../core/state/providers.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/haven_button.dart';
import '../../../core/widgets/press_scale.dart';
import '../../../data/haven_repository.dart';
import '../../../data/models/room.dart';
import '../../../data/models/scene_check.dart';
import '../../updates/update_widgets.dart' show SmallButton, UpdateProgressBar;
import '../../zigbee/widgets/zb_common.dart';
import 'scene_card.dart' show SceneSyncDot;
import 'scene_editor.dart' show sceneErrorText;

// ---- Einstieg im Raum ---------------------------------------------------------

/// „Szenen prüfen“ gibt es mit Integration (Feature `scene_sync`) und einer
/// Zigbee-Gruppe mit Szenen, die Haven aufrufen kann.
bool canCheckScenes(HavenRepository repo, Room room) =>
    repo.canSyncScenes &&
    room.zigbeeGroupId != null &&
    room.scenes.any((s) => s.zigbee);

Future<void> showSceneSyncSheet(BuildContext context, String roomId) =>
    showZbSheet<void>(context, builder: (_) => SceneSyncSheet(roomId: roomId));

/// Knopf im Abschnittskopf „Szenen“ neben „Speichern“.
class SceneCheckChip extends StatelessWidget {
  const SceneCheckChip({
    super.key,
    required this.onTap,
    this.attention = false,
  });
  final VoidCallback onTap;

  /// Eine Szene braucht einen Abgleich: kleiner Punkt am Knopf.
  final bool attention;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      button: true,
      label: 'Szenen prüfen',
      excludeSemantics: true,
      child: PressScale(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 14, 6),
          decoration: BoxDecoration(
            color: hv.s2.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(HavenRadii.pill),
            border: Border.all(color: hv.ln),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(Icons.fact_check_outlined, size: 18, color: hv.acc),
                  if (attention)
                    Positioned(
                      right: -2,
                      top: -2,
                      child: SceneSyncDot(size: 8, ring: hv.s2),
                    ),
                ],
              ),
              const SizedBox(width: 6),
              Text(
                'Prüfen',
                style: HavenText.label.copyWith(color: hv.tx, fontSize: 13.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---- Texte (getestet in scene_sync_test.dart) ----------------------------------

/// Kurzurteil einer Messung für die Pille.
String sceneOutcomeLabel(SceneCheck c) => switch (c.outcome) {
  SceneCheckOutcome.ok => 'In Ordnung',
  SceneCheckOutcome.missing =>
    c.count(SceneLampStatus.missing) > 1
        ? '${c.count(SceneLampStatus.missing)} Lampen fehlen'
        : 'Lampe fehlt',
  SceneCheckOutcome.differs =>
    c.brightnessOnly ? 'Helligkeit weicht ab' : 'Farbe weicht ab',
  SceneCheckOutcome.unreachable => 'Nicht erreichbar',
  SceneCheckOutcome.noTarget => 'Ohne Soll',
};

/// Eine Zeile unter dem Szenennamen nach der Messung.
String sceneOutcomeDetail(SceneCheck c) {
  String names(SceneLampStatus s) {
    final n = [
      for (final m in c.members)
        if (m.status == s) m.name,
    ];
    return n.length <= 2 ? n.join(' und ') : '${n.length} Lampen';
  }

  return switch (c.outcome) {
    SceneCheckOutcome.ok =>
      c.members.length == 1
          ? 'Die Lampe leuchtet wie gespeichert'
          : 'Alle ${c.members.length} Lampen leuchten wie gespeichert',
    SceneCheckOutcome.missing =>
      '${names(SceneLampStatus.missing)} '
          '${c.count(SceneLampStatus.missing) == 1 ? 'kennt' : 'kennen'} '
          'die Szene nicht',
    SceneCheckOutcome.differs =>
      c.count(SceneLampStatus.differs) == 0
          ? 'Weicht vom Soll ab'
          : '${names(SceneLampStatus.differs)} '
                '${c.count(SceneLampStatus.differs) == 1 ? 'leuchtet' : 'leuchten'} '
                'anders als gespeichert',
    SceneCheckOutcome.unreachable =>
      '${names(SceneLampStatus.unreachable)} hat nicht geantwortet',
    SceneCheckOutcome.noTarget =>
      'Gemessen, aber es gibt kein Soll zum Vergleichen',
  };
}

/// Stand einer Szene vor dem Prüfen (aus der Gruppenliste).
String sceneSyncDetail(RoomScene s, [DateTime? now]) => switch (s.sync) {
  SceneSync.stale => 'Lampen der Gruppe haben sich geändert, neu abgleichen',
  SceneSync.differs => 'Wich bei der letzten Prüfung ab',
  SceneSync.unknown => 'Ohne Soll, außerhalb von Haven gespeichert',
  SceneSync.ok =>
    s.checkedAt == null
        ? 'Noch nicht geprüft'
        : 'Geprüft ${agoLabel(s.checkedAt!.toLocal(), now)}',
};

// ---- Blatt ---------------------------------------------------------------------

enum _Act { adopt, repair }

class SceneSyncSheet extends ConsumerStatefulWidget {
  const SceneSyncSheet({super.key, required this.roomId});
  final String roomId;

  @override
  ConsumerState<SceneSyncSheet> createState() => _SceneSyncSheetState();
}

class _SceneSyncSheetState extends ConsumerState<SceneSyncSheet> {
  final Map<int, SceneCheck> _results = {};
  final Map<int, String> _errors = {};
  final Set<int> _expanded = {};
  final List<int> _queue = [];
  int? _running;
  (int, _Act)? _acting;
  bool _all = false;
  int _done = 0;
  int _total = 0;

  bool get _busy => _running != null || _acting != null || _all;

  Future<void> _check(HavenRepository repo, int number) async {
    setState(() {
      _running = number;
      _errors.remove(number);
    });
    try {
      final r = await repo.checkScene(widget.roomId, number);
      if (!mounted) return;
      setState(() {
        _results[number] = r;
        if (r.outcome != SceneCheckOutcome.ok) _expanded.add(number);
      });
    } catch (e) {
      if (mounted) setState(() => _errors[number] = sceneErrorText(e));
    } finally {
      if (mounted) setState(() => _running = null);
    }
  }

  Future<void> _checkOne(int number) async {
    if (_busy) return;
    HapticFeedback.selectionClick();
    await _check(ref.read(repositoryProvider), number);
  }

  Future<void> _checkAll(List<RoomScene> scenes) async {
    if (_busy || scenes.isEmpty) return;
    HapticFeedback.mediumImpact();
    final repo = ref.read(repositoryProvider);
    setState(() {
      _all = true;
      _done = 0;
      _total = scenes.length;
      _queue
        ..clear()
        ..addAll([for (final s in scenes) s.number!]);
    });
    while (_queue.isNotEmpty) {
      await _check(repo, _queue.first);
      // Blatt geschlossen: die übrigen Szenen nicht mehr messen.
      if (!mounted) return;
      setState(() {
        _queue.removeAt(0);
        _done++;
      });
    }
    setState(() => _all = false);
    HapticFeedback.lightImpact();
  }

  Future<void> _adopt(RoomScene s) async {
    if (_busy) return;
    final n = s.number!;
    final repo = ref.read(repositoryProvider);
    setState(() => _acting = (n, _Act.adopt));
    try {
      await repo.adoptScene(widget.roomId, n);
      if (!mounted) return;
      setState(() {
        final r = _results[n];
        if (r != null) _results[n] = r.adopted();
      });
      HapticFeedback.lightImpact();
      zbToast(context, 'Das gemessene Licht ist jetzt das Soll von ${s.name}');
    } catch (e) {
      if (mounted) zbToast(context, sceneErrorText(e), error: true);
    } finally {
      if (mounted) setState(() => _acting = null);
    }
  }

  Future<void> _repair(RoomScene s) async {
    if (_busy) return;
    final n = s.number!;
    final repo = ref.read(repositoryProvider);
    setState(() {
      _acting = (n, _Act.repair);
      _errors.remove(n);
    });
    try {
      final r = await repo.repairScene(widget.roomId, n);
      if (!mounted) return;
      setState(() => _results[n] = r);
      final ok = r.outcome == SceneCheckOutcome.ok;
      HapticFeedback.lightImpact();
      zbToast(
        context,
        ok
            ? '${s.name} ist auf allen Lampen abgeglichen'
            : '${s.name} weicht noch ab: ${sceneOutcomeDetail(r)}',
        error: !ok,
      );
    } catch (e) {
      if (mounted) zbToast(context, sceneErrorText(e), error: true);
    } finally {
      if (mounted) setState(() => _acting = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final room = ref.watch(
      snapshotProvider.select((s) => s.room(widget.roomId)),
    );
    if (room == null) return const SizedBox.shrink();
    final scenes = [
      for (final s in room.scenes)
        if (s.zigbee) s,
    ];
    final checked = [
      for (final s in scenes)
        if (_results[s.number] != null) _results[s.number]!,
    ];
    final good = checked.where((c) => c.outcome == SceneCheckOutcome.ok).length;
    final current = _running == null
        ? null
        : scenes.where((s) => s.number == _running).firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Szenen prüfen', style: HavenText.headline.copyWith(color: hv.tx)),
        const SizedBox(height: 4),
        Text(
          'Haven ruft jede Szene in ${room.name} auf und misst, was die '
          'Lampen wirklich tun. Danach kommt das Licht von vorher zurück.',
          style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
        ),
        const SizedBox(height: 12),
        _Notice(
          icon: Icons.warning_amber_rounded,
          text: 'Die Lampen schalten dabei kurz um.',
          color: hv.warn,
        ),
        const SizedBox(height: 14),
        HavenButton(
          label: checked.isEmpty ? 'Alle prüfen' : 'Alle neu prüfen',
          icon: Icons.fact_check_outlined,
          primary: true,
          busy: _all,
          onTap: _busy ? null : () => _checkAll(scenes),
        ),
        AnimatedSize(
          duration: context.motion(HavenMotion.d3),
          curve: HavenMotion.out,
          alignment: Alignment.topCenter,
          child: _all
              ? Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Prüft ${current?.name ?? 'Szene'} · '
                        '${(_done + 1).clamp(1, _total)} von $_total',
                        style: HavenText.label.copyWith(color: hv.tx2),
                      ),
                      const SizedBox(height: 8),
                      UpdateProgressBar(
                        value: _total == 0 ? null : _done / _total,
                      ),
                    ],
                  ),
                )
              : checked.isEmpty
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    good == checked.length
                        ? checked.length == 1
                              ? 'Die Szene ist in Ordnung.'
                              : 'Alle ${checked.length} Szenen sind in Ordnung.'
                        : '$good in Ordnung, ${checked.length - good} mit '
                              'Abweichung',
                    style: HavenText.label.copyWith(
                      color: good == checked.length ? hv.ok : hv.tx2,
                    ),
                  ),
                ),
        ),
        const SizedBox(height: 16),
        for (final s in scenes) ...[
          _SceneRow(
            key: ValueKey('scene-check-${s.number}'),
            scene: s,
            result: _results[s.number],
            error: _errors[s.number],
            running: _running == s.number,
            queued: _queue.contains(s.number) && _running != s.number,
            acting: _acting?.$1 == s.number ? _acting!.$2 : null,
            expanded: _expanded.contains(s.number),
            enabled: !_busy,
            onTap: () {
              final n = s.number!;
              if (_results[n] == null) {
                _checkOne(n);
              } else {
                setState(
                  () => _expanded.contains(n)
                      ? _expanded.remove(n)
                      : _expanded.add(n),
                );
              }
            },
            onAdopt: () => _adopt(s),
            onRepair: () => _repair(s),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(HavenRadii.m),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: HavenText.label.copyWith(color: hv.tx, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class _SceneRow extends StatelessWidget {
  const _SceneRow({
    super.key,
    required this.scene,
    required this.result,
    required this.error,
    required this.running,
    required this.queued,
    required this.acting,
    required this.expanded,
    required this.enabled,
    required this.onTap,
    required this.onAdopt,
    required this.onRepair,
  });

  final RoomScene scene;
  final SceneCheck? result;
  final String? error;
  final bool running;
  final bool queued;
  final _Act? acting;
  final bool expanded;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onAdopt;
  final VoidCallback onRepair;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final r = result;
    final (String detail, Color detailColor) = running
        ? ('Wird gemessen …', hv.tx2)
        : acting == _Act.repair
        ? ('Gleicht ab …', hv.tx2)
        : acting == _Act.adopt
        ? ('Übernimmt …', hv.tx2)
        : queued
        ? ('Wartet', hv.tx3)
        : error != null
        ? (error!, hv.bad)
        : r != null
        ? (sceneOutcomeDetail(r), hv.tx2)
        : (sceneSyncDetail(scene), scene.needsSync ? hv.warn : hv.tx3);
    final c = scene.colors.map(colorOf).toList();
    final canTap = r != null || enabled;

    Widget trailing;
    if (running || acting != null) {
      trailing = SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2.5, color: hv.acc),
      );
    } else if (r != null) {
      final color = switch (r.outcome) {
        SceneCheckOutcome.ok => hv.ok,
        SceneCheckOutcome.missing || SceneCheckOutcome.unreachable => hv.bad,
        SceneCheckOutcome.differs => hv.warn,
        SceneCheckOutcome.noTarget => hv.tx2,
      };
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ZbPill(
            text: sceneOutcomeLabel(r),
            color: color,
            icon: r.outcome == SceneCheckOutcome.ok
                ? Icons.check_rounded
                : null,
          ),
          AnimatedRotation(
            turns: expanded ? 0.5 : 0,
            duration: context.motion(HavenMotion.d2),
            child: Icon(Icons.expand_more_rounded, color: hv.tx3),
          ),
        ],
      );
    } else if (scene.needsSync) {
      trailing = const SceneSyncDot();
    } else {
      trailing = Icon(
        Icons.play_arrow_rounded,
        color: enabled ? hv.tx3 : hv.s3,
      );
    }

    final header = Semantics(
      button: canTap,
      label: 'Szene ${scene.name}',
      hint: r == null ? 'Prüfen' : (expanded ? 'Zuklappen' : 'Lampen zeigen'),
      child: PressScale(
        onTap: canTap ? onTap : null,
        pressedScale: 0.985,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(HavenRadii.s),
                    gradient: LinearGradient(
                      begin: const Alignment(-0.7, -1),
                      end: const Alignment(0.7, 1),
                      colors: [c[0], c[1], c[2]],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        scene.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HavenText.label.copyWith(
                          color: hv.tx,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: HavenText.caption.copyWith(color: detailColor),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                trailing,
              ],
            ),
          ),
        ),
      ),
    );

    return AnimatedContainer(
      duration: context.motion(HavenMotion.d2),
      decoration: BoxDecoration(
        color: hv.s2,
        borderRadius: BorderRadius.circular(HavenRadii.m),
        border: Border.all(
          color: running || acting != null ? hv.acc : hv.ln,
          width: running || acting != null ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          AnimatedSize(
            duration: context.motion(HavenMotion.d3),
            curve: HavenMotion.out,
            alignment: Alignment.topCenter,
            child: r != null && expanded
                ? _Details(
                    result: r,
                    acting: acting,
                    enabled: enabled,
                    onAdopt: onAdopt,
                    onRepair: onRepair,
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({
    required this.result,
    required this.acting,
    required this.enabled,
    required this.onAdopt,
    required this.onRepair,
  });
  final SceneCheck result;
  final _Act? acting;
  final bool enabled;
  final VoidCallback onAdopt;
  final VoidCallback onRepair;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final r = result;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: 1, child: ColoredBox(color: hv.ln)),
          const SizedBox(height: 6),
          Row(
            children: [
              const Spacer(),
              SizedBox(
                width: 84,
                child: Text(
                  'Soll',
                  style: HavenText.caption.copyWith(color: hv.tx3),
                ),
              ),
              const SizedBox(width: 18),
              SizedBox(
                width: 84,
                child: Text(
                  'Gemessen',
                  style: HavenText.caption.copyWith(color: hv.tx3),
                ),
              ),
            ],
          ),
          for (final m in r.members) _LampLine(lamp: m),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              SmallButton(
                label: acting == _Act.adopt ? 'Übernimmt …' : 'Übernehmen',
                icon: Icons.download_done_rounded,
                onTap: enabled ? onAdopt : null,
              ),
              SmallButton(
                label: acting == _Act.repair ? 'Gleicht ab …' : 'Abgleichen',
                icon: Icons.sync_rounded,
                primary: r.outcome != SceneCheckOutcome.ok,
                onTap: enabled && r.hasTarget ? onRepair : null,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            r.hasTarget
                ? '„Übernehmen“ macht das Gemessene zum Soll und zur Farbe der '
                      'Karte. „Abgleichen“ bringt das Soll neu auf alle Lampen, '
                      'Lampen ohne Soll gehen in dieser Szene aus.'
                : 'Ohne Soll gibt es nichts abzugleichen. „Übernehmen“ macht '
                      'das Gemessene zum Soll.',
            style: HavenText.caption.copyWith(color: hv.tx3),
          ),
        ],
      ),
    );
  }
}

class _LampLine extends StatelessWidget {
  const _LampLine({required this.lamp});
  final SceneLampCheck lamp;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final (String label, Color color) = switch (lamp.status) {
      SceneLampStatus.ok => ('passt', hv.ok),
      SceneLampStatus.missing => ('reagiert nicht', hv.bad),
      SceneLampStatus.differs => ('weicht ab', hv.warn),
      SceneLampStatus.unreachable => ('nicht erreichbar', hv.bad),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  lamp.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HavenText.label.copyWith(color: hv.tx, fontSize: 14),
                ),
                Text(
                  label,
                  style: HavenText.caption.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 84,
            child: _StateView(state: lamp.expected, empty: 'kein Soll'),
          ),
          Icon(Icons.arrow_forward_rounded, size: 14, color: hv.tx3),
          const SizedBox(width: 4),
          SizedBox(
            width: 84,
            child: _StateView(state: lamp.measured, empty: 'keine Antwort'),
          ),
        ],
      ),
    );
  }
}

/// Farbpunkt und Helligkeit eines Lampenzustands.
class _StateView extends StatelessWidget {
  const _StateView({required this.state, required this.empty});
  final LampState? state;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final s = state;
    final style = HavenText.caption.copyWith(color: hv.tx2);
    if (s == null) {
      return Text(empty, style: style.copyWith(color: hv.tx3));
    }
    final color = s.color;
    final text = !s.on
        ? 'aus'
        : [
            if (s.kelvin != null) '${s.kelvin} K',
            if (s.brightness != null) '${s.brightness} %',
            if (s.kelvin == null && s.brightness == null) 'an',
          ].join(' · ');
    return Semantics(
      label: s.on ? 'an, $text' : 'aus',
      excludeSemantics: true,
      child: Row(
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: color == null ? null : colorOf(color),
              shape: BoxShape.circle,
              border: Border.all(
                color: color == null ? hv.tx3 : hv.ln2,
                width: color == null ? 1.5 : 1,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}
