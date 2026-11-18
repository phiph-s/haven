import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/foundation.dart';

import 'furniture.dart';
import 'polygon.dart';

export 'furniture.dart';
export 'polygon.dart' show GridPoint, PointLocation;

/// Aktuelle Schema-Version des Grundrisses. Version 1 (Rechtecke, relative
/// Platzierungen) wird beim Laden umgestellt und mit 2 gespeichert.
const int kFloorPlanVersion = 2;

/// Fester Ort „Draußen“: alles im Raster, was in keinem Raum liegt.
const String kOutsideId = 'outside';
const String kOutsideName = 'Draußen';

/// Kleinste Raumfläche in Zellen.
const double kMinRoomArea = 4;

/// Rand um die Wohnung, um den Version-1-Pläne beim Umstellen wachsen, damit
/// „Draußen“ Platz hat.
const int kMigrateMargin = 3;

/// Raster: eine Zelle ist ungefähr [cellMeters] groß.
@immutable
class FloorGrid {
  const FloorGrid({this.cols = 26, this.rows = 32, this.cellMeters = 0.5});

  factory FloorGrid.fromJson(Map<String, dynamic> j) => FloorGrid(
    cols: (j['cols'] as num).toInt(),
    rows: (j['rows'] as num).toInt(),
    cellMeters: (j['cellMeters'] as num?)?.toDouble() ?? 0.5,
  );

  final int cols;
  final int rows;
  final double cellMeters;

  Rect get rect => Rect.fromLTWH(0, 0, cols.toDouble(), rows.toDouble());

  bool containsCell(int x, int y) => x >= 0 && y >= 0 && x < cols && y < rows;

  FloorGrid copyWith({int? cols, int? rows}) => FloorGrid(
    cols: cols ?? this.cols,
    rows: rows ?? this.rows,
    cellMeters: cellMeters,
  );

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

/// Einstellungen für „Draußen“: [margin] Zellen Rand um die Wohnung, die die
/// Karte als Außenbereich zeigt (im Raster).
@immutable
class FloorOutside {
  const FloorOutside({this.margin = 3});

  factory FloorOutside.fromJson(Object? j) => j is Map
      ? FloorOutside(margin: (j['margin'] as num?)?.toInt() ?? 3)
      : const FloorOutside();

  final int margin;

  Map<String, dynamic> toJson() => {'margin': margin};

  @override
  bool operator ==(Object other) =>
      other is FloorOutside && other.margin == margin;

  @override
  int get hashCode => margin.hashCode;
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

class _RoomGeo {
  _RoomGeo(List<GridPoint> pts) : offsets = [for (final p in pts) p.offset] {
    bounds = polygonBounds(offsets);
    area = polygonArea(offsets);
    centroid = polygonCentroid(offsets);
  }
  final List<Offset> offsets;
  late final Rect bounds;
  late final double area;
  late final Offset centroid;
  late final Rect inner = largestInnerRect(offsets);
}

final _geoCache = Expando<_RoomGeo>('room-geo');

/// Ein Raum: Polygon, dessen Ecken auf Rasterpunkten liegen. Kanten dürfen
/// schräg sein, die Form darf L-förmig sein oder Nischen haben.
@immutable
class FloorRoom {
  const FloorRoom({
    required this.id,
    required this.name,
    required this.points,
    this.areaId,
    this.detached = false,
    this.open = const {},
  });

  /// Rechteck aus Zellen (wie in Version 1).
  factory FloorRoom.rect({
    required String id,
    required String name,
    required int x,
    required int y,
    required int w,
    required int h,
    String? areaId,
    bool detached = false,
  }) => FloorRoom(
    id: id,
    name: name,
    areaId: areaId,
    detached: detached,
    points: [
      GridPoint(x, y),
      GridPoint(x + w, y),
      GridPoint(x + w, y + h),
      GridPoint(x, y + h),
    ],
  );

  factory FloorRoom.fromJson(Map<String, dynamic> j) => FloorRoom(
    id: j['id'] as String,
    name: j['name'] as String,
    areaId: j['areaId'] as String?,
    points: [for (final p in (j['points'] as List)) GridPoint.fromJson(p)],
    open: {
      for (final i in (j['open'] as List?) ?? const [])
        if (i is int) i,
    },
  );

  final String id;
  final String name;

