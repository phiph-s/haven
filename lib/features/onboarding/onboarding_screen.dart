import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/light/color_math.dart';
import '../../core/light/room_palette.dart';
import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/animated_palette.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/haven_card.dart';

/// Erster Start: mit Home Assistant verbinden (Adresse und Token).
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  bool _busy = false;
  bool _showToken = false;
  String? _error;
  final _url = TextEditingController();
  final _token = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connectHa() async {
    final url = _url.text.trim();
    final token = _token.text.trim();
    if (url.isEmpty || token.isEmpty) {
      setState(() => _error = 'Trage Adresse und Token ein.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).connectHa(url, token);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is Exception && e.toString().isNotEmpty
              ? e.toString()
              : 'Die Verbindung hat nicht geklappt.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final palette = computePalette(const [
      LampLight((255, 168, 90), 85),
      LampLight((150, 92, 255), 70),
      LampLight((255, 84, 170), 60),
    ], dark: hv.isDark);
    final media = MediaQuery.of(context);
    return Scaffold(
      backgroundColor: hv.bg,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: media.size.height * 0.62,
            child: IgnorePointer(
              child: MeshGlow(palette: palette, style: MeshStyle.ambient),
            ),
          ),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: media.size.height - media.padding.vertical - 24,
                ),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 72),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(HavenRadii.l),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [palette.primary, palette.secondary],
                            ),
                            boxShadow: hv.shadow,
                          ),
                          child: Icon(
                            Icons.home_rounded,
                            size: 38,
                            color: colorOf(onColorFor(rgbOf(palette.primary))),
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      Text(
                        'Haven',
                        style: HavenText.display.copyWith(
                          color: hv.tx,
                          fontSize: 48,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Dein Zuhause, einfach bedient. Das Licht färbt die ganze App.',
                        style: HavenText.body.copyWith(
                          color: hv.tx2,
                          fontSize: 17,
                        ),
                      ),
                      const Spacer(),
                      const SizedBox(height: 32),
                      _form(hv),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorText(HavenColors hv) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Text(
      _error!,
      style: HavenText.body.copyWith(color: hv.bad, fontSize: 14),
    ),
  );

  Widget _form(HavenColors hv) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      HavenCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Adresse', style: HavenText.label.copyWith(color: hv.tx2)),
            const SizedBox(height: 6),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enabled: !_busy,
              decoration: const InputDecoration(
                hintText: 'http://homeassistant.local:8123',
              ),
            ),
            const SizedBox(height: 14),
            Text('Token', style: HavenText.label.copyWith(color: hv.tx2)),
            const SizedBox(height: 6),
            TextField(
              controller: _token,
              obscureText: !_showToken,
              autocorrect: false,
              enableSuggestions: false,
              enabled: !_busy,
              decoration: InputDecoration(
                hintText: 'Langlebiger Zugriffstoken',
                suffixIcon: IconButton(
                  tooltip: _showToken ? 'Token verbergen' : 'Token zeigen',
                  icon: Icon(
                    _showToken
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  onPressed: () => setState(() => _showToken = !_showToken),
                ),
              ),
            ),
            const SizedBox(height: 10),
            // TODO(oauth): Login über Home Assistant statt Token.
            Text(
              'Den Token legst du als Administrator in Home Assistant unter Profil und Sicherheit an. Er bleibt verschlüsselt auf diesem Gerät. Der Login über Home Assistant folgt später.',
              style: HavenText.caption.copyWith(color: hv.tx3),
            ),
          ],
        ),
      ),
      if (_error != null) _errorText(hv),
      const SizedBox(height: 16),
      HavenButton(
        label: 'Mit Home Assistant verbinden',
        icon: Icons.link_rounded,
        primary: true,
        busy: _busy,
        onTap: _connectHa,
      ),
    ],
  );
}
