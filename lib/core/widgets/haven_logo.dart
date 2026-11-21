import 'package:flutter/widgets.dart';

/// Das App-Icon (Sofa-Raum auf Pfirsich, abgerundet) als Logo in der App.
class HavenLogo extends StatelessWidget {
  const HavenLogo({super.key, this.size = 72});

  final double size;

  static const asset = 'assets/brand/haven_icon.png';

  @override
  Widget build(BuildContext context) => Image.asset(
    asset,
    width: size,
    height: size,
    filterQuality: FilterQuality.medium,
    semanticLabel: 'Haven',
  );
}