  /// HA-Bereich, optional.
  final String? areaId;

  /// Ecken in Reihenfolge (Uhrzeigersinn oder Gegenrichtung).
  final List<GridPoint> points;

  /// Gehört nicht zur Wohnung (z. B. „Ohne Raum“ im Netzgraph): zählt nicht
  /// für Umriss und Draußen. Wird nie gespeichert.
  final bool detached;

  /// Offene Kanten (Kante i führt von Ecke i zur nächsten): Raumgrenze ohne
  /// Wand, z. B. zwischen Küche und Wohnbereich.
  final Set<int> open;

  /// Ist Kante [edge] offen?
  bool isOpen(int edge) => open.contains(edge);

  _RoomGeo get _geo => _geoCache[this] ??= _RoomGeo(points);

  /// Ecken als Offsets (Zellen).
  List<Offset> get offsets => _geo.offsets;

  /// Umschließendes Rechteck in Zellen.
  Rect get bounds => _geo.bounds;

  /// Fläche in Zellen.
  double get area => _geo.area;

  Offset get centroid => _geo.centroid;

  /// Größtes Rechteck aus vollen Zellen (Beschriftung, Mitte).
  Rect get innerRect => _geo.inner;

  /// Mitte für Geräte ohne Platzierung: liegt sicher im Raum.
  Offset get anchor => innerRect.center;

  PointLocation locate(Offset p) => locatePoint(offsets, p);

  /// Punkt im Raum oder auf dem Rand.
  bool contains(Offset p) => locate(p) != PointLocation.outside;

  /// Liegt die Mitte der Zelle im Raum (Rand zählt)?
  bool containsCell(int x, int y) => contains(Offset(x + 0.5, y + 0.5));

  /// Überlappung der Flächen. Gemeinsame Kanten und Ecken zählen nicht.
  bool overlaps(FloorRoom o) => polygonsOverlap(offsets, o.offsets);

  FloorRoom translate(int dx, int dy) =>
      copyWith(points: [for (final p in points) p.translate(dx, dy)]);

  FloorRoom copyWith({
    String? name,
    String? areaId,
    bool clearArea = false,
    List<GridPoint>? points,
    Set<int>? open,
  }) => FloorRoom(
    id: id,
    name: name ?? this.name,
    areaId: clearArea ? null : (areaId ?? this.areaId),
    points: points ?? this.points,
    detached: detached,
    open: open ?? this.open,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'areaId': areaId,
    'points': [for (final p in points) p.toJson()],
    if (open.isNotEmpty) 'open': [...open]..sort(),
  };

  @override
  bool operator ==(Object other) =>
      other is FloorRoom &&
      other.id == id &&
      other.name == name &&
      other.areaId == areaId &&
      other.detached == detached &&
      listEquals(other.points, points) &&
      setEquals(other.open, open);

  @override
  int get hashCode =>
      Object.hash(id, name, areaId, Object.hashAll(points), open.length);

  @override
  String toString() => 'FloorRoom($id, $points)';
}

/// Ein Punkt im Grundriss in Zellen ([x], [y] als Kommazahl, die Mitte der
/// Zelle (2, 3) ist (2,5; 3,5)) und der Ort, zu dem er gehört ([roomId] oder
/// [kOutsideId]). Der Ort entscheidet, mit welchem Raum der Punkt wandert,
/// wenn die Räume auseinanderrücken.
@immutable
class PlanPoint {
  const PlanPoint(this.x, this.y, this.roomId);
  final double x;
  final double y;
  final String roomId;

  Offset get offset => Offset(x, y);

  /// Rasterzelle des Punkts.
  GridPoint get cell => GridPoint(x.floor(), y.floor());

  bool get isOutside => roomId == kOutsideId;

  @override
  bool operator ==(Object other) =>
      other is PlanPoint &&
      other.roomId == roomId &&
      other.x == x &&
      other.y == y;

  @override
  int get hashCode => Object.hash(roomId, x, y);

  @override
  String toString() => 'PlanPoint($roomId, $x, $y)';
}

/// Platzierung eines Geräts auf einer Rasterzelle ([x], [y]). [entityId] ist
/// die Hauptentity des Geräts (Lampe, Schalter, Temperatur, Melder), die
/// übrigen Entities erben die Position. [deviceId] (IEEE bei Zigbee, sonst
/// die HA-Geräte-ID) ist optional. Der Ort (Raum oder Draußen) ergibt sich
/// aus der Lage, siehe [HavenFloorPlan.locationOfCell].
@immutable
class FloorPlacement {
  const FloorPlacement({
    required this.entityId,
    required this.x,
    required this.y,
    this.kind,
    this.deviceId,
    this.model,
    this.height,
  });

