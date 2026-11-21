import 'dart:convert';
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/ha/ha_repository.dart';
import '../../data/haven_repository.dart';
import '../../data/models/entity_state.dart';
import '../../data/models/lamp.dart';
import '../../data/models/snapshot.dart';
import '../../data/models/room.dart';
import '../../data/models/widget_config.dart';
import '../../data/room_view.dart';
import '../../data/storage/settings_store.dart';
import '../../data/sync/app_data.dart';
import '../../data/sync/doc_sync.dart';

/// Wird in `main` mit dem echten Store überschrieben.
final settingsStoreProvider = Provider<SettingsStore>(
  (ref) =>
      throw UnimplementedError('settingsStoreProvider nicht überschrieben'),
);

final tokenStoreProvider = Provider<TokenStore>((ref) => SecureTokenStore());

/// `fake` gibt es nur mit `--dart-define=HAVEN_FAKE=true` (siehe `lib/dev/`).
enum SessionMode { none, ha, fake }

/// Die laufende Sitzung: Modus und Repository.
class Session {
  const Session(this.mode, [this.repo]);
  final SessionMode mode;
  final HavenRepository? repo;
}

/// Startzustand, wird in `main` aus den Einstellungen gebaut.
final initialSessionProvider = Provider<Session>(
  (ref) => const Session(SessionMode.none),
);

class SessionController extends Notifier<Session> {
  HavenRepository? _repo;

  @override
  Session build() {
    final initial = ref.watch(initialSessionProvider);
    _repo = initial.repo;
    // Im Dispose darf `state` nicht gelesen werden, deshalb das Feld.
    ref.onDispose(() => unawaited(_repo?.dispose()));
    return initial;
  }

  Future<void> _swap(Session next) async {
    final old = _repo;
    _repo = next.repo;
    state = next;
    await old?.dispose();
  }

  /// Verbindet mit HA. Wirft [HavenException], wenn Verbindung oder Token
  /// nicht passen. Erst bei Erfolg werden URL und Token gespeichert.
  Future<void> connectHa(String url, String token) async {
    final repo = HaRepository(
      url: url,
      token: token,
      failFast: true,
      localPrefs: ref.read(settingsStoreProvider),
    );
    try {
      await repo.start();
    } catch (e) {
      await repo.dispose();
      rethrow;
    }
    final store = ref.read(settingsStoreProvider);
    await ref.read(tokenStoreProvider).write(token);
    await store.setHaUrl(url);
    await store.setConnectionMode('ha');
    await _swap(Session(SessionMode.ha, repo));
  }

  /// Zurück zum Onboarding. Der Token wird gelöscht.
  Future<void> disconnect() async {
    final store = ref.read(settingsStoreProvider);
    await store.setConnectionMode(null);
    await ref.read(tokenStoreProvider).delete();
    await _swap(const Session(SessionMode.none));
  }
}

final sessionProvider = NotifierProvider<SessionController, Session>(
  SessionController.new,
);

/// Das aktive Repository. Nur nutzen, wenn eine Sitzung läuft.
final repositoryProvider = Provider<HavenRepository>((ref) {
  final repo = ref.watch(sessionProvider).repo;
  if (repo == null) throw StateError('Keine Sitzung aktiv');
  return repo;
});

/// Hält den aktuellen Snapshot und aktualisiert bei jedem Ereignis.
class SnapshotNotifier extends Notifier<HavenSnapshot> {
  @override
  HavenSnapshot build() {
    final repo = ref.watch(sessionProvider).repo;
    if (repo == null) {
      return const HavenSnapshot(status: ConnectionStatus.offline);
    }
    final sub = repo.snapshots.listen((s) => state = s);
    ref.onDispose(sub.cancel);
    return repo.snapshot;
  }
}

final snapshotProvider = NotifierProvider<SnapshotNotifier, HavenSnapshot>(
  SnapshotNotifier.new,
);

final roomsProvider = Provider(
  (ref) => ref.watch(snapshotProvider.select((s) => s.rooms)),
);

