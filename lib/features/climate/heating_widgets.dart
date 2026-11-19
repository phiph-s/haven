import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/router/router.dart' show Routes;
import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/press_scale.dart';
import '../../data/models/room_heating.dart';
import '../zigbee/widgets/zb_common.dart';
import 'heating_logic.dart';
import 'heating_providers.dart';
import 'thermostat_dial.dart' show kHeatColor;
import 'thermostat_model.dart';
import 'thermostat_widgets.dart' show showThermostatSheet;

/// Farbe einer Pause (Fenster, Sommer, Aus).
Color heatingPauseColor(BuildContext context, HeatingPause? p) => switch (p) {
  HeatingPause.window => const Color(0xFF4AA3DF),
  HeatingPause.summer => const Color(0xFFE5A823),
  HeatingPause.off => context.hv.tx3,
  null => kHeatColor,
};

/// Karte der Heizungsregelung eines Raums: Raumtemperatur aus den
/// Thermometern, Ziel mit Plus und Minus, Betriebsart, Zustand und je
/// Thermostat, was Haven ausgleicht. „Einstellen“ öffnet die Einrichtung.
class RoomHeatingCard extends ConsumerWidget {
  const RoomHeatingCard({super.key, required this.roomId, required this.heat});
  final String roomId;
  final RoomHeating heat;

  Future<void> _control(
    BuildContext context,
    WidgetRef ref, {
    double? target,
    HeatingMode? mode,
  }) async {
    final err = await ref
        .read(heatingProvider.notifier)
        .control(heat.areaId, target: target, mode: mode);
    if (err != null && context.mounted) {
      zbToast(context, 'Nicht übernommen. $err', error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final s = heat.status;
    final c = heat.config;
    final pauseColor = heatingPauseColor(context, s.pause);
    final active = s.pause == null && s.heating == true;
    final t = s.effectiveTarget;
    final canStep = s.mode != HeatingMode.off && c.enabled;

    void nudge(int dir) {
      Haptics.tap();
      final base = s.mode == HeatingMode.heat ? s.target : (t ?? s.target);
      final next = ((base + dir * 0.5).clamp(5, 30) * 2).round() / 2;
      unawaited(_control(context, ref, target: next.toDouble()));
    }

    return AnimatedContainer(
      duration: context.motion(HavenMotion.d2),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: active ? kHeatColor.withValues(alpha: 0.08) : hv.s1,
        borderRadius: BorderRadius.circular(HavenRadii.l),
        border: Border.all(
          color: active ? kHeatColor.withValues(alpha: 0.45) : hv.ln,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.roomTemperature == null
                          ? '–'
                          : '${fmtNum1(s.roomTemperature!)}°',
                      key: const ValueKey('heating-room-temp'),
                      style: HavenText.display.copyWith(
                        color: hv.tx,
                        fontSize: 44,
                        height: 1.05,
                      ),
                    ),
                    Text(
                      heatingSourceText(s, c.sensors.length),
                      style: HavenText.caption.copyWith(color: hv.tx2),
                    ),
                  ],
                ),
              ),
              _TargetStepper(
                target: t,
                off: s.mode == HeatingMode.off,
                enabled: canStep,
                onStep: nudge,
              ),
            ],
          ),
          const SizedBox(height: 10),
          _StatusPill(
            text: c.enabled
                ? heatingStatusText(s)
                : 'Regelung pausiert, die Thermostate laufen allein',
            color: !c.enabled
                ? hv.tx3
                : (s.pause != null || active ? pauseColor : hv.tx2),
            icon: switch (s.pause) {
              HeatingPause.window => Icons.window_rounded,
              HeatingPause.summer => Icons.wb_sunny_rounded,
              HeatingPause.off => Icons.power_settings_new_rounded,
              null =>
                active
                    ? Icons.local_fire_department_rounded
                    : Icons.thermostat_rounded,
            },
          ),
          if (s.released && c.enabled) ...[
            const SizedBox(height: 8),
            _ReleasedNote(
              onResume: () async {
                Haptics.tap();
                final err = await ref
                    .read(heatingProvider.notifier)
                    .resume(heat.areaId);
                if (err != null && context.mounted) {
                  zbToast(context, 'Nicht übernommen. $err', error: true);
                }
              },
            ),
          ],
          const SizedBox(height: 12),
          _ModeChips(
            mode: s.mode,
            presets: c.presets,
            enabled: c.enabled,
            onPick: (m) {
              Haptics.tap();
              unawaited(_control(context, ref, mode: m));
            },
          ),
          const SizedBox(height: 10),
          Divider(height: 1, color: hv.ln),
          for (final trv in s.trvs)
            _TrvLine(
              trv: trv,
              target: t,
              onTap: () => showThermostatSheet(context, (
                ieee: trv.ieee,
                entityId: null,
              )),
            ),
          _Footer(
            status: s,
            config: c,
            onSetup: () =>
                unawaited(context.push<void>(Routes.heating(heat.areaId))),
          ),
        ],
      ),
    );
  }
}

