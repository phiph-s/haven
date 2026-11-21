import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/router/router.dart';
import '../../core/state/providers.dart';
import '../../data/models/entity_state.dart';
import '../automations/haven_automations_provider.dart';
import '../map/floor_plan_store.dart';
import '../map/map_data.dart' show num1, snapshotRoomFor;
import '../map/map_jump.dart';
import '../map/map_layers.dart';
import '../zigbee/zigbee_providers.dart';
import '../zigbee/zigbee_screen.dart' show zigbeeDevicePath;
import '../zigbee/mesh/mesh_screen.dart' show zigbeeMeshPath;

// Suche über alles, was die App kennt: Räume, Geräte, ihre Werte (Sensoren,
// Lampen), Szenen, Abläufe und Ansichten (Kartenarten, Seiten). Der Index
// hängt an den Providern und ist damit immer aktuell, auch während das
// Suchfenster offen ist.

/// Art eines Treffers (Symbol, Reihenfolge bei gleicher Güte).
enum SearchKind {
  view('Ansicht'),
  room('Raum'),
  device('Gerät'),
  value('Wert'),
  scene('Szene'),
  automation('Ablauf');

  const SearchKind(this.label);
  final String label;
}

/// Ein Treffer: was angezeigt wird, wonach er gefunden wird und wohin er
/// führt.
class SearchItem {
  const SearchItem({
    required this.kind,
    required this.title,
    required this.icon,
    required this.open,
    this.subtitle,
    this.keywords = '',
    this.color,
  });

  final SearchKind kind;
  final String title;
  final String? subtitle;
  final IconData icon;

  /// Weitere Suchwörter (Entity-ID, Modell, Art des Sensors …).
  final String keywords;

  /// Farbe des Symbols (z. B. Lampenfarbe), sonst neutral.
  final Color? color;

  /// Hinspringen (nach dem Schließen der Suche).
  final void Function(GoRouter router, ProviderContainer ref) open;
}

/// Für den Vergleich: klein, Umlaute und Akzente gefaltet („Küche“,
/// „kueche“ und „kuche“ treffen sich), Satzzeichen als Leerzeichen.
String foldSearch(String s) {
  var t = s.toLowerCase();
  const map = {
    'ä': 'a',
    'ö': 'o',
    'ü': 'u',
    'ß': 'ss',
    'é': 'e',
    'è': 'e',
    'à': 'a',
  };
  map.forEach((k, v) => t = t.replaceAll(k, v));
  t = t.replaceAll('ae', 'a').replaceAll('oe', 'o').replaceAll('ue', 'u');
  return t.replaceAll(RegExp(r'[_\-.:/·,()]+'), ' ').trim();
}

/// Güte von [item] für die Anfrage [q] (gefaltet, in Wörtern), 0: passt
/// nicht. Jedes Wort muss irgendwo vorkommen; Treffer im Titel (am Anfang,
/// am Wortanfang) zählen mehr.
int searchScore(SearchItem item, List<String> words, String whole) {
  if (words.isEmpty) return 0;
  final title = foldSearch(item.title);
  final rest = foldSearch('${item.subtitle ?? ''} ${item.keywords}');
  var score = 0;
  if (title.startsWith(whole)) score += 100;
  if (title == whole) score += 60;
  for (final w in words) {
    if (title.startsWith(w) || title.contains(' $w')) {
      score += 30;
    } else if (title.contains(w)) {
      score += 15;
    } else if (rest.startsWith(w) || rest.contains(' $w')) {
      score += 8;
    } else if (rest.contains(w)) {
      score += 4;
    } else {
      return 0;
    }
  }
  // Bei gleicher Güte: Ansichten und Räume vor Geräten und Werten.
  return score * 10 + (SearchKind.values.length - item.kind.index);
}

/// Treffer für [query], die besten zuerst (höchstens [limit]).
List<SearchItem> searchItems(
  List<SearchItem> index,
  String query, {
  int limit = 40,
}) {
  final whole = foldSearch(query);
  final words = whole.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return const [];
  final scored =
      <(int, SearchItem)>[
        for (final i in index)
          if (searchScore(i, words, whole) case final s when s > 0) (s, i),
      ]..sort((a, b) {
        final c = b.$1.compareTo(a.$1);
        return c != 0 ? c : a.$2.title.compareTo(b.$2.title);
      });
  return [for (final (_, i) in scored.take(limit)) i];
}

// ---- Werte -----------------------------------------------------------------

/// Art eines Sensors auf Deutsch (auch als Suchwort).
String? _classLabel(EntityState e) {
  final dc = '${e.attributes['device_class'] ?? ''}';
  return switch (dc) {
    'temperature' => 'Temperatur',
    'humidity' => 'Luftfeuchte',
    'battery' => 'Batterie',
    'power' => 'Leistung',
    'energy' => 'Energie',
    'illuminance' => 'Helligkeit',
    'motion' || 'occupancy' || 'presence' => 'Bewegung',
    'door' => 'Tür',
    'window' => 'Fenster',
    'opening' => 'Öffnung',
    'moisture' => 'Wasser',
    'smoke' => 'Rauch',
    'co2' || 'carbon_dioxide' => 'CO₂',
    'pressure' => 'Luftdruck',
    'voltage' => 'Spannung',
    _ => switch (e.domain) {
      'light' => 'Lampe',
      'switch' => 'Schalter',
      'climate' => 'Thermostat',
      'cover' => 'Rollladen',
      'lock' => 'Schloss',
      'fan' => 'Lüfter',
      'media_player' => 'Medien',
      _ => null,
    },
  };
}