  factory FloorPlacement.fromJson(Map<String, dynamic> j) => FloorPlacement(
    entityId: j['entityId'] as String,
    x: (j['x'] as num).floor(),
    y: (j['y'] as num).floor(),
    kind: FloorKind.fromJson(j['kind']),
    deviceId: j['deviceId'] as String?,
    model: j['model'] is String ? j['model'] as String : null,
    height: (j['height'] is num && (j['height'] as num).isFinite)
        ? (j['height'] as num).toDouble()
        : null,
  );

  final String entityId;
  final int x;
  final int y;
  final FloorKind? kind;
  final String? deviceId;

  /// Bauform in 3D (z. B. `pendant`, `floor_lamp`, `trv`), `null`: passend
  /// zur Art (siehe 3D-Katalog der Geräte).
  final String? model;

  /// Höhe über dem Boden in Metern, `null`: Standard der Bauform.
  final double? height;

  FloorKind get resolvedKind => kind ?? FloorKind.ofEntity(entityId);
  GridPoint get cell => GridPoint(x, y);

  /// Mitte der Zelle in Zellen.
  Offset get center => Offset(x + 0.5, y + 0.5);

  Map<String, dynamic> toJson() => {
    'entityId': entityId,
    'x': x,
    'y': y,
    if (kind != null) 'kind': kind!.json,
    if (deviceId != null) 'deviceId': deviceId,
    if (model != null) 'model': model,
    if (height != null) 'height': (height! * 100).roundToDouble() / 100,
  };

  FloorPlacement copyWith({
    String? entityId,
    String? deviceId,
    FloorKind? kind,
    int? x,
    int? y,
    String? model,
    bool clearModel = false,
    double? height,
    bool clearHeight = false,
  }) => FloorPlacement(
    entityId: entityId ?? this.entityId,
    x: x ?? this.x,
    y: y ?? this.y,
    kind: kind ?? this.kind,
    deviceId: deviceId ?? this.deviceId,
    model: clearModel ? null : (model ?? this.model),
    height: clearHeight ? null : (height ?? this.height),
  );

  @override
  bool operator ==(Object other) =>
      other is FloorPlacement &&
      other.entityId == entityId &&
      other.x == x &&
      other.y == y &&
      other.kind == kind &&
      other.deviceId == deviceId &&
      other.model == model &&
      other.height == height;

  @override
  int get hashCode =>
      Object.hash(entityId, x, y, kind, deviceId, model, height);

  @override
  String toString() => 'FloorPlacement($entityId @ $x, $y)';
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

/// Grundriss (Schema-Version 2): Raster, Räume als Polygone auf Rasterpunkten,
/// Platzierungen als Rasterzellen, „Draußen“ als fester Ort um die Wohnung.
/// Unveränderlich, Änderungen liefern eine neue Instanz.
///
/// Version-1-Dokumente (Rechtecke `x,y,w,h`, Platzierungen `roomId,rx,ry`)
/// werden in [HavenFloorPlan.fromJson] umgestellt: Räume werden Polygone,
/// Platzierungen absolute Zellen, alles rückt um [kMigrateMargin] nach
/// rechts unten und das Raster wächst entsprechend.
@immutable
class HavenFloorPlan {
  const HavenFloorPlan({
    this.version = kFloorPlanVersion,
    this.grid = const FloorGrid(),
    this.rooms = const [],
    this.placements = const [],
    this.coordinator,
    this.outside = const FloorOutside(),
    this.updatedAt,
    this.migratedFrom,
    this.furniture = const [],
  });

  factory HavenFloorPlan.fromJson(Map<String, dynamic> j) {
    final version = (j['version'] as num?)?.toInt();
    if (version == 1) return _fromV1(j);
    if (version != 2) {
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
      coordinator: c == null ? null : GridPoint.fromJson(c),
      outside: FloorOutside.fromJson(j['outside']),
      updatedAt: (j['updatedAt'] as num?)?.toInt(),
      furniture: _furnitureFromJson(j['furniture']),
    );
  }

