import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';

/// Gruppen der Möbel-Bibliothek.
enum FurnitureCategory {
  sleep('Schlafen'),
  living('Wohnen'),
  kitchen('Essen und Küche'),
  bath('Bad'),
  work('Arbeiten'),
  structure('Bau');

  const FurnitureCategory(this.label);
  final String label;
}

/// Ein Element der Bibliothek: Kennung (steht im JSON als `kind`), Name,
/// Gruppe und Standardgröße in Rasterzellen (eine Zelle ist etwa 0,5 m).
@immutable
class FurnitureType {
  const FurnitureType(
    this.id,
    this.name,
    this.category,
    this.w,
    this.h, {
    this.layer = 1,
  });

  final String id;
  final String name;
  final FurnitureCategory category;

  /// Standardbreite und -tiefe in Zellen.
  final double w;
  final double h;

  /// Zeichen- und Trefferreihenfolge: 0 Boden (Teppich), 1 Möbel,
  /// 2 Bau (Tür, Fenster). Höhere Ebenen liegen oben.
  final int layer;
}

/// Die Bibliothek (25 Elemente). Größen in Zellen nach üblichen Maßen.
const List<FurnitureType> kFurnitureCatalog = [
  // Schlafen
  FurnitureType('bed_double', 'Doppelbett', FurnitureCategory.sleep, 3.6, 4.2),
  FurnitureType('bed_single', 'Einzelbett', FurnitureCategory.sleep, 2, 4.2),
  FurnitureType('nightstand', 'Nachttisch', FurnitureCategory.sleep, 1, 0.9),
  FurnitureType('wardrobe', 'Kleiderschrank', FurnitureCategory.sleep, 4, 1.2),
  // Wohnen
  FurnitureType('sofa', 'Sofa', FurnitureCategory.living, 4.4, 1.8),
  FurnitureType('sofa_corner', 'Ecksofa', FurnitureCategory.living, 5, 4),
  FurnitureType('armchair', 'Sessel', FurnitureCategory.living, 1.8, 1.8),
  FurnitureType(
    'coffee_table',
    'Couchtisch',
    FurnitureCategory.living,
    2.4,
    1.2,
  ),
  FurnitureType('tv_board', 'TV-Board', FurnitureCategory.living, 3.6, 0.9),
  FurnitureType('rug', 'Teppich', FurnitureCategory.living, 4, 3, layer: 0),
  FurnitureType('plant', 'Pflanze', FurnitureCategory.living, 1, 1),
  FurnitureType('shelf', 'Regal', FurnitureCategory.living, 2, 0.8),
  // Essen und Küche
  FurnitureType(
    'dining_table',
    'Esstisch mit Stühlen',
    FurnitureCategory.kitchen,
    3.6,
    3,
  ),
  FurnitureType(
    'kitchen_counter',
    'Küchenzeile',
    FurnitureCategory.kitchen,
    6,
    1.2,
  ),
  FurnitureType('stove', 'Herd', FurnitureCategory.kitchen, 1.2, 1.2),
  FurnitureType('sink', 'Spüle', FurnitureCategory.kitchen, 1.6, 1.2),
  FurnitureType('fridge', 'Kühlschrank', FurnitureCategory.kitchen, 1.2, 1.3),
  // Bad
  FurnitureType('bathtub', 'Badewanne', FurnitureCategory.bath, 3.4, 1.6),
  FurnitureType('shower', 'Dusche', FurnitureCategory.bath, 1.8, 1.8),
  FurnitureType('toilet', 'WC', FurnitureCategory.bath, 0.8, 1.4),
  FurnitureType('washbasin', 'Waschbecken', FurnitureCategory.bath, 1.2, 1),
  // Arbeiten
  FurnitureType('desk', 'Schreibtisch', FurnitureCategory.work, 3, 1.4),
  FurnitureType('office_chair', 'Bürostuhl', FurnitureCategory.work, 1.2, 1.2),
  // Bau
  FurnitureType('door', 'Tür', FurnitureCategory.structure, 1.8, 1.8, layer: 2),
  FurnitureType(
    'window',
    'Fenster',
    FurnitureCategory.structure,
    2.4,
    0.4,
    layer: 2,
  ),
];

final Map<String, FurnitureType> _byId = {
  for (final t in kFurnitureCatalog) t.id: t,
};

/// Typ zur Kennung oder `null` (unbekannt, z. B. von einer neueren App).
FurnitureType? furnitureType(String kind) => _byId[kind];

/// Kleinste Kantenlänge eines Möbels in Zellen.
const double kFurnitureMinSide = 0.3;

double _r3(double v) => (v * 1000).roundToDouble() / 1000;

/// Winkel in Grad auf [0, 360).
double normalizeDegrees(double d) {
  final v = d % 360;
  final out = v < 0 ? v + 360 : v;
  // 359,9999 durch Rundung wird 0.
  return (360 - out).abs() < 1e-9 ? 0 : out;
}

/// Ein Möbelstück im Grundriss, **nur optisch** (keine Logik hängt daran).
///
/// Alle Maße in Rastereinheiten als Kommazahlen: [x], [y] ist die **Mitte**
/// (damit die Drehung eindeutig ist), [w] und [h] Breite und Tiefe vor der
/// Drehung, [rotation] in Grad im Uhrzeigersinn. [kind] ist eine Kennung aus
/// [kFurnitureCatalog]. Unbekannte Kennungen bleiben erhalten und erscheinen
/// als schlichtes Rechteck.
@immutable
class FloorFurniture {
  const FloorFurniture({
    required this.id,
    required this.kind,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.rotation = 0,
  });

