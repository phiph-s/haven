import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/router/router.dart' show Routes;
import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/haven_card.dart';
import '../../core/widgets/haven_switch.dart';
import '../../core/widgets/press_scale.dart';
import '../../core/widgets/segmented.dart';
import '../../data/haven_repository.dart';
import '../../data/models/room_heating.dart';
import '../../data/models/zigbee.dart';
import '../automations/knob_editor_screen.dart' show FieldLabel, PickRow;
import '../zigbee/widgets/zb_common.dart';
import '../zigbee/zigbee_model.dart';
import '../zigbee/zigbee_providers.dart';
import 'heating_logic.dart';
import 'heating_providers.dart';
import 'thermostat_dial.dart' show kHeatColor;
import 'thermostat_model.dart';

/// Kann das Thermostat seine Messung abgleichen (`local_temperature_calibration`)?
bool trvCanCalibrate(ZbDeviceView v) {
  final c = v.device.classified;
  for (final f in [...c.primary, ...c.settings, ...c.hidden]) {
    if (f.property == 'local_temperature_calibration') return f.canWrite;
  }
  return v.values.containsKey('local_temperature_calibration');
}

/// Einrichtung der Heizungsregelung eines Raums: Thermostate, Raumthermometer,
/// Ausgleich, Fenster, Sommerpause, Temperaturen der Betriebsarten.
/// Eine Seite, oben die Vorschau, was Haven mit der Auswahl ausgleicht.
class HeatingSetupScreen extends ConsumerStatefulWidget {
  const HeatingSetupScreen({super.key, required this.areaId});
  final String areaId;

  @override
  ConsumerState<HeatingSetupScreen> createState() => _HeatingSetupState();
}

