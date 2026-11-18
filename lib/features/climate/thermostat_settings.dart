import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/haven_card.dart';
import '../../core/widgets/press_scale.dart';
import '../../core/widgets/segmented.dart';
import '../../data/models/zigbee.dart';
import '../zigbee/widgets/device_settings.dart';
import '../zigbee/widgets/zb_common.dart';
import '../zigbee/zigbee_model.dart';
import '../zigbee/zigbee_providers.dart';
import 'thermostat_dial.dart';
import 'thermostat_model.dart';
import 'thermostat_providers.dart';

/// Einstellungen eines Thermostats: deutsch beschriftete Gruppen
/// ([thermostatSettingGroups]) und der Wochenplan, falls das Gerät einen hat.
class ThermostatSettingsSection extends StatelessWidget {
  const ThermostatSettingsSection({
    super.key,
    required this.view,
    required this.classified,
  });
  final ZbDeviceView view;
  final ZbClassified classified;

  /// Hat das Gerät überhaupt Einstellungen (Gruppen oder Wochenplan)?
  static bool hasAny(ZbClassified c) =>
      thermostatSettingGroups(c).isNotEmpty || _hasSchedule(c);

  static bool _hasSchedule(ZbClassified c) =>
      c.settings.where((f) => parseScheduleDay(f.property) != null).length ==
      kWeekdays.length;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final groups = thermostatSettingGroups(classified);
    Widget header(String name) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 0, 8),
      child: Text(
        name,
        style: HavenText.label.copyWith(color: hv.tx2, fontSize: 13.5),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_hasSchedule(classified)) ...[
          header('Wochenplan'),
          WeekScheduleCard(view: view),
          const SizedBox(height: 16),
        ],
        for (final (name, features) in groups) ...[
          header(name),
          HavenCard(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                for (var i = 0; i < features.length; i++) ...[
                  if (i > 0) Divider(height: 1, thickness: 1, color: hv.ln),
                  if (features[i].isNumeric &&
                      features[i].canWrite &&
                      features[i].unit == '°C')
                    ThermoTempSettingRow(
                      key: ValueKey('${view.ieee}/${features[i].property}'),
                      view: view,
                      feature: features[i],
                    )
                  else
                    ZbSettingRow(
                      key: ValueKey('${view.ieee}/${features[i].property}'),
                      view: view,
                      feature: features[i],
                    ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

/// Temperatur-Einstellung in einer Zeile: Label und Hilfe links, Minus,
/// Wert und Plus rechts. Mehrere Schritte gehen gesammelt nach 600 ms raus.
class ThermoTempSettingRow extends ConsumerStatefulWidget {
  const ThermoTempSettingRow({
    super.key,
    required this.view,
    required this.feature,
  });
  final ZbDeviceView view;
  final ZbFeature feature;

  @override
  ConsumerState<ThermoTempSettingRow> createState() =>
      _ThermoTempSettingRowState();
}

class _ThermoTempSettingRowState extends ConsumerState<ThermoTempSettingRow> {
  double? _local;
  Timer? _debounce;

  ZbFeature get f => widget.feature;
  double get _step => (f.step == null || f.step == 0) ? 1 : f.step!.toDouble();

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _nudge(double cur, int dir) {
    var next = cur + dir * _step;
    if (f.min != null) next = math.max(next, f.min!.toDouble());
    if (f.max != null) next = math.min(next, f.max!.toDouble());
    next = double.parse(next.toStringAsFixed(2));
    if (next == cur) return;
    Haptics.tick();
    setState(() => _local = next);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () async {
      final v = _step % 1 == 0 ? next.round() : next;
      final err = await ref
          .read(zigbeeProvider.notifier)
          .setValue(widget.view.ieee, f.property, v);
      if (!mounted) return;
      setState(() => _local = null);
      zbToast(
        context,
        err == null ? 'Gespeichert' : 'Nicht gespeichert. $err',
        error: err != null,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final raw = widget.view.read(f);
    final cur = _local ?? (raw is num ? raw.toDouble() : null);
    final digits = _step % 1 == 0 ? 0 : 1;
    final text = cur == null
        ? '–'
        : '${cur > 0 && f.property.contains('calibration') ? '+' : ''}${fmtNum(cur, digits: digits)} °C';
    Widget btn(IconData i, String label, int dir) => Semantics(
      button: true,
      label: '$label, ${f.label}',
      child: PressScale(
        onTap: () => _nudge(cur ?? f.min?.toDouble() ?? 0, dir),
        child: SizedBox(
          width: 40,
          height: HavenSpace.touch,
          child: Center(
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: hv.s2,
                shape: BoxShape.circle,
                border: Border.all(color: hv.ln2),
              ),
              child: Icon(i, size: 18, color: hv.tx),
            ),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  f.label,
                  style: HavenText.label.copyWith(color: hv.tx, fontSize: 15),
                ),
                if (f.help != null && f.help!.isNotEmpty)
                  Text(
                    f.help!,
                    style: HavenText.caption.copyWith(
                      color: hv.tx2,
                      fontSize: 12.5,
                      height: 1.35,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          btn(Icons.remove_rounded, 'Weniger', -1),
          SizedBox(
            width: 62,
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: HavenText.label.copyWith(
                color: cur != null && cur != raw ? hv.acc : hv.tx,
                fontSize: 15,
              ),
            ),
          ),
          btn(Icons.add_rounded, 'Mehr', 1),
        ],
      ),
    );
  }
}

// ---- Wochenplan -------------------------------------------------------------

/// Sieben Tage als Balken über 24 Stunden, gefärbt nach Temperatur.
/// Antippen öffnet den Tag im Editor.
class WeekScheduleCard extends ConsumerWidget {
  const WeekScheduleCard({super.key, required this.view});
  final ZbDeviceView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final week = weekScheduleOf(view);
    final now = DateTime.now();
    final today = now.weekday - 1;
    return HavenCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Gilt in der Betriebsart Zeitplan. Tippe auf einen Tag zum Ändern.',
            style: HavenText.caption.copyWith(color: hv.tx2, fontSize: 12.5),
          ),
          const SizedBox(height: 8),
          for (var d = 0; d < kWeekdays.length; d++)
            PressScale(
              pressedScale: 0.99,
              onTap: () => showScheduleEditor(
                context,
                view: view,
                day: d,
                initial: week[d],
              ),
              child: Semantics(
                button: true,
                label: '${kWeekdays[d].$2}: ${_describe(week[d])}',
                excludeSemantics: true,
                child: SizedBox(
                  height: 34,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 30,
                        child: Text(
                          kWeekdays[d].$3,
                          style: HavenText.label.copyWith(
                            color: d == today ? hv.acc : hv.tx2,
                          ),
                        ),
                      ),
                      Expanded(
                        child: ScheduleBar(
                          slots: week[d],
                          nowMinute: d == today
                              ? now.hour * 60 + now.minute
                              : null,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: hv.tx3,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 30, right: 22, top: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final h in const ['0', '6', '12', '18', '24'])
                  Text(h, style: HavenText.caption.copyWith(color: hv.tx3)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _describe(List<ScheduleSlot>? s) {
    if (s == null) return 'kein Plan';
    return [
      for (final x in s) '${x.timeText} ${fmtNum1(x.temp)} Grad',
    ].join(', ');
  }
}

/// Ein Tag als Balken: Abschnitte in der Farbe ihrer Temperatur.
class ScheduleBar extends StatelessWidget {
  const ScheduleBar({super.key, required this.slots, this.nowMinute});
  final List<ScheduleSlot>? slots;
  final int? nowMinute;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return CustomPaint(
      size: const Size(double.infinity, 14),
      painter: _BarPainter(
        slots: slots,
        empty: hv.s2,
        now: nowMinute,
        nowColor: hv.tx,
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.slots,
    required this.empty,
    required this.now,
    required this.nowColor,
  });
  final List<ScheduleSlot>? slots;
  final Color empty;
  final int? now;
  final Color nowColor;

  static const _day = 24 * 60;

  @override
  void paint(Canvas canvas, Size size) {
    final h = 14.0;
    final top = (size.height - h) / 2;
    final rr = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, top, size.width, h),
      const Radius.circular(7),
    );
    canvas.save();
    canvas.clipRRect(rr);
    canvas.drawRect(rr.outerRect, Paint()..color = empty);
    final s = slots;
    if (s != null && s.isNotEmpty) {
      // Vor dem ersten Wechsel gilt der letzte des Vortags (hier: des Tages).
      final edges = <(int, double)>[
        (0, s.last.temp),
        for (final x in s) (x.minute, x.temp),
      ];
      for (var i = 0; i < edges.length; i++) {
        final a = edges[i].$1;
        final b = i + 1 < edges.length ? edges[i + 1].$1 : _day;
        if (b <= a) continue;
        final x0 = size.width * a / _day;
        final x1 = size.width * b / _day;
        canvas.drawRect(
          Rect.fromLTRB(x0, top, x1, top + h),
          Paint()..color = thermoColor(edges[i].$2).withValues(alpha: 0.85),
        );
      }
    }
    canvas.restore();
    final n = now;
    if (n != null) {
      final x = size.width * n / _day;
      canvas.drawLine(
        Offset(x, top - 3),
        Offset(x, top + h + 3),
        Paint()
          ..color = nowColor
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_BarPainter o) =>
      o.slots != slots || o.empty != empty || o.now != now;
}

/// Standardplan, wenn ein Tag noch keinen gültigen hat.
const List<ScheduleSlot> kDefaultSchedule = [
  ScheduleSlot(6 * 60, 20),
  ScheduleSlot(8 * 60, 17, comfort: false),
  ScheduleSlot(12 * 60, 20),
  ScheduleSlot(14 * 60, 17, comfort: false),
  ScheduleSlot(17 * 60, 21),
  ScheduleSlot(22 * 60, 17, comfort: false),
];

/// Für welche Tage der bearbeitete Plan gilt.
enum ScheduleScope {
  day('Nur dieser Tag'),
  weekdays('Mo bis Fr'),
  all('Alle Tage');

  const ScheduleScope(this.label);
  final String label;

  /// Tage (0 = Montag), die beim Speichern geschrieben werden.
  List<int> days(int day) => switch (this) {
    ScheduleScope.day => [day],
    ScheduleScope.weekdays => day >= 5 ? [5, 6] : [0, 1, 2, 3, 4],
    ScheduleScope.all => [0, 1, 2, 3, 4, 5, 6],
  };
}

Future<void> showScheduleEditor(
  BuildContext context, {
  required ZbDeviceView view,
  required int day,
  List<ScheduleSlot>? initial,
}) => showZbSheet<void>(
  context,
  builder: (_) => ScheduleEditor(view: view, day: day, initial: initial),
);

/// Bearbeitet einen Tagesplan: sechs Wechsel mit Uhrzeit (15-min-Schritte),
/// Temperatur (0,5 °C) und Art (Komfort oder Eco).
class ScheduleEditor extends ConsumerStatefulWidget {
  const ScheduleEditor({
    super.key,
    required this.view,
    required this.day,
    this.initial,
  });
  final ZbDeviceView view;
  final int day;
  final List<ScheduleSlot>? initial;

  @override
  ConsumerState<ScheduleEditor> createState() => _ScheduleEditorState();
}

class _ScheduleEditorState extends ConsumerState<ScheduleEditor> {
  late final List<ScheduleSlot> _slots =
      widget.initial != null && widget.initial!.length == kScheduleSlots
      ? [...widget.initial!]
      : [...kDefaultSchedule];
  ScheduleScope _scope = ScheduleScope.day;
  bool _busy = false;

  void _update(int i, ScheduleSlot s) {
    Haptics.tick();
    setState(() => _slots[i] = s);
  }

  void _moveTime(int i, int dir) {
    final lo = i == 0 ? 0 : _slots[i - 1].minute + 15;
    final hi = i == _slots.length - 1
        ? 24 * 60 - 15
        : _slots[i + 1].minute - 15;
    final next = ((_slots[i].minute ~/ 15) + dir) * 15;
    if (next < lo || next > hi) return;
    _update(i, _slots[i].copyWith(minute: next));
  }

  void _moveTemp(int i, int dir) {
    final t = (_slots[i].temp + dir * 0.5).clamp(
      kScheduleMinTemp,
      kScheduleMaxTemp,
    );
    _update(i, _slots[i].copyWith(temp: t.toDouble()));
  }

  void _toggleKind(int i, ThermostatState? t) {
    final comfort = !_slots[i].comfort;
    final temp = comfort ? t?.comfortTemp : t?.ecoTemp;
    _update(
      i,
      _slots[i].copyWith(
        comfort: comfort,
        temp: temp?.clamp(kScheduleMinTemp, kScheduleMaxTemp).toDouble(),
      ),
    );
  }

  Future<void> _save(ThermostatState t) async {
    final err = validateSchedule(_slots);
    if (err != null) {
      zbToast(context, err, error: true);
      return;
    }
    setState(() => _busy = true);
    final w = ThermostatWriter(ref);
    String? fail;
    for (final d in _scope.days(widget.day)) {
      fail = await w.setSchedule(t, d, _slots);
      if (fail != null) break;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (fail != null) {
      zbToast(context, 'Nicht gespeichert. $fail', error: true);
      return;
    }
    zbToast(context, 'Wochenplan gespeichert');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final t = ref.watch(
      thermostatProvider((ieee: widget.view.ieee, entityId: null)),
    );
    final err = validateSchedule(_slots);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          kWeekdays[widget.day].$2,
          style: HavenText.headline.copyWith(color: hv.tx),
        ),
        const SizedBox(height: 4),
        Text(
          'Ab jeder Uhrzeit gilt die Temperatur bis zum nächsten Wechsel, die letzte auch über Nacht.',
          style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
        ),
        const SizedBox(height: 12),
        ScheduleBar(slots: _slots),
        const SizedBox(height: 12),
        for (var i = 0; i < _slots.length; i++)
          _SlotRow(
            slot: _slots[i],
            index: i,
            onTime: (d) => _moveTime(i, d),
            onTemp: (d) => _moveTemp(i, d),
            onKind: () => _toggleKind(i, t),
          ),
        const SizedBox(height: 10),
        Text('Speichern für', style: HavenText.caption.copyWith(color: hv.tx2)),
        const SizedBox(height: 6),
        HavenSegmented<ScheduleScope>(
          options: [
            for (final s in ScheduleScope.values)
              (
                s,
                s == ScheduleScope.weekdays && widget.day >= 5
                    ? 'Sa und So'
                    : s.label,
              ),
          ],
          selected: _scope,
          onChanged: (s) => setState(() => _scope = s),
        ),
        if (err != null) ...[
          const SizedBox(height: 8),
          Text(err, style: HavenText.caption.copyWith(color: hv.bad)),
        ],
        const SizedBox(height: 14),
        HavenButton(
          label: 'Speichern',
          primary: true,
          busy: _busy,
          onTap: t == null || err != null || _busy ? null : () => _save(t),
        ),
      ],
    );
  }
}

class _SlotRow extends StatelessWidget {
  const _SlotRow({
    required this.slot,
    required this.index,
    required this.onTime,
    required this.onTemp,
    required this.onKind,
  });
  final ScheduleSlot slot;
  final int index;
  final ValueChanged<int> onTime;
  final ValueChanged<int> onTemp;
  final VoidCallback onKind;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    Widget btn(IconData i, String label, VoidCallback onTap) => Semantics(
      button: true,
      label: label,
      child: PressScale(
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: HavenSpace.touch,
          child: Icon(i, size: 20, color: hv.tx2),
        ),
      ),
    );
    final c = thermoColor(slot.temp);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: hv.s2,
        borderRadius: BorderRadius.circular(HavenRadii.m),
        border: Border(left: BorderSide(color: c, width: 4)),
      ),
      child: Row(
        children: [
          btn(
            Icons.remove_rounded,
            'Früher, Wechsel ${index + 1}',
            () => onTime(-1),
          ),
          Text(
            slot.timeText,
            style: HavenText.label.copyWith(color: hv.tx, fontSize: 15),
          ),
          btn(
            Icons.add_rounded,
            'Später, Wechsel ${index + 1}',
            () => onTime(1),
          ),
          const Spacer(),
          btn(
            Icons.remove_rounded,
            'Kälter, Wechsel ${index + 1}',
            () => onTemp(-1),
          ),
          SizedBox(
            width: 44,
            child: Text(
              '${fmtNum1(slot.temp)}°',
              textAlign: TextAlign.center,
              style: HavenText.label.copyWith(color: hv.tx, fontSize: 15),
            ),
          ),
          btn(
            Icons.add_rounded,
            'Wärmer, Wechsel ${index + 1}',
            () => onTemp(1),
          ),
          Semantics(
            button: true,
            label: slot.comfort
                ? 'Komfort, umschalten auf Eco'
                : 'Eco, umschalten auf Komfort',
            excludeSemantics: true,
            child: PressScale(
              onTap: onKind,
              child: Container(
                width: 40,
                height: HavenSpace.touch,
                alignment: Alignment.center,
                child: Icon(
                  slot.comfort ? Icons.weekend_outlined : Icons.eco_outlined,
                  size: 19,
                  color: slot.comfort ? c : hv.ok,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
