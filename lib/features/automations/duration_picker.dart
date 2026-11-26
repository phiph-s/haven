import 'package:material_ui/material_ui.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/haven_card.dart';
import '../settings/settings_widgets.dart';
import 'motion_logic.dart';

/// Eigene Dauer wählen: Stunden, Minuten, Sekunden (in 5-s-Schritten) mit
/// Plus und Minus. Ergebnis in Sekunden, `null` = abgebrochen.
Future<int?> showDurationPicker(
  BuildContext context, {
  required String title,
  required int initial,
  int min = 10,
  int max = 6 * 3600,
}) => showHavenSheet<int>(
  context,
  builder: (ctx) => DurationPicker(
    title: title,
    initial: initial,
    min: min,
    max: max,
    onDone: (v) => Navigator.of(ctx).pop(v),
  ),
);

class DurationPicker extends StatefulWidget {
  const DurationPicker({
    super.key,
    required this.title,
    required this.initial,
    required this.min,
    required this.max,
    required this.onDone,
  });
  final String title;
  final int initial;
  final int min;
  final int max;
  final ValueChanged<int> onDone;

  @override
  State<DurationPicker> createState() => _DurationPickerState();
}

class _DurationPickerState extends State<DurationPicker> {
  late int _s = _clamp(widget.initial - widget.initial % 5);

  int _clamp(int v) => v.clamp(widget.min, widget.max);
  void _add(int d) => setState(() => _s = _clamp(_s + d));

  Widget _unit(String key, String label, int value, int step) {
    final hv = context.hv;
    return Expanded(
      child: Column(
        children: [
          RoundIconButton(
            key: ValueKey('duration-$key-up'),
            icon: Icons.add_rounded,
            label: '$label mehr',
            onTap: () => _add(step),
          ),
          const SizedBox(height: 8),
          Text(
            value.toString().padLeft(key == 'h' ? 1 : 2, '0'),
            style: HavenText.headline.copyWith(color: hv.tx, fontSize: 30),
          ),
          Text(label, style: HavenText.caption.copyWith(color: hv.tx2)),
          const SizedBox(height: 8),
          RoundIconButton(
            key: ValueKey('duration-$key-down'),
            icon: Icons.remove_rounded,
            label: '$label weniger',
            onTap: () => _add(-step),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final long = widget.max >= 3600;
    return Padding(
      key: const ValueKey('duration-picker'),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title, style: HavenText.section.copyWith(color: hv.tx)),
          const SizedBox(height: 4),
          Text(
            '${delayLabel(widget.min)} bis ${delayLabel(widget.max)}',
            style: HavenText.caption.copyWith(color: hv.tx2),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              if (long) _unit('h', 'Std.', _s ~/ 3600, 3600),
              _unit('m', 'Min.', long ? _s % 3600 ~/ 60 : _s ~/ 60, 60),
              _unit('s', 'Sek.', _s % 60, 5),
            ],
          ),
          const SizedBox(height: 18),
          HavenButton(
            key: const ValueKey('duration-done'),
            label: '${delayLabel(_s)} übernehmen',
            primary: true,
            onTap: () => widget.onDone(_s),
          ),
        ],
      ),
    );
  }
}