class _HeatingSetupState extends ConsumerState<HeatingSetupScreen> {
  /// Zurück, auch wenn die Seite direkt geöffnet wurde (Link, Screenshot).
  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.home);
    }
  }

  HeatingConfig? _draft;

  /// Zuletzt angezeigter Stand (auch ohne Änderung, für Speichern).
  HeatingConfig? _shown;
  HeatingConfig? _saved;
  bool _busy = false;

  /// Startwerte für einen neuen Raum: alle Thermostate, Thermometer und
  /// Kontakte des Raums.
  HeatingConfig _initial() {
    final existing = ref.watch(heatingProvider).value?.byArea(widget.areaId);
    if (existing != null) return existing.config;
    final trvs = _thermostats().where((v) => v.roomId == widget.areaId);
    final sensors = ref.watch(heatingSensorSourcesProvider(widget.areaId));
    final windows = ref.watch(heatingWindowSourcesProvider(widget.areaId));
    final canCal = trvs.isEmpty || trvs.any(trvCanCalibrate);
    return HeatingConfig(
      areaId: widget.areaId,
      trvs: [for (final v in trvs) v.ieee],
      sensors: [
        for (final s in sensors)
          if (s.inRoom) s.entityId,
      ],
      windows: [
        for (final w in windows)
          if (w.inRoom) w.entityId,
      ],
      calibration: canCal
          ? HeatingCalibration.offset
          : HeatingCalibration.target,
    );
  }

  List<ZbDeviceView> _thermostats() => [
    for (final v in ref.watch(zigbeeViewsProvider))
      if (v.type == ZbType.thermostat) v,
  ];

  void _set(HeatingConfig c) => setState(() => _draft = c);

  Future<void> _save() async {
    final d = _draft ?? _shown!;
    if (d.trvs.isEmpty) {
      zbToast(context, 'Wähle mindestens ein Thermostat.', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(heatingProvider.notifier).save(d);
      if (!mounted) return;
      Haptics.tap();
      zbToast(context, _saved == null ? 'Regelung läuft' : 'Gespeichert');
      _leave();
    } on HavenException catch (e) {
      if (mounted) zbToast(context, e.message, error: true);
    } catch (e) {
      if (mounted) zbToast(context, 'Nicht gespeichert. $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final ok = await showZbSheet<bool>(
      context,
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Regelung entfernen?',
            style: HavenText.headline.copyWith(color: ctx.hv.tx),
          ),
          const SizedBox(height: 6),
          Text(
            'Die Thermostate regeln dann wieder allein nach ihrer eigenen Messung. Haven setzt ihre Kalibrierung auf 0 zurück.',
            style: HavenText.body.copyWith(color: ctx.hv.tx2, fontSize: 14),
          ),
          const SizedBox(height: 16),
          HavenButton(
            label: 'Entfernen',
            destructive: true,
            onTap: () => Navigator.of(ctx).pop(true),
          ),
          const SizedBox(height: 8),
          HavenButton(
            label: 'Abbrechen',
            onTap: () => Navigator.of(ctx).pop(false),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(heatingProvider.notifier).delete(widget.areaId);
      if (mounted) _leave();
    } catch (e) {
      if (mounted) zbToast(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final all = ref.watch(heatingProvider);
    final rooms = ref.watch(snapshotProvider.select((s) => s.rooms));
    final roomName =
        rooms
            .where((r) => (r.areaId ?? r.id) == widget.areaId)
            .firstOrNull
            ?.name ??
        widget.areaId;
    if (all.isLoading && !all.hasValue) {
      return Scaffold(
        backgroundColor: hv.bg,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    _saved ??= all.value?.byArea(widget.areaId)?.config;
    // Bis zur ersten Änderung folgen die Startwerte den Daten (Geräte laden nach).
    final d = _shown = _draft ?? _initial();
    final supported = all.value?.supported ?? false;

    return Scaffold(
      backgroundColor: hv.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
              child: Row(
                children: [
                  RoundIconButton(
                    icon: Icons.arrow_back_rounded,
                    label: 'Zurück',
                    onTap: _leave,
                  ),
                  Expanded(
                    child: Text(
                      'Heizung $roomName',
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HavenText.headline.copyWith(color: hv.tx),
                    ),
                  ),
                  const SizedBox(width: 44),
                ],
              ),
            ),
            Expanded(
              child: !supported
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Die Heizungsregelung braucht eine neuere Haven-Integration in Home Assistant.',
                        style: HavenText.body.copyWith(color: hv.tx2),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
                      children: [
                        Text(
                          'Das Thermostat misst direkt am Heizkörper und hält den Raum deshalb oft zu kalt. Haven regelt nach einem Thermometer im Raum und hält alle Thermostate gleich.',
                          style: HavenText.body.copyWith(
                            color: hv.tx2,
                            fontSize: 14.5,
                          ),
                        ),
                        const SizedBox(height: 14),
                        _Preview(draft: d),
                        _TrvSection(
                          draft: d,
                          others: all.value?.rooms ?? const [],
                          onChanged: _set,
                        ),
                        _SensorSection(draft: d, onChanged: _set),
                        _CalibrationSection(draft: d, onChanged: _set),
                        _WindowSection(draft: d, onChanged: _set),
                        _SummerSection(draft: d, onChanged: _set),
                        _PresetSection(draft: d, onChanged: _set),
                        const FieldLabel('Am Thermostat'),
                        _ToggleCard(
                          title: 'Drehen am Thermostat zurücksetzen',
                          subtitle: d.lockManual
                              ? 'Haven stellt jede Änderung am Gerät wieder zurück.'
                              : 'Aus: Wer am Thermostat dreht, ändert das Ziel für den ganzen Raum.',
                          value: d.lockManual,
                          onChanged: (v) => _set(d.copyWith(lockManual: v)),
                        ),
                        if (!d.lockManual &&
                            d.calibration == HeatingCalibration.offset) ...[
                          const SizedBox(height: 8),
                          _ToggleCard(
                            title: 'Auch bei eigener Steuerung kalibrieren',
                            subtitle: d.calibrateReleased
                                ? 'Stellt jemand am Thermostat den Wochenplan oder Ventil offen ein, hält Haven still, gleicht aber weiter mit dem Raumthermometer aus.'
                                : 'Haven nimmt seine Kalibrierung zurück, solange das Thermostat selbst steuert.',
                            value: d.calibrateReleased,
                            onChanged: (v) =>
                                _set(d.copyWith(calibrateReleased: v)),
                          ),
                        ],
                        if (_saved != null) ...[
                          const SizedBox(height: 8),
                          _ToggleCard(
                            title: 'Regelung aktiv',
                            subtitle: d.enabled
                                ? 'Haven regelt diesen Raum.'
                                : 'Pausiert: Die Thermostate laufen allein, Haven schickt nichts.',
                            value: d.enabled,
                            onChanged: (v) => _set(d.copyWith(enabled: v)),
                          ),
                          const SizedBox(height: 18),
                          HavenButton(
                            label: 'Regelung entfernen',
                            icon: Icons.delete_outline_rounded,
                            destructive: true,
                            onTap: _busy ? null : _remove,
                          ),
                        ],
                      ],
                    ),
            ),
            if (supported)
              Container(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
                decoration: BoxDecoration(
                  color: hv.bg,
                  border: Border(top: BorderSide(color: hv.ln)),
                ),
                child: HavenButton(
                  label: _saved == null ? 'Regelung starten' : 'Speichern',
                  icon: Icons.check_rounded,
                  primary: true,
                  busy: _busy,
                  onTap: _busy || (_saved != null && _saved == d)
                      ? null
                      : _save,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---- Vorschau ---------------------------------------------------------------

class _Preview extends ConsumerWidget {
  const _Preview({required this.draft});
  final HeatingConfig draft;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final entities = ref.watch(snapshotProvider.select((s) => s.entities));
    final room = averageOf(entities, draft.sensors);
    final rows = <Widget>[];
    for (final ieee in draft.trvs) {
      final v = ref.watch(zigbeeViewProvider(ieee));
      if (v == null) continue;
      final local = v.number('local_temperature')?.toDouble();
      final cal = v.number('local_temperature_calibration')?.toDouble() ?? 0;
      final raw = local == null ? null : local - cal;
      final corr = correctionPreview(room, raw);
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Icon(Icons.thermostat_rounded, size: 18, color: hv.tx2),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  raw == null
                      ? '${v.name}: noch keine Messung'
                      : '${v.name}: am Heizkörper ${fmtTemp(raw)}',
                  style: HavenText.body.copyWith(color: hv.tx, fontSize: 14),
                ),
              ),
              if (corr != null && draft.calibration != HeatingCalibration.none)
                ZbPill(
                  text: fmtSigned(corr),
                  color: corr.abs() < 0.3
                      ? hv.ok
                      : (corr < 0 ? const Color(0xFF4AA3DF) : kHeatColor),
                ),
            ],
          ),
        ),
      );
    }
    return HavenCard(
      radius: HavenRadii.m,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'IM RAUM',
                  style: HavenText.caption.copyWith(
                    color: hv.tx3,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              Text(
                room == null ? '–' : fmtTemp(room),
                style: HavenText.headline.copyWith(color: hv.tx, fontSize: 22),
              ),
            ],
          ),
          Text(
            draft.sensors.isEmpty
                ? 'Kein Raumthermometer gewählt'
                : draft.sensors.length == 1
                ? 'laut Raumthermometer'
                : 'Mittel aus ${draft.sensors.length} Thermometern',
            style: HavenText.caption.copyWith(color: hv.tx2),
          ),
          ...rows,
          if (rows.isNotEmpty && room != null && draft.sensors.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(switch (draft.calibration) {
                HeatingCalibration.offset =>
                  'Haven gleicht die Messung der Thermostate um diesen Wert aus.',
                HeatingCalibration.target =>
                  'Haven verschiebt das Ziel am Thermostat um diesen Wert.',
                HeatingCalibration.none =>
                  'Ohne Ausgleich regeln die Thermostate nach ihrer eigenen Messung.',
              }, style: HavenText.caption.copyWith(color: hv.tx2)),
            ),
        ],
      ),
    );
  }
}

