import 'dart:math' as math;
import 'dart:typed_data';

import 'devices.dart';
import 'model.dart';

/// Eine waagerechte Fläche, die Lampenlicht empfängt (Boden, Oberseite
/// eines Möbels): Polygon auf Höhe [z], gerastert mit [texel] Metern.
class LightReceiver {
  LightReceiver(this.polygon, {double texel = 0.05, int maxSide = 160})
    : z = polygon.first.z {
    var x0 = double.infinity, y0 = double.infinity;
    var x1 = -double.infinity, y1 = -double.infinity;
    for (final p in polygon) {
      x0 = math.min(x0, p.x);
      y0 = math.min(y0, p.y);
      x1 = math.max(x1, p.x);
      y1 = math.max(y1, p.y);
    }
    minX = x0;
    minY = y0;
    final w = math.max(x1 - x0, 1e-3), h = math.max(y1 - y0, 1e-3);
    // Gröber rastern, wenn die Fläche sonst zu viele Texel hätte.
    final t = math.max(texel, math.max(w, h) / maxSide);
    width = math.max(2, (w / t).ceil());
    height = math.max(2, (h / t).ceil());
    sizeX = w;
    sizeY = h;
  }

  final List<V3> polygon;
  final double z;
  late final double minX, minY, sizeX, sizeY;
  late final int width, height;

  /// Texturkoordinate (0…1) eines Punkts der Fläche.
  (double, double) uv(V3 p) => ((p.x - minX) / sizeX, (p.y - minY) / sizeY);

  /// Mitte des Texels (ix, iy) auf der Fläche.
  V3 texelCenter(int ix, int iy) => V3(
    minX + (ix + 0.5) / width * sizeX,
    minY + (iy + 0.5) / height * sizeY,
    z,
  );
}

/// Geschlossene Körper, die Schatten werfen (die Möbel eines Raums), als
/// Dreiecke mit umschließender Box je Gruppe für den schnellen Ausschluss.
class LightOccluders {
  LightOccluders(Iterable<Model3> models) {
    for (final m in models) {
      final tris = <double>[];
      var lo = const V3(double.infinity, double.infinity, double.infinity);
      var hi = -lo;
      for (final f in m.faces) {
        final p = f.points;
        for (var i = 1; i + 1 < p.length; i++) {
          for (final q in [p[0], p[i], p[i + 1]]) {
            tris.addAll([q.x, q.y, q.z]);
            lo = V3(
              math.min(lo.x, q.x),
              math.min(lo.y, q.y),
              math.min(lo.z, q.z),
            );
            hi = V3(
              math.max(hi.x, q.x),
              math.max(hi.y, q.y),
              math.max(hi.z, q.z),
            );
          }
        }
      }
      if (tris.isEmpty) continue;
      _groups.add((Float64List.fromList(tris), lo, hi));
    }
  }

  final List<(Float64List, V3, V3)> _groups = [];

  /// Trifft die Strecke a → b ein Körper (Enden ausgenommen)?
  bool blocked(V3 a, V3 b) {
    final d = b - a;
    for (final (tris, lo, hi) in _groups) {
      if (!_segmentHitsBox(a, d, lo, hi)) continue;
      for (var i = 0; i < tris.length; i += 9) {
        if (_segmentHitsTriangle(a, d, tris, i)) return true;
      }
    }
    return false;
  }

  static bool _segmentHitsBox(V3 a, V3 d, V3 lo, V3 hi) {
    var t0 = 0.0, t1 = 1.0;
    for (final (o, dir, l, h) in [
      (a.x, d.x, lo.x, hi.x),
      (a.y, d.y, lo.y, hi.y),
      (a.z, d.z, lo.z, hi.z),
    ]) {
      if (dir.abs() < 1e-12) {
        if (o < l || o > h) return false;
        continue;
      }
      var ta = (l - o) / dir, tb = (h - o) / dir;
      if (ta > tb) (ta, tb) = (tb, ta);
      t0 = math.max(t0, ta);
      t1 = math.min(t1, tb);
      if (t0 > t1) return false;
    }
    return true;
  }

