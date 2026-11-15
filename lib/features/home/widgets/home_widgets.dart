import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/state/providers.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/haven_card.dart';
import '../../../core/widgets/haven_switch.dart';
import '../../../data/models/widget_config.dart';
import '../weather_text.dart';

/// Zeigt ein konfiguriertes Widget. Neue Typen: Enum in widget_config.dart
/// ergänzen und hier im Switch einhängen.
class HomeWidgetCard extends ConsumerWidget {
  const HomeWidgetCard({super.key, required this.config});
  final HavenWidgetConfig config;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (config.type) {
      HavenWidgetType.power => _PowerCard(config: config),
      HavenWidgetType.entityToggle => _ToggleCard(config: config),
      HavenWidgetType.lowBattery => _BatteryCard(config: config),
      HavenWidgetType.weather => _WeatherCard(config: config),
    };
  }
}

/// Titel für die Bearbeitungsliste.
String widgetTitle(HavenWidgetConfig c) => switch (c.type) {
  HavenWidgetType.power => 'Strom',
  HavenWidgetType.entityToggle =>
    (c.options['label'] as String?) ?? c.entityIds.firstOrNull ?? 'Schalter',
  HavenWidgetType.lowBattery => 'Batterien niedrig',
  HavenWidgetType.weather => 'Wetter draußen',
};

IconData widgetIcon(HavenWidgetConfig c) => switch (c.type) {
  HavenWidgetType.power => Icons.bolt_rounded,
  HavenWidgetType.entityToggle => switch (c.options['icon']) {
    'fan' => Icons.air_rounded,
    'light' => Icons.lightbulb_outline_rounded,
    _ => Icons.power_settings_new_rounded,
  },
  HavenWidgetType.lowBattery => Icons.battery_alert_rounded,
  HavenWidgetType.weather => Icons.wb_sunny_outlined,
};

class _Label extends StatelessWidget {
  const _Label(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Row(
      children: [
        Icon(icon, size: 16, color: hv.tx2),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HavenText.label.copyWith(color: hv.tx2, fontSize: 12.5),
          ),
        ),
      ],
    );
  }
}

String _clean(String name) => name
    .replaceAll(RegExp(r'\s+(Leistung|Power|Batterie|Battery)$'), '')
    .replaceAll(' Zähler', '');

// ---- Strom ------------------------------------------------------------