// ---- Thermostate ---------------------------------------------------------------

class _TrvSection extends ConsumerWidget {
  const _TrvSection({
    required this.draft,
    required this.others,
    required this.onChanged,
  });
  final HeatingConfig draft;
  final List<RoomHeating> others;
  final ValueChanged<HeatingConfig> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final trvs =
        [
          for (final v in ref.watch(zigbeeViewsProvider))
            if (v.type == ZbType.thermostat) v,
        ]..sort((a, b) {
          final ia = a.roomId == draft.areaId, ib = b.roomId == draft.areaId;
          if (ia != ib) return ia ? -1 : 1;
          return a.name.compareTo(b.name);
        });
    final rooms = ref.watch(snapshotProvider.select((s) => s.rooms));
    String nameOf(String area) =>
        rooms.where((r) => (r.areaId ?? r.id) == area).firstOrNull?.name ??
        area;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FieldLabel('Thermostate'),
        if (trvs.isEmpty)
          Text(
            'Keine Thermostate gefunden. Lern sie unter Zigbee an.',
            style: HavenText.body.copyWith(color: hv.tx2),
          ),
        for (final v in trvs)
          Builder(
            builder: (context) {
              final owner = others
                  .where(
                    (r) =>
                        r.areaId != draft.areaId &&
                        r.config.trvs.contains(v.ieee),
                  )
                  .firstOrNull;
              final selected = draft.trvs.contains(v.ieee);
              final local = v.number('local_temperature');
              return PickRow(
                multi: true,
                title: v.name,
                subtitle: owner != null
                    ? 'regelt schon ${nameOf(owner.areaId)}'
                    : [
                        if (local != null) 'misst ${fmtTemp(local.toDouble())}',
                        if (v.roomId != draft.areaId && v.roomName != null)
                          v.roomName!,
                        if (v.battery != null) 'Batterie ${v.battery} %',
                      ].join(' · '),
                leading: Icon(
                  Icons.thermostat_rounded,
                  color: selected ? hv.acc : hv.tx2,
                ),
                selected: selected,
                onTap: owner != null && !selected
                    ? null
                    : () => onChanged(
                        draft.copyWith(
                          trvs: selected
                              ? [
                                  for (final t in draft.trvs)
                                    if (t != v.ieee) t,
                                ]
                              : [...draft.trvs, v.ieee],
                        ),
                      ),
              );
            },
          ),
        if (draft.trvs.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Text(
              'Mehrere Thermostate laufen als Gruppe: ein Ziel, eine Betriebsart.',
              style: HavenText.caption.copyWith(color: hv.tx2),
            ),
          ),
      ],
    );
  }
}

