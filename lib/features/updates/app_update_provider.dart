import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../core/state/providers.dart';
import 'app_installer.dart';
import 'app_release.dart';

/// Version, falls `package_info_plus` nichts liefert (Tests). `main`
/// überschreibt den Provider mit der echten Version aus `pubspec.yaml`.
const String kFallbackAppVersion = '0.3.0';

final appVersionProvider = Provider<String>((ref) => kFallbackAppVersion);

final httpClientProvider = Provider<http.Client>((ref) {
  final c = http.Client();
  ref.onDispose(c.close);
  return c;
});

final appInstallerProvider = Provider<AppInstaller>(
  (ref) => AndroidAppInstaller(),
);

/// Öffnet einen Link im Browser. In Tests überschreibbar.
final urlOpenerProvider = Provider<Future<bool> Function(Uri)>(
  (ref) =>
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

final releaseCheckerProvider = Provider<ReleaseChecker>(
  (ref) => ReleaseChecker(ref.watch(httpClientProvider)),
);

enum AppUpdatePhase { idle, checking, downloading, installing }

@immutable
class AppUpdateState {
  const AppUpdateState({
    required this.current,
    this.release,
    this.phase = AppUpdatePhase.idle,
    this.progress,
    this.error,
    this.lastChecked,
    this.dismissed,
    this.needsPermission = false,
  });

  final String current;

  /// Neuestes Release, solange es neuer als [current] ist.
  final ReleaseInfo? release;
  final AppUpdatePhase phase;

  /// 0..1 beim Download, `null` bei unbekannter Größe.
  final double? progress;
  final String? error;
  final DateTime? lastChecked;
  final String? dismissed;

  /// Android verlangt „Unbekannte Apps installieren“ für Haven.
  final bool needsPermission;

  bool get available => release != null;

  /// Hinweiskarte auf der Übersicht: neu und nicht weggewischt.
  bool get showCard => available && dismissed != release!.version;

  bool get busy =>
      phase == AppUpdatePhase.downloading || phase == AppUpdatePhase.installing;

  AppUpdateState copyWith({
    ReleaseInfo? release,
    bool clearRelease = false,
    AppUpdatePhase? phase,
    double? progress,
    bool clearProgress = false,
    String? error,
    bool clearError = false,
    DateTime? lastChecked,
    String? dismissed,
    bool? needsPermission,
  }) => AppUpdateState(
    current: current,
    release: clearRelease ? null : (release ?? this.release),
    phase: phase ?? this.phase,
    progress: clearProgress ? null : (progress ?? this.progress),
    error: clearError ? null : (error ?? this.error),
    lastChecked: lastChecked ?? this.lastChecked,
    dismissed: dismissed ?? this.dismissed,
    needsPermission: needsPermission ?? this.needsPermission,
  );
}

class AppUpdateController extends Notifier<AppUpdateState> {
  @override
  AppUpdateState build() {
    final store = ref.watch(settingsStoreProvider);
    final current = ref.watch(appVersionProvider);
    ReleaseInfo? stored;
    final raw = store.updateRelease;
    if (raw != null) {
      try {
        stored = ReleaseInfo.fromStored(jsonDecode(raw));
      } catch (_) {}
    }
    if (stored != null && !isNewerVersion(stored.version, current)) {
      stored = null;
    }
    return AppUpdateState(
      current: current,
      release: stored,
      lastChecked: store.updateLastCheck,
      dismissed: store.updateDismissed,
    );
  }

  /// Beim Start: nur prüfen, wenn die letzte Prüfung lange genug her ist.
  Future<void> checkIfDue() async {
    if (state.busy || state.phase == AppUpdatePhase.checking) return;
    if (!isCheckDue(state.lastChecked, DateTime.now())) return;
    await check(manual: false);
  }

  /// Fragt GitHub. Bei [manual] landen Fehler im Zustand, sonst bleibt es still.
  Future<void> check({bool manual = true}) async {
    if (state.phase == AppUpdatePhase.checking || state.busy) return;
    state = state.copyWith(phase: AppUpdatePhase.checking, clearError: true);
    try {
      final latest = await ref.read(releaseCheckerProvider).latest(kAppRepo);
      if (!ref.mounted) return;
      final now = DateTime.now();
      final store = ref.read(settingsStoreProvider);
      final newer =
          latest != null && isNewerVersion(latest.version, state.current);
      unawaited(store.setUpdateLastCheck(now));
      unawaited(
        store.setUpdateRelease(newer ? jsonEncode(latest.toJson()) : null),
      );
      state = state.copyWith(
        phase: AppUpdatePhase.idle,
        lastChecked: now,
        release: newer ? latest : null,
        clearRelease: !newer,
      );
    } catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(
        phase: AppUpdatePhase.idle,
        error: manual ? 'Suche fehlgeschlagen. Prüf die Verbindung.' : null,
      );
    }
  }

  /// Blendet die Karte auf der Übersicht bis zur nächsten Version aus.
  void dismiss() {
    final r = state.release;
    if (r == null) return;
    state = state.copyWith(dismissed: r.version);
    unawaited(ref.read(settingsStoreProvider).setUpdateDismissed(r.version));
  }

  Future<void> openReleasePage() async {
    final r = state.release;
    if (r == null) return;
    await ref.read(urlOpenerProvider)(Uri.parse(r.pageUrl));
  }

  Future<void> openInstallSettings() async {
    await ref.read(appInstallerProvider).openInstallSettings();
  }

  /// Lädt das APK in den Cache und startet die Android-Installation. Ohne
  /// Android oder ohne APK im Release öffnet es die Release-Seite.
  Future<void> downloadAndInstall() async {
    final r = state.release;
    if (r == null || state.busy) return;
    final installer = ref.read(appInstallerProvider);
    if (!installer.supported || !r.hasApk) {
      await openReleasePage();
      return;
    }
    state = state.copyWith(clearError: true, needsPermission: false);
    try {
      if (!await installer.canInstall()) {
        state = state.copyWith(needsPermission: true);
        return;
      }
      state = state.copyWith(phase: AppUpdatePhase.downloading, progress: 0);
      final dir = await installer.cacheDir();
      final target = File('$dir/haven-${r.version}.apk');
      await _cleanOldApks(dir, keep: target.path);
      final reusable =
          r.apkSize != null &&
          await target.exists() &&
          await target.length() == r.apkSize;
      if (!reusable) {
        await downloadFile(
          ref.read(httpClientProvider),
          Uri.parse(r.apkUrl!),
          target,
          expectedSize: r.apkSize,
          onProgress: (p) {
            if (state.phase == AppUpdatePhase.downloading) {
              state = state.copyWith(progress: p, clearProgress: p == null);
            }
          },
        );
      }
      state = state.copyWith(phase: AppUpdatePhase.installing, progress: 1);
      await installer.install(target.path);
      state = state.copyWith(phase: AppUpdatePhase.idle, clearProgress: true);
    } catch (e) {
      state = state.copyWith(
        phase: AppUpdatePhase.idle,
        clearProgress: true,
        error: e is http.ClientException
            ? e.message
            : 'Das Update ließ sich nicht installieren.',
      );
    }
  }

  static Future<void> _cleanOldApks(String dir, {required String keep}) async {
    try {
      await for (final f in Directory(dir).list()) {
        final name = f.uri.pathSegments.last;
        if (f is File &&
            f.path != keep &&
            name.startsWith('haven-') &&
            (name.endsWith('.apk') || name.endsWith('.part'))) {
          await f.delete();
        }
      }
    } catch (_) {}
  }
}

final appUpdateProvider = NotifierProvider<AppUpdateController, AppUpdateState>(
  AppUpdateController.new,
);
