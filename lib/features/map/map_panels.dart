import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/haven_card.dart';
import '../../core/widgets/sparkline.dart';
import '../../data/models/entity_state.dart';
import '../../data/models/floor_plan.dart';
import '../../data/models/state_history.dart';
import '../../data/models/zigbee.dart';
import '../automations/haven_automations_provider.dart';
import '../automations/knob_widgets.dart' show knobEditorPath;
import '../automations/motion_editor_screen.dart' show motionEditorPath;
import '../automations/motion_widgets.dart';
import '../zigbee/widgets/zb_common.dart' show showZbSheet;
import '../zigbee/zigbee_providers.dart';
import '../zigbee/zigbee_screen.dart' show zigbeeDevicePath;
import '../climate/heating_providers.dart';
import '../climate/heating_widgets.dart';
import '../climate/thermostat_providers.dart';
import '../climate/thermostat_widgets.dart';
import 'heatmap.dart';
import 'map_actions.dart';
import 'map_info.dart';
import 'map_readings.dart';

/// Kompakte Info-Sheets der Karte. Auf dem Handy erscheinen sie als Sheet
/// ([showMapPanel]), auf dem Desktop im Inspektor rechts ([MapPanelSpec]).

/// Beschreibung eines Panels: stabile [key] (gleiches Ziel, gleiches Panel)
/// und der Inhalt.
class MapPanelSpec {
  const MapPanelSpec({required this.key, required this.builder});
  final String key;
  final WidgetBuilder builder;

  @override
  bool operator ==(Object other) => other is MapPanelSpec && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// Wo ein Panel steckt: im Sheet (schließen = Sheet zu) oder im Inspektor.
/// Im Inspektor ist ein Panel die zweite Ebene, [onClose] führt dort zurück
/// zur Raumliste (Pfeil links im Kopf).
class MapPanelScope extends InheritedWidget {
  const MapPanelScope({
    super.key,
    required this.sheet,
    this.onClose,
    required super.child,
  });
  final bool sheet;
  final VoidCallback? onClose;

  static MapPanelScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MapPanelScope>();

  @override
  bool updateShouldNotify(MapPanelScope old) =>
      old.sheet != sheet || old.onClose != onClose;
}

/// Öffnet ein Panel als Sheet (Handy).
///
/// [overMap]: das Sheet nimmt höchstens [kMapPanelShare] der Höhe ein und
/// dunkelt kaum ab, darüber bleibt die Karte (mit dem Gerät im Blick) sichtbar.
/// [onHeight] meldet die tatsächliche Höhe des Sheets (kurze Panels lassen
/// der Karte mehr Platz).
Future<void> showMapPanel(
  BuildContext context,
  MapPanelSpec spec, {
  bool overMap = false,
  ValueChanged<double>? onHeight,
}) {
  return showZbSheet<void>(
    context,
    onHeight: onHeight,
    maxHeight: overMap ? kMapPanelShare : 0.88,
    barrier: overMap ? const Color(0x1A000000) : null,
    builder: (ctx) => MapPanelScope(sheet: true, child: spec.builder(ctx)),
  );
}

/// Anteil der Bildschirmhöhe für ein Panel über der 3D-Karte.
const double kMapPanelShare = 0.64;

/// Geht von einem Panel aus auf eine Seite. Im Sheet schließt es vorher.
void _goFromPanel(BuildContext context, String path) {
  final scope = MapPanelScope.maybeOf(context);
  final router = GoRouter.of(context);
  if (scope?.sheet ?? false) Navigator.of(context, rootNavigator: true).pop();
  unawaited(router.push<void>(path));
}

// ---- Verlauf ----------------------------------------------------------------

typedef HistoryKey = ({String id, int minutes});

/// Zustandsverlauf einer Entity für die letzten `minutes` (HA:
/// `history/history_during_period`, Fake: erfundener Verlauf).
final entityHistoryProvider = FutureProvider.autoDispose
    .family<List<StateChange>, HistoryKey>((ref, k) async {
      final repo = ref.watch(repositoryProvider);
      final start = DateTime.now().subtract(Duration(minutes: k.minutes + 1));
      final h = await repo.stateHistory([k.id], start);
      return h[k.id] ?? const [];
    });

const int _kDayMinutes = 24 * 60;

// ---- Gerätedaten ------------------------------------------------------------

/// Alles, was zu einem Gerät gehört: Entities desselben Geräts nach Klasse.
class _Facts {
  _Facts(
    this.entityId,
    this.entities,
    this.zb,
    this.fallbackName, [
    this.zbSeen,
  ]);
  final String entityId;
  final List<EntityState> entities;
  final ZbDevice? zb;
  final String fallbackName;