  /// Möbel sind optional (seit App 0.6). Unbrauchbare Einträge fallen weg,
  /// doppelte IDs behalten den ersten.
  static List<FloorFurniture> _furnitureFromJson(Object? raw) {
    if (raw is! List) return const [];
    final seen = <String>{};
    return [
      for (final f in raw.map(FloorFurniture.tryFromJson))
        if (f != null && seen.add(f.id)) f,
    ];
  }

  /// Version 1: Räume als Rechtecke, Platzierungen relativ zum Raum.
  static HavenFloorPlan _fromV1(Map<String, dynamic> j) {
    const m = kMigrateMargin;
    final g = FloorGrid.fromJson(Map<String, dynamic>.from(j['grid'] as Map));
    final rects = <String, (int, int, int, int)>{};
    final rooms = <FloorRoom>[];
    for (final raw in (j['rooms'] as List)) {
      final r = Map<String, dynamic>.from(raw as Map);
      final x = (r['x'] as num).toInt() + m;
      final y = (r['y'] as num).toInt() + m;
      final w = (r['w'] as num).toInt();
      final h = (r['h'] as num).toInt();
      rects[r['id'] as String] = (x, y, w, h);
      rooms.add(
        FloorRoom.rect(
          id: r['id'] as String,
          name: r['name'] as String,
          areaId: r['areaId'] as String?,
          x: x,
          y: y,
          w: w,
          h: h,
        ),
      );
    }
    GridPoint? cellOf(String roomId, num rx, num ry) {
      final r = rects[roomId];
      if (r == null) return null;
      final (x, y, w, h) = r;
      return GridPoint(
        x + (rx * w).floor().clamp(0, math.max(0, w - 1)),
        y + (ry * h).floor().clamp(0, math.max(0, h - 1)),
      );
    }

    final placements = <FloorPlacement>[];
    for (final raw in (j['placements'] as List)) {
      final p = Map<String, dynamic>.from(raw as Map);
      final c = cellOf(p['roomId'] as String, p['rx'] as num, p['ry'] as num);
      if (c == null) continue;
      placements.add(
        FloorPlacement(
          entityId: p['entityId'] as String,
          x: c.x,
          y: c.y,
          kind: FloorKind.fromJson(p['kind']),
          deviceId: p['deviceId'] as String?,
        ),
      );
    }
    final co = j['coordinator'];
    final coord = co is Map
        ? cellOf(co['roomId'] as String, co['rx'] as num, co['ry'] as num)
        : null;
    return HavenFloorPlan(
      grid: g.copyWith(cols: g.cols + 2 * m, rows: g.rows + 2 * m),
      rooms: rooms,
      placements: placements,
      coordinator: coord,
      updatedAt: (j['updatedAt'] as num?)?.toInt(),
      migratedFrom: 1,
    );
  }

  factory HavenFloorPlan.decode(String s) =>
      HavenFloorPlan.fromJson(jsonDecode(s) as Map<String, dynamic>);

  final int version;
  final FloorGrid grid;
  final List<FloorRoom> rooms;
  final List<FloorPlacement> placements;

  /// Zelle des Zigbee-Koordinators (Stick), frei setzbar wie eine Entity.
  final GridPoint? coordinator;
  final FloorOutside outside;

  /// Stempel des Abgleichs (ms), steht im Dokument. Zählt nicht für `==`.
  final int? updatedAt;

  /// Aus welcher Version dieser Stand umgestellt wurde (`null` = keine).
  /// Nur im Speicher, zählt nicht für `==`.
  final int? migratedFrom;

  /// Möbel, nur optisch (siehe [FloorFurniture]). Optionales Feld im Schema 2:
  /// `toJson` schreibt es immer, auch leer. Daran erkennt die Integration
  /// ältere Clients, die es nicht kennen, und behält beim Speichern die
  /// vorhandenen Möbel (siehe `ARCHITECTURE.md`, „Möbel“).
  final List<FloorFurniture> furniture;