  /// Möller-Trumbore, nur Treffer echt zwischen den Enden.
  static bool _segmentHitsTriangle(V3 a, V3 d, Float64List t, int i) {
    final e1x = t[i + 3] - t[i],
        e1y = t[i + 4] - t[i + 1],
        e1z = t[i + 5] - t[i + 2];
    final e2x = t[i + 6] - t[i],
        e2y = t[i + 7] - t[i + 1],
        e2z = t[i + 8] - t[i + 2];
    final px = d.y * e2z - d.z * e2y;
    final py = d.z * e2x - d.x * e2z;
    final pz = d.x * e2y - d.y * e2x;
    final det = e1x * px + e1y * py + e1z * pz;
    if (det.abs() < 1e-12) return false;
    final inv = 1 / det;
    final sx = a.x - t[i], sy = a.y - t[i + 1], sz = a.z - t[i + 2];
    final u = (sx * px + sy * py + sz * pz) * inv;
    if (u < 0 || u > 1) return false;
    final qx = sy * e1z - sz * e1y;
    final qy = sz * e1x - sx * e1z;
    final qz = sx * e1y - sy * e1x;
    final v = (d.x * qx + d.y * qy + d.z * qz) * inv;
    if (v < 0 || u + v > 1) return false;
    final tt = (e2x * qx + e2y * qy + e2z * qz) * inv;
    return tt > 1e-4 && tt < 1 - 1e-4;
  }
}

/// Beleuchtungsstärke (ohne Farbe und Intensität) einer Punktlampe bei
/// [lamp] auf [r], mit weichen Schatten: [samples] Punkte auf einer
/// waagerechten Scheibe mit Radius [radius] um die Lampe, danach leicht
/// weichgezeichnet. Werte sind cos θ / d² mal einem weichen Ausklingen bis
/// [range] (wie flutter_scene).
///
/// Mit [unshadowed] wird dort zusätzlich die Beleuchtung ohne Schatten
/// abgelegt (gleiche Größe wie das Ergebnis): daraus mischt der Renderer
/// Streulicht in die Schatten, ohne neu zu baken.
Float32List bakeLamp(
  LightReceiver r,
  V3 lamp,
  LightOccluders occ, {
  double range = 7,
  double radius = 0.12,
  int samples = 7,
  Float32List? unshadowed,
  double? cone,
}) {
  final pts = [
    lamp,
    for (var k = 0; k < samples - 1; k++)
      lamp +
          V3(
            radius * math.cos(2 * math.pi * k / (samples - 1)),
            radius * math.sin(2 * math.pi * k / (samples - 1)),
            0,
          ),
  ];
  final out = Float32List(r.width * r.height);
  final poly = [for (final p in r.polygon) (p.x, p.y)];
  for (var iy = 0; iy < r.height; iy++) {
    for (var ix = 0; ix < r.width; ix++) {
      final c = r.texelCenter(ix, iy);
      // Texel außerhalb des Polygons: Wert vom Rand übernehmen (Filterung).
      final inside = _inPoly(poly, c.x, c.y);
      final p = c + const V3(0, 0, 0.002);
      final l = lamp - p;
      final d2 = l.dot(l);
      if (l.z <= 0 || d2 < 1e-6) continue;
      final d = math.sqrt(d2);
      final cos = l.z / d;
      final win = math
          .pow((1 - math.pow(d / range, 4)).clamp(0.0, 1.0), 2)
          .toDouble();
      var e = cos / d2 * win;
      // Lichtkegel nach unten (Spot, Pendel): weich zum Rand.
      if (cone != null) e *= coneFactor(cos, cone);
      if (e <= 0) continue;
      unshadowed?[iy * r.width + ix] = e;
      if (inside) {
        var vis = 0;
        for (final s in pts) {
          if (!occ.blocked(p, s)) vis++;
        }
        e *= vis / pts.length;
      }
      out[iy * r.width + ix] = e;
    }
  }
  if (unshadowed != null) {
    unshadowed.setAll(0, _blur(unshadowed, r.width, r.height));
  }
  return _blur(_blur(out, r.width, r.height), r.width, r.height);
}