  /// „Zuletzt gesehen“ des Zigbee-Geräts (Z2M bzw. Netzmessung), wenn bekannt.
  final DateTime? zbSeen;

  EntityState? sensor(String deviceClass) {
    for (final e in entities) {
      if (e.domain == 'sensor' &&
          e.deviceClass == deviceClass &&
          e.number != null &&
          e.isAvailable) {
        return e;
      }
    }
    return null;
  }

  EntityState? get motion {
    for (final e in entities) {
      if (isMotionEntity(e) && e.isAvailable) return e;
    }
    return null;
  }

  EntityState? get battery => sensor('battery');
  EntityState? get lux => sensor('illuminance');
  EntityState? get power => sensor('power');

  /// Spannung in Volt (die Entity kann V oder mV melden).
  double? get volts {
    final e = sensor('voltage');
    final n = e?.number;
    if (n == null) return null;
    return e!.unit == 'mV' ? n / 1000 : n;
  }

  /// Letzte Meldung eines Geräts: `last_seen` von Zigbee2MQTT bzw. der
  /// Netzmessung, sonst der jüngste Wechsel seiner Entities.
  DateTime? get lastSeen {
    if (zbSeen != null) return zbSeen;
    DateTime? best;
    for (final e in entities) {
      final t = e.lastChanged;
      if (t != null && (best == null || t.isAfter(best))) best = t;
    }
    return best;
  }

  String get name => zb?.friendlyName ?? fallbackName;
}

_Facts _factsOf(WidgetRef ref, String entityId) {
  final s = ref.watch(snapshotProvider);
  final devices = ref.watch(zigbeeProvider.select((z) => z.devices));
  final ids = {entityId, ...deviceSiblings(entityId, s, devices)};
  final entities = [
    for (final id in ids)
      if (s.entity(id) != null) s.entity(id)!,
  ];
  final main = s.entity(entityId);
  final zb = zbDeviceForEntity(devices, entityId);
  final seen = zb == null
      ? null
      : ref.watch(zigbeeViewProvider(zb.ieee).select((v) => v?.lastSeen));
  return _Facts(
    entityId,
    entities,
    zb,
    shortDeviceName(main?.name ?? entityId),
    seen,
  );
}

/// Leistung einer Steckdose in Watt, falls ihr Gerät sie meldet.
double? plugPowerOf(WidgetRef ref, String entityId) {
  final s = ref.read(snapshotProvider);
  final devices = ref.read(zigbeeProvider).devices;
  for (final id in {entityId, ...deviceSiblings(entityId, s, devices)}) {
    final e = s.entity(id);
    if (e != null &&
        e.domain == 'sensor' &&
        e.deviceClass == 'power' &&
        e.isAvailable) {
      return e.number;
    }
  }
  return null;
}

String _num(double v, {int digits = 1}) =>
    v.toStringAsFixed(digits).replaceAll('.', ',');

// ---- Bausteine ----------------------------------------------------------------

/// Kopf eines Panels. Im Inspektor mit Zurück-Pfeil zur Raumliste.
class MapPanelHead extends StatelessWidget {
  const MapPanelHead({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });
  final String title;
  final String? subtitle;

  /// Rechts im Kopf, z. B. ein Schalter.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final back = MapPanelScope.maybeOf(context)?.onClose;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          if (back != null) ...[
            // Eigener Knoten: sonst verschmilzt er in manchen Panels mit dem Titel.
            Semantics(
              container: true,
              child: RoundIconButton(
                icon: Icons.arrow_back_rounded,
                label: 'Zurück zur Raumliste',
                onTap: back,
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HavenText.section.copyWith(color: hv.tx, fontSize: 22),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HavenText.caption.copyWith(color: hv.tx2),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value, {this.tone});
  final String label;
  final String value;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HavenText.label.copyWith(
                color: tone ?? hv.tx,
                fontSize: 14.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text, {required this.icon, this.bad = false});
  final String text;
  final IconData icon;
  final bool bad;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final c = bad ? hv.bad : hv.warn;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(HavenRadii.s),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: HavenText.label.copyWith(color: hv.tx, fontSize: 13.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: HavenText.caption.copyWith(color: hv.tx3)),
          Text(
            value,
            style: HavenText.label.copyWith(color: hv.tx, fontSize: 16),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Text(
      text,
      style: HavenText.body.copyWith(color: context.hv.tx3, fontSize: 14),
    ),
  );
}

class _AxisLabels extends StatelessWidget {
  const _AxisLabels(this.left, this.right);
  final String left;
  final String right;

