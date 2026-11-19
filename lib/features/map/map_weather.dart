import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/router/router.dart';
import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/segmented.dart';
import '../zigbee/widgets/zb_common.dart' show showZbSheet;
import 'floor_plan_store.dart';
import 'map_sky.dart';

/// Unauffälliger Knopf in der Kartenleiste: zeigt das Wetter der Karte,
/// öffnet Live oder eigene Werte.
class MapWeatherButton extends ConsumerWidget {
  const MapWeatherButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final north = ref.watch(
      floorPlanProvider.select((p) => p.value?.north ?? 0),
    );
    final w = ref.watch(mapWeatherProvider(north));
    final t = w.temperature;
    final label =
        '${w.live ? 'Live' : 'Eigenes'} · ${w.label}'
        '${t == null ? '' : ', ${t.round()} °C'}';
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: 'Wetter der Karte: $label',
        child: GestureDetector(
          key: const ValueKey('map-weather'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            Haptics.tick();
            showMapWeatherSheet(context);
          },
          child: SizedBox(
            width: 40,
            height: 36,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(w.icon, size: 19, color: hv.tx2),
                // Eigene Werte: kleiner Punkt, damit man es nicht vergisst.
                if (!w.live)
                  Positioned(
                    right: 7,
                    top: 6,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: hv.acc,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Himmel der Karte: Live (aus Home Assistant) oder eigene Werte zum
/// Ausprobieren (Uhrzeit, Jahreszeit, Mond, Wetter, Schnee).
Future<void> showMapWeatherSheet(BuildContext context) =>
    showZbSheet<void>(context, builder: (_) => const _WeatherSheet());

class _WeatherSheet extends ConsumerWidget {
  const _WeatherSheet();

  static String _hm(double h) {
    final m = (h * 60).round() % (24 * 60);
    return '${(m ~/ 60).toString().padLeft(2, '0')}:'
        '${(m % 60).toString().padLeft(2, '0')}';
  }

  static const _months = [
    'Jan',
    'Feb',
    'Mär',
    'Apr',
    'Mai',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Okt',
    'Nov',
    'Dez',
  ];

  static String _date(double day) {
    final d = DateTime(2026).add(Duration(days: day.round() - 1));
    return '${d.day}. ${_months[d.month - 1]}';
  }

  static String _moon(double p) {
    if (p < 0.04 || p > 0.96) return 'Neumond';
    if ((p - 0.5).abs() < 0.04) return 'Vollmond';
    if ((p - 0.25).abs() < 0.04) return 'erstes Viertel';
    if ((p - 0.75).abs() < 0.04) return 'letztes Viertel';
    return p < 0.5 ? 'zunehmend' : 'abnehmend';
  }

  static String _level(double v, List<String> names) => v < 0.05
      ? names[0]
      : v < 0.45
      ? names[1]
      : v < 0.8
      ? names[2]
      : names[3];

  static String _compass(double az) {
    const n = ['N', 'NO', 'O', 'SO', 'S', 'SW', 'W', 'NW'];
    return n[((az % 360) / 45).round() % 8];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final settings = ref.watch(mapSkySettingsProvider);
    final notifier = ref.read(mapSkySettingsProvider.notifier);
    final north = ref.watch(
      floorPlanProvider.select((p) => p.value?.north ?? 0),
    );
    final w = ref.watch(mapWeatherProvider(north));
    final m = settings.manual;
    final cfg = ref.watch(snapshotProvider.select((s) => s.weather));

    Widget slider(
      String label,
      String value,
      double v,
      double min,
      double max,
      ValueChanged<double> on,
    ) => Row(
      children: [
        SizedBox(
          width: 92,
          child: Text(label, style: HavenText.label.copyWith(color: hv.tx)),
        ),
        Expanded(
          child: Slider(
            value: v.clamp(min, max),
            min: min,
            max: max,
            onChanged: on,
          ),
        ),
        SizedBox(
          width: 104,
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: HavenText.caption.copyWith(color: hv.tx2),
          ),
        ),
      ],
    );

    Widget fact(String a, String b) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(a, style: HavenText.body.copyWith(color: hv.tx2)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              b,
              textAlign: TextAlign.right,
              style: HavenText.body.copyWith(color: hv.tx),
            ),
          ),
        ],
      ),
    );

