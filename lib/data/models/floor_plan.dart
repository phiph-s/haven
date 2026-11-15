import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/foundation.dart';

/// Kleinste Raumseite in Zellen (Spec 5).
const int kMinRoomCells = 3;

/// Raster: eine Zelle ist ungefähr [cellMeters] groß.
@immutable
class FloorGrid {
  const FloorGrid({this.cols = 20, this.rows = 26, this.cellMeters = 0.5});

  factory FloorGrid.fromJson(Map<String, dynamic> j) => FloorGrid(
    cols: (j['cols'] as num).toInt(),
    rows: (j['rows'] as num).toInt(),
    cellMeters: (j['cellMeters'] as num?)?.toDouble() ?? 0.5,
  );

  final int cols;
  final int rows;
  final double cellMeters;

  Map<String, dynamic> toJson() => {
    'cols': cols,
    'rows': rows,
    'cellMeters': cellMeters,
  };

  @override
  bool operator ==(Object other) =>
      other is FloorGrid &&
      other.cols == cols &&
      other.rows == rows &&
      other.cellMeters == cellMeters;

  @override
  int get hashCode => Object.hash(cols, rows, cellMeters);
}

/// Darstellungsart einer Platzierung.
///
/// `remote`, `contact`, `media` und `device` kamen mit dem Geräte-Pool dazu.
/// Ältere App-Stände lesen sie als unbekannt und fallen auf [ofEntity]
/// zurück.
enum FloorKind {
  light('light'),
  temperature('temperature'),
  switchKind('switch'),
  presence('presence'),
  remote('remote'),
  contact('contact'),
  media('media'),
  device('device');

  const FloorKind(this.json);
  final String json;

  static FloorKind? fromJson(Object? v) {
    for (final k in values) {
      if (k.json == v) return k;
    }
    return null;
  }

  /// Aus der Domain der Entity abgeleitet.
  static FloorKind ofEntity(String entityId) =>
      switch (entityId.split('.')[0]) {
        'light' => light,
        'switch' => switchKind,
        'binary_sensor' => presence,
        'media_player' => media,
        'event' => remote,
        'sensor' || 'climate' => temperature,
        _ => device,
      };
}

/// Ein Raum: achsenparalleles Rechteck in ganzen Zellen.
@immutable
class FloorRoom {
  const FloorRoom({
    required this.id,
    required this.name,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.areaId,
  });

  factory FloorRoom.fromJson(Map<String, dynamic> j) => FloorRoom(
    id: j['id'] as String,
    name: j['name'] as String,
    areaId: j['areaId'] as String?,
    x: (j['x'] as num).toInt(),
    y: (j['y'] as num).toInt(),
    w: (j['w'] as num).toInt(),
    h: (j['h'] as num).toInt(),
  );

  final String id;
  final String name;

  /// HA-Bereich, optional.
  final String? areaId;
  final int x;
  final int y;
  final int w;
  final int h;

  /// Rechteck in Zellen.
  Rect get rect =>
      Rect.fromLTWH(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble());

  FloorRoom copyWith({
    String? name,
    String? areaId,
    bool clearArea = false,
    int? x,
    int? y,
    int? w,
    int? h,
  }) => FloorRoom(
    id: id,
    name: name ?? this.name,
    areaId: clearArea ? null : (areaId ?? this.areaId),
    x: x ?? this.x,
    y: y ?? this.y,
    w: w ?? this.w,
    h: h ?? this.h,
  );

  /// Überlappung der Flächen. Gemeinsame Kanten zählen nicht.
  bool overlaps(FloorRoom o) =>
      x < o.x + o.w && x + w > o.x && y < o.y + o.h && y + h > o.y;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'areaId': areaId,
    'x': x,
    'y': y,
    'w': w,
    'h': h,
  };

  @override
  bool operator ==(Object other) =>
      other is FloorRoom &&
      other.id == id &&
      other.name == name &&
      other.areaId == areaId &&
      other.x == x &&
      other.y == y &&
      other.w == w &&
      other.h == h;

  @override
  int get hashCode => Object.hash(id, name, areaId, x, y, w, h);
}

