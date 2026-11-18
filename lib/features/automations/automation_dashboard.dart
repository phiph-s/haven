import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/haven_card.dart';
import '../../core/widgets/haven_sheet.dart';
import '../../core/widgets/press_scale.dart';
import '../../data/haven_repository.dart';
import '../../data/models/haven_automation.dart';
import '../settings/settings_widgets.dart';
import 'haven_automations_provider.dart';
import 'knob_editor_screen.dart';

/// Gemeinsame Teile der Dashboards einer bestehenden Haven-Automation
/// (`knob_dashboard_screen.dart`, `motion_dashboard_screen.dart`).
///
/// Der Assistent bleibt fürs Anlegen. Eine bestehende Automation zeigt alle
/// Einstellungen als Kacheln ([SettingTile]); jede öffnet ein Sheet
/// ([showSectionEditor]) mit genau dem Abschnitt des Assistenten und speichert
/// nur ihn (`haven/automations/save`).

/// Prüft einen Entwurf, Fehler je Schritt des Assistenten.
typedef DraftValidator =
    Map<int, String> Function(
      HavenAutomation draft,
      HavenAutomations all, {
      Map<String, String> deviceNames,
    });

/// Baut einen Abschnitt des Assistenten für [draft].
typedef SectionBuilder =
    Widget Function(
      HavenAutomation draft,
      HavenAutomations all,
      ValueChanged<HavenAutomation> onChanged,
    );

/// Eine Kachel im Dashboard samt Abschnitt zum Bearbeiten.
class DashboardSection {
  const DashboardSection({
    required this.step,
    required this.title,
    required this.icon,
    required this.lines,
    required this.builder,
  });

  /// Schritt im Assistenten (für Validierung und `?step=`).
  final int step;
  final String title;
  final IconData icon;

  /// Kurzfassung der aktuellen Werte, eine Zeile je Eintrag.
  final List<String> lines;
  final SectionBuilder builder;
}

/// Geänderte Fehler durch eine Bearbeitung: nur der eigene Abschnitt hält
/// das Speichern auf. Fehler in anderen Abschnitten (z. B. eine Szene nach
/// dem Raumwechsel) zeigt danach die Kachel.
String? sectionSaveError(
  int step,
  HavenAutomation draft,
  HavenAutomations all,
  DraftValidator validate, {
  Map<String, String> deviceNames = const {},
}) => validate(draft, all, deviceNames: deviceNames)[step];

bool sameAutomation(HavenAutomation a, HavenAutomation b) =>
    jsonEncode(a.toJson()) == jsonEncode(b.toJson());

/// Öffnet [section] als großes Sheet. Gibt die gespeicherte Automation
/// zurück, `null` bei Abbruch oder ohne Änderung.
Future<HavenAutomation?> showSectionEditor(
  BuildContext context, {
  required HavenAutomation automation,
  required DashboardSection section,
  required DraftValidator validate,
}) {
  Haptics.tap();
  return showHavenModalSheet<HavenAutomation>(
    context,
    size: HavenSheetSize.large,
    builder: (_) => SectionEditorSheet(
      automation: automation,
      section: section,
      validate: validate,
    ),
  );
}

/// Inhalt des Bearbeiten-Sheets: eigener Entwurf, Abbrechen und Speichern.
class SectionEditorSheet extends ConsumerStatefulWidget {
  const SectionEditorSheet({
    super.key,
    required this.automation,
    required this.section,
    required this.validate,
  });
  final HavenAutomation automation;
  final DashboardSection section;
  final DraftValidator validate;

  @override
  ConsumerState<SectionEditorSheet> createState() => _SectionEditorSheetState();
}

class _SectionEditorSheetState extends ConsumerState<SectionEditorSheet> {
  late HavenAutomation _draft = widget.automation;
  String? _error;
  bool _saving = false;

  void _update(HavenAutomation d) => setState(() {
    _draft = d;
    _error = null;
  });

