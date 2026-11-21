import 'dart:convert';

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

  /// Gesperrte Geräte (Entity-IDs und IEEE-Adressen).
  Set<String> get lockedIds;
  Future<void> setLockedIds(Set<String> ids);

  /// Wetterquellen der Karte (JSON wie in `haven/prefs`).
  Map<String, dynamic> get weatherConfig;
  Future<void> setWeatherConfig(Map<String, dynamic> j);

  /// Lampen-Kalibrierung je Typ (JSON wie `lamp_calibration` in
  /// `haven/prefs`).
  Map<String, dynamic> get lampCalibration;
  Future<void> setLampCalibration(Map<String, dynamic> j);
}

/// Nur im Speicher (Tests).
class MemoryPrefs implements LocalPrefs {
  MemoryPrefs([Set<String>? initial]) : _ids = {...?initial};
  Set<String> _ids;
  Set<String> _locked = {};
  @override
  Set<String> get excludedLights => _ids;
  @override
  Future<void> setExcludedLights(Set<String> ids) async => _ids = {...ids};
  @override
  Set<String> get lockedIds => _locked;
  @override
  Future<void> setLockedIds(Set<String> ids) async => _locked = {...ids};
  Map<String, dynamic> _weather = {};
  @override
  Map<String, dynamic> get weatherConfig => _weather;
  @override
  Future<void> setWeatherConfig(Map<String, dynamic> j) async =>
      _weather = {...j};
  Map<String, dynamic> _lampCalibration = {};
  @override
  Map<String, dynamic> get lampCalibration => _lampCalibration;
  @override
  Future<void> setLampCalibration(Map<String, dynamic> j) async =>
      _lampCalibration = {...j};
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
  static const _kLocked = 'locked_devices';
  static const _kWeather = 'weather_config';
  static const _kLampCalibration = 'lamp_calibration';
  static const _kMapSky = 'map_sky';
  static const _kUpdateChecked = 'update_last_check';
  static const _kUpdateDismissed = 'update_dismissed';
  static const _kUpdateRelease = 'update_latest_release';
  static const _kRoomOrder = 'home_room_order';
  static const _kMapLayer = 'map_layer';
  static const _kMap3dQuality = 'map_3d_quality';
  static const _kMap3dPerspective = 'map_3d_perspective';
  static const _kMap3dTilt = 'map_3d_tilt';
  static const _kEditorFurniture3d = 'editor_furniture_3d';
  static const _kMap3dTransparentWalls = 'map_3d_transparent_walls';
  static const _kMap3dEnvironment = 'map_3d_environment';
  static const _kHomeRoomsDetailed = 'home_rooms_detailed';
  static const _kHiddenRooms = 'home_hidden_rooms';
  static const _kMap3dLightReach = 'map_3d_light_reach';
  static const _kGhostIgnored = 'ghost_ignored';
  static const _kGhostHint = 'ghost_hint_dismissed';

  @override
  Set<String> get excludedLights =>
      (_p.getStringList(_kExcluded) ?? const []).toSet();
  @override
  Future<void> setExcludedLights(Set<String> ids) =>
      _p.setStringList(_kExcluded, ids.toList()..sort());

  @override
  Set<String> get lockedIds => (_p.getStringList(_kLocked) ?? const []).toSet();
  @override
  Future<void> setLockedIds(Set<String> ids) =>
      _p.setStringList(_kLocked, ids.toList()..sort());

  @override
  Map<String, dynamic> get weatherConfig => _json(_kWeather);
  @override
  Future<void> setWeatherConfig(Map<String, dynamic> j) =>
      _p.setString(_kWeather, jsonEncode(j));

  @override
  Map<String, dynamic> get lampCalibration => _json(_kLampCalibration);
  @override
  Future<void> setLampCalibration(Map<String, dynamic> j) =>
      _p.setString(_kLampCalibration, jsonEncode(j));

  /// Himmel der Karte: live oder eigene Werte (JSON, nur dieses Gerät).
  Map<String, dynamic> get mapSky => _json(_kMapSky);
  Future<void> setMapSky(Map<String, dynamic> j) =>
      _p.setString(_kMapSky, jsonEncode(j));

  Map<String, dynamic> _json(String key) {
    final raw = _p.getString(key);
    if (raw == null) return {};
    try {
      final v = jsonDecode(raw);
      return v is Map ? Map<String, dynamic>.from(v) : {};
    } catch (_) {
      return {};
    }
  }

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

  /// Wurden die Widgets je gespeichert (sonst gelten die Voreinstellungen)?
  bool get hasWidgets => _p.containsKey(_kWidgets);

  /// Reihenfolge der Räume in der Übersicht (Raum-IDs). Leer: wie in HA.
  List<String> get roomOrder => _p.getStringList(_kRoomOrder) ?? const [];
  Future<void> setRoomOrder(List<String> ids) =>
      _p.setStringList(_kRoomOrder, ids);

