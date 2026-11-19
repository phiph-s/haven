import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../data/render_api.dart';
import '../map/floor_plan_store.dart';
import '../map/map_3d.dart';
import '../map/map_render.dart';
import 'settings_widgets.dart';

/// Einstellungen „Karte“: Bilder für Widgets und Displays von Hand neu
/// erstellen (sonst geschieht das nach Kartenänderungen von selbst). Nur,
/// wenn Home Assistant Bilder zusammensetzen kann.
class MapRenderSettingsRow extends ConsumerStatefulWidget {
  const MapRenderSettingsRow({super.key});

  @override
  ConsumerState<MapRenderSettingsRow> createState() =>
      _MapRenderSettingsRowState();
}

class _MapRenderSettingsRowState extends ConsumerState<MapRenderSettingsRow> {
  RenderStatus? _status;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final repo = ref.read(sessionProvider).repo;
    RenderStatus? s;
    try {
      s = await repo?.renderStatus();
    } catch (_) {
      s = null;
    }
    if (mounted) {
      setState(() {
        _status = s;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = ref.watch(floorPlanProvider).value;
    final supported = ref.watch(map3dSupportedProvider).value ?? false;
    final repo = ref.watch(sessionProvider.select((s) => s.repo));
    final status = _status;
    if (!_loaded ||
        status == null ||
        plan == null ||
        plan.isEmpty ||
        !supported ||
        repo == null) {
      return const SizedBox.shrink();
    }
    final key = mapRenderKey(plan, mapLayerViews(plan));
    final subtitle = status.key == null
        ? 'Noch keine. Tippen zum Erstellen.'
        : status.key == key
        ? 'Aktuell, ${status.sets.length} Bilder in Home Assistant'
        : 'Veraltet. Tippen zum Erneuern.';
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: SettingsGroup(
        children: [
          SettingsRow(
            icon: Icons.widgets_outlined,
            title: 'Bilder für Widgets',
            subtitle: subtitle,
            onTap: () async {
              await showMapRenderDialog(
                context,
                MapRenderJob(
                  repo,
                  plan,
                  reach: ref.read(map3dSettingsProvider).lightReach,
                ),
              );
              await _load();
            },
          ),
        ],
      ),
    );
  }
}
