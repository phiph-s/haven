import 'package:flutter/foundation.dart';

import 'entity_state.dart';

/// Bits von `supported_features` einer `update.*`-Entity.
abstract final class UpdateFeature {
  static const install = 1;
  static const specificVersion = 2;
  static const progress = 4;
  static const backup = 8;
  static const releaseNotes = 16;
}

/// Gruppen der Update-Liste, in der Reihenfolge der Anzeige.
enum UpdateGroup {
  haven('Haven'),
  homeAssistant('Home Assistant'),
  addons('Add-ons'),
  integrations('Integrationen'),
  devices('Geräte');

  const UpdateGroup(this.label);
  final String label;
}

/// Ein Update aus einer `update.*`-Entity. Alle Felder sind defensiv gelesen,
/// HA liefert je nach Quelle nicht alle Attribute.
@immutable
class HaUpdate {
  const HaUpdate({
    required this.entityId,
    required this.name,
    required this.state,
    this.title,
    this.installed,
    this.latest,
    this.summary,
    this.releaseUrl,
    this.inProgress = false,
    this.percentage,
    this.skipped,
    this.autoUpdate = false,
    this.picture,
    this.features = 0,
    this.deviceClass,
  });

  factory HaUpdate.fromEntity(EntityState e) {
    final a = e.attributes;
    String? str(String k) {
      final v = a[k];
      if (v == null) return null;
      final s = v.toString().trim();
      return s.isEmpty ? null : s;
    }

    final prog = a['in_progress'];
    // `in_progress` ist bool, bei manchen Quellen eine Prozentzahl.
    final inProgress = prog == true || (prog is num && prog > 0);
    final pct =
        a['update_percentage'] ?? (prog is num && prog > 0 ? prog : null);
    return HaUpdate(
      entityId: e.entityId,
      name: e.name,
      state: e.state,
      title: str('title'),
      installed: str('installed_version'),
      latest: str('latest_version'),
      summary: str('release_summary'),
      releaseUrl: str('release_url'),
      inProgress: inProgress,
      percentage: pct is num ? pct.toDouble().clamp(0, 100) : null,
      skipped: str('skipped_version'),
      autoUpdate: a['auto_update'] == true,
      picture: str('entity_picture'),
      features: (a['supported_features'] as num?)?.toInt() ?? 0,
      deviceClass: str('device_class'),
    );
  }

  final String entityId;

  /// Anzeigename der Entity.
  final String name;
  final String state;
  final String? title;
  final String? installed;
  final String? latest;
  final String? summary;
  final String? releaseUrl;
  final bool inProgress;

  /// 0..100, `null` ohne Angabe.
  final double? percentage;
  final String? skipped;
  final bool autoUpdate;
  final String? picture;
  final int features;
  final String? deviceClass;

  /// Es steht ein Update an (Zustand `on`).
  bool get pending => state == 'on';

  bool get canInstall => features & UpdateFeature.install != 0;
  bool get canPickVersion => features & UpdateFeature.specificVersion != 0;
  bool get hasProgress => features & UpdateFeature.progress != 0;
  bool get canBackup => features & UpdateFeature.backup != 0;
  bool get hasReleaseNotes => features & UpdateFeature.releaseNotes != 0;

  /// Name ohne Zusatz „Update“ bzw. „Firmware“, wenn `title` fehlt.
  String get displayName {
    final t = title;
    if (t != null) {
      // `title` ist bei Geräten oft nur „Firmware“, dann trägt der Name mehr.
      if (_generic.contains(t.toLowerCase())) return _stripSuffix(name);
      return t;
    }
    return _stripSuffix(name);
  }

  static const _generic = {'firmware', 'update', 'software'};

  static String _stripSuffix(String n) {
    final s = n.replaceFirst(
      RegExp(r'\s+(update|firmware)$', caseSensitive: false),
      '',
    );
    return s.isEmpty ? n : s;
  }

  UpdateGroup get group => classifyUpdate(this);

  /// Core, OS und Supervisor: Neustart von Home Assistant möglich.
  bool get restartsHa => isCoreComponent(this);

  /// Haven-Integration oder -App über HACS.
  bool get isHaven => group == UpdateGroup.haven;

  @override
  bool operator ==(Object other) =>
      other is HaUpdate &&
      other.entityId == entityId &&
      other.name == name &&
      other.state == state &&
      other.title == title &&
      other.installed == installed &&
      other.latest == latest &&
      other.summary == summary &&
      other.releaseUrl == releaseUrl &&
      other.inProgress == inProgress &&
      other.percentage == percentage &&
      other.skipped == skipped &&
      other.autoUpdate == autoUpdate &&
      other.picture == picture &&
      other.features == features;

