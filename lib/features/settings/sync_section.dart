import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haven_button.dart';
import '../../data/sync/app_data.dart';
import '../../data/sync/doc_sync.dart';
import '../map/floor_plan_store.dart';
import '../zigbee/zigbee_actions.dart';
import 'settings_widgets.dart';

/// „vor 3 Min.“, „vor 2 Std.“, sonst Datum.
String relativeAgo(DateTime t, DateTime now) {
  final d = now.difference(t);
  if (d.inSeconds < 45) return 'gerade eben';
  if (d.inMinutes < 60) return 'vor ${d.inMinutes < 1 ? 1 : d.inMinutes} Min.';
  if (d.inHours < 24) return 'vor ${d.inHours} Std.';
  return 'vor ${d.inDays} ${d.inDays == 1 ? 'Tag' : 'Tagen'}';
}

/// Zeit eines `updated_at` (ms): „heute 11:18“ bzw. „15.11. 11:18“.
String stampText(int ms, DateTime now) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    return 'heute $hm';
  }
  return '${two(t.day)}.${two(t.month)}. $hm';
}

String _kindName(AppDataKind k) => switch (k) {
  AppDataKind.floorplan => 'Grundriss',
  AppDataKind.widgets => 'Übersicht',
  AppDataKind.prefs => 'Lichtsteuerung',
};

/// Einstellungen: Abschnitt „Synchronisation“ je geteiltem Dokument mit
/// Zustand, Stand in HA und den Knöpfen zum Abgleichen und Übernehmen.
class SyncSection extends ConsumerStatefulWidget {
  const SyncSection({super.key, this.clock});
  final DateTime Function()? clock;

  @override
  ConsumerState<SyncSection> createState() => _SyncSectionState();
}

class _SyncSectionState extends ConsumerState<SyncSection> {
  bool _busy = false;
  DateTime? _prefsAt;
  RemoteDoc? _prefsRemote;
  String? _prefsError;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    unawaited(_loadPrefs());
  }

  Future<void> _loadPrefs() async {
    try {
      final r = await ref
          .read(repositoryProvider)
          .fetchAppData(AppDataKind.prefs);
      if (!mounted) return;
      setState(() {
        _prefsRemote = r;
        _prefsAt = _now();
        _prefsError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _prefsError = '$e');
    }
  }

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    try {
      final docs = ref.read(syncRegistryProvider).docs.values.toList();
      await Future.wait([for (final d in docs) d.pull()]);
      await ref.read(repositoryProvider).refresh();
      await _loadPrefs();
      if (mounted) showHavenToast(context, 'Abgeglichen');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _takeRemote() async {
    final ok = await confirmSheet(
      context,
      title: 'Stand aus Home Assistant übernehmen',
      text:
          'Die Fassung auf diesem Gerät wird verworfen. Grundriss und Übersicht gelten dann so, wie sie in Home Assistant gespeichert sind.',
      action: 'Übernehmen',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final docs = ref.read(syncRegistryProvider).docs.values.toList();
      final texts = <String>[];
      for (final d in docs) {
        texts.add('${_kindName(d.kind)}: ${await d.takeRemoteNow()}');
      }
      await ref.read(repositoryProvider).refresh();
      await _loadPrefs();
      if (mounted) showHavenToast(context, texts.join('\n'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    // Die Besitzer anlegen, sie melden ihren Abgleich an (lazy Provider).
    ref.watch(floorPlanProvider.select((_) => 0));
    ref.watch(homeLayoutProvider.select((_) => 0));
    final registry = ref.watch(syncRegistryProvider);
    final repo = ref.watch(repositoryProvider);
    ref.watch(snapshotProvider.select((s) => s.excludedLights));
    return ListenableBuilder(
      listenable: registry,
      builder: (context, _) {
        final docs = registry.docs;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsGroup(
              children: [
                for (final k in const [
                  AppDataKind.floorplan,
                  AppDataKind.widgets,
                ])
                  if (docs[k] != null)
                    ValueListenableBuilder<SyncInfo>(
                      valueListenable: docs[k]!.info,
                      builder: (_, i, _) => _row(hv, k, i),
                    ),
                _prefsRow(hv, repo.prefsShared),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: HavenButton(
                    label: 'Jetzt abgleichen',
                    icon: Icons.sync_rounded,
                    busy: _busy,
                    onTap: _syncNow,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: HavenButton(
                    label: 'Stand aus Home Assistant übernehmen',
                    icon: Icons.cloud_download_outlined,
                    destructive: true,
                    onTap: _busy ? null : _takeRemote,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _row(HavenColors hv, AppDataKind k, SyncInfo i) {
    final now = _now();
    final (label, color) = switch (i.state) {
      SyncState.current => ('Aktuell', hv.ok),
      SyncState.pending => ('Änderung wartet', hv.warn),
      SyncState.error => ('Fehler', hv.bad),
    };
    final lines = <String>[
      label,
      i.lastSync == null
          ? 'Noch nicht abgeglichen'
          : 'Abgeglichen ${relativeAgo(i.lastSync!, now)}',
      if (i.remoteAt != null) 'Stand in HA: ${stampText(i.remoteAt!, now)}',
      if (i.remoteSummary != null) 'In HA: ${i.remoteSummary}',
      if (i.localSummary != null) 'Hier: ${i.localSummary}',
      ?i.lastError,
    ];
    return SettingsRow(
      icon: switch (k) {
        AppDataKind.floorplan => Icons.map_outlined,
        AppDataKind.widgets => Icons.dashboard_outlined,
        AppDataKind.prefs => Icons.lightbulb_outline_rounded,
      },
      title: _kindName(k),
      subtitle: lines.join('\n'),
      subtitleLines: 8,
      iconColor: color,
      trailing: _dot(color),
    );
  }

  Widget _prefsRow(HavenColors hv, bool shared) {
    final now = _now();
    final r = _prefsRemote;
    final (label, color) = _prefsError != null
        ? ('Fehler', hv.bad)
        : (shared ? ('Aktuell', hv.ok) : ('Nur auf diesem Gerät', hv.warn));
    final lines = <String>[
      label,
      _prefsAt == null
          ? 'Noch nicht abgeglichen'
          : 'Abgeglichen ${relativeAgo(_prefsAt!, now)}',
      if (r != null && r.updatedAt != null)
        'Stand in HA: ${stampText(r.updatedAt!, now)}',
      ?_prefsError,
    ];
    return SettingsRow(
      icon: Icons.lightbulb_outline_rounded,
      title: _kindName(AppDataKind.prefs),
      subtitle: lines.join('\n'),
      subtitleLines: 8,
      iconColor: color,
      trailing: _dot(color),
    );
  }

  Widget _dot(Color c) => Container(
    width: 10,
    height: 10,
    decoration: BoxDecoration(color: c, shape: BoxShape.circle),
  );
}
