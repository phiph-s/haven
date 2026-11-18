import '../model.dart';
import 'bath.dart';
import 'kitchen.dart';
import 'living.dart';
import 'sleep.dart';
import 'structure.dart';
import 'work.dart';

/// Baut das Modell eines Möbelstücks im lokalen System (siehe
/// [ModelBuilder]): Breite [w] entlang `x`, Tiefe [d] entlang `y`, Höhe [h]
/// entlang `z`, alles in Metern. Das Modell soll die Box
/// `[-w/2, w/2] × [-d/2, d/2] × [0, h]` füllen, aber nicht verlassen.
typedef FurnitureBuild =
    void Function(ModelBuilder b, double w, double d, double h);

/// 3D-Beschreibung einer Möbel-Kennung aus der App (`FurnitureType.id`).
///
/// [height] ist die Standardhöhe in Metern, [elevation] der Abstand der
/// Unterkante vom Boden (Fenster, Hängeschrank). Beides kann der Plan später
/// pro Möbelstück überschreiben.
class FurnitureSpec {
  const FurnitureSpec({
    required this.height,
    this.elevation = 0,
    this.wallMounted = false,
    this.facesRoom = false,
    required this.build,
  });

  final double height;
  final double elevation;

  /// Sitzt in der Wand (Tür, Fenster): gehört zum Raum auf der Seite `-y`
  /// (bzw. zum Raum, in den es ragt) und verschwindet mit einer
  /// weggeschnittenen Wand.
  final bool wallMounted;

  /// Symmetrisch in der Wand (Fenster): die Szene dreht es um 180°, damit
  /// seine Seite `-y` (Aufgehwinkel) zum Raum zeigt.
  final bool facesRoom;
  final FurnitureBuild build;
}

/// Unbekannte Kennung: schlichter Kasten mit Kreuz oben (wie in 2D).
final FurnitureSpec fallbackFurniture = FurnitureSpec(
  height: 0.75,
  build: (b, w, d, h) {
    b.boxC(0, 0, w, d, 0, h);
    b.line(V3(-w / 2, -d / 2, h), V3(w / 2, d / 2, h));
    b.line(V3(w / 2, -d / 2, h), V3(-w / 2, d / 2, h));
  },
);

/// Alle bekannten Möbel.
final Map<String, FurnitureSpec> kFurnitureModels = {
  ...sleepModels,
  ...livingModels,
  ...kitchenModels,
  ...bathModels,
  ...workModels,
  ...structureModels,
};

/// Beschreibung zu [kind], unbekannt: [fallbackFurniture].
FurnitureSpec furnitureSpec(String kind) =>
    kFurnitureModels[kind] ?? fallbackFurniture;

/// Lokales Modell zu [kind] mit Breite [w] und Tiefe [d] (Meter) und Höhe
/// [height] (sonst die Standardhöhe).
Model3 buildFurniture(
  String kind,
  double w,
  double d, {
  double? height,
  bool? open,
}) {
  final spec = furnitureSpec(kind);
  final b = ModelBuilder(open: open);
  spec.build(b, w, d, height ?? spec.height);
  return b.build();
}