// ---- Raumthermometer -------------------------------------------------------------

class _SensorSection extends ConsumerWidget {
  const _SensorSection({required this.draft, required this.onChanged});
  final HeatingConfig draft;
  final ValueChanged<HeatingConfig> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final sources = ref.watch(heatingSensorSourcesProvider(draft.areaId));
    final inRoom = sources.where((s) => s.inRoom).toList();
    final rest = sources.where((s) => !s.inRoom).toList();
    Widget row(HeatingSource s) {
      final selected = draft.sensors.contains(s.entityId);
      return PickRow(
        multi: true,
        title: s.name,
        subtitle: [
          s.value ?? 'kein Wert',
          if (!s.inRoom && (s.roomName ?? '').isNotEmpty) s.roomName!,
        ].join(' · '),
        leading: Icon(
          Icons.device_thermostat_rounded,
          color: selected ? hv.acc : hv.tx2,
        ),
        selected: selected,
        onTap: () => onChanged(
          draft.copyWith(
            sensors: selected
                ? [
                    for (final x in draft.sensors)
                      if (x != s.entityId) x,
                  ]
                : [...draft.sensors, s.entityId],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FieldLabel('Raumthermometer'),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(
            'Eins oder mehrere, mehrere ergeben den Mittelwert. Fällt eins aus, zählen die übrigen. Fallen alle aus, gilt wieder die Messung am Thermostat.',
            style: HavenText.caption.copyWith(color: hv.tx2),
          ),
        ),
        if (sources.isEmpty)
          Text(
            'Keine Temperatursensoren gefunden.',
            style: HavenText.body.copyWith(color: hv.tx2),
          ),
        for (final s in inRoom) row(s),
        if (rest.isNotEmpty)
          _MoreList(
            count: rest.length,
            label: inRoom.isEmpty ? 'Alle Thermometer' : 'Aus anderen Räumen',
            initiallyOpen:
                inRoom.isEmpty ||
                rest.any((s) => draft.sensors.contains(s.entityId)),
            children: [for (final s in rest) row(s)],
          ),
      ],
    );
  }
}

