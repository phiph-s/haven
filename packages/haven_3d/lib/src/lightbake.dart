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
///
/// Das Baking fragt Millionen Strecken ab: alles liegt in flachen
/// Zahlenfeldern, ohne Objekte je Abfrage. Je Dreieck stehen Ecke, beide
/// Kanten und ein eigener Hüllquader bereit; je Fläche und Lampe kommen nur
/// die Körper in Frage, die überhaupt zwischen beiden liegen ([near]).
class LightOccluders {
  LightOccluders(Iterable<Model3> models) {
    final boxes = <double>[];
    for (final m in models) {
      final tris = <double>[];
      var x0 = double.infinity, y0 = double.infinity, z0 = double.infinity;
      var x1 = -double.infinity, y1 = -double.infinity, z1 = -double.infinity;
      for (final f in m.faces) {
        final p = f.points;
        for (var i = 1; i + 1 < p.length; i++) {
          final a = p[0], b = p[i], c = p[i + 1];
          final lx = math.min(a.x, math.min(b.x, c.x));
          final ly = math.min(a.y, math.min(b.y, c.y));
          final lz = math.min(a.z, math.min(b.z, c.z));
          final hx = math.max(a.x, math.max(b.x, c.x));
          final hy = math.max(a.y, math.max(b.y, c.y));
          final hz = math.max(a.z, math.max(b.z, c.z));
          tris
            ..add(a.x)
            ..add(a.y)
            ..add(a.z)
            ..add(b.x - a.x)
            ..add(b.y - a.y)
            ..add(b.z - a.z)
            ..add(c.x - a.x)
            ..add(c.y - a.y)
            ..add(c.z - a.z)
            ..add(lx - _kSlack)
            ..add(ly - _kSlack)
            ..add(lz - _kSlack)
            ..add(hx + _kSlack)
            ..add(hy + _kSlack)
            ..add(hz + _kSlack);
          x0 = math.min(x0, lx);
          y0 = math.min(y0, ly);
          z0 = math.min(z0, lz);
          x1 = math.max(x1, hx);
          y1 = math.max(y1, hy);
          z1 = math.max(z1, hz);
        }
      }
      if (tris.isEmpty) continue;
      _tris.add(Float64List.fromList(tris));
      boxes
        ..add(x0)
        ..add(y0)
        ..add(z0)
        ..add(x1)
        ..add(y1)
        ..add(z1);
    }
    _boxes = Float64List.fromList(boxes);
    _all = Int32List(_tris.length);
    for (var i = 0; i < _all.length; i++) {
      _all[i] = i;
    }
  }

  /// Rand um die Hüllquader beim groben Aussortieren (Meter): weit über
  /// jedem Rundungsfehler, damit dort nie ein Treffer verloren geht.
  static const double _kSlack = 1e-4;

  /// Zahlen je Dreieck: Ecke, zwei Kanten, Hüllquader (unten, oben).
  static const int _kStride = 15;

  /// Je Körper seine Dreiecke.
  final List<Float64List> _tris = [];

  /// Je Körper sein Hüllquader (unten, oben).
  late final Float64List _boxes;
  late final Int32List _all;

  /// Körper, die eine Strecke innerhalb des Quaders (x0 … z1) treffen kann.
  Int32List near(
    double x0,
    double y0,
    double z0,
    double x1,
    double y1,
    double z1,
  ) => among(_all, x0, y0, z0, x1, y1, z1);

  /// Wie [near], aber nur aus [groups] (eine frühere, gröbere Auswahl).
  Int32List among(
    Int32List groups,
    double x0,
    double y0,
    double z0,
    double x1,
    double y1,
    double z1,
  ) {
    final b = _boxes;
    final out = <int>[];
    for (var c = 0; c < groups.length; c++) {
      final g = groups[c];
      final o = g * 6;
      if (b[o] > x1 + _kSlack ||
          b[o + 3] < x0 - _kSlack ||
          b[o + 1] > y1 + _kSlack ||
          b[o + 4] < y0 - _kSlack ||
          b[o + 2] > z1 + _kSlack ||
          b[o + 5] < z0 - _kSlack) {
        continue;
      }
      out.add(g);
    }
    return Int32List.fromList(out);
  }