final roomViewProvider = Provider.family<RoomView?, String>((ref, id) {
  final s = ref.watch(snapshotProvider);
  final r = s.room(id);
  return r == null ? null : RoomView.from(s, r);
});

final houseViewProvider = Provider<HouseView>((ref) {
  final s = ref.watch(snapshotProvider);
  return HouseView([for (final r in s.rooms) ...s.lampsOf(r)]);
});

/// Eine einzelne Entity, z. B. für Widgets.
final entityProvider = Provider.family<EntityState?, String>(
  (ref, id) => ref.watch(snapshotProvider.select((s) => s.entities[id])),
);

/// Lampe mit der Kalibrierung ihres Typs (baut nur bei Änderungen neu).
final lampProvider = Provider.family<Lamp?, String>(
  (ref, id) => ref.watch(snapshotProvider.select((s) => s.lamp(id))),
);

// ---- Einstellungen ----------------------------------------------------

class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ref.watch(settingsStoreProvider).themeMode;

  Future<void> set(ThemeMode m) async {
    state = m;
    await ref.read(settingsStoreProvider).setThemeMode(m);
  }
}

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(
  ThemeModeController.new,
);

/// Hinweis zum Speichern geteilter Daten (z. B. ohne Admin-Rechte). Die
/// Hülle zeigt ihn als Meldung, gleiche Texte höchstens einmal pro Minute.
class SyncNoticeController extends Notifier<SyncNotice?> {
  final Map<String, DateTime> _shown = {};

  @override
  SyncNotice? build() => null;

  void show(String text) {
    final now = DateTime.now();
    final last = _shown[text];
    if (last != null && now.difference(last) < const Duration(minutes: 1)) {
      return;
    }
    _shown[text] = now;
    state = SyncNotice(text, now);
  }
}

@immutable
class SyncNotice {
  const SyncNotice(this.text, this.at);
  final String text;
  final DateTime at;
}

final syncNoticeProvider = NotifierProvider<SyncNoticeController, SyncNotice?>(
  SyncNoticeController.new,
);

/// Laufende Abgleiche der geteilten Dokumente (Anzeige in den Einstellungen).
final syncRegistryProvider = Provider<SyncRegistry>((ref) {
  final r = SyncRegistry();
  ref.onDispose(r.dispose);
  return r;
});

/// Übersicht: Widgets und Reihenfolge der Räume. Ein geteiltes Dokument
/// (`haven/widgets/set` mit `layout.room_order`, siehe `sync/app_data.dart`),
/// lokal im `SettingsStore` als Cache.
@immutable
class HomeLayout {
  const HomeLayout({
    required this.widgets,
    this.roomOrder = const [],
    this.hiddenRooms = const [],
  });
  final List<HavenWidgetConfig> widgets;

  /// Raum-IDs in der gewünschten Reihenfolge. Leer: wie aus HA.
  final List<String> roomOrder;

  /// Räume, die nicht auf die Startseite sollen (bei „Nein“ auf die Frage
  /// nach einem neuen Raum).
  final List<String> hiddenRooms;

  Map<String, dynamic> toDoc() => {
    'widgets': [for (final w in widgets) w.toJson()],
    'layout': {'room_order': roomOrder, 'hidden_rooms': hiddenRooms},
  };
}

/// Ist [widgets] noch im alten Format (nur kleine Karten, Räume fest)?
bool isLegacyHome(List<HavenWidgetConfig> widgets) =>
    !widgets.any((w) => w.isMain);

/// Startseite als Widgets: Ein altes Layout wird zu Kopf, Hinweisen,
/// Szenen, allen Räumen ([rooms], in bisheriger Reihenfolge) und danach den
/// bisherigen Karten. Räume, die es nicht mehr gibt, fallen weg.
List<HavenWidgetConfig> effectiveHome(
  List<HavenWidgetConfig> widgets,
  List<Room> rooms,
) {
  final ids = {for (final r in rooms) r.id};
  if (isLegacyHome(widgets)) {
    return [
      const HavenWidgetConfig(id: 'header', type: HavenWidgetType.header),
      const HavenWidgetConfig(id: 'notices', type: HavenWidgetType.notices),
      const HavenWidgetConfig(id: 'scenes', type: HavenWidgetType.scenes),
      for (final r in rooms) HavenWidgetConfig.forRoom(r.id),
      ...widgets,
    ];
  }
  return [
    for (final w in widgets)
      // Räume erst prüfen, wenn es welche gibt (sonst verschwänden sie beim
      // Verbindungsaufbau kurz).
      if (w.roomId == null || ids.isEmpty || ids.contains(w.roomId)) w,
  ];
}