    final sky = w.sky;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Himmel der Karte',
          style: HavenText.section.copyWith(color: hv.tx, fontSize: 22),
        ),
        const SizedBox(height: 4),
        Text(
          'Tag und Nacht, Sonne und Mond durch die Fenster, Wolken, Regen und '
          'Schnee rund um die Wohnung.',
          style: HavenText.caption.copyWith(color: hv.tx2),
        ),
        const SizedBox(height: 14),
        HavenSegmented<MapSkyMode>(
          key: const ValueKey('map-sky-mode'),
          options: const [
            (MapSkyMode.live, 'Live'),
            (MapSkyMode.manual, 'Eigenes'),
          ],
          selected: settings.mode,
          onChanged: (v) {
            Haptics.tick();
            notifier.setMode(v);
          },
        ),
        const SizedBox(height: 14),
        if (settings.mode == MapSkyMode.live) ...[
          Row(
            children: [
              Icon(w.icon, color: hv.acc),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  w.label,
                  style: HavenText.label.copyWith(color: hv.tx, fontSize: 16),
                ),
              ),
              if (w.temperature != null)
                Text(
                  '${w.temperature!.toStringAsFixed(1).replaceAll('.', ',')} °C',
                  style: HavenText.label.copyWith(color: hv.tx, fontSize: 16),
                ),
            ],
          ),
          const SizedBox(height: 8),
          fact(
            'Sonne',
            sky.sunElevation < -2
                ? 'untergegangen'
                : '${sky.sunElevation.round()}° ${_compass(sky.sunAzimuth)}',
          ),
          fact(
            'Mond',
            '${_moon(sky.moonPhase)}, '
                '${sky.moonElevation < 0 ? 'nicht zu sehen' : '${sky.moonElevation.round()}° ${_compass(sky.moonAzimuth)}'}',
          ),
          fact('Schnee', w.snowCm < 0.5 ? 'keiner' : '${w.snowCm.round()} cm'),
          const SizedBox(height: 8),
          Text(
            'Quellen: ${cfg.entity ?? 'erste Wetter-Entity'}'
            '${cfg.temperature == null ? '' : ', Temperatur von ${cfg.temperature}'}'
            '${cfg.snowDepth == null ? '' : ', Schneehöhe von ${cfg.snowDepth}'}.',
            style: HavenText.caption.copyWith(color: hv.tx3),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                context.push(Routes.settings);
              },
              icon: const Icon(Icons.tune_rounded, size: 18),
              label: const Text('Wetterquellen einstellen'),
            ),
          ),
        ] else ...[
          slider(
            'Uhrzeit',
            _hm(m.hour),
            m.hour,
            0,
            24,
            (v) => notifier.setManual(m.copyWith(hour: v)),
          ),
          slider(
            'Jahreszeit',
            _date(m.day),
            m.day,
            1,
            365,
            (v) => notifier.setManual(m.copyWith(day: v)),
          ),
          slider(
            'Mond',
            _moon(m.moon),
            m.moon,
            0,
            1,
            (v) => notifier.setManual(m.copyWith(moon: v)),
          ),
          slider(
            'Bewölkung',
            _level(m.cloud, const ['klar', 'leicht', 'bewölkt', 'bedeckt']),
            m.cloud,
            0,
            1,
            (v) => notifier.setManual(m.copyWith(cloud: v)),
          ),
          slider(
            'Regen',
            _level(m.rain, const ['kein', 'leicht', 'mittel', 'stark']),
            m.rain,
            0,
            1,
            (v) => notifier.setManual(m.copyWith(rain: v)),
          ),
          slider(
            'Schneefall',
            _level(m.snowfall, const ['keiner', 'leicht', 'mittel', 'dicht']),
            m.snowfall,
            0,
            1,
            (v) => notifier.setManual(m.copyWith(snowfall: v)),
          ),
          slider(
            'Schneehöhe',
            '${m.snowCm.round()} cm',
            m.snowCm,
            0,
            40,
            (v) => notifier.setManual(m.copyWith(snowCm: v)),
          ),
          slider(
            'Gewitter',
            _level(m.storm, const ['keins', 'fern', 'nah', 'heftig']),
            m.storm,
            0,
            1,
            (v) => notifier.setManual(m.copyWith(storm: v)),
          ),
        ],
      ],
    );
  }
}
