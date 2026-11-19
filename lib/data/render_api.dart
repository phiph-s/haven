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

  /// Datei [name] (`meta.json`, `base.png` …) aus Satz [set] zurücklesen
  /// (Feature `render_files`), etwa für die Bilder in den Raumkacheln. Wirft
  /// `HavenException`, wenn es sie nicht gibt.
  Future<Uint8List> renderFile(String set, String name);

  /// Neue Bilder in Home Assistant (nach einem Upload, auch von anderen
  /// Geräten).
  Stream<void> get renderChanges;
}

/// Datei eines Bildsatzes: Pfad `<satz>/<datei>` und Inhalt.
typedef RenderFile = ({String path, Uint8List bytes});

/// `haven/render/status`.
class RenderStatus {
  const RenderStatus({
    required this.key,
    required this.sets,
    this.info = const {},
    this.files = false,
  });

  factory RenderStatus.fromJson(Map<String, dynamic> j, {bool files = false}) {
    final raw = (j['sets'] as Map?) ?? const {};
    return RenderStatus(
      key: j['key'] as String?,
      sets: raw.keys.map((k) => '$k').toSet(),
      info: {
        for (final e in raw.entries)
          if (e.value is Map)
            '${e.key}': RenderSetInfo.fromJson(
              Map<String, dynamic>.from(e.value as Map),
            ),
      },
      files: files,
    );
  }

  /// Render-Schlüssel der Bilder in HA, `null`: noch keine.
  final String? key;
  final Set<String> sets;

  /// Angaben je Satz (Raum, Design), soweit HA sie liefert.
  final Map<String, RenderSetInfo> info;

  /// Die Dateien lassen sich zurücklesen ([RenderApi.renderFile]).
  final bool files;

  /// Satz für Raum [roomId] (Plan-Raum) im Design [theme], `null`: keiner.
  String? setFor(String roomId, String theme) {
    for (final e in info.entries) {
      if (e.value.room == roomId && e.value.theme == theme) return e.key;
    }
    return null;
  }
}

/// Angaben zu einem Satz aus `haven/render/status`.
class RenderSetInfo {
  const RenderSetInfo({this.room, this.theme = '', this.lamps = const []});

  factory RenderSetInfo.fromJson(Map<String, dynamic> j) => RenderSetInfo(
    room: j['room'] as String?,
    theme: '${j['theme'] ?? ''}',
    lamps: [for (final l in (j['lamps'] as List?) ?? const []) '$l'],
  );

  /// Plan-Raum der Perspektive, `null`: Übersicht.
  final String? room;
  final String theme;
  final List<String> lamps;
}

class RenderUploadCancelled implements Exception {
  const RenderUploadCancelled();
}
