import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/widgets/haven_sheet.dart';

import '../../../core/light/color_math.dart';
import '../../../core/light/room_palette.dart';
import '../../../core/state/providers.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/accent_scope.dart';
import '../../../core/widgets/animated_palette.dart';
import '../../../core/widgets/segmented.dart';
import '../../../data/room_view.dart';
import 'brightness_slider.dart';
import 'color_controls.dart';
import 'light_control_list.dart';

/// Ziel des Sheets: eine Lampe oder mehrere (Farbe für alle).
class LampTarget {
  const LampTarget({
    required this.title,
    required this.subtitle,
    required this.lampIds,
  });
  final String title;
  final String subtitle;
  final List<String> lampIds;
}

/// Lampen zu einer ID-Liste, verbunden mit `|`.
final lampGroupProvider = Provider.family<HouseView, String>((ref, key) {
  final s = ref.watch(snapshotProvider);
  return HouseView([
    for (final id in key.split('|'))
      if (s.lamp(id) != null) s.lamp(id)!,
  ]);
});

Future<void> showLampSheet(BuildContext context, LampTarget target) {
  return showHavenModalSheet<void>(
    context,
    builder: (_) => _LampSheet(target: target),
  );
}

class _LampSheet extends ConsumerStatefulWidget {
  const _LampSheet({required this.target});
  final LampTarget target;

  @override
  ConsumerState<_LampSheet> createState() => _LampSheetState();
}

class _LampSheetState extends ConsumerState<_LampSheet> {
  bool? _white; // null = automatisch aus der Lampe

  List<String> get _ids => widget.target.lampIds;

  void _set({int? brightness, Rgb? rgb, int? kelvin}) {
    ref
        .read(repositoryProvider)
        .setLights(
          _ids,
          on: true,
          brightness: brightness,
          rgb: rgb,
          kelvin: kelvin,
        );
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final dark = hv.isDark;
    final group = ref.watch(lampGroupProvider(_ids.join('|')));
    final lamps = group.lamps;
    if (lamps.isEmpty) return const SizedBox.shrink();
    final on = [
      for (final l in lamps)
        if (l.on) l,
    ];
    final lead = on.isNotEmpty ? on.first : lamps.first;
    final bri = on.isEmpty
        ? 0
        : (on.fold<int>(0, (a, l) => a + l.brightness) / on.length).round();
    final canColor = lamps.any((l) => l.supportsColor);
    final canWhite = lamps.any((l) => l.supportsKelvin);
    final white = _white ?? (lead.kelvin != null || !canColor);
    final palette = group.palette(dark: dark);
    final ui = colorOf(uiColor(lead.color, dark: dark));
    final media = MediaQuery.of(context);

    return AccentScope(
      palette: palette.isOn ? palette : RoomPalette.off,
      child: Builder(
        builder: (context) {
          final hv = context.hv;
          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: media.size.height * 0.9),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: hv.s1,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(HavenRadii.xl),
                ),
                border: Border.all(color: hv.ln),
              ),
              child: SingleChildScrollView(
                // Am oberen Ende übernimmt das Sheet das Ziehen.
                controller: HavenSheetScope.maybeOf(context)?.scrollController,
                padding: EdgeInsets.fromLTRB(
                  20,
                  10,
                  20,
                  20 + media.padding.bottom,
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
                    Row(
                      children: [
                        _Dot(on: lead.on, color: ui),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.target.title,
                                style: HavenText.headline.copyWith(
                                  color: hv.tx,
                                ),
                              ),
                              Text(
                                widget.target.subtitle,
                                style: HavenText.caption.copyWith(
                                  color: hv.tx3,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Helligkeit',
                      style: HavenText.label.copyWith(color: hv.tx2),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 46,
                      child: AnimatedPalette(
                        palette: palette,
                        builder: (context, p) => BrightnessSlider(
                          axis: Axis.horizontal,
                          value: bri,
                          colors: [
                            colorOf(
                              uiColor((255, 190, 120), dark: dark),
                            ).withValues(alpha: 0.9),
                            p.primary,
                          ],
                          onChanged: (v) => _set(brightness: v == 0 ? 1 : v),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (canColor && canWhite)
                      HavenSegmented<bool>(
                        neutral: true,
                        options: const [(false, 'Farbe'), (true, 'Weiß')],
                        selected: white,
                        onChanged: (v) => setState(() => _white = v),
                      ),
                    const SizedBox(height: 8),
                    if (!canWhite && !canColor)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'Dieser Dimmer kennt nur Helligkeit. Farbe und Weißton gibt es bei dieser Lampe nicht.',
                          style: HavenText.caption.copyWith(color: hv.tx2),
                        ),
                      )
                    else if (!white && canColor) ...[
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: ColorWheel(
                            color: lead.color,
                            onChanged: (c) => _set(rgb: c),
                          ),
                        ),
                      ),
                      ColorSwatches(onPick: (c) => _set(rgb: c)),
                    ] else ...[
                      const SizedBox(height: 4),
                      KelvinSlider(
                        kelvin:
                            lead.kelvin ??
                            rgbToKelvinApprox(
                              lead.color,
                            ).clamp(lead.minKelvin, lead.maxKelvin),
                        min: lead.minKelvin,
                        max: lead.maxKelvin,
                        onChanged: (k) => _set(kelvin: k),
                      ),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        children: [
                          for (final (n, k) in const [
                            ('Kerzenlicht', 2200),
                            ('Warm', 2700),
                            ('Neutral', 4000),
                            ('Tageslicht', 6000),
                          ])
                            _Chip(
                              label: '$n · $k K',
                              onTap: () => _set(kelvin: k),
                            ),
                        ],
                      ),
                    ],
                    if (_ids.length == 1) ...[
                      const SizedBox(height: 18),
                      ExcludeLightRow(entityId: _ids.single),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.on, required this.color});
  final bool on;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final fg = on ? colorOf(onColorFor(rgbOf(color))) : hv.tx3;
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: on ? color : hv.s2),
      duration: context.motion(HavenMotion.d3),
      builder: (context, c, _) => Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        child: Icon(Icons.lightbulb_rounded, size: 22, color: fg),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: HavenSpace.touch,
        child: Center(
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hv.s2,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: hv.ln),
            ),
            child: Text(label, style: HavenText.label.copyWith(color: hv.tx)),
          ),
        ),
      ),
    );
  }
}