  /// Trifft die Strecke a → b ein Körper (Enden ausgenommen)?
  bool blocked(V3 a, V3 b) =>
      blockedAmong(_all, a.x, a.y, a.z, b.x, b.y, b.z, null, 0);

  /// Wie [blocked], nur gegen die Körper [groups] (aus [near]). [hint]
  /// merkt sich je [slot] das zuletzt getroffene Dreieck (zwei Einträge je
  /// Platz, anfangs -1): der Nachbartexel liegt meist im selben Schatten.
  bool blockedAmong(
    Int32List groups,
    double ax,
    double ay,
    double az,
    double bx,
    double by,
    double bz,
    Int32List? hint,
    int slot,
  ) {
    final dx = bx - ax, dy = by - ay, dz = bz - az;
    if (hint != null) {
      final g = hint[slot * 2];
      if (g >= 0 &&
          _segmentHitsBox(ax, ay, az, dx, dy, dz, _boxes, g * 6) &&
          _segmentHitsTriangle(
            ax,
            ay,
            az,
            dx,
            dy,
            dz,
            _tris[g],
            hint[slot * 2 + 1],
          )) {
        return true;
      }
    }
    if (groups.isEmpty) return false;
    // Hüllquader der Strecke, gegen die Quader der Dreiecke.
    final sx0 = ax < bx ? ax : bx, sx1 = ax < bx ? bx : ax;
    final sy0 = ay < by ? ay : by, sy1 = ay < by ? by : ay;
    final sz0 = az < bz ? az : bz, sz1 = az < bz ? bz : az;
    for (var c = 0; c < groups.length; c++) {
      final g = groups[c];
      if (!_segmentHitsBox(ax, ay, az, dx, dy, dz, _boxes, g * 6)) continue;
      final t = _tris[g];
      for (var i = 0; i < t.length; i += _kStride) {
        if (t[i + 9] > sx1 ||
            t[i + 12] < sx0 ||
            t[i + 10] > sy1 ||
            t[i + 13] < sy0 ||
            t[i + 11] > sz1 ||
            t[i + 14] < sz0) {
          continue;
        }
        if (_segmentHitsTriangle(ax, ay, az, dx, dy, dz, t, i)) {
          if (hint != null) {
            hint[slot * 2] = g;
            hint[slot * 2 + 1] = i;
          }
          return true;
        }
      }
    }
    return false;
  }

  static bool _segmentHitsBox(
    double ax,
    double ay,
    double az,
    double dx,
    double dy,
    double dz,
    Float64List b,
    int o,
  ) {
    var t0 = 0.0, t1 = 1.0;
    if (dx.abs() < 1e-12) {
      if (ax < b[o] || ax > b[o + 3]) return false;
    } else {
      var ta = (b[o] - ax) / dx, tb = (b[o + 3] - ax) / dx;
      if (ta > tb) {
        final s = ta;
        ta = tb;
        tb = s;
      }
      if (ta > t0) t0 = ta;
      if (tb < t1) t1 = tb;
      if (t0 > t1) return false;
    }
    if (dy.abs() < 1e-12) {
      if (ay < b[o + 1] || ay > b[o + 4]) return false;
    } else {
      var ta = (b[o + 1] - ay) / dy, tb = (b[o + 4] - ay) / dy;
      if (ta > tb) {
        final s = ta;
        ta = tb;
        tb = s;
      }
      if (ta > t0) t0 = ta;
      if (tb < t1) t1 = tb;
      if (t0 > t1) return false;
    }
    if (dz.abs() < 1e-12) {
      if (az < b[o + 2] || az > b[o + 5]) return false;
    } else {
      var ta = (b[o + 2] - az) / dz, tb = (b[o + 5] - az) / dz;
      if (ta > tb) {
        final s = ta;
        ta = tb;
        tb = s;
      }
      if (ta > t0) t0 = ta;
      if (tb < t1) t1 = tb;
      if (t0 > t1) return false;
    }
    return true;
  }

