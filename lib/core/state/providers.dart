import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/ha/ha_repository.dart';
import '../../data/haven_repository.dart';
import '../../data/models/entity_state.dart';
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

/// Übersicht: Widgets und Reihenfolge der Räume. Ein geteiltes Dokument
/// (`haven/widgets/set` mit `layout.room_order`, siehe `sync/app_data.dart`),
/// lokal im `SettingsStore` als Cache.
@immutable
class HomeLayout {
  const HomeLayout({required this.widgets, this.roomOrder = const []});
  final List<HavenWidgetConfig> widgets;

  /// Raum-IDs in der gewünschten Reihenfolge. Leer: wie aus HA.
  final List<String> roomOrder;

  Map<String, dynamic> toDoc() => {
    'widgets': [for (final w in widgets) w.toJson()],
    'layout': {'room_order': roomOrder},
  };
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
        readLocal: () => store.hasWidgets || store.roomOrder.isNotEmpty
            ? state.toDoc()
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
          await store.setWidgets(widgets);
          await store.setRoomOrder(order);
          state = HomeLayout(widgets: widgets, roomOrder: order);
          return true;
        },
        onError: (m) => ref.read(syncNoticeProvider.notifier).show(m),
      );
      _sync = sync;
      ref.onDispose(sync.dispose);
      sync.start();
    }
    return HomeLayout(widgets: store.widgets, roomOrder: store.roomOrder);
  }

  Future<void> _changed(HomeLayout next) async {
    state = next;
    final store = ref.read(settingsStoreProvider);
    await store.setWidgets(next.widgets);
    await store.setRoomOrder(next.roomOrder);
    await _sync?.changed();
  }

  void setWidgets(List<HavenWidgetConfig> l) =>
      unawaited(_changed(HomeLayout(widgets: l, roomOrder: state.roomOrder)));

  void setRoomOrder(List<String> ids) =>
      unawaited(_changed(HomeLayout(widgets: state.widgets, roomOrder: ids)));
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

/// Konfigurierbare Widgets der Zuhause-Seite (Teil von [homeLayoutProvider]).
class WidgetsController extends Notifier<List<HavenWidgetConfig>> {
  @override
  List<HavenWidgetConfig> build() =>
      ref.watch(homeLayoutProvider.select((l) => l.widgets));

  void _save(List<HavenWidgetConfig> l) {
    state = l;
    ref.read(homeLayoutProvider.notifier).setWidgets(l);
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
