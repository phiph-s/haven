import 'dart:typed_data';

/// Bilder der Wohnung für Widgets und Displays (`haven/render/*`,
/// Integration mit Feature `render`). Teil von `HavenRepository`.
///
/// Die App rendert nach Kartenänderungen Lichtebenen (siehe `LayerRenderer`
/// in haven_3d), lädt sie hoch, und Home Assistant setzt daraus Bilder im
/// aktuellen Lichtzustand zusammen (Image-Entities).
abstract interface class RenderApi {
  /// Stand in Home Assistant oder `null`, wenn die Integration keine Bilder
  /// kann (ältere Version, numpy/Pillow fehlen, Entwicklungsdaten).
  Future<RenderStatus?> renderStatus();

  /// Alle Bildsätze ersetzen. [key] ist der Render-Schlüssel des Plans.
  /// [onProgress] meldet gesendete und gesamte Bytes. [cancelled] bricht
  /// zwischen zwei Stücken ab (wirft dann [RenderUploadCancelled]).
  Future<void> uploadRenders(
    String key,
    List<RenderFile> files, {
    void Function(int sent, int total)? onProgress,
    bool Function()? cancelled,
  });
}

/// Datei eines Bildsatzes: Pfad `<satz>/<datei>` und Inhalt.
typedef RenderFile = ({String path, Uint8List bytes});

/// `haven/render/status`.
class RenderStatus {
  const RenderStatus({required this.key, required this.sets});

  factory RenderStatus.fromJson(Map<String, dynamic> j) => RenderStatus(
    key: j['key'] as String?,
    sets: (j['sets'] as Map?)?.keys.map((k) => '$k').toSet() ?? const {},
  );

  /// Render-Schlüssel der Bilder in HA, `null`: noch keine.
  final String? key;
  final Set<String> sets;
}

class RenderUploadCancelled implements Exception {
  const RenderUploadCancelled();
}
