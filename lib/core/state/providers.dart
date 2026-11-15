import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/ha/ha_repository.dart';
import '../../data/haven_repository.dart';
import '../../data/models/entity_state.dart';
import '../../data/models/snapshot.dart';
import '../../data/models/widget_config.dart';
import '../../data/room_view.dart';
import '../../data/storage/settings_store.dart';

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

/// Konfigurierbare Widgets der Zuhause-Seite, lokal gespeichert.
class WidgetsController extends Notifier<List<HavenWidgetConfig>> {
  @override
  List<HavenWidgetConfig> build() => ref.watch(settingsStoreProvider).widgets;

  void _save(List<HavenWidgetConfig> l) {
    state = l;
    unawaited(ref.read(settingsStoreProvider).setWidgets(l));
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