// ---- Ausgleich ----------------------------------------------------------------------

class _CalibrationSection extends ConsumerWidget {
  const _CalibrationSection({required this.draft, required this.onChanged});
  final HeatingConfig draft;
  final ValueChanged<HeatingConfig> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final views = [
      for (final ieee in draft.trvs) ?ref.watch(zigbeeViewProvider(ieee)),
    ];
    final cannot = views.where((v) => !trvCanCalibrate(v)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FieldLabel('Ausgleich'),
        for (final c in HeatingCalibration.values)
          PickRow(
            title: c.label,
            subtitle:
                c == HeatingCalibration.offset &&
                    cannot.isNotEmpty &&
                    views.isNotEmpty
                ? '${c.help} ${cannot.length == views.length ? 'Deine Thermostate können das nicht' : '${cannot.map((v) => v.name).join(', ')} kann das nicht'}, dort verschiebt Haven das Ziel.'
                : c.help,
            selected: draft.calibration == c,
            onTap: () => onChanged(draft.copyWith(calibration: c)),
          ),
        if (draft.sensors.isEmpty &&
            draft.calibration != HeatingCalibration.none)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Text(
              'Ohne Raumthermometer gibt es nichts auszugleichen.',
              style: HavenText.caption.copyWith(color: hv.warn),
            ),
          ),
      ],
    );
  }
}

// ---- Fenster ----------------------------------------------------------------------

class _WindowSection extends ConsumerWidget {
  const _WindowSection({required this.draft, required this.onChanged});
  final HeatingConfig draft;
  final ValueChanged<HeatingConfig> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final sources = ref.watch(heatingWindowSourcesProvider(draft.areaId));
    final inRoom = sources.where((s) => s.inRoom).toList();
    final rest = sources.where((s) => !s.inRoom).toList();
    Widget row(HeatingSource s) {
      final selected = draft.windows.contains(s.entityId);
      return PickRow(
        multi: true,
        title: s.name,
        subtitle: [
          s.value ?? 'unbekannt',
          if (!s.inRoom && (s.roomName ?? '').isNotEmpty) s.roomName!,
        ].join(' · '),
        leading: Icon(Icons.window_rounded, color: selected ? hv.acc : hv.tx2),
        selected: selected,
        onTap: () => onChanged(
          draft.copyWith(
            windows: selected
                ? [
                    for (final x in draft.windows)
                      if (x != s.entityId) x,
                  ]
                : [...draft.windows, s.entityId],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FieldLabel('Fenster'),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(
            'Ist ein Fenster offen, pausiert die Heizung im ganzen Raum. Ein Kontakt ohne Verbindung zählt als zu.',
            style: HavenText.caption.copyWith(color: hv.tx2),
          ),
        ),
        if (sources.isEmpty)
          Text(
            'Keine Fenster- oder Türkontakte gefunden.',
            style: HavenText.body.copyWith(color: hv.tx2),
          ),
        for (final s in inRoom) row(s),
        if (rest.isNotEmpty)
          _MoreList(
            count: rest.length,
            label: inRoom.isEmpty ? 'Alle Kontakte' : 'Aus anderen Räumen',
            initiallyOpen:
                inRoom.isEmpty ||
                rest.any((s) => draft.windows.contains(s.entityId)),
            children: [for (final s in rest) row(s)],
          ),
        if (draft.windows.isNotEmpty) ...[
          const SizedBox(height: 4),
          _LabeledSegments(
            label: 'Pause nach',
            options: kWindowOpenDelays,
            value: nearestDelay(kWindowOpenDelays, draft.windowOpenDelay),
            onChanged: (v) => onChanged(draft.copyWith(windowOpenDelay: v)),
          ),
          const SizedBox(height: 10),
          _LabeledSegments(
            label: 'Weiterheizen nach dem Schließen',
            options: kWindowCloseDelays,
            value: nearestDelay(kWindowCloseDelays, draft.windowCloseDelay),
            onChanged: (v) => onChanged(draft.copyWith(windowCloseDelay: v)),
          ),
        ],
      ],
    );
  }
}