  @override
  Widget build(BuildContext context) {
    final st = HavenText.caption.copyWith(color: context.hv.tx3);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(left, style: st),
          Text(right, style: st),
        ],
      ),
    );
  }
}

Widget _deviceButton(BuildContext context, _Facts f) {
  final zb = f.zb;
  if (zb == null) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.only(top: 14),
    child: HavenButton(
      label: 'Gerät öffnen',
      icon: Icons.open_in_new_rounded,
      onTap: () => _goFromPanel(context, zigbeeDevicePath(zb.ieee)),
    ),
  );
}

// ---- Sensor: Temperatur und Luftfeuchte ---------------------------------------

/// Info zu einem Klimasensor: Wert jetzt, Min und Max, Verlauf der letzten
/// 24 Stunden, Batterie, zuletzt gemeldet.
class SensorPanel extends ConsumerWidget {
  const SensorPanel({super.key, required this.entityId, required this.kind});
  final String entityId;
  final HeatKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final f = _factsOf(ref, entityId);
    final dc = kind == HeatKind.temperature ? 'temperature' : 'humidity';
    final e = f.sensor(dc);
    final unit = kind == HeatKind.temperature ? '°C' : '%';
    final hist = e == null
        ? null
        : ref.watch(
            entityHistoryProvider((id: e.entityId, minutes: _kDayMinutes)),
          );
    final now = DateTime.now();
    final series = numericSeries(hist?.value ?? const []);
    final stats = seriesStats(series);
    final cur = e?.number;
    final lo = stats == null || cur == null
        ? cur
        : (cur < stats.min ? cur : stats.min);
    final hi = stats == null || cur == null
        ? cur
        : (cur > stats.max ? cur : stats.max);
    String fmt(double? v) => v == null
        ? 'n/a'
        : kind == HeatKind.temperature
        ? '${_num(v)} °C'
        : '${v.round()} %';
    final bat = f.battery?.number;
    final values = e == null
        ? const <double?>[]
        : resampleSeries(
            series,
            now.subtract(const Duration(hours: 24)),
            now,
            48,
          );

    // Raumthermometer einer Heizungsregelung: die Regelung oben.
    final heat = kind == HeatKind.temperature
        ? ref.watch(heatingOfDeviceProvider((ieee: null, entityId: entityId)))
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MapPanelHead(
          title: f.name,
          subtitle: kind == HeatKind.temperature
              ? (heat == null
                    ? 'Temperatursensor'
                    : 'Temperatursensor · misst für die Heizung')
              : 'Feuchtesensor',
        ),
        if (heat != null) ...[
          RoomHeatingCard(roomId: heat.areaId, heat: heat),
          const SizedBox(height: 16),
        ],
        Text(
          cur == null
              ? 'Kein Wert'
              : kind == HeatKind.temperature
              ? '${_num(cur)} $unit'
              : '${cur.round()} $unit',
          style: HavenText.display.copyWith(color: hv.tx),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            _Stat('Niedrigster Wert', fmt(lo)),
            _Stat('Höchster Wert', fmt(hi)),
          ],
        ),
        const SizedBox(height: 14),
        if (hist == null)
          const _Note('Kein Sensorwert')
        else if (hist.isLoading)
          const _Note('Verlauf lädt')
        else if (series.length < 2)
          const _Note('Kein Verlauf aufgezeichnet')
        else ...[
          Sparkline(
            values: values,
            semanticLabel: 'Verlauf der letzten 24 Stunden',
          ),
          const _AxisLabels('vor 24 h', 'jetzt'),
        ],
        const SizedBox(height: 8),
        if (bat != null) _Fact('Batterie', '${bat.round()} %'),
        _Fact('Zuletzt gemeldet', lastSeenText(f.lastSeen, now)),
        if (batteryNeedsCheck(bat, f.lastSeen, now))
          const _Hint('Batterie prüfen', icon: Icons.battery_alert_rounded),
        _deviceButton(context, f),
      ],
    );
  }
}

