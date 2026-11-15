import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/widget_config.dart';

/// Lokale Ablage für App-Vorgaben, die eigentlich in HA liegen
/// (`haven/prefs`). Greift in den Entwicklungsdaten und solange die Integration den
/// Befehl nicht kennt.
abstract class LocalPrefs {
  Set<String> get excludedLights;
  Future<void> setExcludedLights(Set<String> ids);
}

/// Nur im Speicher (Tests).
class MemoryPrefs implements LocalPrefs {
  MemoryPrefs([Set<String>? initial]) : _ids = {...?initial};
  Set<String> _ids;
  @override
  Set<String> get excludedLights => _ids;
  @override
  Future<void> setExcludedLights(Set<String> ids) async => _ids = {...ids};
}

/// Lokale Einstellungen (SharedPreferences). Der Token liegt nicht hier,
/// sondern im [TokenStore].
class SettingsStore implements LocalPrefs {
  SettingsStore(this._p);
  final SharedPreferences _p;

  static const _kTheme = 'theme_mode';
  static const _kMode = 'connection_mode';
  static const _kUrl = 'ha_url';
  static const _kWidgets = 'home_widgets';
  static const _kExcluded = 'excluded_lights';
  static const _kUpdateChecked = 'update_last_check';
  static const _kUpdateDismissed = 'update_dismissed';
  static const _kUpdateRelease = 'update_latest_release';

  @override
  Set<String> get excludedLights =>
      (_p.getStringList(_kExcluded) ?? const []).toSet();
  @override
  Future<void> setExcludedLights(Set<String> ids) =>
      _p.setStringList(_kExcluded, ids.toList()..sort());

  /// Letzte erfolgreiche Prüfung auf eine neue App-Version.
  DateTime? get updateLastCheck {
    final ms = _p.getInt(_kUpdateChecked);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> setUpdateLastCheck(DateTime t) =>
      _p.setInt(_kUpdateChecked, t.millisecondsSinceEpoch);

  /// Version, deren Hinweiskarte auf der Übersicht weggewischt wurde.
  String? get updateDismissed => _p.getString(_kUpdateDismissed);
  Future<void> setUpdateDismissed(String? v) => v == null
      ? _p.remove(_kUpdateDismissed)
      : _p.setString(_kUpdateDismissed, v);

  /// Zuletzt gefundenes Release als JSON (damit die Karte nach einem Neustart
  /// ohne neue Prüfung da ist).
  String? get updateRelease => _p.getString(_kUpdateRelease);
  Future<void> setUpdateRelease(String? json) => json == null
      ? _p.remove(_kUpdateRelease)
      : _p.setString(_kUpdateRelease, json);

  ThemeMode get themeMode => switch (_p.getString(_kTheme)) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
  Future<void> setThemeMode(ThemeMode m) => _p.setString(_kTheme, m.name);

  /// `ha` oder `null` (Onboarding steht noch aus).
  String? get connectionMode => _p.getString(_kMode);
  Future<void> setConnectionMode(String? m) =>
      m == null ? _p.remove(_kMode) : _p.setString(_kMode, m);

  String? get haUrl => _p.getString(_kUrl);
  Future<void> setHaUrl(String? u) =>
      u == null ? _p.remove(_kUrl) : _p.setString(_kUrl, u);

  List<HavenWidgetConfig> get widgets {
    final s = _p.getString(_kWidgets);
    if (s == null) return HavenWidgetConfig.defaults;
    try {
      return HavenWidgetConfig.decodeList(s);
    } catch (_) {
      return HavenWidgetConfig.defaults;
    }
  }

  Future<void> setWidgets(List<HavenWidgetConfig> l) =>
      _p.setString(_kWidgets, HavenWidgetConfig.encodeList(l));
}

/// Ablage für den Long-Lived-Token.
abstract class TokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> delete();
}

/// Keystore auf Android (flutter_secure_storage).
class SecureTokenStore implements TokenStore {
  SecureTokenStore([FlutterSecureStorage? s])
    : _s = s ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  static const _key = 'ha_token';

  @override
  Future<String?> read() async {
    try {
      return await _s.read(key: _key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String token) => _s.write(key: _key, value: token);

  @override
  Future<void> delete() => _s.delete(key: _key);
}

/// Für Tests: nur im Speicher.
class MemoryTokenStore implements TokenStore {
  String? _t;
  @override
  Future<String?> read() async => _t;
  @override
  Future<void> write(String token) async => _t = token;
  @override
  Future<void> delete() async => _t = null;
}
