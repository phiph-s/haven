import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/router/router.dart';
import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/haven_card.dart';
import '../../core/widgets/segmented.dart';
import '../../data/models/room.dart';
import '../../data/models/snapshot.dart';
import '../ha_web/ha_web_screen.dart';
import '../map/map_routes.dart';
import '../updates/app_update_provider.dart';
import '../updates/app_update_widgets.dart';
import '../updates/ha_updates_provider.dart';
import 'settings_widgets.dart';
import '../room/widgets/light_control_list.dart';

/// Pfad des Grundriss-Editors. Der Karten-Agent legt die Route `editor` unter
/// `/map` an. Solange sie fehlt, meldet der Eintrag das, statt ins Leere zu laufen.
const String floorPlanEditorPath = '/map/editor';

bool get _editorExists =>
    mapRoutes.any((r) => r is GoRoute && r.path == 'editor');

/// Geräte eines Raums: Lampen, Sensoren und Bedienelemente.
int roomDeviceCount(Room r) =>
    {...r.lightIds, ?r.temperatureId, ?r.humidityId}.length + r.controls.length;

/// Einstellungen: Darstellung, Verbindung, Zuhause, Home Assistant, Über.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Falls die Übersicht die Prüfung noch nicht angestoßen hat.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(appUpdateProvider.notifier).checkIfDue());
    });
  }

  static String _status(ConnectionStatus s) => switch (s) {
    ConnectionStatus.connected => 'Verbunden',
    ConnectionStatus.connecting => 'Verbindet',
    ConnectionStatus.reconnecting => 'Unterbrochen, verbindet neu',
    ConnectionStatus.authFailed => 'Token abgelehnt',
    ConnectionStatus.offline => 'Getrennt',
  };

  Future<void> _reconnect() async {
    final url = ref.read(settingsStoreProvider).haUrl;
    final token = await ref.read(tokenStoreProvider).read();
    if (!mounted) return;
    if (url == null || token == null) {
      showHavenToast(context, 'Adresse oder Token fehlt. Verbinde neu.');
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(sessionProvider.notifier).connectHa(url, token);
      if (mounted) showHavenToast(context, 'Neu verbunden');
    } catch (e) {
      if (mounted) showHavenToast(context, 'Verbindung fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openEditor() {
    if (_editorExists) {
      context.push(floorPlanEditorPath);
    } else {
      showHavenToast(context, 'Der Grundriss-Editor ist noch nicht verfügbar.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final mode = ref.watch(themeModeProvider);
    final session = ref.watch(sessionProvider);
    final snap = ref.watch(snapshotProvider);
    final isFake = session.mode == SessionMode.fake;
    final url = ref.watch(settingsStoreProvider).haUrl;
    final app = ref.watch(appUpdateProvider);
    final haUpdates = ref.watch(haUpdatesProvider);
    final ok = snap.status == ConnectionStatus.connected;
    final statusColor = isFake
        ? hv.warn
        : switch (snap.status) {
            ConnectionStatus.connected => hv.ok,
            ConnectionStatus.authFailed || ConnectionStatus.offline => hv.bad,
            _ => hv.warn,
          };

    Widget section(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 26, 20, 10),
      child: Text(t, style: HavenText.section.copyWith(color: hv.tx)),
    );
    Widget pad(Widget w) =>
        Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: w);

    return Scaffold(
      backgroundColor: hv.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 40),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
              child: Row(
                children: [
                  RoundIconButton(
                    icon: Icons.arrow_back_rounded,
                    label: 'Zurück',
                    onTap: () => context.pop(),
                  ),
                  Expanded(
                    child: Text(
                      'Einstellungen',
                      textAlign: TextAlign.center,
                      style: HavenText.headline.copyWith(
                        color: hv.tx,
                        fontSize: 22,
                      ),
                    ),
                  ),
                  const SizedBox(width: HavenSpace.touch),
                ],
              ),
            ),
            section('Erscheinungsbild'),
            pad(
              HavenSegmented<ThemeMode>(
                options: const [
                  (ThemeMode.system, 'System'),
                  (ThemeMode.light, 'Hell'),
                  (ThemeMode.dark, 'Dunkel'),
                ],
                selected: mode,
                onChanged: ref.read(themeModeProvider.notifier).set,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
              child: Text(
                'System folgt deinem Handy. Hell und Dunkel sind eigens gestaltet.',
                style: HavenText.caption.copyWith(color: hv.tx2),
              ),
            ),
            section('Verbindung'),
            pad(
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: Icons.wifi_tethering_rounded,
                    title: isFake ? 'Entwicklungsdaten' : _status(snap.status),
                    subtitle: isFake
                        ? 'Erfundene Wohnung, kein Home Assistant'
                        : (ok ? 'Home Assistant antwortet' : null),
                    iconColor: statusColor,
                    trailing: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  if (!isFake)
                    SettingsRow(
                      icon: Icons.link_rounded,
                      title: 'Adresse',
                      subtitle: url ?? 'Nicht gesetzt',
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            pad(
              isFake
                  ? const SizedBox.shrink()
                  : Row(
                      children: [
                        Expanded(
                          child: HavenButton(
                            label: 'Neu verbinden',
                            icon: Icons.sync_rounded,
                            busy: _busy,
                            onTap: _reconnect,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: HavenButton(
                            label: 'Trennen',
                            destructive: true,
                            onTap: ref
                                .read(sessionProvider.notifier)
                                .disconnect,
                          ),
                        ),
                      ],
                    ),
            ),
            section('Zuhause'),
            pad(
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: Icons.map_outlined,
                    title: 'Grundriss bearbeiten',
                    subtitle: 'Räume zeichnen, Geräte platzieren',
                    onTap: _openEditor,
                  ),
                  SettingsRow(
                    icon: Icons.meeting_room_outlined,
                    title: 'Räume verwalten',
                    subtitle: '${snap.rooms.length} Räume',
                    onTap: () => showHavenSheet<void>(
                      context,
                      builder: (_) => const _RoomsSheet(),
                    ),
                  ),
                  SettingsRow(
                    icon: Icons.lightbulb_outline_rounded,
                    title: 'Lichtsteuerung',
                    subtitle: snap.excludedLights.isEmpty
                        ? 'Alle Lichter gehören dazu'
                        : '${snap.excludedLights.length} ${snap.excludedLights.length == 1 ? 'Licht' : 'Lichter'} ausgenommen',
                    onTap: () => showLightControlSheet(context),
                  ),
                  SettingsRow(
                    icon: Icons.restart_alt_rounded,
                    title: 'Widgets zurücksetzen',
                    subtitle: 'Startseite auf die Vorgabe',
                    onTap: () {
                      ref.read(widgetsProvider.notifier).reset();
                      showHavenToast(context, 'Widgets zurückgesetzt');
                    },
                  ),
                ],
              ),
            ),
            section('Home Assistant'),
            pad(
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: Icons.open_in_new_rounded,
                    title: 'Home Assistant öffnen',
                    subtitle: 'Die volle Oberfläche in der App',
                    onTap: () => context.push(
                      haWebLocation('/', title: 'Home Assistant'),
                    ),
                  ),
                ],
              ),
            ),
            section('Updates'),
            pad(
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: Icons.system_update_alt_rounded,
                    title: 'Haven-App',
                    subtitle: app.available
                        ? 'Version ${app.current}, ${app.release!.version} verfügbar'
                        : (app.lastChecked == null
                              ? 'Version ${app.current}'
                              : 'Version ${app.current}, aktuell'),
                    iconColor: app.available ? hv.acc : null,
                  ),
                  SettingsRow(
                    icon: Icons.refresh_rounded,
                    title: 'Nach Updates suchen',
                    subtitle: app.phase == AppUpdatePhase.checking
                        ? 'Sucht'
                        : (app.error ??
                              (app.lastChecked == null
                                  ? 'Noch nicht geprüft'
                                  : 'Zuletzt geprüft um ${_hhmm(app.lastChecked!)}')),
                    onTap: () async {
                      await ref.read(appUpdateProvider.notifier).check();
                      if (!context.mounted) return;
                      final s = ref.read(appUpdateProvider);
                      if (s.error == null && !s.available) {
                        showHavenToast(context, 'Haven ist aktuell');
                      }
                    },
                  ),
                  SettingsRow(
                    icon: Icons.upgrade_rounded,
                    title: 'Updates in Home Assistant',
                    subtitle: haUpdates.isEmpty
                        ? 'Alles aktuell'
                        : (haUpdates.count == 1
                              ? 'Ein Update verfügbar'
                              : '${haUpdates.count} Updates verfügbar'),
                    iconColor: haUpdates.isEmpty ? null : hv.warn,
                    onTap: () => context.push(Routes.updates),
                  ),
                ],
              ),
            ),
            pad(const AppUpdatePanel()),
            section('Über Haven'),
            pad(
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: Icons.info_outline_rounded,
                    title: 'Über Haven',
                    subtitle: 'Version ${app.current}',
                    onTap: () => showHavenSheet<void>(
                      context,
                      builder: (_) => _AboutSheet(version: app.current),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoomsSheet extends ConsumerWidget {
  const _RoomsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hv = context.hv;
    final rooms = ref.watch(roomsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Räume', style: HavenText.section.copyWith(color: hv.tx)),
        const SizedBox(height: 4),
        Text(
          'Bearbeiten kommt später. Räume stammen aus den Bereichen in Home Assistant.',
          style: HavenText.body.copyWith(color: hv.tx2, fontSize: 14),
        ),
        const SizedBox(height: 16),
        if (rooms.isEmpty)
          Text(
            'Noch keine Räume.',
            style: HavenText.body.copyWith(color: hv.tx2),
          )
        else
          SettingsGroup(
            children: [
              for (final r in rooms)
                SettingsRow(
                  icon: Icons.meeting_room_outlined,
                  title: r.name,
                  subtitle: switch (roomDeviceCount(r)) {
                    0 => 'Keine Geräte',
                    1 => '1 Gerät',
                    final n => '$n Geräte',
                  },
                ),
            ],
          ),
      ],
    );
  }
}

String _hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class _AboutSheet extends StatelessWidget {
  const _AboutSheet({required this.version});
  final String version;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
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
            child: Icon(Icons.home_rounded, size: 34, color: hv.ai),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Haven',
          textAlign: TextAlign.center,
          style: HavenText.section.copyWith(color: hv.tx),
        ),
        Text(
          'Version $version',
          textAlign: TextAlign.center,
          style: HavenText.caption.copyWith(color: hv.tx2),
        ),
        const SizedBox(height: 14),
        Text(
          'Eine Smart-Home-App für Home Assistant und Zigbee2MQTT. '
          'Lichter, Räume und Abläufe an einem Ort, ohne dass du YAML '
          'anfassen musst.',
          textAlign: TextAlign.center,
          style: HavenText.body.copyWith(color: hv.tx2),
        ),
      ],
    );
  }
}