// ---- Melder ---------------------------------------------------------------------

/// Info zu einem Melder: Zustand jetzt, die letzten Auslösungen aus der
/// History (60 min) und die Helligkeit, falls es sie gibt.
class MotionPanel extends ConsumerWidget {
  const MotionPanel({super.key, required this.entityId});
  final String entityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final f = _factsOf(ref, entityId);
    final m = f.motion;
    final now = DateTime.now();
    final hist = m == null
        ? null
        : ref.watch(entityHistoryProvider((id: m.entityId, minutes: 60)));
    final spans = motionSpans(hist?.value ?? const [], now);
    final lux = f.lux?.number;
    final bat = f.battery?.number;
    final on = m?.isOn ?? false;
    final since = m?.lastChanged;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MapPanelHead(title: f.name, subtitle: 'Bewegungsmelder'),
        Row(
          children: [
            Container(
              width: 12,
              height: 12,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: on ? hv.ok : hv.s3,
              ),
            ),
            Expanded(
              child: Text(
                m == null
                    ? 'Kein Melder'
                    : on
                    ? 'Bewegung jetzt'
                    : since == null
                    ? 'Ruhig'
                    : 'Ruhig, ${agoText(since, now)}',
                style: HavenText.headline.copyWith(color: hv.tx),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          'Letzte 60 Minuten',
          style: HavenText.caption.copyWith(color: hv.tx3),
        ),
        const SizedBox(height: 6),
        if (hist != null && hist.isLoading)
          const _Note('Verlauf lädt')
        else ...[
          MotionStrip(spans: spans, now: now),
          const _AxisLabels('vor 60 min', 'jetzt'),
          const SizedBox(height: 8),
          if (spans.isEmpty)
            const _Note('Keine Bewegung in der letzten Stunde')
          else
            for (final s in spans.take(5))
              _Fact(
                'Bewegung',
                motionSpanText(s, now),
                tone: s.running ? hv.ok : null,
              ),
        ],
        const SizedBox(height: 4),
        if (lux != null) _Fact('Helligkeit', '${lux.round()} lx'),
        if (bat != null) _Fact('Batterie', '${bat.round()} %'),
        _deviceButton(context, f),
      ],
    );
  }
}

/// Zeitstrahl der letzten Stunde: je Auslösung ein Balken.
class MotionStrip extends StatelessWidget {
  const MotionStrip({
    super.key,
    required this.spans,
    required this.now,
    this.window = const Duration(minutes: 60),
  });
  final List<MotionSpan> spans;
  final DateTime now;
  final Duration window;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      label: spans.isEmpty
          ? 'Keine Bewegung in der letzten Stunde'
          : '${spans.length} Auslösungen in der letzten Stunde',
      image: true,
      child: SizedBox(
        height: 18,
        width: double.infinity,
        child: CustomPaint(
          painter: _StripPainter(spans, now, window, hv.ok, hv.s2),
        ),
      ),
    );
  }
}

class _StripPainter extends CustomPainter {
  _StripPainter(this.spans, this.now, this.window, this.on, this.track);
  final List<MotionSpan> spans;
  final DateTime now;
  final Duration window;
  final Color on;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)),
      Paint()..color = track,
    );
    final start = now.subtract(window);
    final total = window.inMilliseconds;
    for (final s in spans) {
      final a = s.from.difference(start).inMilliseconds / total;
      final b = (s.to ?? now).difference(start).inMilliseconds / total;
      final x0 = (a.clamp(0.0, 1.0)) * size.width;
      final x1 = (b.clamp(0.0, 1.0)) * size.width;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(x0, 0, (x1 < x0 + 3 ? x0 + 3 : x1), size.height),
          const Radius.circular(4),
        ),
        Paint()..color = on,
      );
    }
  }

  @override
  bool shouldRepaint(_StripPainter old) =>
      old.spans != spans ||
      old.now != now ||
      old.on != on ||
      old.track != track;
}

// ---- Batterie ---------------------------------------------------------------------

