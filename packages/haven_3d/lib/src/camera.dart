import 'dart:math' as math;
import 'dart:ui' show Offset, Size, lerpDouble;

import 'package:flutter/foundation.dart';

import 'model.dart';

/// Punkt in Kamerakoordinaten: [x], [y] in Pixeln auf dem Bildschirm,
/// [depth] in Metern, größer ist näher an der Kamera.
@immutable
class ViewPoint {
  const ViewPoint(this.x, this.y, this.depth);
  final double x;
  final double y;
  final double depth;
  Offset get offset => Offset(x, y);
}

/// Kamera, die um einen Punkt kreist, orthographisch oder perspektivisch.
///
/// [pitch] 0 ist die Draufsicht (Bild wie der 2D-Plan), `π/2` die Seitenansicht
/// waagerecht von Süden. [yaw] dreht die Welt im Uhrzeigersinn auf dem Plan
/// (Blick wandert gegen den Uhrzeigersinn um den Raum). [scale] sind Pixel je
/// Meter (bei Perspektive auf Höhe von [target]), [pan] verschiebt das Bild
/// in Pixeln. [target] liegt bei `pan == 0` in der Bildmitte.
///
/// [fov] ist der senkrechte Öffnungswinkel in Bogenmaß, 0 heißt
/// orthographisch. Der Abstand der Kamera folgt aus [fov] und [scale], so
/// dass der Maßstab auf Höhe von [target] gleich bleibt: Umschalten (und
/// Überblenden über [lerp]) springt nicht.
@immutable
class OrbitCamera {
  const OrbitCamera({
    this.target = V3.zero,
    this.yaw = 0,
    this.pitch = 0,
    this.scale = 40,
    this.pan = Offset.zero,
    this.fov = 0,
  });

  static const double maxPitch = math.pi / 2;

  /// Öffnungswinkel für die perspektivische Ansicht (40°).
  static const double perspectiveFov = 40 * math.pi / 180;

  final V3 target;
  final double yaw;
  final double pitch;
  final double scale;
  final Offset pan;
  final double fov;

  bool get isTopDown => pitch.abs() < 1e-6 && yaw.abs() < 1e-6;

  bool get isPerspective => fov > 1e-3;

  /// Bild-rechts, Bild-unten und Richtung zur Kamera in Weltkoordinaten.
  ({V3 right, V3 down, V3 toCam}) get basis {
    final c = math.cos(yaw), s = math.sin(yaw);
    final cp = math.cos(pitch), sp = math.sin(pitch);
    return (
      right: V3(c, -s, 0),
      down: V3(s * cp, c * cp, -sp),
      toCam: V3(s * sp, c * sp, cp),
    );
  }

  /// Ziel nach der Verschiebung um [pan] (die Kamera verschiebt sich mit,
  /// so passen Overlays auch bei Perspektive).
  V3 get panTarget {
    final b = basis;
    return target - b.right * (pan.dx / scale) - b.down * (pan.dy / scale);
  }

  /// Abstand der Kamera vom Ziel bei Perspektive in einer Fläche [size].
  double distance(Size size) => isPerspective
      ? (size.height / 2) / (scale * math.tan(fov / 2))
      : double.infinity;

  /// Weltpunkt → Bildschirm in einer Fläche der Größe [size].
  ViewPoint project(V3 p, Size size) {
    final v = _view(p - panTarget);
    var k = 1.0;
    if (isPerspective) {
      final d = distance(size);
      k = d / math.max(d - v.z, 0.05);
    }
    return ViewPoint(
      size.width / 2 + v.x * scale * k,
      size.height / 2 + v.y * scale * k,
      v.z,
    );
  }

  /// Richtung in Kamerakoordinaten (ohne Verschiebung und Maßstab):
  /// `x` rechts, `y` unten, `z` zur Kamera hin.
  V3 viewDir(V3 d) => _view(d);

  /// Zeigt [normal] zur Kamera? Wert > 0 heißt sichtbar (bei Perspektive
  /// genähert über die Blickrichtung zur Bildmitte).
  double facing(V3 normal) => _view(normal).z;

  V3 _view(V3 d) {
    final c = math.cos(yaw), s = math.sin(yaw);
    final x1 = d.x * c - d.y * s;
    final y1 = d.x * s + d.y * c;
    final cp = math.cos(pitch), sp = math.sin(pitch);
    return V3(x1, y1 * cp - d.z * sp, d.z * cp + y1 * sp);
  }