  /// Möller-Trumbore, nur Treffer echt zwischen den Enden.
  static bool _segmentHitsTriangle(
    double ax,
    double ay,
    double az,
    double dx,
    double dy,
    double dz,
    Float64List t,
    int i,
  ) {
    final e1x = t[i + 3], e1y = t[i + 4], e1z = t[i + 5];
    final e2x = t[i + 6], e2y = t[i + 7], e2z = t[i + 8];
    final px = dy * e2z - dz * e2y;
    final py = dz * e2x - dx * e2z;
    final pz = dx * e2y - dy * e2x;
    final det = e1x * px + e1y * py + e1z * pz;
    if (det.abs() < 1e-12) return false;
    final inv = 1 / det;
    final sx = ax - t[i], sy = ay - t[i + 1], sz = az - t[i + 2];
    final u = (sx * px + sy * py + sz * pz) * inv;
    if (u < 0 || u > 1) return false;
    final qx = sy * e1z - sz * e1y;
    final qy = sz * e1x - sx * e1z;
    final qz = sx * e1y - sy * e1x;
    final v = (dx * qx + dy * qy + dz * qz) * inv;
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
  double softness = kConeSoftness,
  V3 axis = const V3(0, 0, -1),
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
  final n = pts.length;
  final sx = Float64List(n), sy = Float64List(n), sz = Float64List(n);
  // Alles, was zwischen Fläche und Lampe liegen kann.
  var x0 = r.minX, y0 = r.minY, z0 = r.z;
  var x1 = r.minX + r.sizeX, y1 = r.minY + r.sizeY, z1 = r.z + 0.002;
  for (var k = 0; k < n; k++) {
    final s = pts[k];
    sx[k] = s.x;
    sy[k] = s.y;
    sz[k] = s.z;
    x0 = math.min(x0, s.x);
    y0 = math.min(y0, s.y);
    z0 = math.min(z0, s.z);
    x1 = math.max(x1, s.x);
    y1 = math.max(y1, s.y);
    z1 = math.max(z1, s.z);
  }
  final near = _NearBlocks(
    occ,
    r,
    occ.near(x0, y0, z0, x1, y1, z1),
    sx.reduce(math.min),
    sy.reduce(math.min),
    sz.reduce(math.min),
    sx.reduce(math.max),
    sy.reduce(math.max),
    sz.reduce(math.max),
    sweep: false,
  );
  final hint = Int32List(n * 2)..fillRange(0, n * 2, -1);
  final out = Float32List(r.width * r.height);
  final poly = _PolyXY(r.polygon);
  final w = r.width, h = r.height;
  final lx0 = lamp.x, ly0 = lamp.y, lz0 = lamp.z;
  final pz = r.z + 0.002;
  final lz = lz0 - pz;
  for (var iy = 0; iy < h; iy++) {
    final cy = r.minY + (iy + 0.5) / h * r.sizeY;
    final ly = ly0 - cy;
    for (var ix = 0; ix < w; ix++) {
      final cx = r.minX + (ix + 0.5) / w * r.sizeX;
      final lx = lx0 - cx;
      final d2 = lx * lx + ly * ly + lz * lz;
      if (lz <= 0 || d2 < 1e-6) continue;
      final d = math.sqrt(d2);
      final cos = lz / d;
      final win = math
          .pow((1 - math.pow(d / range, 4)).clamp(0.0, 1.0), 2)
          .toDouble();
      var e = cos / d2 * win;
      // Lichtkegel entlang [axis] (Spot, Pendel): weich zum Rand.
      if (cone != null) {
        e *= coneFactor(
          -(lx * axis.x + ly * axis.y + lz * axis.z) / d,
          cone,
          softness,
        );
      }
      if (e <= 0) continue;
      unshadowed?[iy * w + ix] = e;
      // Texel außerhalb des Polygons: Wert vom Rand übernehmen (Filterung).
      if (poly.contains(cx, cy)) {
        final among = near.at(ix, iy);
        // Nichts im Weg: ohne Strahlen.
        var vis = among.isEmpty ? n : 0;
        for (var k = 0; k < n && among.isNotEmpty; k++) {
          if (!occ.blockedAmong(
            among,
            cx,
            cy,
            pz,
            sx[k],
            sy[k],
            sz[k],
            hint,
            k,
          )) {
            vis++;
          }
        }
        e *= vis / n;
      }
      out[iy * w + ix] = e;
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
    final inner = y > 0 && y < h - 1;
    for (var x = 0; x < w; x++) {
      if (inner && x > 0 && x < w - 1) {
        // Mitten in der Fläche: alle neun Nachbarn, in derselben
        // Reihenfolge wie am Rand (gleiche Rundung).
        final a = (y - 1) * w + x, b = a + w, c = b + w;
        var s = 0.0;
        s += src[a - 1];
        s += src[a];
        s += src[a + 1];
        s += src[b - 1];
        s += src[b];
        s += src[b + 1];
        s += src[c - 1];
        s += src[c];
        s += src[c + 1];
        out[b] = s / 9;
        continue;
      }
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

/// Die Körper, die Strahlen von einer Fläche aus treffen können, je Kachel
/// von [_kBlock] × [_kBlock] Texeln: große Böden fragen so je Strahl nur die
/// Möbel in ihrer Richtung ab, nicht alle des Raums. Eine Kachel wird erst
/// bestimmt, wenn ein Texel darin fragt.
class _NearBlocks {
  _NearBlocks(
    this._occ,
    this._r,
    this._all,
    this._x0,
    this._y0,
    this._z0,
    this._x1,
    this._y1,
    this._z1, {
    required this.sweep,
  }) : _split = _all.length > 4 && _r.width * _r.height > _kBlock * _kBlock,
       _row = List<Int32List?>.filled((_r.width >> _kShift) + 1, null);

  static const int _kShift = 4;
  static const int _kBlock = 1 << _kShift;

  final LightOccluders _occ;
  final LightReceiver _r;

  /// Auswahl für die ganze Fläche.
  final Int32List _all;

  /// [sweep]: so weit reichen die Strahlen von jedem Texel aus (Sonne).
  /// Sonst der Quader um die Ziele der Strahlen (Punkte der Lampe).
  final double _x0, _y0, _z0, _x1, _y1, _z1;
  final bool sweep;
  final bool _split;
  final List<Int32List?> _row;
  int _rowIndex = -1;

  Int32List at(int ix, int iy) {
    if (!_split) return _all;
    final by = iy >> _kShift;
    if (by != _rowIndex) {
      _rowIndex = by;
      _row.fillRange(0, _row.length, null);
    }
    final bx = ix >> _kShift;
    return _row[bx] ??= _blockAt(bx, by);
  }

  Int32List _blockAt(int bx, int by) {
    final r = _r;
    final ax = r.minX + (bx << _kShift) / r.width * r.sizeX;
    final ay = r.minY + (by << _kShift) / r.height * r.sizeY;
    final bxEnd = math.min(r.width, (bx + 1) << _kShift);
    final byEnd = math.min(r.height, (by + 1) << _kShift);
    final cx = r.minX + bxEnd / r.width * r.sizeX;
    final cy = r.minY + byEnd / r.height * r.sizeY;
    final zLo = r.z, zHi = r.z + 0.002;
    return sweep
        ? _occ.among(
            _all,
            ax + _x0,
            ay + _y0,
            zLo + _z0,
            cx + _x1,
            cy + _y1,
            zHi + _z1,
          )
        : _occ.among(
            _all,
            math.min(ax, _x0),
            math.min(ay, _y0),
            math.min(zLo, _z0),
            math.max(cx, _x1),
            math.max(cy, _y1),
            math.max(zHi, _z1),
          );
  }
}

/// Umriss einer Fläche als Zahlenfelder für den Punkt-im-Polygon-Test.
class _PolyXY {
  _PolyXY(List<V3> polygon)
    : x = Float64List(polygon.length),
      y = Float64List(polygon.length) {
    for (var i = 0; i < polygon.length; i++) {
      x[i] = polygon[i].x;
      y[i] = polygon[i].y;
    }
  }

  final Float64List x, y;

  bool contains(double px, double py) {
    var inside = false;
    final n = x.length;
    for (var i = 0, j = n - 1; i < n; j = i++) {
      final xi = x[i], yi = y[i];
      final xj = x[j], yj = y[j];
      if ((yi > py) != (yj > py) &&
          px < (xj - xi) * (py - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    return inside;
  }
}

/// Summe der Lampen einer Fläche als RGBA-Pixel (sRGB, für eine
/// Emissive-Textur). [lamps] sind (Beleuchtung, lineare Farbe × Stärke).
/// Gibt die Pixel und den Faktor zurück, mit dem die Textur zu
/// multiplizieren ist (die Pixel sind auf den hellsten Wert normiert).
(Uint8List, double) combineLamps(
  int texels,
  List<(Float32List, double, double, double)> lamps,
) {
  final rgb = sumLamps(texels, lamps);
  final max = peakOf(rgb);
  final px = Uint8List(texels * 4);
  if (max <= 0) return (px, 0);
  encodeLight(rgb, max, px, texels, 1);
  return (px, max);
}

/// Summe der Lampen einer Fläche als lineares RGB (drei Werte je Texel).
/// [lamps] sind (Beleuchtung, lineare Farbe × Stärke).
Float32List sumLamps(
  int texels,
  List<(Float32List, double, double, double)> lamps,
) {
  final rgb = Float32List(texels * 3);
  for (final (e, r, g, b) in lamps) {
    for (var i = 0, o = 0; i < texels; i++, o += 3) {
      final v = e[i];
      if (v == 0) continue;
      rgb[o] += v * r;
      rgb[o + 1] += v * g;
      rgb[o + 2] += v * b;
    }
  }
  return rgb;
}

/// Hellster Wert in [rgb] (0, wenn alles dunkel ist).
double peakOf(Float32List rgb) {
  var max = 0.0;
  for (var i = 0; i < rgb.length; i++) {
    final v = rgb[i];
    if (v > max) max = v;
  }
  return max;
}

/// [rgb] (linear, [width] × [height] Texel) auf [max] normiert als sRGB nach
/// [out] schreiben (RGBA, Alpha 255): ab Texel ([x], [y]) in einem Bild mit
/// [stride] Texeln je Zeile. So liegen mehrere Flächen in einer Textur.
///
/// Mit [gutter] bekommt die Fläche ringsum so viele Texel Rand, in denen sie
/// sich wiederholt: die Filterung am Rand (und knapp daneben, wo
/// Kantenglättung über die Fläche hinaus abtastet) ergibt dasselbe wie bei
/// einer eigenen, sich wiederholenden Textur.
void encodeLight(
  Float32List rgb,
  double max,
  Uint8List out,
  int width,
  int height, {
  int stride = -1,
  int x = 0,
  int y = 0,
  int gutter = 0,
}) {
  final row = stride < 0 ? width : stride;
  final codes = _SrgbCodes.instance;
  for (var iy = 0; iy < height; iy++) {
    var o = ((y + iy) * row + x) * 4;
    var i = iy * width * 3;
    for (var ix = 0; ix < width; ix++, o += 4, i += 3) {
      out[o] = codes.of(rgb[i] / max);
      out[o + 1] = codes.of(rgb[i + 1] / max);
      out[o + 2] = codes.of(rgb[i + 2] / max);
      out[o + 3] = 255;
    }
  }
  if (gutter <= 0) return;
  for (var iy = -gutter; iy < height + gutter; iy++) {
    final fy = iy % height;
    for (var ix = -gutter; ix < width + gutter; ix++) {
      if (ix >= 0 && ix < width && iy >= 0 && iy < height) {
        // Innen steht schon alles: gleich hinter die Fläche.
        ix = width - 1;
        continue;
      }
      final f = ((y + fy) * row + x + ix % width) * 4;
      final t = ((y + iy) * row + x + ix) * 4;
      out[t] = out[f];
      out[t + 1] = out[f + 1];
      out[t + 2] = out[f + 2];
      out[t + 3] = out[f + 3];
    }
  }
}

/// sRGB-Stufe (0 … 255) eines linearen Werts, ohne Potenz je Texel: eine
/// Tabelle schätzt die Stufe, die genauen Schwellen stellen sie richtig.
/// Ergibt für jeden Wert dieselbe Stufe wie die Formel.
class _SrgbCodes {
  _SrgbCodes._() {
    // Kleinster Wert je Stufe: die Formel steigt monoton.
    _from[0] = 0;
    for (var c = 1; c < 256; c++) {
      var lo = 0.0, hi = 1.0;
      if (_formula(hi) < c) {
        _from[c] = double.infinity;
        continue;
      }
      // Bis lo und hi benachbarte Zahlen sind.
      while (true) {
        final mid = (lo + hi) / 2;
        if (mid == lo || mid == hi) break;
        if (_formula(mid) >= c) {
          hi = mid;
        } else {
          lo = mid;
        }
      }
      _from[c] = hi;
    }
    var c = 0;
    for (var i = 0; i < _guess.length; i++) {
      final v = i / (_guess.length - 1);
      while (c < 255 && v >= _from[c + 1]) {
        c++;
      }
      _guess[i] = c;
    }
  }

  static final _SrgbCodes instance = _SrgbCodes._();

  final Float64List _from = Float64List(256);
  final Uint8List _guess = Uint8List(4097);

  static int _formula(double v) {
    final s = v <= 0.0031308 ? v * 12.92 : 1.055 * math.pow(v, 1 / 2.4) - 0.055;
    return (s * 255).round().clamp(0, 255);
  }

  int of(double value) {
    final v = value < 0 ? 0.0 : (value > 1 ? 1.0 : value);
    var c = _guess[(v * 4096).floor()];
    while (c < 255 && v >= _from[c + 1]) {
      c++;
    }
    return c;
  }
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
  final n = dirs.length;
  // Strahlen der Länge [reach] in jede Richtung, und alles, was sie von
  // der Fläche aus treffen können.
  final rx = Float64List(n), ry = Float64List(n), rz = Float64List(n);
  final pz = r.z + 0.002;
  final bx0 = r.minX, by0 = r.minY;
  final bx1 = r.minX + r.sizeX, by1 = r.minY + r.sizeY;
  var x0 = bx0, y0 = by0, z0 = r.z;
  var x1 = bx1, y1 = by1, z1 = pz;
  // Wie weit die Strahlen von einem Texel aus höchstens reichen.
  var vx0 = 0.0, vy0 = 0.0, vz0 = 0.0, vx1 = 0.0, vy1 = 0.0, vz1 = 0.0;
  for (var k = 0; k < n; k++) {
    final v = dirs[k] * reach;
    rx[k] = v.x;
    ry[k] = v.y;
    rz[k] = v.z;
    x0 = math.min(x0, bx0 + v.x);
    y0 = math.min(y0, by0 + v.y);
    z0 = math.min(z0, pz + v.z);
    x1 = math.max(x1, bx1 + v.x);
    y1 = math.max(y1, by1 + v.y);
    z1 = math.max(z1, pz + v.z);
    vx0 = math.min(vx0, v.x);
    vy0 = math.min(vy0, v.y);
    vz0 = math.min(vz0, v.z);
    vx1 = math.max(vx1, v.x);
    vy1 = math.max(vy1, v.y);
    vz1 = math.max(vz1, v.z);
  }
  final near = _NearBlocks(
    occ,
    r,
    occ.near(x0, y0, z0, x1, y1, z1),
    vx0,
    vy0,
    vz0,
    vx1,
    vy1,
    vz1,
    sweep: true,
  );
  final hint = Int32List(n * 2)..fillRange(0, n * 2, -1);
  final poly = _PolyXY(r.polygon);
  final w = r.width, h = r.height;
  for (var iy = 0; iy < h; iy++) {
    final cy = r.minY + (iy + 0.5) / h * r.sizeY;
    for (var ix = 0; ix < w; ix++) {
      final cx = r.minX + (ix + 0.5) / w * r.sizeX;
      if (!poly.contains(cx, cy)) {
        out[iy * w + ix] = cos;
        continue;
      }
      final among = near.at(ix, iy);
      // Nichts im Weg: ohne Strahlen.
      var vis = among.isEmpty ? n : 0;
      for (var k = 0; k < n && among.isNotEmpty; k++) {
        if (!occ.blockedAmong(
          among,
          cx,
          cy,
          pz,
          cx + rx[k],
          cy + ry[k],
          pz + rz[k],
          hint,
          k,
        )) {
          vis++;
        }
      }
      out[iy * w + ix] = cos * vis / n;
    }
  }
  return _blur(out, r.width, r.height);
}

// ---- Aufträge (reine Daten, auch in einem Isolate rechenbar) --------------

/// Ein Bake-Auftrag für Fläche Nummer [receiver]: nur Daten, kein GPU-Objekt,
/// damit ihn ein Hintergrund-Isolate rechnen kann ([runBakeTasks]).
sealed class BakeTask {
  const BakeTask(this.receiver, this.surface, this.samples);
  final int receiver;
  final LightReceiver surface;
  final int samples;
}

/// Sonne aus Richtung [toSun] (von der Fläche zur Sonne).
final class SunBakeTask extends BakeTask {
  const SunBakeTask(
    super.receiver,
    super.surface,
    super.samples, {
    required this.toSun,
    required this.occluders,
  });
  final V3 toSun;
  final LightOccluders occluders;
}

/// Lampe [lampId] an [position]. [own]: die Fläche liegt im Raum der Lampe,
/// sonst kommt Licht nur durch Türen und offene Wände ([walls]).
final class LampBakeTask extends BakeTask {
  const LampBakeTask(
    super.receiver,
    super.surface,
    super.samples, {
    required this.lampId,
    required this.position,
    required this.axis,
    required this.cone,
    this.softness = kConeSoftness,
    required this.gain,
    required this.own,
    required this.objects,
    required this.lamp,
    required this.walls,
  });
  final String lampId;
  final V3 position, axis;
  final double? cone;
  final double softness;
  final double gain;
  final bool own;
  final LightOccluders objects, lamp, walls;
}

/// Ergebnis eines [BakeTask]: Licht mit und ohne Schatten. [lampId] `null`
/// heißt Sonne; [lit] `null`: kein Licht (Lampe aus der Fläche nehmen).
class BakeResult {
  const BakeResult(this.receiver, this.lampId, this.lit, this.open);
  final int receiver;
  final String? lampId;
  final Float32List? lit, open;
}

BakeResult runBakeTask(BakeTask t) {
  final r = t.surface;
  switch (t) {
    case SunBakeTask():
      final cos = math.max(0.0, t.toSun.normalized.z);
      return BakeResult(
        t.receiver,
        null,
        bakeSun(r, t.toSun, t.occluders, samples: t.samples),
        Float32List(r.width * r.height)..fillRange(0, r.width * r.height, cos),
      );
    case LampBakeTask():
      Float32List scaled(Float32List v) {
        if (t.gain != 1) {
          for (var i = 0; i < v.length; i++) {
            v[i] *= t.gain;
          }
        }
        return v;
      }
      if (t.own) {
        final open = Float32List(r.width * r.height);
        final lit = bakeLamp(
          r,
          t.position,
          t.objects,
          samples: t.samples,
          unshadowed: open,
          cone: t.cone,
          softness: t.softness,
          axis: t.axis,
        );
        return BakeResult(t.receiver, t.lampId, scaled(lit), scaled(open));
      }
      // Nachbarraum der Zone: erst billig prüfen, ob durch Tür oder offene
      // Wand überhaupt Licht ankommt.
      final through = bakeLamp(
        r,
        t.position,
        t.walls,
        samples: 1,
        cone: t.cone,
        softness: t.softness,
        axis: t.axis,
      );
      if (!through.any((v) => v > 0)) {
        return BakeResult(t.receiver, t.lampId, null, null);
      }
      final lit = bakeLamp(
        r,
        t.position,
        t.lamp,
        samples: t.samples,
        cone: t.cone,
        softness: t.softness,
        axis: t.axis,
      );
      return BakeResult(t.receiver, t.lampId, scaled(lit), scaled(through));
  }
}

/// Alle [tasks] rechnen (für `compute`: oberste Ebene, nur Daten).
List<BakeResult> runBakeTasks(List<BakeTask> tasks) => [
  for (final t in tasks) runBakeTask(t),
];
