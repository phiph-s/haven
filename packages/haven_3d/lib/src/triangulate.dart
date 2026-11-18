import 'model.dart';

/// Zerlegt ein ebenes, einfaches Polygon (auch nicht konvex, z. B. L-Form)
/// in Dreiecke (Ohrenschneiden). Liefert Indexdreiecke in [points], jedes so
/// orientiert, dass sein Kreuzprodukt in Richtung [normal] zeigt.
List<(int, int, int)> triangulate(List<V3> points, V3 normal) {
  final n = points.length;
  if (n < 3) return const [];
  // In die Ebene projizieren.
  final helper = normal.z.abs() < 0.9 ? V3.up : const V3(1, 0, 0);
  final u = helper.cross(normal).normalized;
  final v = normal.cross(u);
  final xs = [for (final p in points) u.dot(p)];
  final ys = [for (final p in points) v.dot(p)];

  // Umlaufsinn in (u, v): positiv = gegen den Uhrzeigersinn um normal.
  var area = 0.0;
  for (var i = 0; i < n; i++) {
    final j = (i + 1) % n;
    area += xs[i] * ys[j] - xs[j] * ys[i];
  }
  final idx = List<int>.generate(n, (i) => i);
  if (area < 0) idx.setAll(0, idx.reversed.toList());

  double cross(int a, int b, int c) =>
      (xs[b] - xs[a]) * (ys[c] - ys[a]) - (ys[b] - ys[a]) * (xs[c] - xs[a]);

  bool inside(int p, int a, int b, int c) =>
      cross(a, b, p) >= -1e-12 &&
      cross(b, c, p) >= -1e-12 &&
      cross(c, a, p) >= -1e-12;

  final out = <(int, int, int)>[];
  var guard = 0;
  while (idx.length > 3 && guard++ < n * n) {
    var cut = false;
    for (var i = 0; i < idx.length; i++) {
      final a = idx[(i - 1 + idx.length) % idx.length];
      final b = idx[i];
      final c = idx[(i + 1) % idx.length];
      if (cross(a, b, c) <= 1e-12) continue; // spitze Ecke nach innen
      var ear = true;
      for (final p in idx) {
        if (p == a || p == b || p == c) continue;
        if (inside(p, a, b, c)) {
          ear = false;
          break;
        }
      }
      if (!ear) continue;
      out.add((a, b, c));
      idx.removeAt(i);
      cut = true;
      break;
    }
    if (!cut) break; // entartet: Rest als Fächer
  }
  if (idx.length >= 3) {
    for (var i = 1; i + 1 < idx.length; i++) {
      out.add((idx[0], idx[i], idx[i + 1]));
    }
  }
  return out;
}
