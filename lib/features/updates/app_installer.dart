import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Brücke zur Android-Installation (`MainActivity.kt`, Kanal
/// `de.phiph.haven/installer`). Auf anderen Plattformen gibt es nur den Link.
abstract class AppInstaller {
  /// Kann die App APKs laden und installieren (Android, nicht Web).
  bool get supported;

  /// Cache-Ordner der App, dort liegt das APK.
  Future<String> cacheDir();

  /// Erlaubnis „Unbekannte Apps installieren“ für Haven.
  Future<bool> canInstall();

  /// Öffnet die Systemeinstellung dieser Erlaubnis für Haven.
  Future<void> openInstallSettings();

  /// Startet die Android-Installation der Datei.
  Future<void> install(String path);
}

class AndroidAppInstaller implements AppInstaller {
  AndroidAppInstaller();
  static const _channel = MethodChannel('de.phiph.haven/installer');

  @override
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<String> cacheDir() async =>
      (await _channel.invokeMethod<String>('cacheDir'))!;

  @override
  Future<bool> canInstall() async =>
      (await _channel.invokeMethod<bool>('canInstall')) ?? false;

  @override
  Future<void> openInstallSettings() =>
      _channel.invokeMethod<void>('openInstallSettings');

  @override
  Future<void> install(String path) =>
      _channel.invokeMethod<void>('install', {'path': path});
}

/// Für Web, Tests und alle Plattformen ohne Installation.
class UnsupportedAppInstaller implements AppInstaller {
  const UnsupportedAppInstaller();
  @override
  bool get supported => false;
  @override
  Future<String> cacheDir() async => throw UnsupportedError('Kein Android');
  @override
  Future<bool> canInstall() async => false;
  @override
  Future<void> openInstallSettings() async {}
  @override
  Future<void> install(String path) async {}
}

/// Lädt die Datei mit Fortschritt (0..1, `null` bei unbekannter Größe).
/// Schreibt zuerst in `<ziel>.part` und benennt am Ende um, damit nie eine
/// halbe Datei als fertig gilt. Prüft die Größe, wenn sie bekannt ist.
Future<File> downloadFile(
  http.Client client,
  Uri url,
  File target, {
  int? expectedSize,
  void Function(double? progress)? onProgress,
}) async {
  final part = File('${target.path}.part');
  if (await part.exists()) await part.delete();
  final req = http.Request('GET', url);
  final res = await client.send(req).timeout(const Duration(seconds: 30));
  if (res.statusCode != 200) {
    throw http.ClientException('Download fehlgeschlagen (${res.statusCode})');
  }
  final total = res.contentLength ?? expectedSize;
  var got = 0;
  final sink = part.openWrite();
  try {
    await for (final chunk in res.stream) {
      sink.add(chunk);
      got += chunk.length;
      onProgress?.call(total == null || total <= 0 ? null : got / total);
    }
    await sink.flush();
  } catch (_) {
    await sink.close();
    if (await part.exists()) await part.delete();
    rethrow;
  }
  await sink.close();
  if (expectedSize != null && got != expectedSize) {
    await part.delete();
    throw http.ClientException(
      'Die Datei ist unvollständig. Versuch es nochmal.',
    );
  }
  if (await target.exists()) await target.delete();
  return part.rename(target.path);
}