  Future<void> _save(HavenAutomations all) async {
    final nav = Navigator.of(context);
    if (sameAutomation(_draft, widget.automation)) {
      nav.pop();
      return;
    }
    final e = sectionSaveError(
      widget.section.step,
      _draft,
      all,
      widget.validate,
      deviceNames: ref.read(knobDeviceNamesProvider),
    );
    if (e != null) {
      Haptics.tap();
      setState(() => _error = e);
      return;
    }
    setState(() => _saving = true);
    try {
      final saved = await ref
          .read(havenAutomationsProvider.notifier)
          .save(_draft);
      if (!mounted) return;
      Haptics.tap();
      nav.pop(saved);
    } on HavenException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final all = ref.watch(havenAutomationsProvider).value;
    return _SheetShell(
      caption: widget.automation.name,
      title: widget.section.title,
      footer: all == null
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AnimatedSize(
                  duration: context.motion(HavenMotion.d2),
                  child: _error == null
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: ErrorLine(_error!),
                        ),
                ),
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
                        label: 'Speichern',
                        icon: Icons.check_rounded,
                        primary: true,
                        busy: _saving,
                        onTap: _saving ? null : () => _save(all),
                      ),
                    ),
                  ],
                ),
              ],
            ),
      child: all == null
          ? Center(
              child: CircularProgressIndicator.adaptive(
                valueColor: AlwaysStoppedAnimation(hv.acc),
              ),
            )
          : widget.section.builder(_draft, all, _update),
    );
  }
}

/// Live-Test als großes Sheet (ohne Speichern).
Future<void> showLiveTestSheet(
  BuildContext context, {
  required String caption,
  required Widget child,
}) {
  Haptics.tap();
  return showHavenModalSheet<void>(
    context,
    size: HavenSheetSize.large,
    builder: (_) =>
        _SheetShell(caption: caption, title: 'Live-Test', child: child),
  );
}

/// Rahmen der großen Sheets: Griff, Kopf mit Schließen, Inhalt, Fußleiste.
class _SheetShell extends StatelessWidget {
  const _SheetShell({
    required this.caption,
    required this.title,
    required this.child,
    this.footer,
  });
  final String caption;
  final String title;
  final Widget child;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: hv.bg,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(HavenRadii.xl),
        ),
        border: Border.all(color: hv.ln),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(HavenRadii.xl),
        ),
        child: Padding(
          padding: EdgeInsets.only(bottom: inset),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetGrabber(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 10, 0),
                child: Row(
                  children: [
                    // Die Überschrift trägt der Abschnitt selbst (StepScroll).
                    Expanded(
                      child: Text(
                        '$title · $caption',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HavenText.caption.copyWith(color: hv.tx2),
                      ),
                    ),
                    RoundIconButton(
                      icon: Icons.close_rounded,
                      label: 'Schließen',
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(child: child),
              if (footer != null)
                Container(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    10,
                    20,
                    12 + (inset > 0 ? 0 : MediaQuery.paddingOf(context).bottom),
                  ),
                  decoration: BoxDecoration(
                    color: hv.bg,
                    border: Border(top: BorderSide(color: hv.ln)),
                  ),
                  child: footer,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Rote Fehlerzeile mit Symbol.
class ErrorLine extends StatelessWidget {
  const ErrorLine(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline_rounded, size: 18, color: hv.bad),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: HavenText.body.copyWith(color: hv.bad, fontSize: 14),
          ),
        ),
      ],
    );
  }
}

/// Kachel einer Einstellung: Symbol, Titel, aktuelle Werte, Pfeil.
class SettingTile extends StatelessWidget {
  const SettingTile({
    super.key,
    required this.icon,
    required this.title,
    required this.lines,
    required this.onTap,
    this.error,
  });
  final IconData icon;
  final String title;
  final List<String> lines;
  final String? error;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Semantics(
        button: true,
        label: '$title bearbeiten: ${lines.join(', ')}',
        excludeSemantics: true,
        child: PressScale(
          pressedScale: 0.985,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
            decoration: BoxDecoration(
              color: hv.s1,
              borderRadius: BorderRadius.circular(HavenRadii.l),
              border: Border.all(
                color: error != null ? hv.bad.withValues(alpha: 0.6) : hv.ln,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: hv.s2,
                    borderRadius: BorderRadius.circular(HavenRadii.s),
                  ),
                  child: Icon(icon, size: 20, color: hv.tx2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: HavenText.caption.copyWith(color: hv.tx2),
                      ),
                      const SizedBox(height: 2),
                      for (final l in lines)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            l,
                            style: HavenText.label.copyWith(color: hv.tx),
                          ),
                        ),
                      if (error != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          error!,
                          style: HavenText.caption.copyWith(color: hv.bad),
                        ),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Icon(Icons.chevron_right_rounded, color: hv.tx3),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Löschen nach Bestätigung. `true`, wenn gelöscht.
Future<bool> confirmAndDeleteAutomation(
  BuildContext context,
  WidgetRef ref,
  HavenAutomation a, {
  required String consequence,
}) async {
  final ok = await showHavenSheet<bool>(
    context,
    builder: (ctx) {
      final hv = ctx.hv;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${a.name} löschen?',
            style: HavenText.section.copyWith(color: hv.tx),
          ),
          const SizedBox(height: 6),
          Text(
            consequence,
            style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
          ),
          const SizedBox(height: 16),
          HavenButton(
            label: 'Löschen',
            icon: Icons.delete_outline_rounded,
            destructive: true,
            onTap: () => Navigator.of(ctx).pop(true),
          ),
          const SizedBox(height: 10),
          HavenButton(
            label: 'Abbrechen',
            onTap: () => Navigator.of(ctx).pop(false),
          ),
        ],
      );
    },
  );
  if (ok != true || !context.mounted) return false;
  try {
    await ref.read(havenAutomationsProvider.notifier).delete(a.id!);
    if (context.mounted) showHavenToast(context, 'Gelöscht');
    return true;
  } catch (e) {
    if (context.mounted) showHavenToast(context, '$e');
    return false;
  }
}