Float32List _blur(Float32List src, int w, int h) {
  final out = Float32List(src.length);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var s = 0.0, n = 0;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final xx = x + dx, yy = y + dy;
          if (xx < 0 || yy < 0 || xx >= w || yy >= h) continue;
          s += src[yy * w + xx];
          n++;
        }
      }
      out[y * w + x] = s / n;
    }
  }
  return out;
}

bool _inPoly(List<(double, double)> poly, double x, double y) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final (xi, yi) = poly[i];
    final (xj, yj) = poly[j];
    if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
      inside = !inside;
    }
  }
  return inside;
}

/// Summe der Lampen einer Fläche als RGBA-Pixel (sRGB, für eine
/// Emissive-Textur). [lamps] sind (Beleuchtung, lineare Farbe × Stärke).
/// Gibt die Pixel und den Faktor zurück, mit dem die Textur zu
/// multiplizieren ist (die Pixel sind auf den hellsten Wert normiert).
(Uint8List, double) combineLamps(
  int texels,
  List<(Float32List, double, double, double)> lamps,
) {
  final rgb = Float32List(texels * 3);
  for (final (e, r, g, b) in lamps) {
    for (var i = 0; i < texels; i++) {
      final v = e[i];
      if (v == 0) continue;
      rgb[i * 3] += v * r;
      rgb[i * 3 + 1] += v * g;
      rgb[i * 3 + 2] += v * b;
    }
  }
  var max = 0.0;
  for (final v in rgb) {
    if (v > max) max = v;
  }
  final px = Uint8List(texels * 4);
  if (max <= 0) return (px, 0);
  int enc(double lin) {
    final v = (lin / max).clamp(0.0, 1.0);
    final s = v <= 0.0031308 ? v * 12.92 : 1.055 * math.pow(v, 1 / 2.4) - 0.055;
    return (s * 255).round().clamp(0, 255);
  }

  for (var i = 0; i < texels; i++) {
    px[i * 4] = enc(rgb[i * 3]);
    px[i * 4 + 1] = enc(rgb[i * 3 + 1]);
    px[i * 4 + 2] = enc(rgb[i * 3 + 2]);
    px[i * 4 + 3] = 255;
  }
  return (px, max);
}

/// Sonnenlicht auf [r]: cos θ zur Sonne mal Sichtbarkeit, mit weichen
/// Schatten über [samples] Richtungen in einem Kegel mit [spread] Bogenmaß.
/// [toSun] zeigt von der Fläche zur Sonne (normiert oder nicht).
Float32List bakeSun(
  LightReceiver r,
  V3 toSun,
  LightOccluders occ, {
  double spread = 0.06,
  int samples = 7,
  double reach = 15,
}) {
  final d0 = toSun.normalized;
  // Zwei Achsen senkrecht zur Sonnenrichtung für den Kegel.
  final a = (d0.z.abs() < 0.9 ? V3.up : const V3(1, 0, 0)).cross(d0).normalized;
  final b = d0.cross(a);
  final dirs = [
    d0,
    for (var k = 0; k < samples - 1; k++)
      (d0 +
              a * (spread * math.cos(2 * math.pi * k / (samples - 1))) +
              b * (spread * math.sin(2 * math.pi * k / (samples - 1))))
          .normalized,
  ];
  final cos = math.max(0.0, d0.z);
  final out = Float32List(r.width * r.height);
  if (cos <= 0) return out;
  final poly = [for (final p in r.polygon) (p.x, p.y)];
  for (var iy = 0; iy < r.height; iy++) {
    for (var ix = 0; ix < r.width; ix++) {
      final c = r.texelCenter(ix, iy);
      if (!_inPoly(poly, c.x, c.y)) {
        out[iy * r.width + ix] = cos;
        continue;
      }
      final p = c + const V3(0, 0, 0.002);
      var vis = 0;
      for (final d in dirs) {
        if (!occ.blocked(p, p + d * reach)) vis++;
      }
      out[iy * r.width + ix] = cos * vis / dirs.length;
    }
  }
  return _blur(out, r.width, r.height);
}
