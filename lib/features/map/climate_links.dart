import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:haven_3d/haven_3d.dart' as h3;
import 'package:material_ui/material_ui.dart';

import '../../data/models/floor_plan.dart';
import '../../data/models/room_heating.dart';
import '../../data/models/snapshot.dart';
import '../../data/models/zigbee.dart';
import 'map_readings.dart' show deviceSiblings;

/// Was eine Leitung verbindet: Raumthermometer oder Fensterkontakt mit einem
/// Thermostat ihrer Heizungsregelung.
enum ClimateLinkKind { sensor, window }

/// Zustand einer Leitung.
enum ClimateLinkState {
  /// Verbunden, wirkt gerade nicht.
  idle,

  /// Wirkt gerade: das Thermometer lässt das Thermostat heizen bzw. das
  /// offene Fenster hält es an.
  active,

  /// Thermostat steuert selbst (am Gerät gestellt) oder Regelung pausiert.
  released,
}

/// Eine „Leitung im Boden“ der Klima-Karte.
@immutable
class ClimateLink {
  const ClimateLink({
    required this.from,
    required this.to,
    required this.kind,
    required this.state,
    required this.path,
    this.fromWindow,
  });

  /// Knoten-ID der Quelle (Platzierung) bzw. `null` bei einem Fenster als
  /// Möbel ([fromWindow]).
  final String? from;

  /// Knoten-ID des Thermostats (Platzierung).
  final String to;
  final ClimateLinkKind kind;
  final ClimateLinkState state;

  /// Weg über den Boden in Zellen (Zellmitten, Ecken des Wegs).
  final List<Offset> path;

  /// Fenster (Möbel) als Quelle: Mitte in Zellen.
  final Offset? fromWindow;

  @override
  bool operator ==(Object other) =>
      other is ClimateLink &&
      other.from == from &&
      other.to == to &&
      other.kind == kind &&
      other.state == state &&
      other.fromWindow == fromWindow &&
      listEquals(other.path, path);

  @override
  int get hashCode => Object.hash(from, to, kind, state, path.length);
}

/// Leitungen aller Heizungsregelungen, deren Thermostat auf dem Plan steht.
List<ClimateLink> climateLinks({
  required HavenFloorPlan plan,
  required List<RoomHeating> heating,
  required HavenSnapshot snapshot,
  required List<ZbDevice> zigbee,
}) {
  if (heating.isEmpty || plan.placements.isEmpty) return const [];
  final siblings = <String, List<String>>{
    for (final p in plan.placements)
      p.entityId: deviceSiblings(p.entityId, snapshot, zigbee),
  };
  FloorPlacement? placementOf(String entityId) {
    for (final p in plan.placements) {
      if (p.entityId == entityId) return p;
    }
    for (final p in plan.placements) {
      if (siblings[p.entityId]!.contains(entityId)) return p;
    }
    return null;
  }

  FloorPlacement? trvPlacement(String ieee) {
    final d = zigbee.where((d) => d.ieee == ieee).firstOrNull;
    if (d == null) return null;
    for (final p in plan.placements) {
      if (d.haEntities.contains(p.entityId)) return p;
    }
    return null;
  }

  final out = <ClimateLink>[];
  for (final room in heating) {
    final c = room.config;
    final s = room.status;
    for (final ieee in c.trvs) {
      final trv = trvPlacement(ieee);
      if (trv == null) continue;
      final ts = s.trvs.where((t) => t.ieee == ieee).firstOrNull;
      final released = !c.enabled || (ts?.released ?? false);
      final heats = s.pause == null && (ts?.heating ?? s.heating) == true;
      for (final id in c.sensors) {
        final p = placementOf(id);
        if (p == null || p.entityId == trv.entityId) continue;
        out.add(
          ClimateLink(
            from: p.entityId,
            to: trv.entityId,
            kind: ClimateLinkKind.sensor,
            state: released
                ? ClimateLinkState.released
                : (heats ? ClimateLinkState.active : ClimateLinkState.idle),
            path: routeOnFloor(plan, p.cell, trv.cell),
          ),
        );
      }
      for (final id in c.windows) {
        final open = s.contacts[id] == true;
        final state = released
            ? ClimateLinkState.released
            : (open ? ClimateLinkState.active : ClimateLinkState.idle);
        final p = placementOf(id);
        if (p != null) {
          if (p.entityId == trv.entityId) continue;
          out.add(
            ClimateLink(
              from: p.entityId,
              to: trv.entityId,
              kind: ClimateLinkKind.window,
              state: state,
              path: routeOnFloor(plan, p.cell, trv.cell),
            ),
          );
          continue;
        }
        // Fenster als Möbel mit verknüpftem Kontakt.
        final f = plan.furniture.where((f) => f.sensor == id).firstOrNull;
        if (f == null) continue;
        final start = nearestRoomCell(plan, f.center);
        if (start == null) continue;
        out.add(
          ClimateLink(
            from: null,
            fromWindow: f.center,
            to: trv.entityId,
            kind: ClimateLinkKind.window,
            state: state,
            path: routeOnFloor(plan, start, trv.cell),
          ),
        );
      }
    }
  }
  return out;
}

/// Nächste Zelle in einem Raum zu [p] (Zellen), z. B. für ein Fenster in der
/// Wand. `null`, wenn in drei Zellen Umkreis kein Raum liegt.
GridPoint? nearestRoomCell(HavenFloorPlan plan, Offset p) {
  GridPoint? best;
  var bestD = double.infinity;
  final cx = p.dx.floor(), cy = p.dy.floor();
  for (var dy = -3; dy <= 3; dy++) {
    for (var dx = -3; dx <= 3; dx++) {
      final g = GridPoint(cx + dx, cy + dy);
      if (plan.locationOfCell(g.x, g.y) == kOutsideId) continue;
      final d = (g.center - p).distanceSquared;
      if (d < bestD) {
        bestD = d;
        best = g;
      }
    }
  }
  return best;
}