  /// Neues Möbelstück in Standardgröße mit Mitte [center].
  factory FloorFurniture.of(
    FurnitureType type, {
    required String id,
    required Offset center,
    double rotation = 0,
  }) => FloorFurniture(
    id: id,
    kind: type.id,
    x: center.dx,
    y: center.dy,
    w: type.w,
    h: type.h,
    rotation: rotation,
  );

  /// Liest tolerant. `null` bei unbrauchbaren Einträgen (fehlende ID oder
  /// Zahlen), damit ein kaputtes Möbelstück nicht den Grundriss kostet.
  static FloorFurniture? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final kind = raw['kind'];
    double? n(String k) =>
        (raw[k] as Object?) is num ? (raw[k] as num).toDouble() : null;
    final x = n('x'), y = n('y'), w = n('w'), h = n('h');
    if (id is! String || kind is! String) return null;
    if (x == null || y == null || w == null || h == null) return null;
    if (!x.isFinite || !y.isFinite || !w.isFinite || !h.isFinite) return null;
    final rot = n('rotation') ?? 0;
    return FloorFurniture(
      id: id,
      kind: kind,
      x: x,
      y: y,
      w: math.max(kFurnitureMinSide, w),
      h: math.max(kFurnitureMinSide, h),
      rotation: rot.isFinite ? normalizeDegrees(rot) : 0,
    );
  }

  final String id;
  final String kind;
  final double x;
  final double y;
  final double w;
  final double h;
  final double rotation;

  FurnitureType? get type => furnitureType(kind);

  /// Zeichenebene (siehe [FurnitureType.layer]), unbekannt: 1.
  int get layer => type?.layer ?? 1;

  Offset get center => Offset(x, y);

  double get _rad => rotation * math.pi / 180;

  /// Punkt im eigenen Koordinatensystem (Mitte 0, ungedreht) nach Zellen.
  Offset toWorld(Offset local) {
    final c = math.cos(_rad), s = math.sin(_rad);
    return Offset(
      x + local.dx * c - local.dy * s,
      y + local.dx * s + local.dy * c,
    );
  }

  /// Punkt in Zellen ins eigene Koordinatensystem (Mitte 0, ungedreht).
  Offset toLocal(Offset p) {
    final d = p - center;
    final c = math.cos(_rad), s = math.sin(_rad);
    return Offset(d.dx * c + d.dy * s, -d.dx * s + d.dy * c);
  }

  /// Ecken im Uhrzeigersinn ab oben links (vor der Drehung), in Zellen.
  List<Offset> get corners => [
    toWorld(Offset(-w / 2, -h / 2)),
    toWorld(Offset(w / 2, -h / 2)),
    toWorld(Offset(w / 2, h / 2)),
    toWorld(Offset(-w / 2, h / 2)),
  ];

  /// Umschließendes Rechteck (achsparallel) in Zellen.
  Rect get bounds {
    final cs = corners;
    var l = cs.first.dx, r = l, t = cs.first.dy, b = t;
    for (final c in cs.skip(1)) {
      l = math.min(l, c.dx);
      r = math.max(r, c.dx);
      t = math.min(t, c.dy);
      b = math.max(b, c.dy);
    }
    return Rect.fromLTRB(l, t, r, b);
  }

  /// Liegt [p] (Zellen) auf dem Möbelstück? [tolerance] erweitert in Zellen.
  bool contains(Offset p, {double tolerance = 0}) {
    final l = toLocal(p);
    return l.dx.abs() <= w / 2 + tolerance && l.dy.abs() <= h / 2 + tolerance;
  }

  FloorFurniture copyWith({
    String? id,
    double? x,
    double? y,
    double? w,
    double? h,
    double? rotation,
  }) => FloorFurniture(
    id: id ?? this.id,
    kind: kind,
    x: x ?? this.x,
    y: y ?? this.y,
    w: w ?? this.w,
    h: h ?? this.h,
    rotation: rotation == null ? this.rotation : normalizeDegrees(rotation),
  );

  FloorFurniture moveTo(Offset c) => copyWith(x: c.dx, y: c.dy);

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'x': _r3(x),
    'y': _r3(y),
    'w': _r3(w),
    'h': _r3(h),
    'rotation': _r3(rotation),
  };

  @override
  bool operator ==(Object other) =>
      other is FloorFurniture &&
      other.id == id &&
      other.kind == kind &&
      other.x == x &&
      other.y == y &&
      other.w == w &&
      other.h == h &&
      other.rotation == rotation;

  @override
  int get hashCode => Object.hash(id, kind, x, y, w, h, rotation);

  @override
  String toString() =>
      'FloorFurniture($kind @ ${x.toStringAsFixed(2)}, '
      '${y.toStringAsFixed(2)}, ${w}x$h, $rotation°)';
}

int _idSeq = 0;

/// Neue, eindeutige Möbel-ID.
String newFurnitureId() {
  _idSeq = (_idSeq + 1) % 1296;
  return 'f${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${_idSeq.toRadixString(36)}';
}

/// Möbel in Zeichenreihenfolge (Teppiche unten, Türen und Fenster oben,
/// sonst wie gespeichert).
List<FloorFurniture> furnitureInPaintOrder(List<FloorFurniture> items) {
  final idx = {for (var i = 0; i < items.length; i++) items[i].id: i};
  return [...items]..sort((a, b) {
    final l = a.layer.compareTo(b.layer);
    return l != 0 ? l : idx[a.id]!.compareTo(idx[b.id]!);
  });
}

/// Oberstes Möbelstück am Punkt [p] (Zellen) oder `null`.
FloorFurniture? furnitureAt(
  List<FloorFurniture> items,
  Offset p, {
  double tolerance = 0,
}) {
  final ordered = furnitureInPaintOrder(items);
  for (final f in ordered.reversed) {
    if (f.contains(p, tolerance: tolerance)) return f;
  }
  return null;
}
