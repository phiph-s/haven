import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../state/providers.dart';
import 'panel_host_stub.dart'
    if (dart.library.js_interop) 'panel_host_web.dart'
    as impl;

/// Zustand, den das Panel-Modul (`haven-panel.js`) aus Home Assistant
/// weiterreicht. Alle Felder sind optional, das Modul kann älter oder neuer
/// sein als die App.
@immutable
class PanelState {
  const PanelState({
    this.token,
    this.darkMode,
    this.origin,
    this.version,
    this.narrow = false,
    this.language,
    this.standalone = false,
  });

  /// Liest das JS-Objekt `window.__havenPanel` (als Map). Unbrauchbares wird
  /// `null`, nie eine Ausnahme.
  factory PanelState.fromMap(Map<String, Object?> m) {
    String? str(String k) {
      final v = m[k];
      return v is String && v.isNotEmpty ? v : null;
    }

    final dark = m['darkMode'];
    final narrow = m['narrow'];
    final standalone = m['standalone'];
    return PanelState(
      token: str('token'),
      darkMode: dark is bool ? dark : null,
      origin: str('origin'),
      version: str('version'),
      narrow: narrow is bool && narrow,
      language: str('language'),
      standalone: standalone is bool && standalone,
    );
  }

  /// Access-Token aus `hass.auth` (kurzlebig, HA erneuert es).
  final String? token;

  /// `hass.themes.darkMode`, `null` wenn unbekannt.
  final bool? darkMode;

  /// Herkunft von HA, z. B. `https://ha.example:8123`. Der WebSocket ist
  /// dieselbe Herkunft (`/api/websocket`).
  final String? origin;

  /// Version des Panel-Moduls bzw. der Integration.
  final String? version;

  /// HA meldet eine schmale Ansicht (Seitenleiste eingeklappt, Handy).
  final bool narrow;
  final String? language;

  /// Eigenständig als installierte Web-App (`/haven_app/`, `haven-app.js`)
  /// statt in der Seitenleiste von HA: eigene Anmeldung bei HA, kein Menü
  /// von HA, das Theme wählt man in Haven.
  final bool standalone;

  /// Theme aus HA: dunkel, hell oder dem System folgen.
  ThemeMode get themeMode => switch (darkMode) {
    true => ThemeMode.dark,
    false => ThemeMode.light,
    null => ThemeMode.system,
  };

  @override
  bool operator ==(Object other) =>
      other is PanelState &&
      other.token == token &&
      other.darkMode == darkMode &&
      other.origin == origin &&
      other.version == version &&
      other.narrow == narrow &&
      other.language == language &&
      other.standalone == standalone;

  @override
  int get hashCode => Object.hash(
    token,
    darkMode,
    origin,
    version,
    narrow,
    language,
    standalone,
  );
}

/// Verbindung zum Panel-Modul in Home Assistant (nur Web, nur im Panel).
abstract class PanelHost {
  /// Letzter bekannter Zustand.
  PanelState get state;

  /// Neuer Zustand, sobald HA ein neues `hass`-Objekt setzt (Token,
  /// Dunkelmodus, schmale Ansicht).
  Stream<PanelState> get changes;

  /// Gültiges Token für eine neue Verbindung. Das Modul erneuert es über
  /// `hass.auth.refreshAccessToken()`, wenn es abgelaufen ist.
  Future<String> freshToken();

  /// Öffnet die Seitenleiste von HA (Schmalansicht, `hass-toggle-menu`).
  void toggleMenu();

  /// Nur eigenständig: Anmeldung bei HA widerrufen und zum Login von HA.
  void logout();
}

/// Panel-Host der laufenden Seite oder `null` (App, normales Web, Tests).
/// Erkennung: Das Modul setzt vor dem Start `window.__havenPanel`.
PanelHost? detectPanelHost() => impl.detectPanelHost();

/// `null` außerhalb von Home Assistant. In `main` überschrieben.
final panelHostProvider = Provider<PanelHost?>((ref) => null);

/// Läuft die App als Seitenleisten-Eintrag in Home Assistant?
final panelModeProvider = Provider<bool>(
  (ref) => ref.watch(panelHostProvider) != null,
);

/// Aktueller Zustand aus HA (`null` außerhalb des Panels).
class PanelStateController extends Notifier<PanelState?> {
  @override
  PanelState? build() {
    final host = ref.watch(panelHostProvider);
    if (host == null) return null;
    final sub = host.changes.listen((s) => state = s);
    ref.onDispose(sub.cancel);
    return host.state;
  }
}

final panelStateProvider = NotifierProvider<PanelStateController, PanelState?>(
  PanelStateController.new,
);

/// Theme im Panel: folgt `hass.themes.darkMode`, Änderungen live.
class PanelThemeModeController extends ThemeModeController {
  PanelThemeModeController(this.host);
  final PanelHost host;

  @override
  ThemeMode build() {
    final sub = host.changes.listen((s) => state = s.themeMode);
    ref.onDispose(sub.cancel);
    return host.state.themeMode;
  }

  /// Im Panel bestimmt HA das Theme. Eine Wahl in den Einstellungen gilt
  /// nur bis zur nächsten Meldung von HA.
  @override
  Future<void> set(ThemeMode m) async => state = m;
}

/// Für Tests: fester Zustand, Änderungen per [emit].
class StaticPanelHost implements PanelHost {
  StaticPanelHost(this._state, {this.token = 'test-token'});
  PanelState _state;
  final String token;
  final _ctrl = StreamController<PanelState>.broadcast();

  @override
  PanelState get state => _state;

  @override
  Stream<PanelState> get changes => _ctrl.stream;

  @override
  Future<String> freshToken() async => _state.token ?? token;

  int menuToggles = 0;

  @override
  void toggleMenu() => menuToggles++;

  int logouts = 0;

  @override
  void logout() => logouts++;

  void emit(PanelState s) {
    _state = s;
    _ctrl.add(s);
  }
}