class _PowerCard extends ConsumerWidget {
  const _PowerCard({required this.config});
  final HavenWidgetConfig config;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final snap = ref.watch(snapshotProvider);
    final ents = config.entityIds.isNotEmpty
        ? [for (final id in config.entityIds) ?snap.entity(id)]
        : snap.entities.values.where((e) => e.deviceClass == 'power').toList();
    final vals = [
      for (final e in ents)
        if (e.number != null) e,
    ]..sort((a, b) => b.number!.compareTo(a.number!));
    final total = vals.fold<double>(0, (a, e) => a + e.number!);
    final top = vals.where((e) => e.number! > 0.5).take(4).toList();
    final maxV = top.isEmpty ? 1.0 : top.first.number!;
    return HavenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Label(Icons.bolt_rounded, 'Strom jetzt'),
          const SizedBox(height: 6),
          if (vals.isEmpty)
            Text(
              'Keine Leistungssensoren gefunden',
              style: HavenText.caption.copyWith(color: hv.tx3),
            )
          else ...[
            TweenAnimationBuilder<double>(
              tween: Tween(end: total),
              duration: context.motion(HavenMotion.d4),
              curve: HavenMotion.out,
              builder: (context, v, _) => Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: v.round().toString(),
                      style: HavenText.power.copyWith(color: hv.tx),
                    ),
                    TextSpan(
                      text: ' W',
                      style: HavenText.label.copyWith(
                        color: hv.tx2,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            for (final e in top)
              Padding(
                padding: const EdgeInsets.only(top: 7),
                child: Row(
                  children: [
                    SizedBox(
                      width: 100,
                      child: Text(
                        _clean(e.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HavenText.caption.copyWith(
                          color: hv.tx2,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: SizedBox(
                          height: 6,
                          child: Stack(
                            children: [
                              ColoredBox(
                                color: hv.s2,
                                child: const SizedBox.expand(),
                              ),
                              // Balken per Skalierung, nicht per Breite.
                              Positioned.fill(
                                child: TweenAnimationBuilder<double>(
                                  tween: Tween(
                                    end: (e.number! / maxV).clamp(0.02, 1.0),
                                  ),
                                  duration: context.motion(HavenMotion.d3),
                                  curve: HavenMotion.out,
                                  builder: (context, f, child) =>
                                      Transform.scale(
                                        scaleX: f,
                                        alignment: Alignment.centerLeft,
                                        child: child,
                                      ),
                                  child: ColoredBox(color: hv.acc),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 52,
                      child: Text(
                        '${e.number!.round()} W',
                        textAlign: TextAlign.right,
                        style: HavenText.caption.copyWith(
                          color: hv.tx,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

// ---- Beliebiger Schalter ------------------------------------------------

class _ToggleCard extends ConsumerWidget {
  const _ToggleCard({required this.config});
  final HavenWidgetConfig config;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final id = config.entityIds.firstOrNull;
    final e = id == null ? null : ref.watch(entityProvider(id));
    final label =
        (config.options['label'] as String?) ?? e?.name ?? id ?? 'Schalter';
    final on = e?.isOn ?? false;
    final humId = config.options['humidityEntity'] as String?;
    final hum = humId == null ? null : ref.watch(entityProvider(humId))?.number;
    return HavenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Label(widgetIcon(config), label),
          const SizedBox(height: 8),
          Text(
            e == null || !e.isAvailable
                ? 'Nicht verfügbar'
                : (on ? 'Läuft' : 'Aus'),
            style: HavenText.headline.copyWith(
              color: hv.tx,
              fontSize: 24,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (hum != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Icon(Icons.water_drop_outlined, size: 14, color: hv.tx2),
                  const SizedBox(width: 4),
                  Text(
                    '${num1(hum)} %',
                    style: HavenText.caption.copyWith(color: hv.tx2),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: HavenSwitch(
              value: on,
              semanticLabel: label,
              onChanged: e == null || !e.isAvailable
                  ? null
                  : (v) => ref
                        .read(repositoryProvider)
                        .callService(
                          e.domain,
                          v ? 'turn_on' : 'turn_off',
                          entityId: e.entityId,
                        ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Batterien ----------------------------------------------------------

class _BatteryCard extends ConsumerWidget {
  const _BatteryCard({required this.config});
  final HavenWidgetConfig config;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final threshold = ((config.options['threshold'] as num?) ?? 50).toDouble();
    final snap = ref.watch(snapshotProvider);
    final ents = config.entityIds.isNotEmpty
        ? [for (final id in config.entityIds) ?snap.entity(id)]
        : snap.entities.values
              .where((e) => e.deviceClass == 'battery')
              .toList();
    final low = [
      for (final e in ents)
        if (e.number != null && e.number! <= threshold) e,
    ]..sort((a, b) => a.number!.compareTo(b.number!));
    return HavenCard(
      onTap: () => context.go('/zigbee'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Label(Icons.battery_alert_rounded, 'Batterien'),
          const SizedBox(height: 8),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${low.length}',
                  style: HavenText.power.copyWith(
                    color: low.isEmpty ? hv.ok : hv.warn,
                  ),
                ),
                TextSpan(
                  text: low.isEmpty ? ' alles gut' : ' niedrig',
                  style: HavenText.label.copyWith(color: hv.tx2, fontSize: 15),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            low.isEmpty
                ? 'Keine Batterie unter ${threshold.round()} %'
                : [
                    for (final e in low.take(3))
                      '${_clean(e.name)} ${e.number!.round()} %',
                  ].join(', '),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: HavenText.caption.copyWith(color: hv.tx2),
          ),
        ],
      ),
    );
  }
}

// ---- Wetter -------------------------------------------------------------

class _WeatherCard extends ConsumerWidget {
  const _WeatherCard({required this.config});
  final HavenWidgetConfig config;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final weatherId = config.entityIds.isNotEmpty
        ? config.entityIds.first
        : ref.watch(
            snapshotProvider.select(
              (s) => s.entities.keys
                  .where((k) => k.startsWith('weather.'))
                  .firstOrNull,
            ),
          );
    final w = weatherId == null ? null : ref.watch(entityProvider(weatherId));
    final tId = config.options['sensorTemp'] as String?;
    final hId = config.options['sensorHumidity'] as String?;
    final t =
        (tId == null ? null : ref.watch(entityProvider(tId))?.number) ??
        (w?.attributes['temperature'] as num?)?.toDouble();
    final h =
        (hId == null ? null : ref.watch(entityProvider(hId))?.number) ??
        (w?.attributes['humidity'] as num?)?.toDouble();
    final cond = w?.state ?? 'unknown';
    return HavenCard(
      child: Row(
        children: [
          Icon(weatherIcon(cond), size: 52, color: hv.tx2),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Draußen',
                  style: HavenText.label.copyWith(
                    color: hv.tx2,
                    fontSize: 12.5,
                  ),
                ),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: t == null ? '–' : num1(t),
                        style: HavenText.power.copyWith(color: hv.tx),
                      ),
                      TextSpan(
                        text: ' °C',
                        style: HavenText.label.copyWith(
                          color: hv.tx2,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                w == null ? 'unbekannt' : weatherLabel(cond),
                style: HavenText.body.copyWith(color: hv.tx2, fontSize: 13),
              ),
              if (h != null)
                Text(
                  '${h.round()} % Feuchte',
                  style: HavenText.body.copyWith(color: hv.tx2, fontSize: 13),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---- Hinzufügen ---------------------------------------------------------

Future<void> showAddWidgetSheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    // Sheet reicht bis unter die Gestenleiste, Abstand innen (edge-to-edge).
    useSafeArea: false,
    backgroundColor: const Color(0x00000000),
    barrierColor: const Color(0x8C000000),
    builder: (_) => const _AddWidgetSheet(),
  );
}

class _AddWidgetSheet extends ConsumerStatefulWidget {
  const _AddWidgetSheet();
  @override
  ConsumerState<_AddWidgetSheet> createState() => _AddWidgetSheetState();
}

class _AddWidgetSheetState extends ConsumerState<_AddWidgetSheet> {
  bool _pickEntity = false;
  String _filter = '';

  String _newId(String p) => '$p-${DateTime.now().microsecondsSinceEpoch}';

  void _add(HavenWidgetConfig c) {
    ref.read(widgetsProvider.notifier).add(c);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final snap = ref.watch(snapshotProvider);
    final media = MediaQuery.of(context);
    final candidates = [
      for (final e in snap.entities.values)
        if (const {
              'switch',
              'light',
              'fan',
              'input_boolean',
            }.contains(e.domain) &&
            (_filter.isEmpty ||
                e.name.toLowerCase().contains(_filter.toLowerCase()) ||
                e.entityId.contains(_filter.toLowerCase())))
          e,
    ]..sort((a, b) => a.name.compareTo(b.name));

    Widget option(
      IconData icon,
      String title,
      String sub,
      VoidCallback onTap,
    ) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: hv.s2, shape: BoxShape.circle),
              child: Icon(icon, size: 20, color: hv.tx),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: HavenText.label.copyWith(color: hv.tx, fontSize: 15),
                  ),
                  Text(sub, style: HavenText.caption.copyWith(color: hv.tx3)),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.85),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: hv.s1,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(HavenRadii.xl),
          ),
          border: Border.all(color: hv.ln),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            10,
            20,
            16 + media.padding.bottom + media.viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 5,
                  decoration: BoxDecoration(
                    color: hv.s3,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                _pickEntity ? 'Entity wählen' : 'Widget hinzufügen',
                style: HavenText.section.copyWith(color: hv.tx),
              ),
              const SizedBox(height: 8),
              if (!_pickEntity) ...[
                option(
                  Icons.bolt_rounded,
                  'Strom',
                  'Verbrauch aller Messsteckdosen',
                  () => _add(
                    HavenWidgetConfig(
                      id: _newId('power'),
                      type: HavenWidgetType.power,
                    ),
                  ),
                ),
                option(
                  Icons.battery_alert_rounded,
                  'Batterien niedrig',
                  'Geräte mit schwacher Batterie',
                  () => _add(
                    HavenWidgetConfig(
                      id: _newId('battery'),
                      type: HavenWidgetType.lowBattery,
                      options: const {'threshold': 50},
                    ),
                  ),
                ),
                option(
                  Icons.wb_sunny_outlined,
                  'Wetter draußen',
                  'Temperatur und Zustand',
                  () => _add(
                    HavenWidgetConfig(
                      id: _newId('weather'),
                      type: HavenWidgetType.weather,
                    ),
                  ),
                ),
                option(
                  Icons.power_settings_new_rounded,
                  'Schalter',
                  'Eine beliebige Entity ein- und ausschalten',
                  () => setState(() => _pickEntity = true),
                ),
              ] else ...[
                TextField(
                  decoration: const InputDecoration(hintText: 'Suchen'),
                  onChanged: (v) => setState(() => _filter = v),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final e in candidates.take(60))
                        option(
                          Icons.power_settings_new_rounded,
                          e.name,
                          e.entityId,
                          () => _add(
                            HavenWidgetConfig(
                              id: _newId('toggle'),
                              type: HavenWidgetType.entityToggle,
                              entityIds: [e.entityId],
                              options: {'label': e.name},
                            ),
                          ),
                        ),
                      if (candidates.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            'Nichts gefunden',
                            style: HavenText.body.copyWith(color: hv.tx3),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Eine Zeile im Bearbeiten-Modus: Entfernen, Titel, Griff zum Umsortieren.
class EditRow extends StatelessWidget {
  const EditRow({
    super.key,
    required this.config,
    required this.index,
    required this.onRemove,
  });
  final HavenWidgetConfig config;
  final int index;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        customSemanticsActions: {
          const CustomSemanticsAction(label: 'Entfernen'): onRemove,
        },
        child: HavenCard(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
          radius: HavenRadii.m,
          child: Row(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onRemove,
                child: Semantics(
                  button: true,
                  label: '${widgetTitle(config)} entfernen',
                  child: SizedBox(
                    width: HavenSpace.touch,
                    height: HavenSpace.touch,
                    child: Center(
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: hv.bad,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.remove_rounded,
                          size: 18,
                          color: Color(0xFFFFFFFF),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Icon(widgetIcon(config), size: 20, color: hv.tx2),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widgetTitle(config),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HavenText.label.copyWith(color: hv.tx, fontSize: 15),
                ),
              ),
              ReorderableDragStartListener(
                index: index,
                child: SizedBox(
                  width: HavenSpace.touch,
                  height: HavenSpace.touch,
                  child: Icon(Icons.drag_handle_rounded, color: hv.tx3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