class _TargetStepper extends StatelessWidget {
  const _TargetStepper({
    required this.target,
    required this.off,
    required this.enabled,
    required this.onStep,
  });
  final double? target;
  final bool off;
  final bool enabled;
  final ValueChanged<int> onStep;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    Widget btn(IconData i, String label, int dir) => Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: PressScale(
        onTap: enabled ? () => onStep(dir) : null,
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: hv.s2,
            shape: BoxShape.circle,
            border: Border.all(color: hv.ln2),
          ),
          child: Icon(
            i,
            size: 20,
            color: enabled ? hv.tx : hv.tx3.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          'ZIEL',
          style: HavenText.caption.copyWith(
            color: hv.tx3,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            btn(Icons.remove_rounded, 'Kälter', -1),
            SizedBox(
              width: 62,
              child: AnimatedSwitcher(
                duration: context.motion(HavenMotion.d2),
                child: Text(
                  off || target == null ? 'Aus' : '${fmtNum1(target!)}°',
                  key: ValueKey('heating-target-${target ?? 'off'}'),
                  textAlign: TextAlign.center,
                  style: HavenText.headline.copyWith(
                    color: off ? hv.tx2 : hv.tx,
                    fontSize: 22,
                  ),
                ),
              ),
            ),
            btn(Icons.add_rounded, 'Wärmer', 1),
          ],
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.text,
    required this.color,
    required this.icon,
  });
  final String text;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: AnimatedContainer(
      duration: context.motion(HavenMotion.d2),
      padding: const EdgeInsets.fromLTRB(9, 5, 11, 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(HavenRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: HavenText.label.copyWith(color: color, fontSize: 13.5),
            ),
          ),
        ],
      ),
    ),
  );
}

class _ModeChips extends StatelessWidget {
  const _ModeChips({
    required this.mode,
    required this.presets,
    required this.enabled,
    required this.onPick,
  });
  final HeatingMode mode;
  final Map<HeatingMode, double> presets;
  final bool enabled;
  final ValueChanged<HeatingMode> onPick;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final m in HeatingMode.values)
          Semantics(
            button: true,
            selected: m == mode,
            label: m.label,
            excludeSemantics: true,
            child: PressScale(
              onTap: enabled && m != mode ? () => onPick(m) : null,
              child: AnimatedContainer(
                duration: context.motion(HavenMotion.d2),
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: m == mode ? hv.acc : hv.s2,
                  borderRadius: BorderRadius.circular(HavenRadii.pill),
                  border: Border.all(color: m == mode ? hv.acc : hv.ln),
                ),
                child: Text(
                  presets[m] == null
                      ? m.label
                      : '${m.label} ${fmtNum1(presets[m]!)}°',
                  style: HavenText.label.copyWith(
                    color: m == mode ? hv.ai : hv.tx,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Hinweis: ein Thermostat steuert gerade selbst (am Gerät gestellt), mit
/// „Wieder regeln“.
class _ReleasedNote extends StatelessWidget {
  const _ReleasedNote({required this.onResume});
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Container(
      key: const ValueKey('heating-released'),
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: hv.s2,
        borderRadius: BorderRadius.circular(HavenRadii.m),
        border: Border.all(color: hv.ln),
      ),
      child: Row(
        children: [
          Icon(Icons.pan_tool_alt_rounded, size: 18, color: hv.tx2),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Am Thermostat gesteuert, Haven hält still',
              style: HavenText.caption.copyWith(color: hv.tx),
            ),
          ),
          TextButton(
            key: const ValueKey('heating-resume'),
            onPressed: onResume,
            child: const Text('Wieder regeln'),
          ),
        ],
      ),
    );
  }
}