/// Info zu einem Batteriegerät: Stand, Spannung, zuletzt gemeldet, Hinweis.
class BatteryPanel extends ConsumerWidget {
  const BatteryPanel({super.key, required this.entityId});
  final String entityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final f = _factsOf(ref, entityId);
    final bat = f.battery?.number;
    final volts = f.volts;
    final now = DateTime.now();
    final check = batteryNeedsCheck(bat, f.lastSeen, now);
    final low = bat != null && bat < kBatteryLow;
    final silent =
        f.lastSeen != null && now.difference(f.lastSeen!) > kSilentLimit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MapPanelHead(title: f.name, subtitle: 'Batterie'),
        Text(
          bat == null ? 'Kein Stand' : '${bat.round()} %',
          style: HavenText.display.copyWith(color: low ? hv.bad : hv.tx),
        ),
        const SizedBox(height: 12),
        if (bat != null) _LevelBar(level: bat),
        const SizedBox(height: 10),
        if (volts != null) _Fact('Spannung', '${_num(volts, digits: 2)} V'),
        _Fact(
          'Zuletzt gemeldet',
          lastSeenText(f.lastSeen, now),
          tone: silent ? hv.warn : null,
        ),
        if (check)
          _Hint(
            low && silent
                ? 'Batterie prüfen: schwach und lange nichts gemeldet'
                : low
                ? 'Batterie prüfen: unter 20 %'
                : 'Batterie prüfen: seit über 2 Tagen nichts gemeldet',
            icon: Icons.battery_alert_rounded,
            bad: low,
          ),
        _deviceButton(context, f),
      ],
    );
  }
}

class _LevelBar extends StatelessWidget {
  const _LevelBar({required this.level});
  final double level;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final c = level < kBatteryLow
        ? hv.bad
        : level < 40
        ? hv.warn
        : hv.ok;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: 10,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: hv.s2)),
            FractionallySizedBox(
              widthFactor: (level / 100).clamp(0.02, 1.0),
              child: ColoredBox(color: c),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Lichtschalter -------------------------------------------------------------------

/// Welchen Raum bzw. welche Automation ein Lichtschalter steuert, mit Link.
class ControlPanel extends ConsumerWidget {
  const ControlPanel({super.key, required this.entityId, required this.room});
  final String entityId;
  final String room;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final f = _factsOf(ref, entityId);
    final auto = f.zb == null
        ? null
        : knobAutomationFor(
            ref.watch(havenAutomationsProvider).value,
            f.zb!.ieee,
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MapPanelHead(title: f.name, subtitle: 'Lichtschalter'),
        Text(
          'Steuert das Licht in $room',
          style: HavenText.headline.copyWith(color: hv.tx),
        ),
        const SizedBox(height: 6),
        if (auto != null)
          _Fact('Automation', auto.name)
        else
          Text(
            'Über die Zigbee-Gruppe des Raums, ohne Haven-Automation.',
            style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
          ),
        if (auto?.id != null)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: HavenButton(
              label: 'Automation öffnen',
              icon: Icons.tune_rounded,
              primary: true,
              onTap: () => _goFromPanel(context, knobEditorPath(auto!.id)),
            ),
          ),
        _deviceButton(context, f),
      ],
    );
  }
}

// ---- Räume ----------------------------------------------------------------------------

List<PlacedReading> _inRoom(MapReadings r, FloorRoom room) => [
  for (final x in r.items)
    if (x.location == room.id) x,
];

/// Klima eines Raums: Mittelwert, Spanne, alle Sensoren, kleiner Verlauf.
class RoomClimatePanel extends ConsumerWidget {
  const RoomClimatePanel({
    super.key,
    required this.plan,
    required this.room,
    required this.kind,
  });
  final HavenFloorPlan plan;
  final FloorRoom room;
  final HeatKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final readings = ref.watch(mapReadingsProvider(plan));
    final measured = [
      for (final r in _inRoom(readings, room))
        if ((kind == HeatKind.temperature ? r.temp : r.hum) != null) r,
    ];
    // Thermostate messen am Heizkörper: Gibt es einen Sensor, zählen sie
    // nicht mit (wie in der Heatmap).
    final hasSensor = measured.any((r) => !r.thermostat);
    final mine = [
      for (final r in measured)
        if (!r.thermostat || !hasSensor) r,
    ];
    final thermostats = kind == HeatKind.temperature
        ? [
            for (final r in _inRoom(readings, room))
              if (r.thermostat) r,
          ]
        : const <PlacedReading>[];
    double v(PlacedReading r) =>
        (kind == HeatKind.temperature ? r.temp : r.hum)!;
    String fmt(double x) =>
        kind == HeatKind.temperature ? '${_num(x)} °C' : '${x.round()} %';
    final spread = spreadOf([for (final r in mine) v(r)]);
    final dc = kind == HeatKind.temperature ? 'temperature' : 'humidity';
    final snap = ref.watch(snapshotProvider);
    final zb = ref.watch(zigbeeProvider.select((z) => z.devices));