class HomeLayoutController extends Notifier<HomeLayout> {
  DocSync? _sync;

  @override
  HomeLayout build() {
    final store = ref.watch(settingsStoreProvider);
    final repo = ref.watch(sessionProvider.select((s) => s.repo));
    if (repo != null) {
      final sync = DocSync(
        kind: AppDataKind.widgets,
        repo: repo,
        store: store,
        debounce: repo.isFake
            ? Duration.zero
            : const Duration(milliseconds: 800),
        // Nur Eigenes zählt als lokaler Stand, nicht die Voreinstellung.
        // Aus dem Speicher, nicht aus `state`: beim Start ist der Provider
        // noch nicht fertig gebaut.
        readLocal: () => store.hasWidgets || store.roomOrder.isNotEmpty
            ? HomeLayout(
                widgets: store.widgets,
                roomOrder: store.roomOrder,
                hiddenRooms: store.hiddenRooms,
              ).toDoc()
            : null,
        applyRemote: (data) async {
          final List<HavenWidgetConfig> widgets;
          try {
            widgets = [
              for (final j in data['widgets'] as List)
                HavenWidgetConfig.fromJson(Map<String, dynamic>.from(j as Map)),
            ];
          } catch (_) {
            return false;
          }
          final layout = data['layout'];
          // Ältere Integration speichert kein Layout: lokale Reihenfolge bleibt.
          final order = layout is Map && layout['room_order'] is List
              ? [for (final id in layout['room_order'] as List) '$id']
              : state.roomOrder;
          final hidden = layout is Map && layout['hidden_rooms'] is List
              ? [for (final id in layout['hidden_rooms'] as List) '$id']
              : state.hiddenRooms;
          await store.setWidgets(widgets);
          await store.setRoomOrder(order);
          await store.setHiddenRooms(hidden);
          state = HomeLayout(
            widgets: widgets,
            roomOrder: order,
            hiddenRooms: hidden,
          );
          return true;
        },
        onError: (m) => ref.read(syncNoticeProvider.notifier).show(m),
        describe: (d) {
          final n = (d['widgets'] as List).length;
          return n == 1 ? '1 Widget' : '$n Widgets';
        },
      );
      _sync = sync;
      final registry = ref.read(syncRegistryProvider);
      registry.register(sync);
      ref.onDispose(() {
        registry.unregister(sync);
        sync.dispose();
      });
      sync.start();
    }
    return HomeLayout(
      widgets: store.widgets,
      roomOrder: store.roomOrder,
      hiddenRooms: store.hiddenRooms,
    );
  }

  Future<void> _changed(HomeLayout next) async {
    // Nur echte Änderungen zählen (sonst käme ein Hochladen ohne Anlass).
    if (jsonEncode(next.toDoc()) == jsonEncode(state.toDoc())) return;
    state = next;
    final store = ref.read(settingsStoreProvider);
    await store.setWidgets(next.widgets);
    await store.setRoomOrder(next.roomOrder);
    await store.setHiddenRooms(next.hiddenRooms);
    await _sync?.changed();
  }

  /// Widgets setzen; die Reihenfolge der Räume folgt ihren Widgets.
  void setWidgets(List<HavenWidgetConfig> l, {List<String>? hiddenRooms}) {
    final order = [for (final w in l) ?w.roomId];
    unawaited(
      _changed(
        HomeLayout(
          widgets: l,
          roomOrder: order.isEmpty ? state.roomOrder : order,
          hiddenRooms: hiddenRooms ?? state.hiddenRooms,
        ),
      ),
    );
  }