  @override
  int get hashCode =>
      Object.hash(entityId, state, installed, latest, inProgress, percentage);
}

bool _has(String? s, Pattern p) => s != null && s.toLowerCase().contains(p);

/// Core, Operating System und Supervisor. Erkennt die festen IDs von
/// Home Assistant und den Titel.
bool isCoreComponent(HaUpdate u) {
  final id = u.entityId.toLowerCase();
  const ids = [
    'update.home_assistant_core_update',
    'update.home_assistant_operating_system_update',
    'update.home_assistant_supervisor_update',
  ];
  if (ids.contains(id)) return true;
  final t = (u.title ?? u.name).toLowerCase();
  return RegExp(
    r'^home assistant (core|operating system|os|supervisor)\b',
  ).hasMatch(t);
}

/// Ordnet ein Update einer Gruppe zu, aus `entity_id`, Titel und Bild. Was sich
/// nicht einordnen lässt, landet bei den Integrationen.
UpdateGroup classifyUpdate(HaUpdate u) {
  if (isCoreComponent(u)) return UpdateGroup.homeAssistant;
  final id = u.entityId.toLowerCase();
  final slug = id.substring(id.indexOf('.') + 1);
  // Haven selbst: `update.haven_*` oder Titel „Haven“. Ein Gerät, das nur
  // so heißt, bleibt bei den Geräten (Firmware).
  final havenName =
      slug == 'haven' ||
      slug.startsWith('haven_') ||
      _has(u.title, RegExp(r'^haven\b')) ||
      _has(u.releaseUrl, 'phiph-s/haven');
  if (havenName && u.deviceClass != 'firmware') return UpdateGroup.haven;
  // Add-ons des Supervisors liefern ihr Symbol unter /api/hassio/addons/.
  if (_has(u.picture, '/api/hassio/addons/') ||
      _has(u.picture, '/api/hassio/app/') ||
      slug.startsWith('addon_') ||
      // Add-ons ohne Symbol: nur der Supervisor bietet ein Backup vor dem
      // Update an (Core/OS sind oben schon abgefangen), HACS nicht.
      (u.canBackup && u.deviceClass != 'firmware')) {
    return UpdateGroup.addons;
  }
  if (u.deviceClass == 'firmware' ||
      _has(u.title, 'firmware') ||
      _has(u.name, 'firmware') ||
      _has(u.entityId, 'firmware')) {
    return UpdateGroup.devices;
  }
  // HACS (GitHub-Link, Marken-Symbol) und alles Unbekannte.
  return UpdateGroup.integrations;
}

/// Alle anstehenden Updates, nach Gruppen. Eigene Klasse mit `==`, damit
/// Oberflächen nur bei echten Änderungen neu bauen.
@immutable
class HaUpdates {
  const HaUpdates(this.items);
  final List<HaUpdate> items;

  static const empty = HaUpdates([]);

  /// Alle `update.*`-Entities, die anstehen oder gerade laufen, sortiert
  /// nach Gruppe und Name.
  factory HaUpdates.fromEntities(Iterable<EntityState> entities) {
    final l = [
      for (final e in entities)
        if (e.entityId.startsWith('update.'))
          if (HaUpdate.fromEntity(e) case final u
              when u.pending || u.inProgress)
            u,
    ];
    l.sort((a, b) {
      final g = a.group.index.compareTo(b.group.index);
      if (g != 0) return g;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    return HaUpdates(l);
  }

  int get count => items.length;
  bool get isEmpty => items.isEmpty;

  Map<UpdateGroup, List<HaUpdate>> get byGroup {
    final m = <UpdateGroup, List<HaUpdate>>{};
    for (final u in items) {
      m.putIfAbsent(u.group, () => []).add(u);
    }
    return m;
  }

  /// Updates, die „Alle aktualisieren“ erfasst: installierbar, nicht Core, OS
  /// oder Supervisor, nicht schon laufend.
  List<HaUpdate> get bulkTargets => [
    for (final u in items)
      if (u.canInstall && !u.restartsHa && !u.inProgress) u,
  ];

  bool get anyRunning => items.any((u) => u.inProgress);

  @override
  bool operator ==(Object other) =>
      other is HaUpdates && listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(items.length, count);
}
