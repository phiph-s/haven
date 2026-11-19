import 'dart:convert';
import 'dart:typed_data';

import '../render_api.dart';
import 'ha_client.dart';

/// Bilder der Wohnung gegen die Integration (`haven/render/*`): Upload in
/// Stücken über die bestehende WebSocket-Verbindung (geht auch im Browser
/// ohne CORS und im HA-Panel).
class HaRender {
  HaRender(this.client);

  final HaClient client;

  /// Rohe Bytes je Stück (Base64 macht daraus ein Drittel mehr).
  static const chunkSize = 256 * 1024;

  Future<RenderStatus?> status({bool files = false}) async {
    final r = await client.send({'type': 'haven/render/status'});
    if (r is! Map || r['available'] != true) return null;
    return RenderStatus.fromJson(Map<String, dynamic>.from(r), files: files);
  }

  /// Datei eines Satzes in Stücken lesen (`haven/render/file`).
  Future<Uint8List> file(String set, String name) async {
    final out = BytesBuilder(copy: false);
    var size = -1;
    while (size < 0 || out.length < size) {
      final r = await client.send({
        'type': 'haven/render/file',
        'set': set,
        'name': name,
        'offset': out.length,
      });
      final m = Map<String, dynamic>.from(r as Map);
      size = (m['size'] as num).toInt();
      final data = base64Decode(m['data'] as String);
      if (data.isEmpty) break;
      out.add(data);
    }
    return out.takeBytes();
  }

  Future<void> upload(
    String key,
    List<RenderFile> files, {
    void Function(int sent, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    final begin = await client.send({'type': 'haven/render/begin', 'key': key});
    final upload = (begin as Map)['upload'] as String;
    final total = files.fold<int>(0, (a, f) => a + f.bytes.length);
    var sent = 0;
    try {
      for (final f in files) {
        for (var off = 0; off < f.bytes.length; off += chunkSize) {
          if (cancelled?.call() ?? false) throw const RenderUploadCancelled();
          final end = (off + chunkSize).clamp(0, f.bytes.length);
          await client.send({
            'type': 'haven/render/chunk',
            'upload': upload,
            'path': f.path,
            'offset': off,
            'data': base64Encode(f.bytes.sublist(off, end)),
          });
          sent += end - off;
          onProgress?.call(sent, total);
        }
      }
      await client.send({'type': 'haven/render/commit', 'upload': upload});
    } catch (_) {
      try {
        await client.send({'type': 'haven/render/abort'});
      } catch (_) {}
      rethrow;
    }
  }
}
