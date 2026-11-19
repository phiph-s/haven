import 'dart:async';

import 'package:haven/features/map/map_3d.dart';

/// Für alle Tests: der Himmel der Karte steht still, sonst endet
/// `pumpAndSettle` nie.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  mapSkyAnimations = false;
  await testMain();
}
