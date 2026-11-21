import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'panel_host.dart';

/// Name des Objekts, das `haven-panel.js` vor dem Start der App setzt.
const String kPanelGlobal = '__havenPanel';

/// Panel-Host über `window.__havenPanel` (siehe `web/ha_panel/haven-panel.js`):
/// - Felder `token`, `darkMode`, `origin`, `version`, `narrow`, `language`
/// - `getToken()` liefert ein Promise mit einem gültigen Token
/// - `addListener(fn)`: Das Modul ruft `fn` bei jedem neuen `hass`.
PanelHost? detectPanelHost() {
  if (!globalContext.has(kPanelGlobal)) return null;
  final bridge = globalContext.getProperty<JSObject?>(kPanelGlobal.toJS);
  if (bridge == null) return null;
  return _WebPanelHost(bridge);
}

class _WebPanelHost implements PanelHost {
  _WebPanelHost(this._bridge) {
    _state = _read();
    final fn = (() {
      final s = _read();
      if (s == _state) return;
      _state = s;
      _ctrl.add(s);
    }).toJS;
    _bridge.callMethod('addListener'.toJS, fn);
  }

  final JSObject _bridge;
  late PanelState _state;
  final _ctrl = StreamController<PanelState>.broadcast();

  PanelState _read() {
    Object? v(String k) => _bridge.getProperty<JSAny?>(k.toJS).dartify();
    return PanelState.fromMap({
      for (final k in const [
        'token',
        'darkMode',
        'origin',
        'version',
        'narrow',
        'language',
        'standalone',
      ])
        k: v(k),
    });
  }

  @override
  PanelState get state => _state;

  @override
  Stream<PanelState> get changes => _ctrl.stream;

  @override
  void toggleMenu() => _bridge.callMethod('toggleMenu'.toJS);

  @override
  void logout() {
    if (_bridge.has('logout')) _bridge.callMethod('logout'.toJS);
  }

  @override
  Future<String> freshToken() async {
    try {
      final p = _bridge.callMethod<JSPromise<JSString>>('getToken'.toJS);
      final t = (await p.toDart).toDart;
      if (t.isNotEmpty) return t;
    } catch (_) {
      // Rückfall: letztes bekanntes Token.
    }
    return _read().token ?? '';
  }
}