/// Gerüst des Dashboards: Kopf, Zustand, Aktiv, Live-Test, Kacheln, Löschen.
///
/// Handy: eine Spalte. Ab 860 dp Breite zwei Spalten (links Zustand und
/// Aktionen, rechts die Einstellungen).
class AutomationDashboard extends ConsumerStatefulWidget {
  const AutomationDashboard({
    super.key,
    required this.id,
    required this.kindLabel,
    required this.status,
    required this.sections,
    required this.validate,
    required this.liveTest,
    required this.activeHint,
    required this.deleteHint,
    required this.wizardPath,
    this.conflicts,
    this.initialStep,
  });

  final String id;

  /// „Bewegungslicht“, „Drehregler“.
  final String kindLabel;
  final Widget Function(HavenAutomation a) status;
  final List<DashboardSection> Function(
    WidgetRef ref,
    HavenAutomation a,
    HavenAutomations all,
  )
  sections;
  final DraftValidator validate;
  final Widget Function(HavenAutomation a) liveTest;

  /// Untertitel des Schalters „Aktiv“.
  final String activeHint;
  final String deleteHint;

  /// Assistent für diese Automation (alle Schritte durchgehen).
  final String wizardPath;
  final Widget? Function(WidgetRef ref, HavenAutomation a)? conflicts;

  /// Abschnitt (Schritt des Assistenten) gleich öffnen, z. B. `?step=1`.
  /// Der Live-Test hat den Schritt 5.
  final int? initialStep;

  @override
  ConsumerState<AutomationDashboard> createState() =>
      _AutomationDashboardState();
}

class _AutomationDashboardState extends ConsumerState<AutomationDashboard> {
  bool _openedInitial = false;

  void _close() =>
      context.canPop() ? context.pop() : context.go('/automations');

  Future<void> _edit(HavenAutomation a, DashboardSection s) async {
    final saved = await showSectionEditor(
      context,
      automation: a,
      section: s,
      validate: widget.validate,
    );
    if (saved != null && mounted) showHavenToast(context, 'Gespeichert');
  }

  void _liveTest(HavenAutomation a) =>
      showLiveTestSheet(context, caption: a.name, child: widget.liveTest(a));

