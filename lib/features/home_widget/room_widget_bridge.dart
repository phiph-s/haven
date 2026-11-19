import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/router/router.dart';
import '../../core/state/providers.dart';
import '../../data/room_view.dart';
import '../../data/models/snapshot.dart';
import '../home/room_render.dart';
import '../map/floor_plan_store.dart';
import '../map/map_data.dart' show snapshotRoomFor;

/// Raum-Widgets auf dem Android-Startbildschirm (nativ, siehe
/// android/…/widget/). Die App legt dort Adresse und Token ab, richtet
/// Widgets ein und meldet Lichtänderungen, solange sie läuft; sonst holt ein
/// Hintergrund-Job alle 15 Minuten den Stand, und ein Tipp aufs Widget
/// schaltet direkt über Home Assistant.
abstract final class RoomWidgetBridge {
  static const _ch = MethodChannel('de.phiph.haven/room_widget');

  /// Nur in der Android-App (nicht im Web oder HA-Panel).
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> setCredentials(String? url, String? token) async {
    if (!supported) return;
    await _ch.invokeMethod('setCredentials', {'url': url, 'token': token});
  }

  /// Eingerichtete Widgets (je eine Einstellung mit `id`).
  static Future<List<Map<String, dynamic>>> widgets() async {
    if (!supported) return const [];
    final raw = await _ch.invokeMethod<String>('widgets');
    if (raw == null) return const [];
    return [
      for (final w in jsonDecode(raw) as List)
        Map<String, dynamic>.from(w as Map),
    ];
  }

  static Future<void> save(int id, Map<String, dynamic> config) =>
      _ch.invokeMethod('saveWidget', {'id': id, 'config': jsonEncode(config)});

  static Future<void> finishConfigure(int id) =>
      _ch.invokeMethod('finishConfigure', {'id': id});

  static Future<void> refresh([List<int>? ids]) async {
    if (!supported) return;
    await _ch.invokeMethod('refresh', {'ids': ids});
  }

  /// Sprungziel, wenn die App über den Pfeil eines Widgets geöffnet wurde.
  static Future<String?> launchRoute() async {
    if (!supported) return null;
    try {
      return await _ch.invokeMethod<String>('launchRoute');
    } catch (_) {
      return null;
    }
  }
}

/// Einstellung eines Raum-Widgets für Raum [roomId] (`Room.id`): Name,
/// Lampen, Thermometer und die Bild-Entities des Raums (hell und dunkel)
/// aus der Integration, soweit es sie gibt.
Map<String, dynamic> roomWidgetConfig(
  HavenSnapshot snap,
  RoomView view,
  String? planRoomId,
) {
  String? image(String theme) {
    if (planRoomId == null) return null;
    for (final e in snap.byDomain('image')) {
      if (e.attributes['room'] == planRoomId &&
          e.attributes['theme'] == theme) {
        return e.entityId;
      }
    }
    return null;
  }

  return {
    'room': view.room.id,
    'name': view.name,
    'lights': [for (final l in view.lamps) l.entityId],
    'temp': ?view.room.temperatureId,
    'image': {'light': ?image('light'), 'dark': ?image('dark')},
  };
}

/// JSON mit sortierten Schlüsseln (Android ordnet sie beim Speichern um).
@visibleForTesting
String canonicalJson(Object? v) {
  Object? sort(Object? x) => switch (x) {
    final Map<dynamic, dynamic> m => {
      for (final k in (m.keys.map((k) => '$k').toList()..sort())) k: sort(m[k]),
    },
    final List<dynamic> l => [for (final e in l) sort(e)],
    _ => x,
  };
  return jsonEncode(sort(v));
}

/// Hält die Widgets aktuell, solange die App läuft: Zugangsdaten nach dem
/// Anmelden ablegen, Einstellungen (Lampen, Bilder) nachziehen und bei
/// Licht- oder Temperaturwechseln neu zeichnen lassen.
final roomWidgetSyncProvider = Provider<void>((ref) {
  if (!RoomWidgetBridge.supported) return;
  final session = ref.watch(sessionProvider);
  if (session.mode != SessionMode.ha) return;
  final store = ref.read(settingsStoreProvider);
  unawaited(() async {
    final token = await ref.read(tokenStoreProvider).read();
    await RoomWidgetBridge.setCredentials(store.haUrl, token);
  }());

  List<Map<String, dynamic>> widgets = const [];
  Timer? debounce;
  String? last;

  Future<void> sync() async {
    widgets = await RoomWidgetBridge.widgets();
    if (widgets.isEmpty) return;
    final snap = ref.read(snapshotProvider);
    final plan = ref.read(floorPlanProvider).value;
    final changed = <int>[];
    final parts = <String>[];
    for (final w in widgets) {
      final id = w['id'] as int;
      final view = ref.read(roomViewProvider('${w['room']}'));
      if (view == null) continue;
      final planRoom = plan?.rooms
          .where((r) => snapshotRoomFor(snap, r)?.id == view.room.id)
          .firstOrNull;
      final cfg = roomWidgetConfig(snap, view, planRoom?.id);
      // Lampen oder Bilder des Raums haben sich geändert: Einstellung neu.
      final now = {...w}..remove('id');
      if (canonicalJson(now) != canonicalJson(cfg)) {
        await RoomWidgetBridge.save(id, cfg);
      }
      for (final e in [...cfg['lights'] as List, ?cfg['temp']]) {
        final s = snap.entity('$e');
        parts.add(
          '$e=${s?.state}:${s?.attributes['brightness']}:'
          '${s?.attributes['rgb_color']}:${s?.attributes['color_temp_kelvin']}',
        );
      }
      changed.add(id);
    }
    final sig = parts.join('|');
    if (sig == last) return;
    last = sig;
    await RoomWidgetBridge.refresh(changed);
  }

  void schedule() {
    debounce?.cancel();
    // Home Assistant setzt das Bild nach etwa einer Sekunde neu zusammen.
    debounce = Timer(const Duration(milliseconds: 1500), () => sync());
  }

  ref.listen(snapshotProvider, (_, _) => schedule(), fireImmediately: true);
  ref.listen(renderStatusProvider, (_, _) => schedule());
  ref.onDispose(() => debounce?.cancel());
});

/// Öffnet den Raum, wenn die App über den Pfeil eines Widgets kam (beim
/// Start und beim Zurückkehren).
class RoomWidgetLaunchHandler extends StatefulWidget {
  const RoomWidgetLaunchHandler({super.key, required this.child});
  final Widget child;

  @override
  State<RoomWidgetLaunchHandler> createState() =>
      _RoomWidgetLaunchHandlerState();
}

class _RoomWidgetLaunchHandlerState extends State<RoomWidgetLaunchHandler> {
  late final AppLifecycleListener _life = AppLifecycleListener(
    onResume: _check,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final route = await RoomWidgetBridge.launchRoute();
    final ctx = rootNavigatorKey.currentContext;
    if (route == null || ctx == null || !ctx.mounted) return;
    GoRouter.of(ctx).push(route);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
