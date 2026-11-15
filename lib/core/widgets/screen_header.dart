import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';
import 'haven_card.dart';

/// Kopf der Hauptseiten: kleine Zeile, Titel, Untertitel und Aktionen rechts.
class ScreenHeader extends StatelessWidget {
  const ScreenHeader({
    super.key,
    required this.title,
    this.eyebrow,
    this.subtitle,
    this.actions = const [],
    this.large = true,
  });

  final String title;
  final String? eyebrow;
  final String? subtitle;
  final List<Widget> actions;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Padding(
      padding: const EdgeInsets.fromLTRB(HavenSpace.page, 8, 8, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (eyebrow != null)
                    Text(
                      eyebrow!,
                      style: HavenText.body.copyWith(
                        color: hv.tx2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  Text(
                    title,
                    style: (large ? HavenText.display : HavenText.title)
                        .copyWith(color: hv.tx),
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        subtitle!,
                        style: HavenText.body.copyWith(
                          color: hv.tx2,
                          fontSize: 14.5,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          for (final a in actions) a,
        ],
      ),
    );
  }
}

/// Symbol für die Einstellungen, sitzt in jeder Kopfzeile.
class SettingsButton extends StatelessWidget {
  const SettingsButton({super.key});

  @override
  Widget build(BuildContext context) => RoundIconButton(
    icon: Icons.settings_outlined,
    label: 'Einstellungen',
    onTap: () => context.push('/settings'),
  );
}

/// Schön gestaltete Seite für Bereiche, die später gebaut werden.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.headline,
    required this.points,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final String headline;
  final List<String> points;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return ListView(
      padding: const EdgeInsets.only(bottom: HavenSpace.navClearance),
      children: [
        ScreenHeader(
          title: title,
          subtitle: subtitle,
          large: false,
          actions: const [SettingsButton()],
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HavenSpace.page),
          child: HavenCard(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [hv.acc, hv.acc2],
                    ),
                  ),
                  child: Icon(icon, size: 34, color: hv.ai),
                ),
                const SizedBox(height: 20),
                Text(headline, style: HavenText.section.copyWith(color: hv.tx)),
                const SizedBox(height: 6),
                Text(
                  'Dieser Bereich kommt in einer der nächsten Etappen.',
                  style: HavenText.body.copyWith(color: hv.tx2),
                ),
                const SizedBox(height: 16),
                for (final p in points)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 7),
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: hv.acc,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            p,
                            style: HavenText.body.copyWith(color: hv.tx),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