/// Ein Punkt relativ zu einem Raum (rx, ry in 0..1).
@immutable
class PlanPoint {
  const PlanPoint(this.roomId, this.rx, this.ry);
  final String roomId;
  final double rx;
  final double ry;

  @override
  bool operator ==(Object other) =>
      other is PlanPoint &&
      other.roomId == roomId &&
      other.rx == rx &&
      other.ry == ry;

  @override
  int get hashCode => Object.hash(roomId, rx, ry);

  @override
  String toString() => 'PlanPoint($roomId, $rx, $ry)';
}

/// Platzierung eines Geräts in einem Raum. [entityId] ist die Hauptentity
/// des Geräts (Lampe, Schalter, Temperatur, Melder), die übrigen Entities
/// des Geräts erben die Position. [deviceId] (IEEE bei Zigbee, sonst die
/// HA-Geräte-ID) ist optional und additiv: Pläne ohne sie bleiben gültig,
/// `migrateDevices` ergänzt sie.
@immutable
class FloorPlacement {
  const FloorPlacement({
    required this.entityId,
    required this.roomId,
    required this.rx,
    required this.ry,
    this.kind,
    this.deviceId,
  });

  factory FloorPlacement.fromJson(Map<String, dynamic> j) => FloorPlacement(
    entityId: j['entityId'] as String,
    roomId: j['roomId'] as String,
    rx: (j['rx'] as num).toDouble(),
    ry: (j['ry'] as num).toDouble(),
    kind: FloorKind.fromJson(j['kind']),
    deviceId: j['deviceId'] as String?,
  );

  final String entityId;
  final String roomId;
  final double rx;
  final double ry;
  final FloorKind? kind;
  final String? deviceId;

  FloorKind get resolvedKind => kind ?? FloorKind.ofEntity(entityId);
  PlanPoint get point => PlanPoint(roomId, rx, ry);

  Map<String, dynamic> toJson() => {
    'entityId': entityId,
    'roomId': roomId,
    'rx': rx,
    'ry': ry,
    if (kind != null) 'kind': kind!.json,
    if (deviceId != null) 'deviceId': deviceId,
  };

  FloorPlacement copyWith({
    String? entityId,
    String? deviceId,
    FloorKind? kind,
  }) => FloorPlacement(
    entityId: entityId ?? this.entityId,
    roomId: roomId,
    rx: rx,
    ry: ry,
    kind: kind ?? this.kind,
    deviceId: deviceId ?? this.deviceId,
  );

  @override
  bool operator ==(Object other) =>
      other is FloorPlacement &&
      other.entityId == entityId &&
      other.roomId == roomId &&
      other.rx == rx &&
      other.ry == ry &&
      other.kind == kind &&
      other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(entityId, roomId, rx, ry, kind, deviceId);
}

/// Ein Gerät für die Positionsableitung: Entity-IDs mit der Hauptentity
/// zuerst, dazu der Raum (Plan-Raum-ID oder Bereichs-ID) oder `null`.
@immutable
class FloorDevice {
  const FloorDevice(this.id, this.entityIds, {this.roomId});
  final String id;
  final List<String> entityIds;
  final String? roomId;
}

/// Grundriss nach Spec 5: Raster, Räume als Rechtecke, Platzierungen relativ
/// zum Raum. Unveränderlich, Änderungen liefern eine neue Instanz.
///
/// Das Dokument ist der Speicherinhalt (`toJson`). Geplanter Speicherort ist
/// die Haven-Integration in HA (`.storage`), siehe `FloorPlanRepository`.
@immutable
class HavenFloorPlan {
  const HavenFloorPlan({
    this.version = 1,
    this.grid = const FloorGrid(),
    this.rooms = const [],
    this.placements = const [],
    this.coordinator,
  });