// ---- Sommerpause -------------------------------------------------------------------

class _SummerSection extends ConsumerWidget {
  const _SummerSection({required this.draft, required this.onChanged});
  final HeatingConfig draft;
  final ValueChanged<HeatingConfig> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final sources = ref.watch(heatingOutdoorSourcesProvider);
    final on = draft.outdoorEntity != null;
    // Wetter und Sensoren ohne Raum zuerst, Sensoren in Räumen aufklappbar.
    final outside = [
      for (final s in sources)
        if (s.entityId.startsWith('weather.') || (s.roomName ?? '').isEmpty) s,
    ];
    final inside = [
      for (final s in sources)
        if (!outside.contains(s)) s,
    ];
    Widget row(HeatingSource s) => PickRow(
      title: s.name,
      subtitle: [
        s.value ?? 'kein Wert',
        if ((s.roomName ?? '').isNotEmpty) s.roomName!,
      ].join(' · '),
      selected: draft.outdoorEntity == s.entityId,
      onTap: () => onChanged(draft.copyWith(outdoorEntity: s.entityId)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FieldLabel('Sommerpause'),
        _ToggleCard(
          title: 'Bei warmem Wetter nicht heizen',
          subtitle: on
              ? 'Ab ${fmtTemp(draft.outdoorThreshold)} draußen, im Mittel der letzten Stunden.'
              : 'Haven pausiert die Heizung, solange es draußen warm ist.',
          value: on,
          onChanged: sources.isEmpty
              ? null
              : (v) => onChanged(
                  v
                      ? draft.copyWith(outdoorEntity: sources.first.entityId)
                      : draft.copyWith(clearOutdoor: true),
                ),
          children: [
            const SizedBox(height: 4),
            for (final s in outside) row(s),
            if (inside.isNotEmpty)
              _MoreList(
                count: inside.length,
                label: outside.isEmpty ? 'Alle Sensoren' : 'Sensoren in Räumen',
                initiallyOpen:
                    outside.isEmpty ||
                    inside.any((s) => s.entityId == draft.outdoorEntity),
                children: [for (final s in inside) row(s)],
              ),
            _TempStepper(
              label: 'Pause ab',
              value: draft.outdoorThreshold,
              min: 10,
              max: 25,
              onChanged: (v) => onChanged(draft.copyWith(outdoorThreshold: v)),
            ),
          ],
        ),
        if (sources.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
            child: Text(
              'Dafür braucht es einen Außensensor oder eine Wetter-Entity in Home Assistant.',
              style: HavenText.caption.copyWith(color: hv.tx2),
            ),
          ),
      ],
    );
  }
}

// ---- Temperaturen -------------------------------------------------------------------

