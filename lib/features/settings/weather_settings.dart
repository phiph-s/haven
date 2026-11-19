import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/press_scale.dart';
import '../../data/models/entity_state.dart';
import '../../data/models/weather.dart';
import '../zigbee/widgets/zb_common.dart' show showZbSheet, zbToast;
import 'settings_widgets.dart';

/// Einstellungen „Wetter“: woher die Karte Wetter, Außentemperatur und
/// Schneehöhe für den Live-Himmel nimmt. Gilt für alle Geräte (in HA).
class WeatherSettingsGroup extends ConsumerWidget {
  const WeatherSettingsGroup({super.key});

  Future<void> _save(
    BuildContext context,
    WidgetRef ref,
    WeatherConfig next,
  ) async {
    try {
      await ref.read(repositoryProvider).setWeatherConfig(next);
    } catch (e) {
      if (context.mounted) {
        zbToast(context, 'Nicht gespeichert. $e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(snapshotProvider);
    final cfg = s.weather;
    String nameOf(String id) => s.entity(id)?.name ?? id;
    final weathers = s.byDomain('weather');
    final temps = [
      for (final e in s.byDomain('sensor'))
        if (e.deviceClass == 'temperature') e,
    ];
    final snows = [
      for (final e in s.byDomain('sensor'))
        if (_looksLikeSnow(e)) e,
    ];
    final auto = weathers.isEmpty ? null : weathers.first;
    return SettingsGroup(
      children: [
        SettingsRow(
          icon: Icons.cloud_outlined,
          title: 'Wetterdienst',
          subtitle: cfg.entity != null
              ? nameOf(cfg.entity!)
              : (auto == null
                    ? 'Keine Wetter-Entity in Home Assistant'
                    : 'Automatisch: ${auto.name}'),
          onTap: () async {
            final v = await _pick(
              context,
              'Wetterdienst',
              'Standard ist die Wetter-Entity von Home Assistant, meist Met.no (eine offene Quelle).',
              [
                (null, 'Automatisch', auto?.name),
                for (final e in weathers) (e.entityId, e.name, e.state),
              ],
              cfg.entity,
            );
            if (v == null || !context.mounted) return;
            await _save(
              context,
              ref,
              v.$1 == null
                  ? cfg.copyWith(clearEntity: true)
                  : cfg.copyWith(entity: v.$1),
            );
          },
        ),
        SettingsRow(
          icon: Icons.thermostat_rounded,
          title: 'Außentemperatur',
          subtitle: cfg.temperature != null
              ? nameOf(cfg.temperature!)
              : 'Vom Wetterdienst',
          onTap: () async {
            final v = await _pick(
              context,
              'Außentemperatur',
              'Ein Außenthermometer misst genauer als der Wetterdienst. Unter 0,5 °C wird aus Regen Schnee.',
              [
                (null, 'Vom Wetterdienst', null),
                for (final e in temps)
                  (
                    e.entityId,
                    e.name,
                    e.number == null ? null : '${e.number} °C',
                  ),
              ],
              cfg.temperature,
            );
            if (v == null || !context.mounted) return;
            await _save(
              context,
              ref,
              v.$1 == null
                  ? cfg.copyWith(clearTemperature: true)
                  : cfg.copyWith(temperature: v.$1),
            );
          },
        ),
        SettingsRow(
          icon: Icons.ac_unit_rounded,
          title: 'Schneehöhe',
          subtitle: cfg.snowDepth != null ? nameOf(cfg.snowDepth!) : 'Keine',
          onTap: () async {
            final v = await _pick(
              context,
              'Schneehöhe',
              'Ein Sensor in cm, mm oder m. Die Karte zeigt den Schnee auf den Mauern und rund ums Haus.',
              [
                (null, 'Keine', null),
                for (final e in snows)
                  (
                    e.entityId,
                    e.name,
                    '${e.state} ${e.attributes['unit_of_measurement'] ?? ''}',
                  ),
              ],
              cfg.snowDepth,
            );
            if (v == null || !context.mounted) return;
            await _save(
              context,
              ref,
              v.$1 == null
                  ? cfg.copyWith(clearSnowDepth: true)
                  : cfg.copyWith(snowDepth: v.$1),
            );
          },
        ),
      ],
    );
  }

  static bool _looksLikeSnow(EntityState e) {
    final unit = '${e.attributes['unit_of_measurement'] ?? ''}';
    final id = e.entityId.toLowerCase();
    return const {'cm', 'mm', 'm'}.contains(unit) &&
        (id.contains('snow') ||
            id.contains('schnee') ||
            e.deviceClass == 'distance');
  }

  /// Auswahl als Blatt; liefert `(id,)` (id `null` = Standard) oder `null`
  /// bei Abbruch.
  static Future<(String?,)?> _pick(
    BuildContext context,
    String title,
    String hint,
    List<(String?, String, String?)> options,
    String? current,
  ) => showZbSheet<(String?,)>(
    context,
    builder: (ctx) {
      final hv = ctx.hv;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: HavenText.section.copyWith(color: hv.tx, fontSize: 22),
          ),
          const SizedBox(height: 4),
          Text(hint, style: HavenText.caption.copyWith(color: hv.tx2)),
          const SizedBox(height: 12),
          for (final (id, name, sub) in options)
            PressScale(
              onTap: () {
                Haptics.tick();
                Navigator.of(ctx).pop((id,));
              },
              child: Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: id == current ? hv.acc.withValues(alpha: 0.12) : hv.s2,
                  borderRadius: BorderRadius.circular(HavenRadii.m),
                  border: Border.all(color: id == current ? hv.acc : hv.ln),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: HavenText.label.copyWith(color: hv.tx),
                      ),
                    ),
                    if (sub != null)
                      Text(
                        sub,
                        style: HavenText.caption.copyWith(color: hv.tx2),
                      ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}
