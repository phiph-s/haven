import 'package:material_ui/material_ui.dart';

import '../../../core/light/color_math.dart';
import '../../../core/light/room_palette.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/haven_switch.dart';
import '../../../data/models/lamp.dart';

/// Zeile in der Lampenliste: Farbpunkt, Name, Zustand, Schalter. Tippen
/// öffnet das Sheet mit Farbe und Weißton.
class LampRow extends StatelessWidget {
  const LampRow({
    super.key,
    required this.lamp,
    required this.onToggle,
    required this.onOpen,
    this.onLongPress,
  });

  final Lamp lamp;
  final ValueChanged<bool> onToggle;
  final VoidCallback onOpen;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final ui = colorOf(uiColor(lamp.displayColor, dark: hv.isDark));
    final fg = lamp.on ? colorOf(onColorFor(rgbOf(ui))) : hv.tx3;
    final sub = !lamp.available
        ? 'nicht erreichbar'
        : lamp.on
        ? (lamp.supportsBrightness ? '${lamp.brightness} %' : 'an')
        : 'aus';
    return Semantics(
      button: true,
      label: '${lamp.name}, $sub',
      hint: 'Öffnet Helligkeit und Farbe',
      onLongPressHint: 'Einstellungen der Lampe',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onOpen,
        onLongPress: onLongPress,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Row(
            children: [
              TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: lamp.on ? ui : hv.s2),
                duration: context.motion(HavenMotion.d4),
                builder: (context, c, _) => Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                  child: Icon(Icons.lightbulb_rounded, size: 20, color: fg),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      lamp.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HavenText.label.copyWith(
                        color: hv.tx,
                        fontSize: 15,
                      ),
                    ),
                    Text(sub, style: HavenText.caption.copyWith(color: hv.tx3)),
                  ],
                ),
              ),
              HavenSwitch(
                value: lamp.on,
                onChanged: lamp.available ? onToggle : null,
                semanticLabel: lamp.name,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