/// Zustand lesbar: „21,3 °C“, „an · 80 %“, „offen“, „Bewegung“.
String _valueText(EntityState e) {
  if (!e.isAvailable) return 'nicht erreichbar';
  final unit = '${e.attributes['unit_of_measurement'] ?? ''}';
  final n = double.tryParse(e.state);
  if (n != null) {
    final v = n == n.roundToDouble() && n.abs() >= 10
        ? n.round().toString()
        : num1(n);
    return unit.isEmpty ? v : '$v $unit';
  }
  final dc = '${e.attributes['device_class'] ?? ''}';
  if (e.domain == 'binary_sensor') {
    final on = e.isOn;
    return switch (dc) {
      'motion' || 'occupancy' || 'presence' => on ? 'Bewegung' : 'ruhig',
      'door' || 'window' || 'opening' => on ? 'offen' : 'zu',
      'moisture' => on ? 'nass' : 'trocken',
      'battery' => on ? 'schwach' : 'ok',
      _ => on ? 'an' : 'aus',
    };
  }
  if (e.domain == 'light') {
    if (!e.isOn) return 'aus';
    final b = e.attributes['brightness'];
    return b is num ? 'an · ${(b / 255 * 100).round()} %' : 'an';
  }
  if (e.domain == 'climate') {
    final t = e.attributes['current_temperature'];
    final s = e.attributes['temperature'];
    return [
      if (t is num) '${num1(t.toDouble())} °C',
      if (s is num) 'Ziel ${num1(s.toDouble())} °C',
    ].join(' · ');
  }
  return switch (e.state) {
    'on' => 'an',
    'off' => 'aus',
    'open' => 'offen',
    'closed' => 'zu',
    _ => e.state,
  };
}

IconData _iconOf(EntityState e) {
  final dc = '${e.attributes['device_class'] ?? ''}';
  return switch (dc) {
    'temperature' => Icons.thermostat_rounded,
    'humidity' || 'moisture' => Icons.water_drop_outlined,
    'battery' => Icons.battery_5_bar_rounded,
    'power' || 'energy' || 'voltage' => Icons.bolt_rounded,
    'illuminance' => Icons.wb_sunny_outlined,
    'motion' || 'occupancy' || 'presence' => Icons.directions_walk_rounded,
    'door' || 'window' || 'opening' => Icons.sensor_door_outlined,
    _ => switch (e.domain) {
      'light' => Icons.lightbulb_outline_rounded,
      'switch' => Icons.power_outlined,
      'climate' => Icons.device_thermostat_rounded,
      'cover' => Icons.blinds_outlined,
      _ => Icons.sensors_rounded,
    },
  };
}

Color? _lampColor(EntityState e) {
  if (e.domain != 'light' || !e.isOn) return null;
  final rgb = e.attributes['rgb_color'];
  if (rgb is List && rgb.length >= 3) {
    return Color.fromARGB(
      255,
      (rgb[0] as num).toInt(),
      (rgb[1] as num).toInt(),
      (rgb[2] as num).toInt(),
    );
  }
  return const Color(0xFFFFC98A);
}

// ---- Index -----------------------------------------------------------------

const _valueDomains = {
  'sensor',
  'binary_sensor',
  'light',
  'switch',
  'climate',
  'cover',
  'lock',
  'fan',
  'media_player',
};

