import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/press_scale.dart';
import '../../core/widgets/section_header.dart';
import '../zigbee/widgets/zb_common.dart';
import '../zigbee/zigbee_screen.dart' show zigbeeDevicePath;
import 'heating_providers.dart';
import 'heating_widgets.dart';
import 'thermostat_dial.dart';
import 'thermostat_model.dart';
import 'thermostat_providers.dart';

/// Bedienung eines Thermostats: Stellrad, Plus und Minus, Betriebsart,
/// Boost und die wichtigsten Werte. Für Gerät-Detail, Karte und Raum.
class ThermostatControl extends ConsumerStatefulWidget {
  const ThermostatControl({
    super.key,
    required this.thermostat,
    this.dialSize = 248,
  });
  final ThermostatRef thermostat;
  final double dialSize;

  @override
  ConsumerState<ThermostatControl> createState() => _ThermostatControlState();
}

class _ThermostatControlState extends ConsumerState<ThermostatControl> {
  final _dial = GlobalKey<ThermostatDialState>();

  Future<void> _run(Future<String?> f) async {
    final err = await f;
    if (err != null && mounted) {
      zbToast(context, 'Nicht übernommen. $err', error: true);
    }
  }

  Future<void> _pickBoost(ThermostatState t) async {
    final w = ThermostatWriter(ref);
    if (t.boosting) {
      Haptics.tap();
      return _run(w.setBoost(t, 0));
    }
    final minutes = await showZbSheet<int>(
      context,
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Boost', style: HavenText.headline.copyWith(color: ctx.hv.tx)),
          const SizedBox(height: 4),
          Text(
            'Das Ventil öffnet ganz, damit der Raum schnell warm wird. Danach gilt wieder die Betriebsart.',
            style: HavenText.body.copyWith(color: ctx.hv.tx2, fontSize: 14),
          ),
          const SizedBox(height: 14),
          for (final m in const [15, 30, 60, 120])
            ZbChoiceRow(
              label: m < 60
                  ? '$m Minuten'
                  : '${m ~/ 60} ${m == 60 ? 'Stunde' : 'Stunden'}',
              selected: false,
              onTap: () => Navigator.of(ctx).pop(m),
            ),
        ],
      ),
    );
    if (minutes != null) await _run(w.setBoost(t, minutes));
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final t = ref.watch(thermostatProvider(widget.thermostat));
    if (t == null) {
      return Text(
        'Dieses Thermostat gibt es nicht mehr.',
        style: HavenText.body.copyWith(color: hv.tx2),
      );
    }
    final w = ThermostatWriter(ref);
    final modes = t.modes.isNotEmpty
        ? t.modes
        : (t.isZigbee ? ThermoMode.values : const <ThermoMode>[]);
    final small = widget.dialSize < 230;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusLine(state: t),
        const SizedBox(height: 6),
        Center(
          child: ThermostatDial(
            key: _dial,
            state: t,
            size: widget.dialSize,
            onCommit: (v) => _run(w.setTarget(t, v)),
          ),
        ),
        Transform.translate(
          offset: Offset(0, small ? -22 : -30),
          child: Row(
            children: [
              _RoundStep(
                icon: Icons.remove_rounded,
                label: 'Kälter',
                enabled: t.canSetTarget,
                onTap: () => _dial.currentState?.nudge(-1),
              ),
              const Spacer(),
              _RoundStep(
                icon: Icons.add_rounded,
                label: 'Wärmer',
                enabled: t.canSetTarget,
                onTap: () => _dial.currentState?.nudge(1),
              ),
            ],
          ),
        ),
        if (modes.isNotEmpty) ...[
          Transform.translate(
            offset: Offset(0, small ? -10 : -16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Betriebsart',
                  style: HavenText.caption.copyWith(color: hv.tx2),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final m in modes)
                      ThermoModeChip(
                        mode: m,
                        selected: t.mode == m,
                        onTap: () {
                          Haptics.tick();
                          _run(w.setMode(t, m));
                        },
                      ),
                  ],
                ),
                if (t.mode != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _modeHint(t),
                    style: HavenText.caption.copyWith(color: hv.tx2),
                  ),
                ],
              ],
            ),
          ),
        ],
        if (t.canBoost) ...[
          const SizedBox(height: 2),
          _BoostRow(state: t, onTap: () => _pickBoost(t)),
        ],
        const SizedBox(height: 12),
        ThermostatFacts(state: t),
      ],
    );
  }

  String _modeHint(ThermostatState t) {
    final m = t.mode!;
    final temp = switch (m) {
      ThermoMode.comfort => t.comfortTemp,
      ThermoMode.eco => t.ecoTemp,
      ThermoMode.frost => t.frostTemp,
      _ => null,
    };
    return temp == null
        ? m.help
        : '${m.help.substring(0, m.help.length - 1)} (${fmtTemp(temp)}).';
  }
}

