import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';
import 'haptics.dart';

/// Haptischer Schalter: Daumen weitet beim Drücken, federt beim Umlegen.
/// Zielgröße 62 x 48 dp, sichtbar 54 x 32. Farbe aus dem Akzent des Bildschirms.
class HavenSwitch extends StatefulWidget {
  const HavenSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  @override
  State<HavenSwitch> createState() => _HavenSwitchState();
}

class _HavenSwitchState extends State<HavenSwitch> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final reduce = context.reduceMotion;
    final d = reduce ? Duration.zero : HavenMotion.d2;
    return Semantics(
      toggled: widget.value,
      label: widget.semanticLabel,
      onTap: widget.onChanged == null
          ? null
          : () => widget.onChanged!(!widget.value),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onChanged == null
            ? null
            : () {
                Haptics.tick();
                widget.onChanged!(!widget.value);
              },
        child: SizedBox(
          width: 62,
          height: HavenSpace.touch,
          child: Center(
            child: AnimatedScale(
              scale: _down ? 0.95 : 1,
              duration: reduce ? Duration.zero : HavenMotion.d1,
              curve: HavenMotion.out,
              child: SizedBox(
                width: 54,
                height: 32,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: hv.s3,
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: AnimatedOpacity(
                        opacity: widget.value ? 1 : 0,
                        duration: reduce ? Duration.zero : HavenMotion.d2,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            gradient: LinearGradient(colors: [hv.acc, hv.acc2]),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 3,
                      top: 3,
                      child: AnimatedSlide(
                        offset: Offset(widget.value ? 22 / 26 : 0, 0),
                        duration: d,
                        curve: HavenMotion.spring,
                        child: AnimatedScale(
                          scale: _down ? 1.15 : 1,
                          duration: reduce ? Duration.zero : HavenMotion.d1,
                          curve: HavenMotion.out,
                          child: Container(
                            width: 26,
                            height: 26,
                            decoration: const BoxDecoration(
                              color: Color(0xFFFFFFFF),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Color(0x59000000),
                                  blurRadius: 5,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                          ),
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
    );
  }
}
