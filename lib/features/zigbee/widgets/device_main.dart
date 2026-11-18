import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/light/color_math.dart';
import '../../../core/light/room_palette.dart';
import '../../../core/state/providers.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/accent_scope.dart';
import '../../../core/widgets/haven_card.dart';
import '../../../core/widgets/haven_switch.dart';
import '../../../core/widgets/segmented.dart';
import '../../../data/models/zigbee.dart';
import '../../../data/room_view.dart';
import '../../climate/thermostat_widgets.dart';
import '../../room/widgets/brightness_slider.dart';
import '../../room/widgets/color_controls.dart';
import '../../room/widgets/light_control_list.dart';
import '../zigbee_model.dart';
import '../zigbee_providers.dart';
import 'device_icon.dart';
import 'zb_common.dart';

/// Hauptfunktion eines Geräts, groß und je `device_type`. [compact] lässt
/// Farbrad und Zusatzwerte weg (Vorschau im Anlernen-Assistenten).
class ZbMainFunction extends ConsumerWidget {
  const ZbMainFunction({super.key, required this.view, this.compact = false});
  final ZbDeviceView view;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (view.type) {
      case ZbType.light:
        final e = view.entities.where((e) => e.domain == 'light').firstOrNull;
        if (e != null) {
          return _LightMain(view: view, entityId: e.entityId, compact: compact);
        }
        return _SwitchMain(view: view, title: 'Licht', zigbeeOnly: true);
      case ZbType.plug:
        return _SwitchMain(view: view, title: 'Steckdose', metrics: !compact);
      case ZbType.relay:
      case ZbType.switch_:
        return _SwitchMain(view: view, title: 'Schalter');
      case ZbType.climate:
        return _ClimateMain(view: view);
      case ZbType.thermostat:
        return ThermostatMain(
          ieee: view.ieee,
          entityId: view.entities
              .where((e) => e.domain == 'climate')
              .firstOrNull
              ?.entityId,
          compact: compact,
        );
      case ZbType.motion:
      case ZbType.presence:
        return _PresenceMain(view: view, compact: compact);
      case ZbType.contact:
        return _ContactMain(view: view);
      case ZbType.remote:
      case ZbType.knob:
        return _RemoteMain(view: view);
      default:
        return _GenericMain(view: view);
    }
  }
}

class _MainCard extends StatelessWidget {
  const _MainCard({required this.child, this.glow});
  final Widget child;