/// Zeile ganz oben: Flamme beim Heizen, sonst ein ruhiges Symbol, dazu der
/// Zustand als Satz.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.state});
  final ThermostatState state;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final t = state;
    final (IconData icon, Color color) = t.windowOpen == true
        ? (Icons.sensor_window_outlined, hv.warn)
        : t.isOff
        ? (Icons.power_settings_new_rounded, hv.tx3)
        : t.boosting
        ? (Icons.bolt_rounded, kHeatColor)
        : t.heating == true
        ? (Icons.local_fire_department_rounded, kHeatColor)
        : (Icons.thermostat_rounded, hv.tx2);
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            t.statusText,
            style: HavenText.headline.copyWith(color: hv.tx, fontSize: 17),
          ),
        ),
      ],
    );
  }
}

class _RoundStep extends StatelessWidget {
  const _RoundStep({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      button: true,
      label: label,
      enabled: enabled,
      child: PressScale(
        onTap: enabled ? onTap : null,
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: hv.s2,
            shape: BoxShape.circle,
            border: Border.all(color: hv.ln2),
          ),
          child: Icon(
            icon,
            size: 26,
            color: enabled ? hv.tx : hv.tx3.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}

/// Auswahl einer Betriebsart.
class ThermoModeChip extends StatelessWidget {
  const ThermoModeChip({
    super.key,
    required this.mode,
    required this.selected,
    required this.onTap,
  });
  final ThermoMode mode;
  final bool selected;
  final VoidCallback onTap;

  static IconData iconOf(ThermoMode m) => switch (m) {
    ThermoMode.manual => Icons.pan_tool_alt_outlined,
    ThermoMode.open => Icons.local_fire_department_outlined,
    ThermoMode.schedule => Icons.schedule_rounded,
    ThermoMode.comfort => Icons.weekend_outlined,
    ThermoMode.eco => Icons.eco_outlined,
    ThermoMode.frost => Icons.ac_unit_rounded,
    ThermoMode.off => Icons.power_settings_new_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Betriebsart ${mode.label}',
      excludeSemantics: true,
      child: PressScale(
        onTap: onTap,
        child: AnimatedContainer(
          duration: context.motion(HavenMotion.d2),
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected ? hv.acc : hv.s2,
            borderRadius: BorderRadius.circular(HavenRadii.pill),
            border: Border.all(color: selected ? hv.acc : hv.ln2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(iconOf(mode), size: 16, color: selected ? hv.ai : hv.tx2),
              const SizedBox(width: 6),
              Text(
                mode.label,
                style: HavenText.label.copyWith(
                  color: selected ? hv.ai : hv.tx,
                  fontSize: 13.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BoostRow extends StatelessWidget {
  const _BoostRow({required this.state, required this.onTap});
  final ThermostatState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final on = state.boosting;
    return PressScale(
      pressedScale: 0.99,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: HavenSpace.touch),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: on ? kHeatColor.withValues(alpha: 0.14) : hv.s2,
          borderRadius: BorderRadius.circular(HavenRadii.m),
          border: Border.all(color: on ? kHeatColor : hv.ln),
        ),
        child: Row(
          children: [
            Icon(Icons.bolt_rounded, size: 20, color: on ? kHeatColor : hv.tx2),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    on ? 'Boost läuft' : 'Boost',
                    style: HavenText.label.copyWith(color: hv.tx, fontSize: 14),
                  ),
                  Text(
                    on
                        ? 'Noch ${state.boostMinutes} min volle Wärme'
                        : 'Kurz volle Wärme, danach wie vorher',
                    style: HavenText.caption.copyWith(color: hv.tx2),
                  ),
                ],
              ),
            ),
            Text(
              on ? 'Beenden' : 'Starten',
              style: HavenText.label.copyWith(
                color: on ? kHeatColor : hv.acc,
                fontSize: 13.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Kleine Werte als Pillen: Ventil, Fenster, Batterie, Kindersicherung.
class ThermostatFacts extends StatelessWidget {
  const ThermostatFacts({super.key, required this.state});
  final ThermostatState state;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final t = state;
    final items = <(IconData, String, Color?)>[
      if (t.valve != null)
        (
          Icons.water_drop_outlined,
          'Ventil ${t.valve} %',
          (t.valve ?? 0) > 0 ? kHeatColor : null,
        ),
      if (t.windowOpen != null)
        (
          t.windowOpen! ? Icons.sensor_window_outlined : Icons.window_outlined,
          t.windowOpen! ? 'Fenster offen' : 'Fenster zu',
          t.windowOpen! ? hv.warn : null,
        ),
      if (t.battery != null)
        (
          t.battery! < 20
              ? Icons.battery_alert_rounded
              : Icons.battery_std_rounded,
          'Batterie ${t.battery} %',
          batteryColor(context, t.battery!),
        ),
      if (t.childLock == true)
        (Icons.lock_outline_rounded, 'Tasten gesperrt', null),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (icon, text, tone) in items)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: hv.s2,
              borderRadius: BorderRadius.circular(HavenRadii.pill),
              border: Border.all(color: hv.ln),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: tone ?? hv.tx2),
                const SizedBox(width: 5),
                Text(
                  text,
                  style: HavenText.caption.copyWith(
                    color: hv.tx,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Hauptkarte im Gerät-Detail: Bedienung mit warmem Schein beim Heizen.
class ThermostatMain extends ConsumerWidget {
  const ThermostatMain({
    super.key,
    required this.ieee,
    this.entityId,
    this.compact = false,
  });
  final String ieee;
  final String? entityId;

  /// Vorschau im Anlernen: kleineres Rad.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final r = (ieee: ieee, entityId: entityId);
    final heating = ref.watch(
      thermostatProvider(r).select((t) => t?.heating == true && !t!.isOff),
    );
    return Container(
      decoration: BoxDecoration(
        color: hv.s1,
        borderRadius: BorderRadius.circular(HavenRadii.l),
        border: Border.all(color: hv.ln),
        boxShadow: hv.shadowSmall,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(HavenRadii.l),
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedOpacity(
                opacity: heating ? 1 : 0,
                duration: context.motion(HavenMotion.d4),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0, -0.6),
                      radius: 1,
                      colors: [
                        kHeatColor.withValues(alpha: hv.isDark ? 0.24 : 0.16),
                        kHeatColor.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(18),
              child: ThermostatControl(
                thermostat: r,
                dialSize: compact ? 200 : 248,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Kompakte Zeile: Name, Zustand, Plus und Minus. Antippen öffnet das
/// Thermostat-Sheet ([onOpen]).
class ThermostatRow extends ConsumerStatefulWidget {
  const ThermostatRow({super.key, required this.thermostat, this.onOpen});
  final ThermostatRef thermostat;
  final VoidCallback? onOpen;

  @override
  ConsumerState<ThermostatRow> createState() => _ThermostatRowState();
}

class _ThermostatRowState extends ConsumerState<ThermostatRow> {
  double? _local;
  Timer? _debounce;
  Timer? _release;

  @override
  void dispose() {
    _debounce?.cancel();
    _release?.cancel();
    super.dispose();
  }

  void _nudge(ThermostatState t, int dir) {
    Haptics.tick();
    final base = _local ?? t.shownTarget ?? t.current ?? 20;
    setState(() => _local = t.clampTarget(base + dir * t.step));
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 650), () async {
      final v = _local;
      if (v == null) return;
      final err = await ThermostatWriter(ref).setTarget(t, v);
      if (!mounted) return;
      if (err != null) zbToast(context, 'Nicht übernommen. $err', error: true);
      // Kurz halten, bis der neue Sollwert gemeldet ist.
      _release?.cancel();
      _release = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _local = null);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final t = ref.watch(thermostatProvider(widget.thermostat));
    if (t == null) return const SizedBox.shrink();
    final target = _local ?? t.shownTarget;
    final heating = t.heating == true && !t.isOff;
    Widget step(IconData i, String label, int dir) => Semantics(
      button: true,
      label: '$label ${t.name}',
      child: PressScale(
        onTap: t.canSetTarget ? () => _nudge(t, dir) : null,
        child: Container(
          width: HavenSpace.touch,
          height: HavenSpace.touch,
          alignment: Alignment.center,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: hv.s2,
              shape: BoxShape.circle,
              border: Border.all(color: hv.ln2),
            ),
            child: Icon(
              i,
              size: 20,
              color: t.canSetTarget ? hv.tx : hv.tx3.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
    return PressScale(
      pressedScale: 0.99,
      onTap: widget.onOpen,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
        decoration: BoxDecoration(
          color: heating ? kHeatColor.withValues(alpha: 0.1) : hv.s2,
          borderRadius: BorderRadius.circular(HavenRadii.m),
          border: Border.all(
            color: heating ? kHeatColor.withValues(alpha: 0.5) : hv.ln,
          ),
        ),
        child: Row(
          children: [
            Icon(
              heating
                  ? Icons.local_fire_department_rounded
                  : Icons.thermostat_rounded,
              size: 22,
              color: heating ? kHeatColor : hv.tx2,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HavenText.label.copyWith(color: hv.tx, fontSize: 15),
                  ),
                  Text(
                    [
                      if (t.current != null) 'Raum ${fmtTemp(t.current!)}',
                      if (t.mode != null) t.mode!.label,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HavenText.caption.copyWith(color: hv.tx2),
                  ),
                ],
              ),
            ),
            step(Icons.remove_rounded, 'Kälter', -1),
            SizedBox(
              width: 58,
              child: Text(
                t.isOff
                    ? 'Aus'
                    : (target == null ? '–' : '${fmtNum1(target)}°'),
                textAlign: TextAlign.center,
                style: HavenText.headline.copyWith(
                  color: t.isOff ? hv.tx2 : hv.tx,
                  fontSize: 20,
                ),
              ),
            ),
            step(Icons.add_rounded, 'Wärmer', 1),
          ],
        ),
      ),
    );
  }
}

/// Sheet mit der vollen Bedienung, dazu „Gerät öffnen“ bei Zigbee.
Future<void> showThermostatSheet(BuildContext context, ThermostatRef r) {
  final router = GoRouter.of(context);
  return showZbSheet<void>(
    context,
    builder: (ctx) => Consumer(
      builder: (ctx, ref, _) {
        final t = ref.watch(thermostatProvider(r));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t?.name ?? 'Thermostat',
              style: HavenText.section.copyWith(color: ctx.hv.tx, fontSize: 22),
            ),
            if (t?.roomName != null)
              Text(
                'Thermostat · ${t!.roomName}',
                style: HavenText.caption.copyWith(color: ctx.hv.tx2),
              ),
            const SizedBox(height: 12),
            ThermostatControl(thermostat: r, dialSize: 232),
            if (r.ieee != null) ...[
              const SizedBox(height: 14),
              HavenButton(
                label: 'Gerät öffnen',
                icon: Icons.open_in_new_rounded,
                onTap: () {
                  Navigator.of(ctx).pop();
                  unawaited(router.push<void>(zigbeeDevicePath(r.ieee!)));
                },
              ),
            ],
          ],
        );
      },
    ),
  );
}

/// Abschnitt „Heizung“ im Raum. Mit Heizungsregelung die Karte der
/// Regelung, sonst je Thermostat eine Zeile mit Plus und Minus (Antippen
/// öffnet die volle Bedienung) und der Hinweis, nach einem Raumthermometer
/// zu regeln. Ohne Thermostat leer.
class RoomHeatingSection extends ConsumerWidget {
  const RoomHeatingSection({super.key, required this.roomId});
  final String roomId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final refs = ref.watch(roomThermostatsProvider(roomId));
    final heat = ref.watch(roomHeatingProvider(roomId));
    if (refs.isEmpty && heat == null) return const SizedBox.shrink();
    final canSetup =
        ref.watch(heatingSupportedProvider) && refs.any((r) => r.ieee != null);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader('Heizung'),
          const SizedBox(height: 10),
          if (heat != null)
            RoomHeatingCard(roomId: roomId, heat: heat)
          else ...[
            for (final r in refs)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ThermostatRow(
                  thermostat: r,
                  onOpen: () => showThermostatSheet(context, r),
                ),
              ),
            if (canSetup)
              HeatingSetupPrompt(areaId: ref.watch(roomAreaProvider(roomId))),
          ],
        ],
      ),
    );
  }
}