class _TrvLine extends StatelessWidget {
  const _TrvLine({
    required this.trv,
    required this.target,
    required this.onTap,
  });
  final HeatingTrvStatus trv;
  final double? target;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final heating = trv.heating == true;
    final fix = trvCorrectionText(trv, target);
    final released = trvReleasedText(trv);
    final parts = [
      ?released,
      if (trv.localTemperature != null)
        'misst ${fmtTemp(trv.localTemperature!)}',
      if (trv.valve != null) 'Ventil ${trv.valve} %',
    ];
    return Semantics(
      button: true,
      label: trv.name,
      child: PressScale(
        pressedScale: 0.99,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Icon(
                heating
                    ? Icons.local_fire_department_rounded
                    : Icons.thermostat_rounded,
                size: 20,
                color: heating ? kHeatColor : hv.tx2,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      trv.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HavenText.label.copyWith(
                        color: hv.tx,
                        fontSize: 14.5,
                      ),
                    ),
                    Text(
                      [...parts, ?fix].join(' · '),
                      maxLines: 2,
                      style: HavenText.caption.copyWith(color: hv.tx2),
                    ),
                  ],
                ),
              ),
              if (trv.pending)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Tooltip(
                    message: 'Wartet auf das Thermostat',
                    child: Icon(Icons.sync_rounded, size: 16, color: hv.tx3),
                  ),
                ),
              Icon(Icons.chevron_right_rounded, size: 20, color: hv.tx3),
            ],
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.status,
    required this.config,
    required this.onSetup,
  });
  final HeatingStatus status;
  final HeatingConfig config;
  final VoidCallback onSetup;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final chips = <Widget>[
      if (config.windows.isNotEmpty)
        ZbPill(
          icon: Icons.window_rounded,
          text: status.windowOpen ? 'Fenster offen' : 'Fenster zu',
          color: status.windowOpen ? const Color(0xFF4AA3DF) : hv.tx2,
        ),
      if (config.outdoorEntity != null)
        ZbPill(
          icon: Icons.wb_sunny_outlined,
          text: status.outdoorValue == null
              ? 'Außen –'
              : 'Außen ${fmtTemp(status.outdoorValue!)}',
          color: status.summer ? const Color(0xFFE5A823) : hv.tx2,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      // Bricht bei wenig Platz um (Kartenpanel, Inspektor).
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 6,
        children: [
          Wrap(spacing: 6, runSpacing: 6, children: chips),
          TextButton.icon(
            onPressed: () {
              Haptics.tap();
              onSetup();
            },
            icon: Icon(Icons.tune_rounded, size: 18, color: hv.acc),
            label: Text(
              'Regelung',
              style: HavenText.label.copyWith(color: hv.acc),
            ),
          ),
        ],
      ),
    );
  }
}

/// Hinweis im Raum ohne Regelung: Thermostate nach einem Raumthermometer
/// regeln lassen.
class HeatingSetupPrompt extends StatelessWidget {
  const HeatingSetupPrompt({super.key, required this.areaId});
  final String areaId;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      button: true,
      label: 'Nach Raumthermometer regeln',
      excludeSemantics: true,
      child: PressScale(
        pressedScale: 0.99,
        onTap: () {
          Haptics.tap();
          unawaited(context.push<void>(Routes.heating(areaId)));
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          decoration: BoxDecoration(
            color: hv.acc.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(HavenRadii.m),
            border: Border.all(color: hv.acc.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              Icon(Icons.device_thermostat_rounded, color: hv.acc),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Nach Raumthermometer regeln',
                      style: HavenText.label.copyWith(color: hv.tx),
                    ),
                    Text(
                      'Das Thermostat misst am Heizkörper. Haven gleicht das mit einem Thermometer im Raum aus, pausiert bei offenem Fenster und im Sommer.',
                      style: HavenText.caption.copyWith(color: hv.tx2),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: hv.tx3),
            ],
          ),
        ),
      ),
    );
  }
}