/// Alle Treffer, die es gerade gibt.
final searchIndexProvider = Provider<List<SearchItem>>((ref) {
  final snap = ref.watch(snapshotProvider);
  final plan = ref.watch(floorPlanProvider).value;
  final zb = ref.watch(zigbeeProvider).devices;
  final autos = ref.watch(havenAutomationsProvider).value?.automations;
  final out = <SearchItem>[];

  void goMap(GoRouter router, ProviderContainer ref, MapJump j) {
    ref.read(mapJumpProvider.notifier).request(j);
    router.go(Routes.map);
  }

  // Ansichten: Seiten und Kartenarten.
  void page(String title, IconData icon, String path, [String keys = '']) {
    out.add(
      SearchItem(
        kind: SearchKind.view,
        title: title,
        icon: icon,
        keywords: keys,
        open: (router, _) => router.go(path),
      ),
    );
  }

  page('Zuhause', Icons.home_rounded, Routes.home, 'start übersicht räume');
  page('Karte', Icons.map_rounded, Routes.map, 'grundriss 3d 2d');
  page('Netzwerk', Icons.hub_rounded, Routes.zigbee, 'zigbee matter geräte koppeln');
  page('Funknetz', Icons.device_hub_rounded, zigbeeMeshPath, 'mesh netz lqi');
  page(
    'Abläufe',
    Icons.auto_awesome_rounded,
    Routes.automations,
    'automationen drehregler bewegungslicht',
  );
  page(
    'Einstellungen',
    Icons.settings_outlined,
    Routes.settings,
    'verbindung darstellung',
  );
  page(
    'Updates',
    Icons.system_update_rounded,
    Routes.updates,
    'aktualisieren version',
  );
  for (final l in MapLayer.values) {
    out.add(
      SearchItem(
        kind: SearchKind.view,
        title: 'Karte: ${l.label}',
        subtitle: 'Kartenart',
        icon: l.icon,
        keywords: 'karte ${l.storeName}',
        open: (router, ref) => goMap(router, ref, MapJump(layer: l)),
      ),
    );
  }

  // Räume (mit ihren Szenen).
  final roomName = <String, String>{};
  final roomOfEntity = <String, String>{};
  for (final r in snap.rooms) {
    roomName[r.id] = r.name;
    for (final id in [...r.lightIds, ?r.temperatureId, ?r.humidityId]) {
      roomOfEntity[id] = r.id;
    }
    final lamps = r.lightIds.length;
    out.add(
      SearchItem(
        kind: SearchKind.room,
        title: r.name,
        subtitle: lamps == 0 ? 'Raum' : 'Raum · $lamps Lampen',
        icon: Icons.meeting_room_outlined,
        open: (router, _) => router.go(Routes.room(r.id)),
      ),
    );
    for (final s in r.scenes) {
      out.add(
        SearchItem(
          kind: SearchKind.scene,
          title: s.name,
          subtitle: 'Szene in ${r.name}',
          icon: Icons.palette_outlined,
          open: (router, _) => router.go(Routes.room(r.id)),
        ),
      );
    }
  }

  // Plan-Räume der Karte → Raum der App (für Untertitel).
  String? roomOfPlacement(String entityId) {
    final p = plan?.entityPoint(entityId);
    final pr = p == null ? null : plan!.room(p.roomId);
    return pr == null ? null : snapshotRoomFor(snap, pr)?.name ?? pr.name;
  }

  final placed = plan?.placedEntityIds ?? const <String>{};

  // Zigbee-Geräte.
  final deviceOfEntity = <String, String>{};
  for (final d in zb) {
    if (d.isCoordinator) continue;
    for (final e in d.haEntities) {
      deviceOfEntity[e] = d.ieee;
    }
    final onMap = d.haEntities.where(placed.contains).firstOrNull;
    final where = onMap == null ? null : roomOfPlacement(onMap);
    out.add(
      SearchItem(
        kind: SearchKind.device,
        title: d.friendlyName,
        subtitle: [
          ?where,
          [?d.vendor, ?d.model].join(' '),
        ].where((s) => s.isNotEmpty).join(' · '),
        icon: Icons.memory_rounded,
        keywords: '${d.ieee} ${d.description ?? ''} zigbee',
        open: (router, ref) => onMap != null
            ? goMap(router, ref, MapJump(nodeId: onMap))
            : router.go(zigbeeDevicePath(d.ieee)),
      ),
    );
  }

  // Werte: Entities in Räumen, auf der Karte oder an Zigbee-Geräten.
  final relevant = {...roomOfEntity.keys, ...placed, ...deviceOfEntity.keys};
  for (final id in relevant) {
    final e = snap.entities[id];
    // Nur Zustände und Messwerte, keine Einstellungen der Geräte (number,
    // select, button, update …).
    if (e == null || !_valueDomains.contains(e.domain)) continue;
    final kind = _classLabel(e);
    final room =
        roomOfPlacement(id) ??
        (roomOfEntity[id] == null ? null : roomName[roomOfEntity[id]]);
    final ieee = deviceOfEntity[id];
    out.add(
      SearchItem(
        kind: SearchKind.value,
        title: e.name,
        subtitle: [_valueText(e), ?room].join(' · '),
        icon: _iconOf(e),
        color: _lampColor(e),
        keywords: '$id ${kind ?? ''}',
        open: (router, ref) {
          if (placed.contains(id)) {
            goMap(router, ref, MapJump(nodeId: id));
          } else if (ieee != null) {
            router.go(zigbeeDevicePath(ieee));
          } else if (roomOfEntity[id] case final r?) {
            router.go(Routes.room(r));
          }
        },
      ),
    );
  }

  // Abläufe.
  for (final a in autos ?? const []) {
    final id = a.id;
    if (id == null) continue;
    out.add(
      SearchItem(
        kind: SearchKind.automation,
        title: a.name,
        subtitle: a.isMotion ? 'Bewegungslicht' : 'Drehregler und Taster',
        icon: a.isMotion
            ? Icons.directions_walk_rounded
            : Icons.settings_input_component_outlined,
        keywords: a.enabled ? 'an' : 'aus',
        open: (router, _) => router.go(
          a.isMotion ? '/automations/motion/$id' : '/automations/knob/$id',
        ),
      ),
    );
  }
  return out;
});
