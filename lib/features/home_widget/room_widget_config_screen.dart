import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/state/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../home/room_render.dart';
import '../map/floor_plan_store.dart';
import '../map/map_data.dart' show snapshotRoomFor;
import '../settings/settings_widgets.dart';
import 'room_widget_bridge.dart';

/// Einrichten eines Raum-Widgets: Raum wählen. Öffnet sich, wenn auf dem
/// Startbildschirm ein „Haven Raum“-Widget hinzugefügt wird.
class RoomWidgetConfigScreen extends ConsumerStatefulWidget {
  const RoomWidgetConfigScreen({super.key, required this.widgetId});

  final int widgetId;

  @override
  ConsumerState<RoomWidgetConfigScreen> createState() =>
      _RoomWidgetConfigScreenState();
}

class _RoomWidgetConfigScreenState
    extends ConsumerState<RoomWidgetConfigScreen> {
  bool _saving = false;

  Future<void> _pick(String roomId) async {
    if (_saving) return;
    setState(() => _saving = true);
    Haptics.tick();
    final snap = ref.read(snapshotProvider);
    final view = ref.read(roomViewProvider(roomId));
    if (view == null) return;
    final plan = ref.read(floorPlanProvider).value;
    final planRoom = plan?.rooms
        .where((r) => snapshotRoomFor(snap, r)?.id == roomId)
        .firstOrNull;
    final token = await ref.read(tokenStoreProvider).read();
    await RoomWidgetBridge.setCredentials(
      ref.read(settingsStoreProvider).haUrl,
      token,
    );
    await RoomWidgetBridge.save(
      widget.widgetId,
      roomWidgetConfig(snap, view, planRoom?.id),
    );
    await RoomWidgetBridge.finishConfigure(widget.widgetId);
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final session = ref.watch(sessionProvider);
    final rooms = ref.watch(snapshotProvider.select((s) => s.rooms));
    final renders = ref.watch(roomRendersAvailableProvider);
    return Scaffold(
      backgroundColor: hv.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          children: [
            Text(
              'Raum fürs Widget',
              style: HavenText.headline.copyWith(color: hv.tx, fontSize: 26),
            ),
            const SizedBox(height: 6),
            Text(
              session.mode != SessionMode.ha
                  ? 'Melde dich zuerst in Haven bei Home Assistant an, dann lässt sich das Widget einrichten.'
                  : renders
                  ? 'Das Widget zeigt den Raum mit seinem Licht. Tippen schaltet das Licht, der Pfeil öffnet den Raum in Haven.'
                  : 'Das Widget zeigt Licht und Temperatur des Raums. Das Bild des Raums erscheint, sobald Haven die Bilder für Widgets erstellt hat (Karte öffnen).',
              style: HavenText.body.copyWith(color: hv.tx2),
            ),
            const SizedBox(height: 18),
            if (session.mode == SessionMode.ha)
              SettingsGroup(
                children: [
                  for (final r in rooms)
                    SettingsRow(
                      key: ValueKey('widget-room-${r.id}'),
                      icon: Icons.meeting_room_outlined,
                      title: r.name,
                      onTap: _saving ? null : () => _pick(r.id),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