    // Verlauf: je Sensor die Messentity, gemittelt über 24 Stunden.
    final now = DateTime.now();
    final histories = <AsyncValue<List<StateChange>>>[];
    final names = <String>[];
    for (final r in mine) {
      final ids = {r.entityId, ...deviceSiblings(r.entityId, snap, zb)};
      final id = ids
          .where((i) => snap.entity(i)?.deviceClass == dc)
          .firstOrNull;
      histories.add(
        id == null
            ? const AsyncData(<StateChange>[])
            : ref.watch(entityHistoryProvider((id: id, minutes: _kDayMinutes))),
      );
      final d = zbDeviceForEntity(zb, r.entityId);
      names.add(
        d?.friendlyName ??
            shortDeviceName(snap.entity(r.entityId)?.name ?? r.entityId),
      );
    }
    final loading = histories.any((h) => h.isLoading);
    final start = now.subtract(const Duration(hours: 24));
    final mean = meanSeries([
      for (final h in histories)
        if ((h.value ?? const []).isNotEmpty)
          resampleSeries(numericSeries(h.value!), start, now, 48),
    ]);
    final hasLine = mean.where((x) => x != null).length >= 2;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MapPanelHead(
          title: room.name,
          subtitle: kind == HeatKind.temperature ? 'Temperatur' : 'Luftfeuchte',
        ),
        if (spread == null)
          const _Note('Im Raum liegt kein Sensor auf dem Grundriss.')
        else ...[
          Text(
            fmt(spread.mean),
            style: HavenText.display.copyWith(color: hv.tx),
          ),
          Text(
            mine.length == 1
                ? 'ein Sensor'
                : 'Mittelwert aus ${mine.length} Sensoren',
            style: HavenText.caption.copyWith(color: hv.tx2),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _Stat('Niedrigster Wert', fmt(spread.min)),
              _Stat('Höchster Wert', fmt(spread.max)),
              _Stat(
                'Spanne',
                mine.length == 1 ? 'n/a' : fmt(spread.max - spread.min),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (loading)
            const _Note('Verlauf lädt')
          else if (!hasLine)
            const _Note('Kein Verlauf aufgezeichnet')
          else ...[
            Sparkline(
              values: mean,
              semanticLabel: 'Mittlerer Verlauf der letzten 24 Stunden',
            ),
            const _AxisLabels('vor 24 h', 'jetzt'),
          ],
          const SizedBox(height: 8),
          for (var i = 0; i < mine.length; i++)
            _Fact(names[i], fmt(v(mine[i]))),
          if (kind == HeatKind.humidity && needsVenting(spread.mean))
            const _Hint('Zu feucht: Lüften hilft', icon: Icons.air_rounded),
        ],
        if (thermostats.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('Heizung', style: HavenText.label.copyWith(color: hv.tx2)),
          const SizedBox(height: 8),
          for (final r in thermostats)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ThermostatRow(
                thermostat: thermostatRefFor(r.entityId, zb),
              ),
            ),
          if (hasSensor)
            Text(
              'Thermostate messen direkt am Heizkörper und zählen hier nicht mit.',
              style: HavenText.caption.copyWith(color: hv.tx3),
            ),
        ],
      ],
    );
  }
}

// ---- Thermostat ----------------------------------------------------------------

