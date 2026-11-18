import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_scene/scene.dart' as fs;

import 'support_env_stub.dart'
    if (dart.library.io) 'support_env_io.dart'
    as env;

/// Kann dieses Gerät die 3D-Ansicht zeigen? flutter_scene braucht Flutter GPU
/// (nativ mit Impeller und eingeschaltetem Flutter GPU) oder WebGL2 (Web).
///
/// Ohne GPU meldet flutter_scene den Fehler asynchron; die Prüfung fängt ihn
/// ab, damit die App auf ihre 2D-Karte ausweichen kann.
abstract final class Scene3DSupport {
  static Future<bool>? _result;

  /// Erzwingt das Ergebnis (Tests). `null` prüft wirklich.
  static bool? debugOverride;

  static Future<bool> available() {
    final o = debugOverride;
    if (o != null) return Future.value(o);
    // In `flutter test` ohne `--enable-flutter-gpu` gibt es keine GPU; ein
    // Versuch hinterließe nur Fehler und Zeitgeber.
    if (env.isFlutterTest) return Future.value(false);
    return _result ??= _probe();
  }

  static Future<bool> _probe() {
    final done = Completer<bool>();
    runZonedGuarded(
      () async {
        await fs.Scene.initializeStaticResources();
        if (!done.isCompleted) done.complete(fs.Scene.isReadyToRender);
      },
      (e, s) {
        debugPrint('haven_3d: keine 3D-Ansicht ($e)');
        if (!done.isCompleted) done.complete(false);
      },
    );
    return done.future;
  }
}