  void _openInitial(HavenAutomation a, List<DashboardSection> sections) {
    final step = widget.initialStep;
    if (_openedInitial || step == null) return;
    _openedInitial = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (step == 5) {
        _liveTest(a);
        return;
      }
      final s = sections.where((s) => s.step == step).firstOrNull;
      if (s != null) _edit(a, s);
    });
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final async = ref.watch(havenAutomationsProvider);
    final all = async.value;
    final a = all?.byId(widget.id);

    Widget body;
    if (all == null) {
      body = Center(
        child: async.hasError
            ? Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Automationen nicht erreichbar: ${async.error}',
                  textAlign: TextAlign.center,
                  style: HavenText.body.copyWith(color: hv.tx2),
                ),
              )
            : const CircularProgressIndicator.adaptive(),
      );
    } else if (a == null) {
      body = Center(
        child: Text(
          'Diese Automation gibt es nicht mehr.',
          style: HavenText.body.copyWith(color: hv.tx2),
        ),
      );
    } else {
      final sections = widget.sections(ref, a, all);
      _openInitial(a, sections);
      body = _content(a, all, sections);
    }

    final room = a == null ? null : all?.rooms[a.roomAreaId]?.name;
    return Scaffold(
      backgroundColor: hv.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
              child: Row(
                children: [
                  RoundIconButton(
                    icon: Icons.arrow_back_rounded,
                    label: 'Zurück',
                    onTap: _close,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          [widget.kindLabel, ?room].join(' · '),
                          style: HavenText.caption.copyWith(color: hv.tx2),
                        ),
                        Text(
                          a?.name ?? widget.kindLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HavenText.headline.copyWith(color: hv.tx),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }

  Widget _content(
    HavenAutomation a,
    HavenAutomations all,
    List<DashboardSection> sections,
  ) {
    final hv = context.hv;
    final errors = widget.validate(
      a,
      all,
      deviceNames: ref.watch(knobDeviceNamesProvider),
    );
    final conflict = a.enabled ? widget.conflicts?.call(ref, a) : null;

    final head = <Widget>[
      widget.status(a),
      const SizedBox(height: 12),
      SwitchRow(
        title: 'Aktiv',
        subtitle: widget.activeHint,
        value: a.enabled,
        onChanged: (v) async {
          Haptics.tap();
          try {
            await ref
                .read(havenAutomationsProvider.notifier)
                .setEnabled(a.id!, v);
          } catch (e) {
            if (mounted) showHavenToast(context, '$e');
          }
        },
      ),
      const SizedBox(height: 12),
      HavenButton(
        label: 'Live-Test',
        icon: Icons.play_arrow_rounded,
        onTap: () => _liveTest(a),
      ),
      if (conflict != null) ...[const SizedBox(height: 12), conflict],
    ];
    final settings = <Widget>[
      const FieldLabel('Einstellungen'),
      for (final s in sections)
        SettingTile(
          icon: s.icon,
          title: s.title,
          lines: s.lines,
          error: errors[s.step],
          onTap: () => _edit(a, s),
        ),
    ];
    final tail = <Widget>[
      const SizedBox(height: 4),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => context.push(widget.wizardPath),
          icon: Icon(Icons.auto_fix_high_rounded, size: 18, color: hv.acc),
          label: Text(
            'Alle Schritte im Assistenten durchgehen',
            style: HavenText.label.copyWith(color: hv.acc),
          ),
        ),
      ),
      const SizedBox(height: 12),
      HavenButton(
        label: 'Automation löschen',
        icon: Icons.delete_outline_rounded,
        destructive: true,
        onTap: () async {
          final gone = await confirmAndDeleteAutomation(
            context,
            ref,
            a,
            consequence: widget.deleteHint,
          );
          if (gone && mounted) _close();
        },
      ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 860) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              ...head,
              const SizedBox(height: 14),
              ...settings,
              ...tail,
            ],
          );
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 12, 28, 40),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1080),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 380,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [...head, const SizedBox(height: 8), ...tail],
                    ),
                  ),
                  const SizedBox(width: 28),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: settings,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Kleine Info-Pille im Zustand („Aus um 21:40“, „Licht gehört: Melder“).
class StatusFact extends StatelessWidget {
  const StatusFact({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: hv.s2,
        borderRadius: BorderRadius.circular(HavenRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: hv.tx2),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text, style: HavenText.caption.copyWith(color: hv.tx)),
          ),
        ],
      ),
    );
  }
}

/// Karte für den Zustand oben im Dashboard.
class StatusCard extends StatelessWidget {
  const StatusCard({
    super.key,
    required this.icon,
    required this.headline,
    required this.tone,
    required this.active,
    this.facts = const [],
  });
  final IconData icon;
  final String headline;
  final Color tone;
  final bool active;
  final List<Widget> facts;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return AnimatedContainer(
      duration: context.motion(HavenMotion.d3),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: active ? hv.acc.withValues(alpha: 0.10) : hv.s1,
        borderRadius: BorderRadius.circular(HavenRadii.l),
        border: Border.all(color: active ? hv.acc : hv.ln),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AnimatedContainer(
                duration: context.motion(HavenMotion.d3),
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active ? hv.acc.withValues(alpha: 0.18) : hv.s2,
                  border: Border.all(color: active ? hv.acc : hv.ln),
                ),
                child: Icon(icon, color: active ? hv.acc : hv.tx2),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Jetzt',
                      style: HavenText.caption.copyWith(color: hv.tx2),
                    ),
                    Text(
                      headline,
                      style: HavenText.headline.copyWith(color: tone),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (facts.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 6, children: facts),
          ],
        ],
      ),
    );
  }
}