  /// Bildschirmpunkt auf der Ebene `z = [z]` (z. B. Boden), `null` wenn der
  /// Sehstrahl die Ebene nicht trifft.
  V3? unprojectOnPlane(Offset screen, Size size, {double z = 0}) {
    final b = basis;
    final t0 = panTarget;
    final sx = (screen.dx - size.width / 2) / scale;
    final sy = (screen.dy - size.height / 2) / scale;
    // Punkt auf der Bildebene durch das Ziel.
    final q = t0 + b.right * sx + b.down * sy;
    final V3 origin, dir;
    if (isPerspective) {
      origin = t0 + b.toCam * distance(size);
      dir = q - origin;
    } else {
      origin = q;
      dir = -b.toCam;
    }
    if (dir.z.abs() < 1e-9) return null;
    final t = (z - origin.z) / dir.z;
    if (isPerspective && t <= 0) return null;
    final hit = origin + dir * t;
    return V3(hit.x, hit.y, z);
  }

  /// Kamera mit derselben Blickrichtung, die alle [points] mit [padding]
  /// Pixeln Rand in [size] zeigt: Ziel ist die Mitte der umschließenden Box,
  /// [pan] wird 0.
  OrbitCamera fit(
    Iterable<V3> points,
    Size size, {
    double padding = 24,
    double maxScale = 400,
  }) {
    final it = points.iterator;
    if (!it.moveNext()) return this;
    var minX = it.current.x, maxX = minX;
    var minY = it.current.y, maxY = minY;
    var minZ = it.current.z, maxZ = minZ;
    while (it.moveNext()) {
      final p = it.current;
      minX = math.min(minX, p.x);
      maxX = math.max(maxX, p.x);
      minY = math.min(minY, p.y);
      maxY = math.max(maxY, p.y);
      minZ = math.min(minZ, p.z);
      maxZ = math.max(maxZ, p.z);
    }
    final center = V3((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2);
    // Die Projektion einer Box ist punktsymmetrisch zur Projektion ihrer
    // Mitte, die Ecken genügen also für die Ausdehnung.
    var ex = 0.0, ey = 0.0;
    for (final x in [minX, maxX]) {
      for (final y in [minY, maxY]) {
        for (final z in [minZ, maxZ]) {
          final v = _view(V3(x, y, z) - center);
          ex = math.max(ex, v.x.abs());
          ey = math.max(ey, v.y.abs());
        }
      }
    }
    final aw = math.max(1.0, size.width - 2 * padding);
    final ah = math.max(1.0, size.height - 2 * padding);
    final s = math.min(
      maxScale,
      math.min(
        ex < 1e-9 ? maxScale : aw / (2 * ex),
        ey < 1e-9 ? maxScale : ah / (2 * ey),
      ),
    );
    return copyWith(target: center, scale: s, pan: Offset.zero);
  }

  OrbitCamera copyWith({
    V3? target,
    double? yaw,
    double? pitch,
    double? scale,
    Offset? pan,
    double? fov,
  }) => OrbitCamera(
    target: target ?? this.target,
    yaw: yaw ?? this.yaw,
    pitch: (pitch ?? this.pitch).clamp(0.0, maxPitch),
    scale: scale ?? this.scale,
    pan: pan ?? this.pan,
    fov: fov ?? this.fov,
  );

  /// Übergang von [a] nach [b]. [yaw] nimmt den kürzeren Weg.
  static OrbitCamera lerp(OrbitCamera a, OrbitCamera b, double t) {
    var dy = (b.yaw - a.yaw) % (2 * math.pi);
    if (dy > math.pi) dy -= 2 * math.pi;
    if (dy < -math.pi) dy += 2 * math.pi;
    return OrbitCamera(
      target: V3.lerp(a.target, b.target, t),
      yaw: a.yaw + dy * t,
      pitch: lerpDouble(a.pitch, b.pitch, t)!,
      // Maßstab logarithmisch, damit Zoomen gleichmäßig wirkt.
      scale: math.exp(lerpDouble(math.log(a.scale), math.log(b.scale), t)!),
      pan: Offset.lerp(a.pan, b.pan, t)!,
      fov: lerpDouble(a.fov, b.fov, t)!,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OrbitCamera &&
      other.target == target &&
      other.yaw == yaw &&
      other.pitch == pitch &&
      other.scale == scale &&
      other.pan == pan &&
      other.fov == fov;

  @override
  int get hashCode => Object.hash(target, yaw, pitch, scale, pan, fov);
}
