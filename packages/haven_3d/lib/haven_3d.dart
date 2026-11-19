/// 3D-Renderer für den Haven-Grundriss auf flutter_scene.
///
/// Szene, Kamera, Möbelmodelle, Kanten und Treffertest sind reines Dart; das
/// Zeichnen (Tiefenpuffer, Licht, Schatten) übernimmt flutter_scene auf
/// Flutter GPU (nativ) bzw. WebGL2 (Web). Siehe README.
library;

export 'src/camera.dart';
export 'src/devices.dart';
export 'src/edges.dart' show Edge3, featureEdges;
export 'src/gpu_scene.dart' show kSunDirection, sunDirectionOf;
export 'src/heatmap.dart';
export 'src/furniture/catalog.dart'
    show
        FurnitureBuild,
        FurnitureSpec,
        buildFurniture,
        fallbackFurniture,
        furnitureSpec,
        kFurnitureModels;
export 'src/model.dart';
export 'src/picking.dart';
export 'src/quality.dart';
export 'src/sample.dart';
export 'src/shape.dart' show fitInside, roundedInset;
export 'src/scene.dart';
export 'src/style.dart';
export 'src/support.dart';
export 'src/triangulate.dart' show triangulate;
export 'src/view.dart';