  factory HavenFloorPlan.fromJson(Map<String, dynamic> j) {
    final version = (j['version'] as num?)?.toInt();
    if (version != 1) {
      throw FormatException('Unbekannte Grundriss-Version: $version');
    }
    final c = j['coordinator'];
    return HavenFloorPlan(
      grid: FloorGrid.fromJson(Map<String, dynamic>.from(j['grid'] as Map)),
      rooms: [
        for (final r in (j['rooms'] as List))
          FloorRoom.fromJson(Map<String, dynamic>.from(r as Map)),
      ],
      placements: [
        for (final p in (j['placements'] as List))
          FloorPlacement.fromJson(Map<String, dynamic>.from(p as Map)),
      ],
      coordinator: c == null
          ? null
          : PlanPoint(
              (c as Map)['roomId'] as String,
              (c['rx'] as num).toDouble(),
              (c['ry'] as num).toDouble(),
            ),
    );
  }

  factory HavenFloorPlan.decode(String s) =>
      HavenFloorPlan.fromJson(jsonDecode(s) as Map<String, dynamic>);

  final int version;
  final FloorGrid grid;
  final List<FloorRoom> rooms;
  final List<FloorPlacement> placements;

  /// Position des Zigbee-Koordinators (Stick), frei setzbar wie eine Entity.
  final PlanPoint? coordinator;

  Map<String, dynamic> toJson() => {
    'version': version,
    'grid': grid.toJson(),
    'rooms': [for (final r in rooms) r.toJson()],
    'placements': [for (final p in placements) p.toJson()],
    if (coordinator != null)
      'coordinator': {
        'roomId': coordinator!.roomId,
        'rx': coordinator!.rx,
        'ry': coordinator!.ry,
      },
  };

  String encode() => jsonEncode(toJson());

  bool get isEmpty => rooms.isEmpty;

  // ---- Suche ----------------------------------------------------------