  Map<String, dynamic> toJson() => {
    'version': kFloorPlanVersion,
    'grid': grid.toJson(),
    'rooms': [
      for (final r in rooms)
        if (!r.detached) r.toJson(),
    ],
    'placements': [for (final p in placements) p.toJson()],
    if (coordinator != null) 'coordinator': coordinator!.toJson(),
    'outside': outside.toJson(),
    if (updatedAt != null) 'updatedAt': updatedAt,
    'furniture': [for (final f in furniture) f.toJson()],
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

  /// Raum am Punkt [p] (Zellen, Rand zählt), sonst `null`. Bei einem Punkt
  /// auf einer gemeinsamen Kante gewinnt der Raum, der ihn im Inneren hat,
  /// sonst der erste.
  FloorRoom? roomAt(Offset p) {
    FloorRoom? edge;
    for (final r in rooms) {
      if (!r.bounds.inflate(1e-6).contains(p)) continue;
      switch (r.locate(p)) {
        case PointLocation.inside:
          return r;
        case PointLocation.boundary:
          edge ??= r;
        case PointLocation.outside:
      }
    }
    return edge;
  }

  /// Ort der Zelle: Raum-ID oder [kOutsideId].
  String locationOfCell(int x, int y) =>
      roomAt(Offset(x + 0.5, y + 0.5))?.id ?? kOutsideId;

  /// Ort einer Platzierung: Raum-ID oder [kOutsideId].
  String locationOf(FloorPlacement p) => locationOfCell(p.x, p.y);

  /// Platzierungen eines Orts (Raum-ID oder [kOutsideId]).
  List<FloorPlacement> placementsAt(String locationId) => [
    for (final p in placements)
      if (locationOf(p) == locationId) p,
  ];

  /// Punkt einer Zelle (Mitte) samt Ort.
  PlanPoint pointOfCell(GridPoint c) =>
      PlanPoint(c.x + 0.5, c.y + 0.5, locationOfCell(c.x, c.y));

  // ---- Prüfung --------------------------------------------------------

  /// Meldet jeden Verstoß (leer = gültig).
  List<String> validate() {
    final e = <String>[];
    if (grid.cols < 4 || grid.rows < 4) e.add('Raster zu klein');
    final ids = <String>{};
    for (final r in rooms) {
      if (!ids.add(r.id)) e.add('Raum-ID doppelt: ${r.id}');
      if (r.id == kOutsideId) e.add('Raum-ID $kOutsideId ist vergeben');
      final shape = polygonShapeProblem(r.offsets, minArea: kMinRoomArea);
      if (shape != null) e.add('${r.name}: $shape');
      if (!_inGrid(r)) e.add('${r.name} liegt außerhalb des Rasters');
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
      if (!grid.containsCell(p.x, p.y)) {
        e.add('${p.entityId}: Position außerhalb des Rasters');
      }
    }
    final c = coordinator;
    if (c != null && !grid.containsCell(c.x, c.y)) {
      e.add('Koordinator: Position außerhalb des Rasters');
    }
    return e;
  }

  bool get isValid => validate().isEmpty;

  bool _inGrid(FloorRoom r) => r.points.every(
    (p) => p.x >= 0 && p.y >= 0 && p.x <= grid.cols && p.y <= grid.rows,
  );

  /// `null`, wenn [r] (neu oder geändert) passt, sonst der Grund.
  String? roomProblem(FloorRoom r) {
    final shape = polygonShapeProblem(r.offsets, minArea: kMinRoomArea);
    if (shape != null) return shape;
    if (!_inGrid(r)) return 'Außerhalb des Rasters';
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
    GridPoint? coordinator,
    bool clearCoordinator = false,
    FloorOutside? outside,
    List<FloorFurniture>? furniture,
  }) => HavenFloorPlan(
    grid: grid ?? this.grid,
    rooms: rooms ?? this.rooms,
    placements: placements ?? this.placements,
    coordinator: clearCoordinator ? null : (coordinator ?? this.coordinator),
    outside: outside ?? this.outside,
    updatedAt: updatedAt,
    migratedFrom: migratedFrom,
    furniture: furniture ?? this.furniture,
  );

  // ---- Möbel ------------------------------------------------------------

  FloorFurniture? furnitureById(String id) {
    for (final f in furniture) {
      if (f.id == id) return f;
    }
    return null;
  }

  /// Fügt das Möbelstück an oder ersetzt das mit gleicher ID (Reihenfolge
  /// bleibt).
  HavenFloorPlan withFurniture(FloorFurniture f) {
    final i = furniture.indexWhere((x) => x.id == f.id);
    final l = [...furniture];
    if (i < 0) {
      l.add(f);
    } else {
      l[i] = f;
    }
    return copyWith(furniture: l);
  }