final Expando<Map<(GridPoint, GridPoint), List<Offset>>> _routes = Expando();

/// Weg einer Leitung von Zelle [a] nach [b] über den Boden: rechtwinklig
/// wie ein verlegtes Kabel, möglichst nicht unter Möbeln, möglichst nicht
/// durch Wände in andere Räume, mit wenig Knicken. Liefert die Ecken als
/// Zellmitten (erste und letzte sind [a] und [b]). Je Plan zwischengespeichert.
List<Offset> routeOnFloor(HavenFloorPlan plan, GridPoint a, GridPoint b) {
  final cache = _routes[plan] ??= {};
  return cache[(a, b)] ??= _route(plan, a, b);
}

/// Aufschlag je Zelle unter einem Möbelstück (statt verboten: notfalls
/// geht es drunter durch).
const double kCostUnderFurniture = 12;

/// Aufschlag für den Schritt durch eine Wand in einen anderen Raum.
const double kCostThroughWall = 8;

/// Aufschlag je Knick.
const double kCostTurn = 0.6;

List<Offset> _route(HavenFloorPlan plan, GridPoint a, GridPoint b) {
  if (a == b) return [a.center];
  // Fläche: alle Räume plus etwas Rand.
  var minX = math.min(a.x, b.x), maxX = math.max(a.x, b.x);
  var minY = math.min(a.y, b.y), maxY = math.max(a.y, b.y);
  for (final r in plan.rooms) {
    for (final p in r.points) {
      minX = math.min(minX, p.x);
      maxX = math.max(maxX, p.x);
      minY = math.min(minY, p.y);
      maxY = math.max(maxY, p.y);
    }
  }
  minX -= 1;
  minY -= 1;
  final w = maxX - minX + 2, h = maxY - minY + 2;
  int idx(int x, int y) => (y - minY) * w + (x - minX);
  bool inside(int x, int y) =>
      x >= minX && y >= minY && x < minX + w && y < minY + h;

  // Ort und Möbel je Zelle.
  final loc = List<String?>.filled(w * h, null);
  final blocked = List<bool>.filled(w * h, false);
  final solid = [
    for (final f in plan.furniture)
      if (f.kind != 'rug' && !h3.furnitureSpec(f.kind).wallMounted) f,
  ];
  for (var y = minY; y < minY + h; y++) {
    for (var x = minX; x < minX + w; x++) {
      final l = plan.locationOfCell(x, y);
      loc[idx(x, y)] = l == kOutsideId ? null : l;
      final c = Offset(x + 0.5, y + 0.5);
      for (final f in solid) {
        if (f.contains(c)) {
          blocked[idx(x, y)] = true;
          break;
        }
      }
    }
  }

  // A* über (Zelle, Richtung), Richtung 0..3 (4 = Start).
  const dirs = [(1, 0), (0, 1), (-1, 0), (0, -1)];
  final n = w * h * 5;
  final g = List<double>.filled(n, double.infinity);
  final prev = List<int>.filled(n, -1);
  int key(int i, int d) => i * 5 + d;
  double heur(int x, int y) => ((x - b.x).abs() + (y - b.y).abs()).toDouble();
  final open = SplayTreeSet<(double, int)>((p, q) {
    final c = p.$1.compareTo(q.$1);
    return c != 0 ? c : p.$2.compareTo(q.$2);
  });
  final start = key(idx(a.x, a.y), 4);
  g[start] = 0;
  open.add((heur(a.x, a.y), start));
  final goal = idx(b.x, b.y);
  var end = -1;
  while (open.isNotEmpty) {
    final (_, k) = open.first;
    open.remove(open.first);
    final i = k ~/ 5, d = k % 5;
    if (i == goal) {
      end = k;
      break;
    }
    final x = i % w + minX, y = i ~/ w + minY;
    for (var nd = 0; nd < 4; nd++) {
      final nx = x + dirs[nd].$1, ny = y + dirs[nd].$2;
      if (!inside(nx, ny)) continue;
      final ni = idx(nx, ny);
      if (loc[ni] == null && ni != goal) continue;
      var cost = 1.0;
      if (blocked[ni] && ni != goal) cost += kCostUnderFurniture;
      if (loc[ni] != loc[i] && loc[i] != null) cost += kCostThroughWall;
      if (d != 4 && d != nd) cost += kCostTurn;
      final nk = key(ni, nd);
      final ng = g[k] + cost;
      if (ng < g[nk]) {
        if (g[nk] != double.infinity) open.remove((g[nk] + heur(nx, ny), nk));
        g[nk] = ng;
        prev[nk] = k;
        open.add((ng + heur(nx, ny), nk));
      }
    }
  }
  if (end < 0) return [a.center, b.center];
  final cells = <int>[];
  for (var k = end; k >= 0; k = prev[k]) {
    cells.add(k ~/ 5);
  }
  final pts = [
    for (final i in cells.reversed)
      Offset(i % w + minX + 0.5, i ~/ w + minY + 0.5),
  ];
  // Nur die Ecken behalten.
  final out = <Offset>[pts.first];
  for (var j = 1; j < pts.length - 1; j++) {
    final d1 = pts[j] - pts[j - 1], d2 = pts[j + 1] - pts[j];
    if (d1 != d2) out.add(pts[j]);
  }
  out.add(pts.last);
  return out;
}