  FloorRoom? room(String id) {
    for (final r in rooms) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// Raum nach Plan-ID, danach nach Bereichs-ID.
  FloorRoom? roomByIdOrArea(String id) {
    final r = room(id);
    if (r != null) return r;
    for (final r in rooms) {
      if (r.areaId == id) return r;
    }
    return null;
  }

  FloorPlacement? placementOf(String entityId) {
    for (final p in placements) {
      if (p.entityId == entityId) return p;
    }
    return null;
  }

  Set<String> get placedEntityIds => {for (final p in placements) p.entityId};

  /// Raum, der die Zelle [cell] enthält (Zellkoordinaten), sonst `null`.
  FloorRoom? roomAtCell(Offset cell) {
    for (final r in rooms) {
      if (r.rect.contains(cell)) return r;
    }
    return null;
  }

  // ---- Prüfung --------------------------------------------------------

  /// Meldet jeden Verstoß gegen die Regeln aus Spec 5 (leer = gültig).
  List<String> validate() {
    final e = <String>[];
    if (grid.cols < 4 || grid.rows < 4) e.add('Raster zu klein');
    final ids = <String>{};
    for (final r in rooms) {
      if (!ids.add(r.id)) e.add('Raum-ID doppelt: ${r.id}');
      if (r.w < kMinRoomCells || r.h < kMinRoomCells) {
        e.add('${r.name} ist kleiner als $kMinRoomCells x $kMinRoomCells');
      }
      if (r.x < 0 ||
          r.y < 0 ||
          r.x + r.w > grid.cols ||
          r.y + r.h > grid.rows) {
        e.add('${r.name} liegt außerhalb des Rasters');
      }
    }
    for (var i = 0; i < rooms.length; i++) {
      for (var j = i + 1; j < rooms.length; j++) {
        if (rooms[i].overlaps(rooms[j])) {
          e.add('${rooms[i].name} überlappt ${rooms[j].name}');
        }
      }
    }
    final seen = <String>{};
    for (final p in placements) {
      if (!seen.add(p.entityId)) e.add('Platzierung doppelt: ${p.entityId}');
      if (!ids.contains(p.roomId)) e.add('${p.entityId}: Raum fehlt');
      if (p.rx < 0 || p.rx > 1 || p.ry < 0 || p.ry > 1) {
        e.add('${p.entityId}: Position außerhalb des Raums');
      }
    }
    final c = coordinator;
    if (c != null) {
      if (!ids.contains(c.roomId)) e.add('Koordinator: Raum fehlt');
      if (c.rx < 0 || c.rx > 1 || c.ry < 0 || c.ry > 1) {
        e.add('Koordinator: Position außerhalb des Raums');
      }
    }
    return e;
  }

  bool get isValid => validate().isEmpty;

  /// `null`, wenn [r] (neu oder geändert) passt, sonst der Grund.
  String? roomProblem(FloorRoom r) {
    if (r.w < kMinRoomCells || r.h < kMinRoomCells) {
      return 'Mindestens $kMinRoomCells x $kMinRoomCells Zellen';
    }
    if (r.x < 0 || r.y < 0 || r.x + r.w > grid.cols || r.y + r.h > grid.rows) {
      return 'Außerhalb des Rasters';
    }
    for (final o in rooms) {
      if (o.id != r.id && o.overlaps(r)) return 'Überlappt ${o.name}';
    }
    return null;
  }

  // ---- Änderungen -----------------------------------------------------

  HavenFloorPlan copyWith({
    FloorGrid? grid,
    List<FloorRoom>? rooms,
    List<FloorPlacement>? placements,
    PlanPoint? coordinator,
    bool clearCoordinator = false,
  }) => HavenFloorPlan(
    grid: grid ?? this.grid,
    rooms: rooms ?? this.rooms,
    placements: placements ?? this.placements,
    coordinator: clearCoordinator ? null : (coordinator ?? this.coordinator),
  );

  /// Fügt den Raum an oder ersetzt den mit gleicher ID.
  HavenFloorPlan withRoom(FloorRoom r) {
    final i = rooms.indexWhere((x) => x.id == r.id);
    final l = [...rooms];
    if (i < 0) {
      l.add(r);
    } else {
      l[i] = r;
    }
    return copyWith(rooms: l);
  }

  /// Entfernt den Raum samt Platzierungen (die Entities kehren in den Pool
  /// zurück) und den Koordinator, falls er dort stand.
  HavenFloorPlan withoutRoom(String id) => HavenFloorPlan(
    grid: grid,
    rooms: [
      for (final r in rooms)
        if (r.id != id) r,
    ],
    placements: [
      for (final p in placements)
        if (p.roomId != id) p,
    ],
    coordinator: coordinator?.roomId == id ? null : coordinator,
  );

  HavenFloorPlan withPlacement(FloorPlacement p) => copyWith(
    placements: [
      for (final x in placements)
        if (x.entityId != p.entityId) x,
      p,
    ],
  );

  HavenFloorPlan withoutPlacement(String entityId) => copyWith(
    placements: [
      for (final x in placements)
        if (x.entityId != entityId) x,
    ],
  );

  /// Fügt mehrere Platzierungen an (gleiche Entity wird ersetzt).
  HavenFloorPlan withPlacements(Iterable<FloorPlacement> ps) {
    final ids = {for (final p in ps) p.entityId};
    return copyWith(
      placements: [
        for (final x in placements)
          if (!ids.contains(x.entityId)) x,
        ...ps,
      ],
    );
  }

  /// Stellt alte Pläne (eine Platzierung je Entity) auf Geräte um: Jede
  /// Platzierung einer Entity aus [devices] wandert auf die Hauptentity des
  /// Geräts (erste in der Liste) und bekommt `deviceId`. Hat ein Gerät
  /// mehrere Platzierungen, bleibt die der Hauptentity, sonst die erste.
  /// [kinds] setzt die Darstellung je Gerät. Unbekannte Entities bleiben.
  HavenFloorPlan migrateDevices(
    Iterable<FloorDevice> devices, {
    Map<String, FloorKind> kinds = const {},
  }) {
    final byEntity = <String, FloorDevice>{};
    for (final d in devices) {
      if (d.entityIds.isEmpty) continue;
      for (final e in d.entityIds) {
        byEntity.putIfAbsent(e, () => d);
      }
    }
    final chosen = <String, FloorPlacement>{};
    final fromMain = <String>{};
    final out = <FloorPlacement>[];
    for (final p in placements) {
      final d =
          (p.deviceId == null ? null : _deviceById(devices, p.deviceId!)) ??
          byEntity[p.entityId];
      if (d == null) {
        out.add(p);
        continue;
      }
      final isMain = p.entityId == d.entityIds.first;
      if (chosen.containsKey(d.id) && (fromMain.contains(d.id) || !isMain)) {
        continue;
      }
      if (isMain) fromMain.add(d.id);
      chosen[d.id] = p.copyWith(
        entityId: d.entityIds.first,
        deviceId: d.id,
        kind: kinds[d.id] ?? p.kind,
      );
    }
    final next = copyWith(placements: [...out, ...chosen.values]);
    return next == this ? this : next;
  }

  static FloorDevice? _deviceById(Iterable<FloorDevice> ds, String id) {
    for (final d in ds) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// Raster in der Raummitte für [count] Geräte, als relative Punkte.
  /// Abstand etwa 1,6 Zellen, höchstens 80 % des Raums, Zeile für Zeile.
  static List<(double, double)> quickGrid(FloorRoom room, int count) {
    if (count <= 0) return const [];
    final aspect = room.w / room.h;
    var cols = math.max(1, math.sqrt(count * aspect).round());
    cols = math.min(cols, count);
    final rows = (count / cols).ceil();
    final stepX = math.min(1.6 / room.w, 0.8 / math.max(1, cols - 1));
    final stepY = math.min(1.6 / room.h, 0.8 / math.max(1, rows - 1));
    final out = <(double, double)>[];
    for (var i = 0; i < count; i++) {
      final r = i ~/ cols;
      final inRow = r == rows - 1 ? count - r * cols : cols;
      final c = i % cols;
      final x = 0.5 + (c - (inRow - 1) / 2) * stepX;
      final y = 0.5 + (r - (rows - 1) / 2) * stepY;
      double clip(double v) => (v.clamp(0.08, 0.92) * 100).round() / 100;
      out.add((clip(x), clip(y)));
    }
    return out;
  }

  HavenFloorPlan withCoordinator(PlanPoint? p) =>
      p == null ? copyWith(clearCoordinator: true) : copyWith(coordinator: p);

  // ---- Layout und Positionen -------------------------------------------

  /// Raumrechtecke in Zellen mit zusätzlichem Abstand [gap] (Zellen) zwischen
  /// allen Räumen. Die Räume behalten ihre Größe. Jede neue linke (obere)
  /// Kante, die weiter rechts (unten) liegt als eine andere, rückt um [gap]
  /// weiter weg. So bekommt jedes Nachbarpaar mindestens [gap] Abstand, und
  /// der Verlauf ist für Bruchwerte stetig (Animation 0 bis 2).
  Map<String, Rect> layout({double gap = 0}) {
    final xs = ({for (final r in rooms) r.x}.toList()..sort());
    final ys = ({for (final r in rooms) r.y}.toList()..sort());
    return {
      for (final r in rooms)
        r.id: Rect.fromLTWH(
          r.x + gap * xs.indexOf(r.x),
          r.y + gap * ys.indexOf(r.y),
          r.w.toDouble(),
          r.h.toDouble(),
        ),
    };
  }

  /// Umschließendes Rechteck aller Räume bei Abstand [gap] (Zellen).
  Rect layoutBounds({double gap = 0}) {
    final l = layout(gap: gap).values;
    if (l.isEmpty) {
      return Rect.fromLTWH(0, 0, grid.cols.toDouble(), grid.rows.toDouble());
    }
    return l.reduce((a, b) => a.expandToInclude(b));
  }

  Size layoutSize({double gap = 0}) => layoutBounds(gap: gap).size;

  /// Zellposition eines Punkts. Mit [layoutRects] aus [layout], sonst Abstand 0.
  Offset cellOf(PlanPoint p, {Map<String, Rect>? layoutRects}) {
    final rects = layoutRects ?? layout();
    final r = rects[p.roomId];
    if (r == null) return Offset.zero;
    return Offset(r.left + p.rx * r.width, r.top + p.ry * r.height);
  }

  /// Raumrelativer Punkt einer Entity oder `null`, wenn nicht platziert.
  PlanPoint? entityPoint(String entityId) => placementOf(entityId)?.point;

  /// Position einer Entity in Zellen (Abstand [gap]) oder `null`.
  Offset? entityPosition(String entityId, {double gap = 0}) {
    final p = entityPoint(entityId);
    return p == null ? null : cellOf(p, layoutRects: layout(gap: gap));
  }

  /// Position des Koordinators in Zellen oder `null`.
  Offset? coordinatorPosition({double gap = 0}) {
    final p = coordinator;
    return p == null ? null : cellOf(p, layoutRects: layout(gap: gap));
  }

  /// Punkte aller Geräte, die sich verorten lassen.
  ///
  /// 1. Das Gerät nimmt die Platzierung seiner ersten platzierten Entity.
  /// 2. Sonst liegt es in der Raummitte seines Raums. Mehrere davon liegen im
  ///    kleinen Kreis um die Mitte, damit sie sich nicht überdecken.
  /// 3. Geräte ohne Platzierung und ohne bekannten Raum fehlen im Ergebnis.
  Map<String, PlanPoint> devicePoints(Iterable<FloorDevice> devices) {
    final out = <String, PlanPoint>{};
    final byRoom = <String, List<FloorDevice>>{};
    for (final d in devices) {
      PlanPoint? p;
      for (final id in d.entityIds) {
        p = entityPoint(id);
        if (p != null) break;
      }
      if (p != null) {
        out[d.id] = p;
        continue;
      }
      final room = d.roomId == null ? null : roomByIdOrArea(d.roomId!);
      if (room != null) (byRoom[room.id] ??= []).add(d);
    }
    for (final e in byRoom.entries) {
      final room = this.room(e.key)!;
      final n = e.value.length;
      if (n == 1) {
        out[e.value.first.id] = PlanPoint(room.id, 0.5, 0.5);
        continue;
      }
      // Radius in Zellen: wächst mit der Zahl, bleibt im Raum.
      final r = math.min(
        0.3 * math.min(room.w, room.h),
        math.max(1.0, 0.22 * n),
      );
      for (var i = 0; i < n; i++) {
        final a = -math.pi / 2 + 2 * math.pi * i / n;
        out[e.value[i].id] = PlanPoint(
          room.id,
          0.5 + math.cos(a) * r / room.w,
          0.5 + math.sin(a) * r / room.h,
        );
      }
    }
    return out;
  }

  /// Position eines einzelnen Geräts in Zellen (Abstand [gap]), siehe
  /// [devicePoints]. Für mehrere Geräte lieber [devicePoints] aufrufen,
  /// sonst fehlt der Kreis um die Raummitte.
  Offset? devicePosition(FloorDevice d, {double gap = 0}) {
    final p = devicePoints([d])[d.id];
    return p == null ? null : cellOf(p, layoutRects: layout(gap: gap));
  }

  @override
  bool operator ==(Object other) =>
      other is HavenFloorPlan &&
      other.grid == grid &&
      listEquals(other.rooms, rooms) &&
      listEquals(other.placements, placements) &&
      other.coordinator == coordinator;

  @override
  int get hashCode => Object.hash(
    grid,
    Object.hashAll(rooms),
    Object.hashAll(placements),
    coordinator,
  );
}