  HavenFloorPlan withoutFurniture(String id) => copyWith(
    furniture: [
      for (final f in furniture)
        if (f.id != id) f,
    ],
  );

  /// Raum, in dem die Mitte des Möbelstücks liegt, sonst [kOutsideId].
  String locationOfFurniture(FloorFurniture f) =>
      roomAt(f.center)?.id ?? kOutsideId;

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

  /// Entfernt den Raum samt der Geräte darin (sie kehren in den Pool
  /// zurück) und den Koordinator, falls er dort stand.
  HavenFloorPlan withoutRoom(String id) {
    final r = room(id);
    if (r == null) return this;
    final c = coordinator;
    return HavenFloorPlan(
      grid: grid,
      outside: outside,
      updatedAt: updatedAt,
      migratedFrom: migratedFrom,
      rooms: [
        for (final x in rooms)
          if (x.id != id) x,
      ],
      placements: [
        for (final p in placements)
          if (locationOf(p) != id) p,
      ],
      coordinator: c != null && locationOfCell(c.x, c.y) == id ? null : c,
      furniture: [
        for (final f in furniture)
          if (!r.contains(f.center)) f,
      ],
    );
  }

  /// Verschiebt den Raum um ganze Zellen, Geräte und Koordinator darin
  /// wandern mit.
  HavenFloorPlan withRoomMoved(String id, int dx, int dy) {
    final r = room(id);
    if (r == null || (dx == 0 && dy == 0)) return this;
    final c = coordinator;
    return copyWith(
      placements: [
        for (final p in placements)
          locationOf(p) == id ? p.copyWith(x: p.x + dx, y: p.y + dy) : p,
      ],
      coordinator: c != null && locationOfCell(c.x, c.y) == id
          ? c.translate(dx, dy)
          : null,
      furniture: [
        for (final f in furniture)
          r.contains(f.center)
              ? f.moveTo(f.center + Offset(dx.toDouble(), dy.toDouble()))
              : f,
      ],
    ).withRoom(r.translate(dx, dy));
  }

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

  /// Freie Zellen im Raum für [count] Geräte, von der Mitte nach außen, mit
  /// etwa [spacing] Zellen Abstand (bei Platzmangel dichter). [occupied]
  /// sind belegte Zellen.
  static List<GridPoint> quickCells(
    FloorRoom room,
    int count, {
    Set<GridPoint> occupied = const {},
    int spacing = 2,
  }) {
    if (count <= 0) return const [];
    final inside = <GridPoint>[];
    final b = room.bounds;
    for (var y = b.top.floor(); y < b.bottom.ceil(); y++) {
      for (var x = b.left.floor(); x < b.right.ceil(); x++) {
        if (room.locate(Offset(x + 0.5, y + 0.5)) == PointLocation.inside &&
            !occupied.contains(GridPoint(x, y))) {
          inside.add(GridPoint(x, y));
        }
      }
    }
    final a = room.anchor;
    double d(GridPoint c) => (c.center - a).distanceSquared;
    inside.sort((p, q) {
      final c = d(p).compareTo(d(q));
      return c != 0 ? c : (p.y != q.y ? p.y - q.y : p.x - q.x);
    });
    final out = <GridPoint>[];
    for (var s = spacing; s >= 1 && out.length < count; s--) {
      for (final c in inside) {
        if (out.length >= count) break;
        if (out.contains(c)) continue;
        final ok = out.every(
          (o) => math.max((o.x - c.x).abs(), (o.y - c.y).abs()) >= s,
        );
        if (ok) out.add(c);
      }
    }
    // Volles Zimmer: der Rest teilt sich die Mitte (wird gruppiert).
    while (out.length < count) {
      out.add(
        inside.isEmpty ? GridPoint(a.dx.floor(), a.dy.floor()) : inside.first,
      );
    }
    return out;
  }