/// Thermostat auf der Karte: volle Bedienung wie im Gerät-Detail, dazu
/// „Gerät öffnen“.
class ThermostatPanel extends ConsumerWidget {
  const ThermostatPanel({super.key, required this.entityId});
  final String entityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(zigbeeProvider.select((z) => z.devices));
    final r = thermostatRefFor(entityId, devices);
    final t = ref.watch(thermostatProvider(r));
    final name =
        t?.name ??
        shortDeviceName(ref.watch(entityProvider(entityId))?.name ?? entityId);
    // Teil einer Heizungsregelung: der Raum steht vorn, das einzelne
    // Thermostat darunter als Zeile (Drehen dort ändert ohnehin den Raum).
    final heat = ref.watch(
      heatingOfDeviceProvider((ieee: r.ieee, entityId: r.entityId)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MapPanelHead(
          title: heat == null ? name : 'Heizung · ${t?.roomName ?? name}',
          subtitle: heat == null
              ? (t?.roomName == null
                    ? 'Thermostat'
                    : 'Thermostat · ${t!.roomName}')
              : '$name ist Teil der Raumregelung',
        ),
        if (heat != null) ...[
          RoomHeatingCard(roomId: heat.areaId, heat: heat),
          const SizedBox(height: 12),
          ThermostatRow(
            thermostat: r,
            onOpen: () => showThermostatSheet(context, r),
          ),
        ] else
          ThermostatControl(thermostat: r, dialSize: 220),
        if (r.ieee != null)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: HavenButton(
              label: 'Gerät öffnen',
              icon: Icons.open_in_new_rounded,
              onTap: () => _goFromPanel(context, zigbeeDevicePath(r.ieee!)),
            ),
          ),
      ],
    );
  }
}

/// Bewegungslicht eines Raums: Zustand live, Schalter, Bearbeiten. Ohne
/// Automation der Weg in den Assistenten.
class RoomMotionPanel extends ConsumerWidget {
  const RoomMotionPanel({super.key, required this.room, required this.areaIds});
  final FloorRoom room;

  /// Kennungen des Raums im Snapshot (Bereich und Raum-ID).
  final List<String?> areaIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final auto = motionAutomationFor(
      ref.watch(havenAutomationsProvider).value,
      areaIds,
    );
    final area = areaIds.whereType<String>().firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MapPanelHead(title: room.name, subtitle: 'Bewegungslicht'),
        if (auto != null) ...[
          MotionAutomationCard(automation: auto, roomName: room.name),
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: HavenButton(
              label: 'Bewegungslicht bearbeiten',
              icon: Icons.tune_rounded,
              onTap: () => _goFromPanel(context, motionEditorPath(auto.id)),
            ),
          ),
        ] else ...[
          Text(
            'In ${room.name} schaltet noch kein Melder das Licht.',
            style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14.5),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: HavenButton(
              label: 'Bewegungslicht einrichten',
              icon: Icons.add_rounded,
              primary: true,
              onTap: () => _goFromPanel(
                context,
                area == null
                    ? motionEditorPath()
                    : '${motionEditorPath()}?room=${Uri.encodeComponent(area)}',
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Batteriegeräte eines Raums, der schwächste zuerst.
class RoomBatteriesPanel extends ConsumerWidget {
  const RoomBatteriesPanel({super.key, required this.plan, required this.room});
  final HavenFloorPlan plan;
  final FloorRoom room;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final readings = ref.watch(mapReadingsProvider(plan));
    final snap = ref.watch(snapshotProvider);
    final zb = ref.watch(zigbeeProvider.select((z) => z.devices));
    final mine = [
      for (final r in _inRoom(readings, room))
        if (r.battery != null) r,
    ]..sort((a, b) => a.battery!.compareTo(b.battery!));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MapPanelHead(
          title: room.name,
          subtitle: mine.isEmpty
              ? 'Batterien'
              : mine.length == 1
              ? 'Eine Batterie'
              : '${mine.length} Batterien',
        ),
        if (mine.isEmpty)
          const _Note('Im Raum liegt kein Batteriegerät auf dem Grundriss.')
        else
          for (final r in mine)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Text(
                      zbDeviceForEntity(zb, r.entityId)?.friendlyName ??
                          shortDeviceName(
                            snap.entity(r.entityId)?.name ?? r.entityId,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HavenText.label.copyWith(
                        color: hv.tx,
                        fontSize: 14.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: _LevelBar(level: r.battery!)),
                  SizedBox(
                    width: 52,
                    child: Text(
                      '${r.battery!.round()} %',
                      textAlign: TextAlign.right,
                      style: HavenText.label.copyWith(
                        color: r.battery! < kBatteryLow ? hv.bad : hv.tx2,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        if (mine.any((r) => r.battery! < kBatteryLow))
          const _Hint(
            'Batterie prüfen',
            icon: Icons.battery_alert_rounded,
            bad: true,
          ),
      ],
    );
  }
}