  void setRoomOrder(List<String> ids) => unawaited(
    _changed(
      HomeLayout(
        widgets: state.widgets,
        roomOrder: ids,
        hiddenRooms: state.hiddenRooms,
      ),
    ),
  );
}

final homeLayoutProvider = NotifierProvider<HomeLayoutController, HomeLayout>(
  HomeLayoutController.new,
);

/// Räume der Übersicht in der gespeicherten Reihenfolge. Neue Räume kommen
/// ans Ende, gelöschte fallen weg.
List<Room> sortRooms(List<Room> rooms, List<String> order) {
  if (order.isEmpty) return rooms;
  final idx = {for (var i = 0; i < order.length; i++) order[i]: i};
  final known = [
    for (final r in rooms)
      if (idx.containsKey(r.id)) r,
  ]..sort((a, b) => idx[a.id]!.compareTo(idx[b.id]!));
  return [
    ...known,
    for (final r in rooms)
      if (!idx.containsKey(r.id)) r,
  ];
}

final orderedRoomsProvider = Provider<List<Room>>((ref) {
  final rooms = ref.watch(roomsProvider);
  final order = ref.watch(homeLayoutProvider.select((l) => l.roomOrder));
  return sortRooms(rooms, order);
});

/// Die Startseite als Widgets (Teil von [homeLayoutProvider]): Kopf,
/// Hinweise, Szenen, Räume und kleine Karten, in dieser gespeicherten
/// Reihenfolge (siehe [effectiveHome]).
class WidgetsController extends Notifier<List<HavenWidgetConfig>> {
  @override
  List<HavenWidgetConfig> build() => effectiveHome(
    ref.watch(homeLayoutProvider.select((l) => l.widgets)),
    ref.watch(orderedRoomsProvider),
  );

  void _save(List<HavenWidgetConfig> l, {List<String>? hiddenRooms}) {
    state = l;
    ref
        .read(homeLayoutProvider.notifier)
        .setWidgets(l, hiddenRooms: hiddenRooms);
  }

  /// Einstellungen eines Widgets ändern.
  void update(HavenWidgetConfig c) =>
      _save([for (final w in state) w.id == c.id ? c : w]);

  /// Neuen Raum auf die Startseite (nach dem letzten Raum).
  void addRoom(String roomId) {
    final l = [...state];
    final last = l.lastIndexWhere((w) => w.type == HavenWidgetType.room);
    l.insert(last < 0 ? l.length : last + 1, HavenWidgetConfig.forRoom(roomId));
    final hidden = ref.read(homeLayoutProvider).hiddenRooms;
    _save(
      l,
      hiddenRooms: [
        for (final h in hidden)
          if (h != roomId) h,
      ],
    );
  }

  /// Neuen Raum nicht auf die Startseite (nicht wieder fragen).
  void hideRoom(String roomId) {
    final hidden = ref.read(homeLayoutProvider).hiddenRooms;
    _save(state, hiddenRooms: {...hidden, roomId}.toList());
  }

  void reorder(int from, int to) {
    final l = [...state];
    final w = l.removeAt(from);
    l.insert(to, w);
    _save(l);
  }

  void remove(String id) => _save([
    for (final w in state)
      if (w.id != id) w,
  ]);

  void add(HavenWidgetConfig w) => _save([...state, w]);

  void reset() => _save(HavenWidgetConfig.defaults);
}

final widgetsProvider =
    NotifierProvider<WidgetsController, List<HavenWidgetConfig>>(
      WidgetsController.new,
    );

/// Räume, die es neu gibt: weder auf der Startseite noch abgelehnt. Die
/// Startseite fragt, ob sie dazukommen sollen.
final newRoomsProvider = Provider<List<Room>>((ref) {
  final widgets = ref.watch(widgetsProvider);
  final hidden = ref.watch(homeLayoutProvider.select((l) => l.hiddenRooms));
  final shown = {for (final w in widgets) ?w.roomId};
  return [
    for (final r in ref.watch(orderedRoomsProvider))
      if (!shown.contains(r.id) && !hidden.contains(r.id)) r,
  ];
});
