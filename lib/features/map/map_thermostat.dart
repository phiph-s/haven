import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/tokens.dart';
import '../climate/thermostat_dial.dart';
import '../climate/thermostat_model.dart';
import '../climate/thermostat_providers.dart';
import '../zigbee/zigbee_providers.dart';
import 'map_layer_widgets.dart' show onFill;

/// Thermostat auf der Karte: gemessene Temperatur, Pfeil, Zieltemperatur,
/// beim Heizen mit Flamme und warmem Rand. [fill] färbt den Messwert in der
/// Farbe der Heatmap-Skala (Kartenart Temperatur), sonst neutral.
class ThermostatMarker extends ConsumerWidget {
  const ThermostatMarker({super.key, required this.entityId, this.fill});
  final String entityId;
  final Color? fill;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final devices = ref.watch(zigbeeProvider.select((z) => z.devices));
    final t = ref.watch(
      thermostatProvider(thermostatRefFor(entityId, devices)),
    );
    final heating = t != null && t.heating == true && !t.isOff;
    final cur = t?.current;
    final target = t?.shownTarget;
    final left = fill ?? hv.s1;
    final fgLeft = fill == null ? hv.tx : onFill(fill!);
    final label = t == null
        ? entityId
        : '${t.name}, ${t.shortText}${heating ? ', heizt' : ''}';
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: OverflowBox(
        maxWidth: 190,
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Opacity(
              opacity: t == null ? 0.45 : 1,
              child: Container(
                height: 26,
                decoration: BoxDecoration(
                  color: hv.s1,
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(
                    color: heating ? kHeatColor : hv.s1.withValues(alpha: 0.9),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: heating
                          ? kHeatColor.withValues(alpha: 0.45)
                          : const Color(
                              0xFF000000,
                            ).withValues(alpha: hv.isDark ? 0.4 : 0.14),
                      blurRadius: heating ? 12 : 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        color: left,
                        padding: const EdgeInsets.only(left: 6, right: 7),
                        alignment: Alignment.center,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              heating
                                  ? Icons.local_fire_department_rounded
                                  : Icons.thermostat_rounded,
                              size: 13,
                              color: heating && fill == null
                                  ? kHeatColor
                                  : fgLeft,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              cur == null ? '–' : '${fmtNum1(cur)}°',
                              style: _style.copyWith(color: fgLeft),
                            ),
                          ],
                        ),
                      ),
                      if (t != null && (t.isOff || target != null))
                        Padding(
                          padding: const EdgeInsets.only(left: 5, right: 8),
                          child: Text(
                            t.isOff ? 'aus' : '→ ${fmtNum1(target!)}°',
                            style: _style.copyWith(
                              color: t.isOff
                                  ? hv.tx3
                                  : (heating ? kHeatColor : hv.tx2),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static const _style = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w800,
    height: 1.1,
  );
}

/// Kurztext eines Thermostats für Listen der Karte, z. B. „19,6° → 21°“.
String thermostatLine(ThermostatState t) =>
    t.heating == true && !t.isOff ? '${t.shortText}, heizt' : t.shortText;
