import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/adaptive/breakpoints.dart';

/// Gewähltes Gerät im Desktop-Layout (Master-Detail, IEEE oder `null`).
class ZigbeeSelection extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? ieee) => state = ieee;
}

final zigbeeSelectionProvider = NotifierProvider<ZigbeeSelection, String?>(
  ZigbeeSelection.new,
);

/// Markiert die Liste im Master-Detail: Zeilen darin öffnen das Gerät rechts
/// statt als eigene Seite.
class ZigbeeMasterScope extends InheritedWidget {
  const ZigbeeMasterScope({super.key, required super.child});

  static bool active(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ZigbeeMasterScope>() != null;

  @override
  bool updateShouldNotify(ZigbeeMasterScope old) => false;
}

/// Öffnet ein Gerät: am Desktop in der Detailspalte, sonst als Seite.
void openZigbeeDevice(BuildContext context, String ieee) {
  if (context.isDesktopLayout && ZigbeeMasterScope.active(context)) {
    ProviderScope.containerOf(
      context,
      listen: false,
    ).read(zigbeeSelectionProvider.notifier).select(ieee);
    return;
  }
  context.push('/zigbee/device/$ieee');
}
