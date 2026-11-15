import 'dart:convert';

/// Brücke zur HA-Oberfläche nach dem Vorbild der Companion-App.
///
/// Annahmen (aus dem Wissen über den HA-Frontend-Code, nicht gegen ein
/// echtes HA geprüft):
/// - Die URL trägt `external_auth=1`. Damit nutzt das Frontend statt der
///   eigenen Anmeldung `window.externalApp.getExternalAuth(json)` (Android)
///   bzw. `webkit.messageHandlers.getExternalAuth` (iOS).
/// - `json` ist `{"callback": "<Name>", "force": <bool>}`. Die App antwortet,
///   indem sie `window[<Name>](true, {access_token, expires_in})` aufruft,
///   bei Fehler `window[<Name>](false)`.
/// - `revokeExternalAuth(json)` wird beim Abmelden gerufen, Antwort per
///   Callback `(true)`.
/// - `externalBus` (Nachrichten wie `config/get`) beantworten wir nicht.
///   Das Frontend läuft ohne, nur App-spezifische Menüpunkte fehlen.
/// - Statt eines kurzlebigen OAuth-Tokens liefern wir den Long-Lived-Token
///   der App. HA nimmt ihn als Bearer. `expires_in` ist nur der Takt, in dem
///   das Frontend erneut fragt.
const String haExternalAuthChannel = 'externalApp';

/// JavaScript, das im geladenen Dokument `window.externalApp` so ersetzt,
/// dass `getExternalAuth` & Co. existieren. `webview_flutter` legt nur
/// `externalApp.postMessage(String)` an, daher der Umweg über JSON.
const String haExternalAuthScript = r'''
(function () {
  if (window.__havenBridge) return;
  var native = window.externalApp;
  if (!native || !native.postMessage) return;
  window.__havenBridge = true;
  function send(type, payload) {
    native.postMessage(JSON.stringify({ type: type, payload: payload || '' }));
  }
  window.externalApp = {
    postMessage: function (m) { native.postMessage(m); },
    getExternalAuth: function (p) { send('getExternalAuth', p); },
    revokeExternalAuth: function (p) { send('revokeExternalAuth', p); },
    externalBus: function (p) { send('externalBus', p); }
  };
})();
''';

enum ExternalAuthKind { get, revoke, other }

class ExternalAuthMessage {
  const ExternalAuthMessage(this.kind, this.callback, {this.force = false});
  final ExternalAuthKind kind;

  /// Name der globalen JS-Funktion, die wir aufrufen sollen.
  final String? callback;
  final bool force;
}

/// Liest die Nachricht, die [haExternalAuthScript] sendet. `null` bei Müll.
ExternalAuthMessage? parseExternalAuthMessage(String raw) {
  try {
    final m = jsonDecode(raw);
    if (m is! Map) return null;
    final kind = switch (m['type']) {
      'getExternalAuth' => ExternalAuthKind.get,
      'revokeExternalAuth' => ExternalAuthKind.revoke,
      _ => ExternalAuthKind.other,
    };
    String? callback;
    var force = false;
    final p = m['payload'];
    if (p is String && p.isNotEmpty) {
      final j = jsonDecode(p);
      if (j is Map) {
        callback = j['callback'] as String?;
        force = j['force'] == true;
      }
    }
    return ExternalAuthMessage(kind, callback, force: force);
  } catch (_) {
    return null;
  }
}

/// Erlaubt nur gültige JS-Bezeichner (mit Punkten), nie beliebigen Code.
final RegExp _callbackName = RegExp(r'^[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*)*$');

/// JS, das den Token an das Frontend zurückgibt. `null`, wenn der
/// Callback-Name verdächtig ist.
String? authSuccessJs(String? callback, String token, {int expiresIn = 1800}) {
  if (callback == null || !_callbackName.hasMatch(callback)) return null;
  final data = jsonEncode({'access_token': token, 'expires_in': expiresIn});
  return '$callback(true, $data);';
}

String? authFailureJs(String? callback) {
  if (callback == null || !_callbackName.hasMatch(callback)) return null;
  return '$callback(false);';
}

String? authAckJs(String? callback) {
  if (callback == null || !_callbackName.hasMatch(callback)) return null;
  return '$callback(true);';
}

/// Ziel-URL: Basis-URL von HA plus Pfad, mit `external_auth=1`.
Uri haTargetUri(String baseUrl, String path, {bool externalAuth = true}) {
  var base = baseUrl.trim();
  if (!base.contains('://')) base = 'http://$base';
  final b = Uri.parse(base);
  final p = Uri.parse(path.startsWith('/') ? path : '/$path');
  final basePath = b.path.endsWith('/')
      ? b.path.substring(0, b.path.length - 1)
      : b.path;
  return b.replace(
    path: '$basePath${p.path}',
    queryParameters: {
      ...p.queryParameters,
      if (externalAuth) 'external_auth': '1',
    },
  );
}