  /// Gewählte Kartenart (`MapLayer.name`), lokal gemerkt.
  String? get mapLayer => _p.getString(_kMapLayer);
  Future<void> setMapLayer(String name) => _p.setString(_kMapLayer, name);

  /// Qualitätsstufe der 3D-Karte (`low`, `medium`, `high`), `null`: Vorgabe.
  String? get map3dQuality => _p.getString(_kMap3dQuality);
  Future<void> setMap3dQuality(String v) => _p.setString(_kMap3dQuality, v);

  /// Perspektivische statt orthographischer Kamera in der Schrägansicht.
  bool get map3dPerspective => _p.getBool(_kMap3dPerspective) ?? false;
  Future<void> setMap3dPerspective(bool v) => _p.setBool(_kMap3dPerspective, v);

  /// Zuletzt gewählte Ansicht: schräg (Puppenhaus) statt Draufsicht.
  bool get map3dTilt => _p.getBool(_kMap3dTilt) ?? false;
  Future<void> setMap3dTilt(bool v) => _p.setBool(_kMap3dTilt, v);

  /// Einrichten im Grundriss-Editor in 3D (Standard) statt von oben.
  bool get editorFurniture3d => _p.getBool(_kEditorFurniture3d) ?? true;
  Future<void> setEditorFurniture3d(bool v) =>
      _p.setBool(_kEditorFurniture3d, v);

  /// Wände halbdurchsichtig (Nachbarräume scheinen durch); Standard deckend.
  bool get map3dTransparentWalls =>
      _p.getBool(_kMap3dTransparentWalls) ?? false;
  Future<void> setMap3dTransparentWalls(bool v) =>
      _p.setBool(_kMap3dTransparentWalls, v);

  /// Umgebung der Karte: Sonne, Mond, Tageszeit und Wetter.
  bool get map3dEnvironment => _p.getBool(_kMap3dEnvironment) ?? true;
  Future<void> setMap3dEnvironment(bool v) => _p.setBool(_kMap3dEnvironment, v);

  /// Wie weit Lampenlicht in der 3D-Karte reicht (`doors`, `open`, `room`).
  String? get map3dLightReach => _p.getString(_kMap3dLightReach);
  Future<void> setMap3dLightReach(String v) =>
      _p.setString(_kMap3dLightReach, v);

  /// Räume, die nicht auf die Startseite sollen.
  List<String> get hiddenRooms => _p.getStringList(_kHiddenRooms) ?? const [];
  Future<void> setHiddenRooms(List<String> v) =>
      _p.setStringList(_kHiddenRooms, v);

  /// Räume auf Zuhause (Handy): ausführlich (einer je Zeile, mit Szenen)
  /// oder kompakt (zwei je Zeile).
  bool get homeRoomsDetailed => _p.getBool(_kHomeRoomsDetailed) ?? true;
  Future<void> setHomeRoomsDetailed(bool v) =>
      _p.setBool(_kHomeRoomsDetailed, v);

  /// Ignorierte Geister-Geräte: IEEE → `last_seen`-Stempel (siehe
  /// `ghostStamp`), gelten bis zur nächsten Meldung.
  Map<String, String> get ghostIgnored {
    final raw = _p.getStringList(_kGhostIgnored) ?? const [];
    return {
      for (final e in raw)
        if (e.contains('|'))
          e.substring(0, e.indexOf('|')): e.substring(e.indexOf('|') + 1),
    };
  }

  Future<void> setGhostIgnored(Map<String, String> v) => _p.setStringList(
    _kGhostIgnored,
    [for (final e in v.entries) '${e.key}|${e.value}'],
  );

  /// Die einmalige Hinweiskarte „Zuletzt gesehen einschalten“ wurde weggewischt.
  bool get ghostHintDismissed => _p.getBool(_kGhostHint) ?? false;
  Future<void> setGhostHintDismissed(bool v) => _p.setBool(_kGhostHint, v);

  // ---- Abgleich mit HA (sync/app_data.dart) ------------------------------

  /// Stempel (ms) der lokalen Fassung eines geteilten Dokuments.
  int? syncStamp(String kind) => _p.getInt('sync_${kind}_at');

  /// Lokal geändert, aber noch nicht in HA gespeichert.
  bool syncDirty(String kind) => _p.getBool('sync_${kind}_dirty') ?? false;

  /// Server-Stand (`updated_at`), auf dem die lokale Fassung beruht: zuletzt
  /// übernommen oder erfolgreich gespeichert. `null`: nie abgeglichen.
  int? syncBase(String kind) => _p.getInt('sync_${kind}_base');

  /// [base] nur setzen, wenn angegeben, sonst bleibt der bisherige Stand.
  Future<void> setSync(
    String kind, {
    int? stamp,
    required bool dirty,
    int? base,
  }) async {
    if (base != null) await _p.setInt('sync_${kind}_base', base);
    if (stamp == null) {
      await _p.remove('sync_${kind}_at');
    } else {
      await _p.setInt('sync_${kind}_at', stamp);
    }
    await _p.setBool('sync_${kind}_dirty', dirty);
  }
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