  /// Freie Zellen draußen für [count] Geräte: auf einem Ring knapp neben der
  /// Wohnung (eine Zelle Abstand), im Uhrzeigersinn ab oben links, mit etwa
  /// [spacing] Zellen Abstand.
  List<GridPoint> outsideCells(int count, {int spacing = 2}) {
    if (count <= 0) return const [];
    final occupied = {for (final p in placements) p.cell};
    final h = houseBounds;
    final l = h.left.round() - 2;
    final t = h.top.round() - 2;
    final r = h.right.round() + 1;
    final b = h.bottom.round() + 1;
    final ring = <GridPoint>[
      for (var x = l; x <= r; x++) GridPoint(x, t),
      for (var y = t + 1; y <= b; y++) GridPoint(r, y),
      for (var x = r - 1; x >= l; x--) GridPoint(x, b),
      for (var y = b - 1; y > t; y--) GridPoint(l, y),
    ];
    final free = [
      for (final c in ring)
        if (grid.containsCell(c.x, c.y) &&
            !occupied.contains(c) &&
            locationOfCell(c.x, c.y) == kOutsideId)
          c,
    ];
    final out = <GridPoint>[];
    for (var s = spacing; s >= 1 && out.length < count; s--) {
      for (final c in free) {
        if (out.length >= count) break;
        if (out.contains(c)) continue;
        if (out.every(
          (o) => math.max((o.x - c.x).abs(), (o.y - c.y).abs()) >= s,
        )) {
          out.add(c);
        }
      }
    }
    while (out.length < count && free.isNotEmpty) {
      out.add(free.first);
    }
    return out;
  }

  HavenFloorPlan withCoordinator(GridPoint? p) =>
      p == null ? copyWith(clearCoordinator: true) : copyWith(coordinator: p);

  // ---- Umriss, Draußen, Abstand -----------------------------------------

  /// Umschließendes Rechteck der Wohnung (ohne abgesetzte Räume) in Zellen.
  Rect get houseBounds {
    Rect? b;
    for (final r in rooms) {
      if (r.detached) continue;
      b = b == null ? r.bounds : b.expandToInclude(r.bounds);
    }
    return b ?? grid.rect;
  }

  /// Außenbereich: Wohnung plus [FloorOutside.margin] im Raster, erweitert um
  /// draußen platzierte Geräte und den Koordinator.
  Rect get outsideRect {
    var r = houseBounds.inflate(outside.margin.toDouble()).intersect(grid.rect);
    for (final p in placements) {
      if (locationOf(p) == kOutsideId) {
        r = r.expandToInclude(Rect.fromLTWH(p.x - 0.5, p.y - 0.5, 2, 2));
      }
    }
    final c = coordinator;
    if (c != null && locationOfCell(c.x, c.y) == kOutsideId) {
      r = r.expandToInclude(Rect.fromLTWH(c.x - 0.5, c.y - 0.5, 2, 2));
    }
    return r.intersect(grid.rect);
  }

  /// Mittelpunkt, von dem aus die Räume auseinanderrücken.
  Offset get explodeCenter => houseBounds.center;

  /// Faktor, um den Abstände zum Mittelpunkt bei [gap] wachsen. Zwei Räume
  /// mit gemeinsamer Kante bekommen so etwa [gap] Zellen Abstand.
  double explodeFactor(double gap) {
    if (gap == 0 || rooms.isEmpty) return 0;
    final sides = [
      for (final r in rooms)
        if (!r.detached) math.min(r.bounds.width, r.bounds.height),
    ]..sort();
    final s = sides.isEmpty ? 8.0 : sides[sides.length ~/ 2].clamp(4.0, 16.0);
    return gap / s;
  }

  /// Verschiebung jedes Raums in Zellen bei Abstand [gap]: jedes Polygon
  /// rückt als Ganzes vom Mittelpunkt weg (Schwerpunkt), die Form bleibt.
  Map<String, Offset> roomOffsets({double gap = 0}) {
    final k = explodeFactor(gap);
    final c = explodeCenter;
    return {
      for (final r in rooms) r.id: k == 0 ? Offset.zero : (r.centroid - c) * k,
    };
  }

  /// Lage eines Punkts (Zellen) bei Abstand [gap]: Punkte in Räumen wandern
  /// mit dem Raum, Punkte draußen rücken wie alles vom Mittelpunkt weg.
  Offset explodePoint(
    Offset p,
    String roomId, {
    double gap = 0,
    Map<String, Offset>? offsets,
  }) {
    if (gap == 0) return p;
    final o = (offsets ?? roomOffsets(gap: gap))[roomId];
    if (o != null) return p + o;
    final c = explodeCenter;
    return c + (p - c) * (1 + explodeFactor(gap));
  }