class _PresetSection extends StatelessWidget {
  const _PresetSection({required this.draft, required this.onChanged});
  final HeatingConfig draft;
  final ValueChanged<HeatingConfig> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FieldLabel('Temperaturen'),
        HavenCard(
          radius: HavenRadii.m,
          padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
          child: Column(
            children: [
              for (final m in kDefaultHeatingPresets.keys)
                _TempStepper(
                  label: m.label,
                  value: draft.presets[m] ?? kDefaultHeatingPresets[m]!,
                  min: 5,
                  max: 30,
                  onChanged: (v) => onChanged(
                    draft.copyWith(presets: {...draft.presets, m: v}),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---- Bausteine --------------------------------------------------------------------

class _ToggleCard extends StatelessWidget {
  const _ToggleCard({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.children = const [],
  });
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return AnimatedSize(
      duration: context.motion(HavenMotion.d2),
      curve: HavenMotion.out,
      alignment: Alignment.topCenter,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
        decoration: BoxDecoration(
          color: hv.s1,
          borderRadius: BorderRadius.circular(HavenRadii.m),
          border: Border.all(
            color: value ? hv.acc.withValues(alpha: 0.5) : hv.ln,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: HavenText.label.copyWith(color: hv.tx),
                        ),
                        Text(
                          subtitle,
                          style: HavenText.caption.copyWith(color: hv.tx2),
                        ),
                      ],
                    ),
                  ),
                ),
                HavenSwitch(
                  value: value,
                  semanticLabel: title,
                  onChanged: onChanged,
                ),
              ],
            ),
            if (value && children.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 0, 6, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TempStepper extends StatelessWidget {
  const _TempStepper({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    Widget btn(IconData i, String what, double next) {
      final ok = next >= min && next <= max;
      return Semantics(
        button: true,
        enabled: ok,
        label: '$label $what',
        excludeSemantics: true,
        child: PressScale(
          onTap: ok
              ? () {
                  Haptics.tap();
                  onChanged(next);
                }
              : null,
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hv.s2,
              shape: BoxShape.circle,
              border: Border.all(color: hv.ln2),
            ),
            child: Icon(
              i,
              size: 18,
              color: ok ? hv.tx : hv.tx3.withValues(alpha: 0.5),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: HavenText.label.copyWith(color: hv.tx)),
          ),
          btn(Icons.remove_rounded, 'kälter', value - 0.5),
          SizedBox(
            width: 64,
            child: Text(
              fmtTemp(value),
              textAlign: TextAlign.center,
              style: HavenText.label.copyWith(color: hv.tx, fontSize: 15),
            ),
          ),
          btn(Icons.add_rounded, 'wärmer', value + 0.5),
        ],
      ),
    );
  }
}

class _LabeledSegments extends StatelessWidget {
  const _LabeledSegments({
    required this.label,
    required this.options,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final List<(int, String)> options;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
        child: Text(
          label,
          style: HavenText.caption.copyWith(color: context.hv.tx2),
        ),
      ),
      HavenSegmented<int>(
        options: options,
        selected: value,
        onChanged: onChanged,
      ),
    ],
  );
}

/// Aufklappbare Liste für Geräte aus anderen Räumen.
class _MoreList extends StatefulWidget {
  const _MoreList({
    required this.count,
    required this.label,
    required this.children,
    this.initiallyOpen = false,
  });
  final int count;
  final String label;
  final List<Widget> children;
  final bool initiallyOpen;

  @override
  State<_MoreList> createState() => _MoreListState();
}

class _MoreListState extends State<_MoreList> {
  /// Von Hand auf- oder zugeklappt, sonst folgt die Liste [_MoreList.initiallyOpen]
  /// (die Daten laden nach).
  bool? _manual;
  bool get _open => _manual ?? widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return AnimatedSize(
      duration: context.motion(HavenMotion.d2),
      curve: HavenMotion.out,
      alignment: Alignment.topCenter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: _open,
            child: PressScale(
              onTap: () => setState(() => _manual = !_open),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${widget.label} (${widget.count})',
                        style: HavenText.label.copyWith(
                          color: hv.acc,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    Icon(
                      _open
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: hv.acc,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_open) ...widget.children,
        ],
      ),
    );
  }
}
