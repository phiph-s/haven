import 'package:flutter/foundation.dart';

import '../core/light/room_palette.dart';
import 'models/lamp.dart';
import 'models/room.dart';
import 'models/snapshot.dart';

/// Abgeleitete Sicht auf einen Raum für die Oberfläche. Mit Wertgleichheit,
/// damit Riverpod nur neu baut, wenn sich wirklich etwas geändert hat.
@immutable
class RoomView {
  const RoomView({
    required this.room,
    required this.lamps,
    this.temperature,
    this.humidity,
    this.activeSceneId,
  });

  factory RoomView.from(HavenSnapshot s, Room r) => RoomView(
    room: r,
    lamps: s.lampsOf(r),
    temperature: r.temperatureId == null
        ? null
        : s.entity(r.temperatureId!)?.number,
    humidity: r.humidityId == null ? null : s.entity(r.humidityId!)?.number,
    activeSceneId: s.activeScenes[r.id],
  );

  final Room room;
  final List<Lamp> lamps;
  final double? temperature;
  final double? humidity;
  final String? activeSceneId;

  String get id => room.id;
  String get name => room.name;
  List<Lamp> get lampsOn => [
    for (final l in lamps)
      if (l.on) l,
  ];
  bool get anyOn => lamps.any((l) => l.on);

  /// Mittlere Helligkeit der eingeschalteten Lampen, 0 wenn alle aus.
  int get brightness {
    final on = lampsOn;
    if (on.isEmpty) return 0;
    return (on.fold<int>(0, (a, l) => a + l.brightness) / on.length).round();
  }

  RoomPalette palette({required bool dark}) =>
      computePalette([for (final l in lamps) ?l.asLight], dark: dark);

  @override
  bool operator ==(Object other) =>
      other is RoomView &&
      identical(other.room, room) &&
      listEquals(other.lamps, lamps) &&
      other.temperature == temperature &&
      other.humidity == humidity &&
      other.activeSceneId == activeSceneId;

  @override
  int get hashCode => Object.hash(
    room,
    Object.hashAll(lamps),
    temperature,
    humidity,
    activeSceneId,
  );
}

/// Alle Lampen aller Räume: Grundlage für die Hausfarbe.
@immutable
class HouseView {
  const HouseView(this.lamps);
  final List<Lamp> lamps;

  int get onCount => lamps.where((l) => l.on).length;

  RoomPalette palette({required bool dark}) =>
      computePalette([for (final l in lamps) ?l.asLight], dark: dark);

  @override
  bool operator ==(Object other) =>
      other is HouseView && listEquals(other.lamps, lamps);

  @override
  int get hashCode => Object.hashAll(lamps);
}