  /// Umschließendes Rechteck aller Räume (und mit [withOutside] des
  /// Außenbereichs) bei Abstand [gap] in Zellen.
  Rect layoutBounds({double gap = 0, bool withOutside = false}) {
    if (rooms.isEmpty) return grid.rect;
    final offs = roomOffsets(gap: gap);
    Rect? b;
    for (final r in rooms) {
      final rb = r.bounds.shift(offs[r.id]!);
      b = b == null ? rb : b.expandToInclude(rb);
    }
    if (withOutside) {
      final o = outsideRect;
      final c = explodeCenter;
      final k = 1 + explodeFactor(gap);
      b = b!.expandToInclude(
        Rect.fromPoints(c + (o.topLeft - c) * k, c + (o.bottomRight - c) * k),
      );
    }
    return b!;
  }

  Size layoutSize({double gap = 0, bool withOutside = false}) =>
      layoutBounds(gap: gap, withOutside: withOutside).size;

  // ---- Positionen -------------------------------------------------------

  /// Punkt einer platzierten Entity (Zellmitte) oder `null`.
  PlanPoint? entityPoint(String entityId) {
    final p = placementOf(entityId);
    return p == null ? null : pointOfCell(p.cell);
  }

  /// Position einer Entity in Zellen (Zellmitte, Abstand [gap]) oder `null`.
  Offset? entityPosition(String entityId, {double gap = 0}) {
    final p = entityPoint(entityId);
    return p == null ? null : explodePoint(p.offset, p.roomId, gap: gap);
  }

  /// Punkt des Koordinators oder `null`.
  PlanPoint? get coordinatorPoint {
    final c = coordinator;
    return c == null ? null : pointOfCell(c);
  }

  /// Position des Koordinators in Zellen oder `null`.
  Offset? coordinatorPosition({double gap = 0}) {
    final p = coordinatorPoint;
    return p == null ? null : explodePoint(p.offset, p.roomId, gap: gap);
  }

  /// Punkte aller Geräte, die sich verorten lassen.
  ///
  /// 1. Das Gerät nimmt die Zelle seiner ersten platzierten Entity.
  /// 2. Sonst liegt es in seinem Raum auf einer freien Zelle nahe der Mitte
  ///    (mehrere verteilen sich, damit sie sich nicht überdecken).
  /// 3. Geräte ohne Platzierung und ohne bekannten Raum fehlen im Ergebnis.
  Map<String, PlanPoint> devicePoints(Iterable<FloorDevice> devices) {
    final out = <String, PlanPoint>{};
    final byRoom = <String, List<FloorDevice>>{};
    final used = <GridPoint>{};
    for (final d in devices) {
      PlanPoint? p;
      for (final id in d.entityIds) {
        p = entityPoint(id);
        if (p != null) break;
      }
      if (p != null) {
        out[d.id] = p;
        used.add(p.cell);
        continue;
      }
      final room = d.roomId == null ? null : roomByIdOrArea(d.roomId!);
      if (room != null) (byRoom[room.id] ??= []).add(d);
    }
    for (final e in byRoom.entries) {
      final room = this.room(e.key)!;
      final cells = quickCells(room, e.value.length, occupied: used);
      for (var i = 0; i < e.value.length; i++) {
        used.add(cells[i]);
        out[e.value[i].id] = PlanPoint(
          cells[i].x + 0.5,
          cells[i].y + 0.5,
          room.id,
        );
      }
    }
    return out;
  }

  /// Position eines einzelnen Geräts in Zellen (Abstand [gap]), siehe
  /// [devicePoints].
  Offset? devicePosition(FloorDevice d, {double gap = 0}) {
    final p = devicePoints([d])[d.id];
    return p == null ? null : explodePoint(p.offset, p.roomId, gap: gap);
  }

  @override
  bool operator ==(Object other) =>
      other is HavenFloorPlan &&
      other.grid == grid &&
      other.outside == outside &&
      listEquals(other.rooms, rooms) &&
      listEquals(other.placements, placements) &&
      listEquals(other.furniture, furniture) &&
      other.coordinator == coordinator;

  @override
  int get hashCode => Object.hash(
    grid,
    outside,
    Object.hashAll(rooms),
    Object.hashAll(placements),
    coordinator,
    Object.hashAll(furniture),
  );
}
