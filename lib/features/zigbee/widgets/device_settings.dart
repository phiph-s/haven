import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/haven_button.dart';
import '../../../core/widgets/haven_card.dart';
import '../../../core/widgets/haven_switch.dart';
import '../../../core/widgets/press_scale.dart';
import '../../../core/widgets/segmented.dart';
import '../../../data/models/zigbee.dart';
import '../../room/widgets/brightness_slider.dart';
import '../zigbee_actions.dart';
import '../zigbee_model.dart';
import '../zigbee_providers.dart';
import 'zb_common.dart';

/// Einstellungen eines Geräts, generisch aus `classified.settings`, gruppiert
/// nach `group` in der Reihenfolge `setting_groups`.
class ZbSettingsSection extends StatelessWidget {
  const ZbSettingsSection({
    super.key,
    required this.view,
    required this.classified,
  });
  final ZbDeviceView view;
  final ZbClassified classified;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final groups = classified.groupedSettings;
    if (groups.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (name, features) in groups) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 0, 8),
            child: Text(
              name,
              style: HavenText.label.copyWith(color: hv.tx2, fontSize: 13.5),
            ),
          ),
          HavenCard(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                for (var i = 0; i < features.length; i++) ...[
                  if (i > 0) Divider(height: 1, thickness: 1, color: hv.ln),
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

/// Eine Einstellung mit Label, Hilfetext und passender Steuerung.
class ZbSettingRow extends ConsumerStatefulWidget {
  const ZbSettingRow({super.key, required this.view, required this.feature});
  final ZbDeviceView view;
  final ZbFeature feature;

  @override
  ConsumerState<ZbSettingRow> createState() => _ZbSettingRowState();
}

class _ZbSettingRowState extends ConsumerState<ZbSettingRow> {
  double? _drag; // Wert während des Ziehens
  Timer? _debounce;

  ZbFeature get f => widget.feature;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _send(dynamic value) async {
    final err = await ref
        .read(zigbeeProvider.notifier)
        .setValue(widget.view.ieee, f.property, value);
    if (!mounted) return;
    if (err != null) {
      zbToast(context, 'Nicht gespeichert. $err', error: true);
    } else {
      zbToast(context, 'Gespeichert');
    }
  }

  // ---- Zahl ----

  num get _min => f.min ?? 0;
  num get _max => f.max ?? 100;
  num get _step => (f.step == null || f.step == 0) ? 1 : f.step!;
  bool get _hasRange => f.min != null && f.max != null && _max > _min;
  bool get _wide => _hasRange && (_max - _min) / _step > 100;

  double _fromPct(int p) {
    final t = p / 100;
    final v = _min + (_wide ? t * t : t) * (_max - _min);
    return _quantize(v);
  }

  int _toPct(num v) {
    final t = ((v - _min) / (_max - _min)).clamp(0.0, 1.0).toDouble();
    return ((_wide ? math.sqrt(t) : t) * 100).round();
  }

  double _quantize(num v) {
    final s = _step.toDouble();
    final q = (((v - _min) / s).round() * s + _min).clamp(
      _min.toDouble(),
      _max.toDouble(),
    );
    // Gleitkomma-Rauschen entfernen.
    return double.parse(q.toStringAsFixed(4));
  }

  String _numText(num v) {
    final u = f.unit;
    if (u == 's' || u == 'seconds') return durationLabel(v);
    final d = (_step % 1 == 0) ? 0 : 1;
    final ul = unitLabel(u);
    return ul.isEmpty ? fmtNum(v, digits: d) : '${fmtNum(v, digits: d)} $ul';
  }

  void _stepBy(int dir, num current) {
    final next = _quantize(current + dir * _step);
    setState(() => _drag = next.toDouble());
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      final out = (_step % 1 == 0) ? next.round() : next;
      _send(out);
      if (mounted) setState(() => _drag = null);
    });
  }

  // ---- Bau ----

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final current = widget.view.read(f);
    final writable = f.canWrite;

    Widget title(String right) => Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Expanded(
          child: Text(
            f.label,
            style: HavenText.label.copyWith(color: hv.tx, fontSize: 15),
          ),
        ),
        if (right.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(
              right,
              style: HavenText.label.copyWith(color: hv.acc, fontSize: 14),
            ),
          ),
      ],
    );

    Widget help() => f.help == null || f.help!.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              f.help!,
              style: HavenText.caption.copyWith(
                color: hv.tx2,
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          );

    Widget padded(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: child,
    );

    // Schalter
    if (f.isBinary) {
      final on = f.isOn(current);
      return padded(
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    f.label,
                    style: HavenText.label.copyWith(color: hv.tx, fontSize: 15),
                  ),
                  help(),
                ],
              ),
            ),
            const SizedBox(width: 8),
            HavenSwitch(
              value: on,
              semanticLabel: f.label,
              onChanged: writable ? (v) => _send(f.binaryValue(v)) : null,
            ),
          ],
        ),
      );
    }

    // Auswahl
    if (f.isEnum) {
      final cur = current?.toString();
      final maxLen = f.values.fold<int>(
        0,
        (a, v) => math.max(a, v.label.length),
      );
      final n = f.values.length;
      final fits = n >= 2 && n <= 4 && maxLen <= ((332 / n - 12) / 7.6).floor();
      if (writable && fits) {
        return padded(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title(''),
              help(),
              const SizedBox(height: 10),
              HavenSegmented<String>(
                options: [for (final v in f.values) (v.value, v.label)],
                selected: cur ?? '',
                onChanged: _send,
              ),
            ],
          ),
        );
      }
      return PressScale(
        pressedScale: 0.99,
        onTap: writable ? () => _pickEnum(cur) : null,
        child: padded(
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      f.label,
                      style: HavenText.label.copyWith(
                        color: hv.tx,
                        fontSize: 15,
                      ),
                    ),
                    help(),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(
                  cur == null ? '–' : f.labelOf(cur),
                  textAlign: TextAlign.end,
                  style: HavenText.label.copyWith(color: hv.acc, fontSize: 14),
                ),
              ),
              if (writable)
                Icon(Icons.unfold_more_rounded, size: 20, color: hv.tx3),
            ],
          ),
        ),
      );
    }

    // Zahl
    if (f.isNumeric) {
      final num? cur = _drag ?? (current is num ? current : null);
      final label = cur == null ? '–' : _numText(cur);
      if (!writable) {
        return padded(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [title(label), help()],
          ),
        );
      }
      return padded(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            title(label),
            help(),
            const SizedBox(height: 10),
            if (_hasRange && _max - _min > 2 * _step)
              SizedBox(
                height: 44,
                child: BrightnessSlider(
                  axis: Axis.horizontal,
                  label: f.label,
                  value: _toPct(cur ?? _min),
                  colors: [hv.acc2.withValues(alpha: 0.7), hv.acc],
                  onChanged: (p) => setState(() => _drag = _fromPct(p)),
                  onChangeEnd: () {
                    final v = _drag;
                    if (v == null) return;
                    _send(_step % 1 == 0 ? v.round() : v);
                    setState(() => _drag = null);
                  },
                ),
              ),
            if (_hasRange && _max - _min > 2 * _step) const SizedBox(height: 8),
            _Stepper(
              text: label,
              onMinus: () => _stepBy(-1, cur ?? _min),
              onPlus: () => _stepBy(1, cur ?? _min),
              canMinus: cur == null || cur > _min || !_hasRange,
              canPlus: cur == null || cur < _max || !_hasRange,
            ),
            if (f.presets.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in f.presets)
                    if (p.value is num)
                      _PresetChip(
                        label: _presetLabel(p),
                        selected: cur == p.value,
                        onTap: () => _send(p.value),
                      ),
                ],
              ),
            ],
          ],
        ),
      );
    }

    // Text und alles andere: Zeile mit Wert, bei Schreibrecht Eingabe im Sheet.
    final text = current?.toString() ?? '–';
    return PressScale(
      pressedScale: 0.99,
      onTap: writable && f.type == 'text' ? () => _editText(text) : null,
      child: padded(
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    f.label,
                    style: HavenText.label.copyWith(color: hv.tx, fontSize: 15),
                  ),
                  help(),
                ],
              ),
            ),
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: HavenText.label.copyWith(color: hv.acc, fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _presetLabel(ZbPreset p) {
    const names = {
      'coolest': 'Kaltweiß',
      'cool': 'Kühl',
      'neutral': 'Neutral',
      'warm': 'Warm',
      'warmest': 'Warmweiß',
    };
    return names[p.name] ?? _numText(p.value as num);
  }

  Future<void> _pickEnum(String? cur) async {
    final choice = await showZbSheet<String>(
      context,
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(f.label, style: HavenText.headline.copyWith(color: ctx.hv.tx)),
          if (f.help != null) ...[
            const SizedBox(height: 4),
            Text(
              f.help!,
              style: HavenText.body.copyWith(color: ctx.hv.tx2, fontSize: 14),
            ),
          ],
          const SizedBox(height: 14),
          for (final v in f.values)
            ZbChoiceRow(
              label: v.label,
              selected: v.value == cur,
              onTap: () => Navigator.of(ctx).pop(v.value),
            ),
        ],
      ),
    );
    if (choice != null && choice != cur) await _send(choice);
  }

  Future<void> _editText(String cur) async {
    final c = TextEditingController(text: cur == '–' ? '' : cur);
    final v = await showZbSheet<String>(
      context,
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(f.label, style: HavenText.headline.copyWith(color: ctx.hv.tx)),
          const SizedBox(height: 14),
          NameField(
            controller: c,
            autofocus: true,
            onSubmitted: (t) => Navigator.of(ctx).pop(t),
          ),
          const SizedBox(height: 14),
          HavenButton(
            label: 'Speichern',
            primary: true,
            onTap: () => Navigator.of(ctx).pop(c.text),
          ),
        ],
      ),
    );
    c.dispose();
    if (v != null && v != cur) await _send(v);
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.text,
    required this.onMinus,
    required this.onPlus,
    required this.canMinus,
    required this.canPlus,
  });
  final String text;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  final bool canMinus;
  final bool canPlus;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    Widget btn(IconData i, String label, bool enabled, VoidCallback t) =>
        Semantics(
          button: true,
          label: label,
          enabled: enabled,
          child: PressScale(
            onTap: enabled ? t : null,
            child: Container(
              width: HavenSpace.touch,
              height: HavenSpace.touch,
              decoration: BoxDecoration(
                color: hv.s2,
                borderRadius: BorderRadius.circular(HavenRadii.m),
                border: Border.all(color: hv.ln2),
              ),
              child: Icon(
                i,
                size: 22,
                color: enabled ? hv.tx : hv.tx3.withValues(alpha: 0.5),
              ),
            ),
          ),
        );
    return Row(
      children: [
        btn(Icons.remove_rounded, 'Weniger', canMinus, onMinus),
        Expanded(
          child: Center(
            child: Text(
              text,
              style: HavenText.headline.copyWith(color: hv.tx, fontSize: 19),
            ),
          ),
        ),
        btn(Icons.add_rounded, 'Mehr', canPlus, onPlus),
      ],
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return PressScale(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? hv.acc : hv.s2,
          borderRadius: BorderRadius.circular(HavenRadii.pill),
          border: Border.all(color: selected ? hv.acc : hv.ln2),
        ),
        child: Text(
          label,
          style: HavenText.label.copyWith(
            color: selected ? hv.ai : hv.tx2,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}
