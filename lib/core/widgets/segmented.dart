import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';
import 'haptics.dart';

/// Segmentierter Schalter, Daumen gleitet per Translation.
class HavenSegmented<T> extends StatelessWidget {
  const HavenSegmented({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.neutral = false,
  });

  /// Wert und Beschriftung.
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onChanged;

  /// Neutraler Daumen (Textfarbe) statt Akzent.
  final bool neutral;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final n = options.length;
    final idx = options.indexWhere((o) => o.$1 == selected).clamp(0, n - 1);
    final thumb = neutral ? hv.tx : hv.acc;
    final onThumb = neutral ? hv.bg : hv.ai;
    return Container(
      height: HavenSpace.touch,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: hv.s2,
        borderRadius: BorderRadius.circular(HavenRadii.m),
        border: Border.all(color: hv.ln),
      ),
      child: Stack(
        children: [
          FractionallySizedBox(
            widthFactor: 1 / n,
            child: AnimatedSlide(
              offset: Offset(idx.toDouble(), 0),
              duration: context.motion(HavenMotion.d2),
              curve: HavenMotion.spring,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: thumb,
                  borderRadius: BorderRadius.circular(HavenRadii.m - 4),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x40000000),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          Row(
            children: [
              for (final o in options)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: o.$1 == selected,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        if (o.$1 != selected) {
                          Haptics.tick();
                          onChanged(o.$1);
                        }
                      },
                      child: Center(
                        child: AnimatedDefaultTextStyle(
                          duration: context.motion(HavenMotion.d2),
                          style: HavenText.label.copyWith(
                            color: o.$1 == selected ? onThumb : hv.tx2,
                          ),
                          child: Text(o.$2),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
