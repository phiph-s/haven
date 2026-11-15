import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/providers.dart';
import '../../data/haven_repository.dart';
import '../../data/models/ha_update.dart';
import '../../data/models/snapshot.dart';
import 'app_release.dart';
import 'app_update_provider.dart';

/// Alle anstehenden Updates aus Home Assistant.
final haUpdatesProvider = Provider<HaUpdates>((ref) {
  final entities = ref.watch(snapshotProvider.select((s) => s.entities));
  return HaUpdates.fromEntities(entities.values);
});

/// Gibt es eine `update.*`-Entity für Haven (auch ohne anstehendes Update)?
final havenUpdateEntityProvider = Provider<bool>((ref) {
  final entities = ref.watch(snapshotProvider.select((s) => s.entities));
  for (final e in entities.values) {
    if (e.entityId.startsWith('update.') &&
        HaUpdate.fromEntity(e).group == UpdateGroup.haven) {
      return true;
    }
  }
  return false;
});

/// Versionshinweise per `update/release_notes`. `null`, wenn die Entity sie
/// nicht anbietet oder HA keine liefert.
final releaseNotesProvider = FutureProvider.family<String?, String>((
  ref,
  entityId,
) async {
  final e = ref.read(snapshotProvider).entities[entityId];
  if (e == null || !HaUpdate.fromEntity(e).hasReleaseNotes) return null;
  final res = await ref.read(repositoryProvider).command(
    'update/release_notes',
    {'entity_id': entityId},
  );
  if (res is String && res.trim().isNotEmpty) return res.trim();
  return null;
});

/// Stand der Haven-Integration in HA, aus `haven/info` und dem neuesten
/// Release von `phiph-s/haven-ha`.
@immutable
class IntegrationInfo {
  const IntegrationInfo({this.installed, this.latest, this.releaseUrl});
  final String? installed;
  final String? latest;
  final String? releaseUrl;

  bool get newerAvailable =>
      installed != null &&
      latest != null &&
      isNewerVersion(latest!, installed!);
}

final integrationInfoProvider = FutureProvider<IntegrationInfo>((ref) async {
  // Neu laden, wenn die Verbindung wieder steht.
  ref.watch(snapshotProvider.select((s) => s.status));
  final repo = ref.read(repositoryProvider);
  String? installed;
  try {
    final info = await repo.command('haven/info');
    final v = info is Map ? info['version'] : null;
    installed = v is String && v.isNotEmpty ? v : null;
  } catch (_) {}
  if (installed == null) return const IntegrationInfo();
  String? latest;
  String? url;
  try {
    final r = await ref
        .read(releaseCheckerProvider)
        .latest(kIntegrationRepo, assetPrefix: 'haven-ha');
    latest = r?.version;
    url = r?.pageUrl;
  } catch (_) {}
  return IntegrationInfo(installed: installed, latest: latest, releaseUrl: url);
});

@immutable
class UpdatesUi {
  const UpdatesUi({
    this.installing = const {},
    this.restartExpectedAt,
    this.error,
  });

  /// Updates, für die diese App gerade `update.install` gerufen hat.
  final Set<String> installing;

  /// Seit wann ein Neustart von Home Assistant erwartet wird.
  final DateTime? restartExpectedAt;
  final String? error;

  UpdatesUi copyWith({
    Set<String>? installing,
    DateTime? restartExpectedAt,
    bool clearRestart = false,
    String? error,
    bool clearError = false,
  }) => UpdatesUi(
    installing: installing ?? this.installing,
    restartExpectedAt: clearRestart
        ? null
        : (restartExpectedAt ?? this.restartExpectedAt),
    error: clearError ? null : (error ?? this.error),
  );
}

/// Fehlercodes, die bei langen oder neu startenden Updates normal sind.
const _expectedCodes = {'timeout', 'disconnected'};

class UpdatesController extends Notifier<UpdatesUi> {
  bool _sawDisconnect = false;

  @override
  UpdatesUi build() {
    ref.listen<ConnectionStatus>(snapshotProvider.select((s) => s.status), (
      _,
      next,
    ) {
      if (next != ConnectionStatus.connected) {
        _sawDisconnect = true;
      } else if (_sawDisconnect) {
        _sawDisconnect = false;
        state = state.copyWith(clearRestart: true);
      }
    });
    return const UpdatesUi();
  }

  /// Home Assistant startet gerade neu (Core, OS oder Supervisor), die
  /// Verbindung ist weg.
  bool restarting(HavenSnapshot s) {
    final t = state.restartExpectedAt;
    if (t == null || s.status == ConnectionStatus.connected) return false;
    return DateTime.now().difference(t) < const Duration(minutes: 20);
  }

  void clearError() => state = state.copyWith(clearError: true);

  Future<void> install(HaUpdate u, {bool backup = false}) async {
    if (state.installing.contains(u.entityId)) return;
    state = state.copyWith(
      installing: {...state.installing, u.entityId},
      clearError: true,
      restartExpectedAt: u.restartsHa ? DateTime.now() : null,
    );
    final repo = ref.read(repositoryProvider);
    try {
      await repo.callService(
        'update',
        'install',
        entityId: u.entityId,
        data: {if (backup && u.canBackup) 'backup': true},
      );
      if (u.restartsHa && repo.snapshot.status == ConnectionStatus.connected) {
        // Kein Neustart bemerkt, das Update lief ohne.
        state = state.copyWith(clearRestart: true);
      }
    } catch (e) {
      final code = e is HavenException ? e.code : null;
      if (!_expectedCodes.contains(code)) {
        state = state.copyWith(
          error:
              '${u.displayName}: ${e is HavenException ? e.message : 'Update fehlgeschlagen.'}',
          clearRestart: true,
        );
      }
    } finally {
      state = state.copyWith(
        installing: {...state.installing}..remove(u.entityId),
      );
    }
  }

  Future<void> skip(HaUpdate u) async {
    try {
      await ref
          .read(repositoryProvider)
          .callService('update', 'skip', entityId: u.entityId);
    } catch (e) {
      state = state.copyWith(
        error: '${u.displayName} ließ sich nicht überspringen.',
      );
    }
  }

  /// Installiert [list] nacheinander. Core, OS und Supervisor gehören nie
  /// dazu, dafür ist [HaUpdates.bulkTargets] zuständig.
  Future<void> installAll(List<HaUpdate> list) async {
    for (final u in list) {
      if (u.restartsHa) continue;
      await install(u);
    }
  }
}

final updatesControllerProvider =
    NotifierProvider<UpdatesController, UpdatesUi>(UpdatesController.new);