  /// Tönt den oberen Rand der Karte.
  final Color? glow;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
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
            if (glow != null)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0, -1.1),
                      radius: 1.1,
                      colors: [
                        glow!.withValues(alpha: hv.isDark ? 0.28 : 0.2),
                        glow!.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            Padding(padding: const EdgeInsets.all(18), child: child),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.unit,
    this.big = true,
  });
  final String label;
  final String value;
  final String? unit;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: HavenText.caption.copyWith(color: hv.tx2)),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: (big ? HavenText.power : HavenText.headline).copyWith(
                  color: hv.tx,
                ),
              ),
              if (unit != null && unit!.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(
                  unit!,
                  style: HavenText.label.copyWith(
                    color: hv.tx2,
                    fontSize: big ? 17 : 14,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

String _num(ZbDeviceView v, String p, {int digits = 1}) {
  final n = v.number(p);
  return n == null ? '–' : fmtNum(n, digits: digits);
}

// ---- Licht ------------------------------------------------------------------

class _LightMain extends ConsumerStatefulWidget {
  const _LightMain({
    required this.view,
    required this.entityId,
    required this.compact,
  });
  final ZbDeviceView view;
  final String entityId;
  final bool compact;

  @override
  ConsumerState<_LightMain> createState() => _LightMainState();
}

class _LightMainState extends ConsumerState<_LightMain> {
  bool? _white;

  void _set({bool? on, int? brightness, Rgb? rgb, int? kelvin}) => ref
      .read(repositoryProvider)
      .setLights(
        [widget.entityId],
        on: on,
        brightness: brightness,
        rgb: rgb,
        kelvin: kelvin,
      );

  @override
  Widget build(BuildContext context) {
    final lamp = ref.watch(
      snapshotProvider.select((s) => s.lamp(widget.entityId)),
    );
    if (lamp == null) return const SizedBox.shrink();
    final hv = context.hv;
    final dark = hv.isDark;
    final palette = HouseView([lamp]).palette(dark: dark);
    final white = _white ?? (lamp.kelvin != null || !lamp.supportsColor);
    return AccentScope(
      palette: palette.isOn ? palette : RoomPalette.off,
      child: Builder(
        builder: (context) {
          final hv = context.hv;
          return _MainCard(
            glow: lamp.on ? colorOf(uiColor(lamp.color, dark: dark)) : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            lamp.on ? 'An' : 'Aus',
                            style: HavenText.title.copyWith(
                              color: hv.tx,
                              fontSize: 30,
                            ),
                          ),
                          Text(
                            lamp.on
                                ? '${lamp.brightness} % hell'
                                : 'Zum Einschalten tippen',
                            style: HavenText.body.copyWith(
                              color: hv.tx2,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                    HavenSwitch(
                      value: lamp.on,
                      semanticLabel: 'Licht',
                      onChanged: (v) => _set(on: v),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                SizedBox(
                  height: 46,
                  child: BrightnessSlider(
                    axis: Axis.horizontal,
                    value: lamp.on ? lamp.brightness : 0,
                    colors: [
                      colorOf(
                        uiColor((255, 190, 120), dark: dark),
                      ).withValues(alpha: 0.9),
                      hv.acc,
                    ],
                    onChanged: (v) =>
                        _set(on: true, brightness: v == 0 ? 1 : v),
                  ),
                ),
                if (!widget.compact) ...[
                  const SizedBox(height: 14),
                  if (lamp.supportsColor && lamp.supportsKelvin)
                    HavenSegmented<bool>(
                      neutral: true,
                      options: const [(false, 'Farbe'), (true, 'Weiß')],
                      selected: white,
                      onChanged: (v) => setState(() => _white = v),
                    ),
                  if (!lamp.supportsColor && !lamp.supportsKelvin)
                    Text(
                      'Dieses Licht kennt nur Helligkeit.',
                      style: HavenText.caption.copyWith(color: hv.tx2),
                    )
                  else if (!white && lamp.supportsColor) ...[
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: ColorWheel(
                          size: 200,
                          color: lamp.color,
                          onChanged: (c) => _set(on: true, rgb: c),
                        ),
                      ),
                    ),
                    ColorSwatches(onPick: (c) => _set(on: true, rgb: c)),
                  ] else ...[
                    const SizedBox(height: 10),
                    KelvinSlider(
                      kelvin:
                          lamp.kelvin ??
                          rgbToKelvinApprox(
                            lamp.color,
                          ).clamp(lamp.minKelvin, lamp.maxKelvin),
                      min: lamp.minKelvin,
                      max: lamp.maxKelvin,
                      onChanged: (k) => _set(on: true, kelvin: k),
                    ),
                  ],
                  const SizedBox(height: 16),
                  ExcludeLightRow(entityId: widget.entityId),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

// ---- Schalter, Steckdose -----------------------------------------------------

class _SwitchMain extends ConsumerWidget {
  const _SwitchMain({
    required this.view,
    required this.title,
    this.metrics = false,
    this.zigbeeOnly = false,
  });
  final ZbDeviceView view;
  final String title;
  final bool metrics;
  final bool zigbeeOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final e = zigbeeOnly ? null : view.mainEntity;
    final stateF = view.device.classified.primaryOf('state');
    final bool? on = e != null
        ? (e.isAvailable ? e.isOn : null)
        : (view.values.containsKey('state')
              ? (stateF ?? const ZbFeature(property: 'state', label: '')).isOn(
                  view.values['state'],
                )
              : null);

    Future<void> toggle(bool v) async {
      if (e != null) {
        await ref
            .read(repositoryProvider)
            .callService(
              e.domain,
              v ? 'turn_on' : 'turn_off',
              entityId: e.entityId,
            );
      } else {
        final err = await ref
            .read(zigbeeProvider.notifier)
            .setValue(view.ieee, 'state', v ? 'ON' : 'OFF');
        if (err != null && context.mounted) {
          zbToast(context, err, error: true);
        }
      }
    }

    final power = view.number('power');
    return _MainCard(
      glow: on == true ? hv.acc : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      on == null ? 'Unbekannt' : (on ? 'An' : 'Aus'),
                      style: HavenText.title.copyWith(
                        color: hv.tx,
                        fontSize: 30,
                      ),
                    ),
                    Text(
                      title,
                      style: HavenText.body.copyWith(
                        color: hv.tx2,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
              HavenSwitch(
                value: on == true,
                semanticLabel: title,
                onChanged: on == null && e == null && !zigbeeOnly
                    ? null
                    : toggle,
              ),
            ],
          ),
          if (metrics && (power != null || view.number('energy') != null)) ...[
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _Metric(
                    label: 'Leistung',
                    value: _num(view, 'power', digits: 0),
                    unit: 'W',
                  ),
                ),
                Expanded(
                  child: _Metric(
                    label: 'Energie gesamt',
                    value: _num(view, 'energy', digits: 1),
                    unit: 'kWh',
                  ),
                ),
              ],
            ),
            if (view.number('voltage') != null ||
                view.number('current') != null) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _Metric(
                      label: 'Spannung',
                      value: _num(view, 'voltage', digits: 0),
                      unit: 'V',
                      big: false,
                    ),
                  ),
                  Expanded(
                    child: _Metric(
                      label: 'Strom',
                      value: _num(view, 'current', digits: 2),
                      unit: 'A',
                      big: false,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}

// ---- Klimasensor --------------------------------------------------------------

class _ClimateMain extends StatelessWidget {
  const _ClimateMain({required this.view});
  final ZbDeviceView view;

  @override
  Widget build(BuildContext context) {
    final hasHum = view.number('humidity') != null;
    return _MainCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _Metric(
              label: 'Temperatur',
              value: _num(view, 'temperature'),
              unit: '°C',
            ),
          ),
          if (hasHum)
            Expanded(
              child: _Metric(
                label: 'Luftfeuchte',
                value: _num(view, 'humidity', digits: 0),
                unit: '%',
              ),
            ),
        ],
      ),
    );
  }
}

// ---- Bewegung, Anwesenheit -----------------------------------------------------

class _PresenceMain extends StatelessWidget {
  const _PresenceMain({required this.view, required this.compact});
  final ZbDeviceView view;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final isPresence = view.type == ZbType.presence;
    final raw = view.raw(isPresence ? 'presence' : 'occupancy');
    final active = raw == true;
    final known = raw is bool;
    final text = !known
        ? 'Unbekannt'
        : isPresence
        ? (active ? 'Jemand ist da' : 'Niemand erkannt')
        : (active ? 'Bewegung erkannt' : 'Ruhig');
    final seen = view.lastSeen;
    final lux = view.number('illuminance');
    final temp = view.number('temperature');
    final hum = view.number('humidity');
    return _MainCard(
      glow: active ? hv.ok : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ZbPulsingIcon(type: view.type, size: 56, active: active),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      text,
                      style: HavenText.title.copyWith(
                        color: hv.tx,
                        fontSize: 25,
                      ),
                    ),
                    if (seen != null)
                      Text(
                        'Zuletzt gemeldet ${agoLabel(seen)}',
                        style: HavenText.body.copyWith(
                          color: hv.tx2,
                          fontSize: 14,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (!compact && (lux != null || temp != null || hum != null)) ...[
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (lux != null)
                  Expanded(
                    child: _Metric(
                      label: 'Helligkeit',
                      value: fmtNum(lux, digits: 0),
                      unit: 'lx',
                      big: false,
                    ),
                  ),
                if (temp != null)
                  Expanded(
                    child: _Metric(
                      label: 'Temperatur',
                      value: fmtNum(temp),
                      unit: '°C',
                      big: false,
                    ),
                  ),
                if (hum != null)
                  Expanded(
                    child: _Metric(
                      label: 'Luftfeuchte',
                      value: fmtNum(hum, digits: 0),
                      unit: '%',
                      big: false,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ---- Kontakt ----------------------------------------------------------------------

class _ContactMain extends StatelessWidget {
  const _ContactMain({required this.view});
  final ZbDeviceView view;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    // Z2M: contact true = geschlossen. HA-Entity: on = offen.
    bool? closed;
    if (view.values['contact'] is bool) {
      closed = view.values['contact'] as bool;
    } else {
      final e = view.entity('contact');
      if (e != null && e.isAvailable) closed = !e.isOn;
    }
    return _MainCard(
      glow: closed == false ? hv.warn : null,
      child: Row(
        children: [
          ZbDeviceIcon(
            type: view.type,
            size: 56,
            active: closed == false,
            tint: hv.warn,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  closed == null
                      ? 'Unbekannt'
                      : (closed ? 'Geschlossen' : 'Offen'),
                  style: HavenText.title.copyWith(color: hv.tx, fontSize: 25),
                ),
                if (view.lastSeen != null)
                  Text(
                    'Zuletzt gemeldet ${agoLabel(view.lastSeen!)}',
                    style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Taster, Drehregler ---------------------------------------------------------------

class _RemoteMain extends ConsumerWidget {
  const _RemoteMain({required this.view});
  final ZbDeviceView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final rooms = ref.watch(roomsProvider);
    String? target;
    for (final r in rooms) {
      if (r.controls.any((c) => c.name == view.name)) target = r.name;
    }
    target ??= view.roomName;
    final action = view.values['action']?.toString();
    return _MainCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Letzte Aktion',
            style: HavenText.caption.copyWith(color: hv.tx2),
          ),
          const SizedBox(height: 2),
          Text(
            actionLabel(action),
            style: HavenText.title.copyWith(color: hv.tx, fontSize: 25),
          ),
          if (view.lastSeen != null)
            Text(
              agoLabel(view.lastSeen!),
              style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
            ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: hv.s2,
              borderRadius: BorderRadius.circular(HavenRadii.m),
            ),
            child: Row(
              children: [
                Icon(Icons.tune_rounded, size: 20, color: hv.tx2),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    target == null
                        ? 'Noch keinem Raum zugeordnet'
                        : 'Steuert $target',
                    style: HavenText.label.copyWith(color: hv.tx, fontSize: 14),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Sonstige ---------------------------------------------------------------------------

class _GenericMain extends StatelessWidget {
  const _GenericMain({required this.view});
  final ZbDeviceView view;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final rows = <Widget>[];
    for (final f in view.device.classified.primary) {
      final v = view.read(f);
      if (v == null || f.type == 'composite') continue;
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  f.label,
                  style: HavenText.body.copyWith(color: hv.tx2),
                ),
              ),
              Text(
                '${v is num ? fmtNum(v) : v}${f.unit == null ? '' : ' ${unitLabel(f.unit)}'}',
                style: HavenText.label.copyWith(color: hv.tx),
              ),
            ],
          ),
        ),
      );
    }
    return HavenCard(
      padding: const EdgeInsets.all(18),
      child: rows.isEmpty
          ? Text(
              'Für dieses Gerät gibt es noch keine Anzeige.',
              style: HavenText.body.copyWith(color: hv.tx2),
            )
          : Column(children: rows),
    );
  }
}
