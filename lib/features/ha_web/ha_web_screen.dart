import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/haven_card.dart';
import '../settings/settings_widgets.dart';
import 'ha_auth_bridge.dart';
import 'ha_webview.dart';

/// Route zur eingebetteten HA-Oberfläche: `/automations/ha?path=...&title=...`.
String haWebLocation(String path, {String? title}) => Uri(
  path: '/automations/ha',
  queryParameters: {'path': path, 'title': ?title},
).toString();

const String _placeholderBase = 'http://homeassistant.local:8123';

/// Vollbild: lädt eine Seite von Home Assistant. Auf Android (echte
/// Sitzung) per WebView, sonst ein Platzhalter mit der Ziel-URL.
class HaWebScreen extends ConsumerStatefulWidget {
  const HaWebScreen({super.key, required this.path, this.title});

  final String path;
  final String? title;

  @override
  ConsumerState<HaWebScreen> createState() => _HaWebScreenState();
}

class _HaWebScreenState extends ConsumerState<HaWebScreen> {
  final _reload = ValueNotifier<int>(0);

  @override
  void dispose() {
    _reload.dispose();
    super.dispose();
  }

  bool _canEmbed(Session s) =>
      !kIsWeb &&
      s.mode == SessionMode.ha &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final session = ref.watch(sessionProvider);
    final url = ref.watch(settingsStoreProvider).haUrl;
    final embed = _canEmbed(session) && url != null && url.isNotEmpty;
    final target = haTargetUri(url ?? _placeholderBase, widget.path);
    final shown = haTargetUri(
      url ?? _placeholderBase,
      widget.path,
      externalAuth: false,
    );

    return Scaffold(
      backgroundColor: hv.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Row(
                children: [
                  RoundIconButton(
                    icon: Icons.arrow_back_rounded,
                    label: 'Zurück',
                    onTap: () => context.pop(),
                  ),
                  Expanded(
                    child: Text(
                      widget.title ?? 'Home Assistant',
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HavenText.headline.copyWith(
                        color: hv.tx,
                        fontSize: 20,
                      ),
                    ),
                  ),
                  RoundIconButton(
                    icon: Icons.refresh_rounded,
                    label: 'Neu laden',
                    onTap: () => _reload.value++,
                  ),
                ],
              ),
            ),
            Expanded(
              child: embed
                  ? HaWebView(
                      uri: target,
                      reload: _reload,
                      readToken: ref.read(tokenStoreProvider).read,
                    )
                  : _Placeholder(url: shown.toString()),
            ),
          ],
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.url});
  final String url;
  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      children: [
        HavenCard(
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
                child: Icon(Icons.open_in_new_rounded, size: 32, color: hv.ai),
              ),
              const SizedBox(height: 20),
              Text(
                'Öffnet in Home Assistant',
                style: HavenText.section.copyWith(color: hv.tx),
              ),
              const SizedBox(height: 6),
              Text(
                'Auf dem Handy erscheint hier die Oberfläche von Home '
                'Assistant, ohne dass du die App verlässt. Im Browser '
                'und in den Entwicklungsdaten zeigen wir nur das Ziel.',
                style: HavenText.body.copyWith(color: hv.tx2),
              ),
              const SizedBox(height: 18),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: hv.s2,
                  borderRadius: BorderRadius.circular(HavenRadii.m),
                  border: Border.all(color: hv.ln),
                ),
                child: SelectableText(
                  url,
                  style: HavenText.body.copyWith(
                    color: hv.tx,
                    fontFamily: 'monospace',
                    fontSize: 13.5,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              HavenButton(
                label: 'Adresse kopieren',
                icon: Icons.copy_rounded,
                onTap: () {
                  Clipboard.setData(ClipboardData(text: url));
                  showHavenToast(context, 'Adresse kopiert');
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}
