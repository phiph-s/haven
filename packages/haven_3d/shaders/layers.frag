#version 460 core
// Lichtebenen zusammensetzen (siehe layers.dart, render_compose.py):
//   hdr  = T⁻¹(start)/e + Σ faktor · (T⁻¹(ebene) − T⁻¹(bezug))/e
//   bild = T(hdr)
// T = PBR Neutral (wie flutter_scene), auf linearem Licht. Texturen sind
// vormultipliziert, sRGB-kodiert.
#include <flutter/runtime_effect.glsl>

precision highp float;

// Zielrechteck auf der Leinwand und Größe der Ebenen in Pixeln.
uniform vec2 uOrigin;
uniform vec2 uSize;
uniform vec2 uImage;
uniform float uExposure;
// 1: Raum an (Möbellinien aus), Start ist das Bild mit Raumausschnitt.
uniform float uLit;
uniform float uCount;
// Lampen: Ausschnitt (x, y, w, h) im Bild und Faktor je Kanal (linear,
// Helligkeit/gain eingerechnet); w des Faktors 1: Bezug ist „Raum an“.
uniform vec4 uRect0;
uniform vec4 uRect1;
uniform vec4 uRect2;
uniform vec4 uRect3;
uniform vec4 uRect4;
uniform vec4 uRect5;
uniform vec4 uRect6;
uniform vec4 uRect7;
uniform vec4 uFactor0;
uniform vec4 uFactor1;
uniform vec4 uFactor2;
uniform vec4 uFactor3;
uniform vec4 uFactor4;
uniform vec4 uFactor5;
uniform vec4 uFactor6;
uniform vec4 uFactor7;

uniform sampler2D uBase;
uniform sampler2D uRoom;
uniform sampler2D uLamp0;
uniform sampler2D uLamp1;
uniform sampler2D uLamp2;
uniform sampler2D uLamp3;
uniform sampler2D uLamp4;
uniform sampler2D uLamp5;
uniform sampler2D uLamp6;
uniform sampler2D uLamp7;

out vec4 fragColor;

const float KS = 0.76;
const float D = 0.24;
const float DS = 0.15;

vec3 toLinear(vec3 c) {
  return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}

vec3 toSrgb(vec3 l) {
  l = clamp(l, 0.0, 1.0);
  return mix(l * 12.92, 1.055 * pow(l, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, l));
}

vec3 tone(vec3 c) {
  float x = min(c.r, min(c.g, c.b));
  float off = x < 0.08 ? x - 6.25 * x * x : 0.04;
  c -= off;
  float peak = max(c.r, max(c.g, c.b));
  if (peak < KS) return c;
  float np = 1.0 - D * D / (peak + D - KS);
  float g = 1.0 - 1.0 / (DS * (peak - np) + 1.0);
  return mix(c * np / peak, vec3(np), g);
}

vec3 untone(vec3 y) {
  float p = max(y.r, max(y.g, y.b));
  if (p >= KS) {
    float pc = min(p, 0.995);
    float peak = D * D / (1.0 - pc) - D + KS;
    float g = 1.0 - 1.0 / (DS * (peak - pc) + 1.0);
    y = (y - g * pc) * peak / max((1.0 - g) * pc, 1e-6);
  }
  float m = max(min(y.r, min(y.g, y.b)), 0.0);
  float x = m >= 0.04 ? m + 0.04 : sqrt(m / 6.25);
  float off = x < 0.08 ? x - 6.25 * x * x : 0.04;
  return y + off;
}

vec3 hdrOf(vec4 c) {
  if (c.a <= 0.0) return vec3(0.0);
  return untone(toLinear(c.rgb / c.a)) / uExposure;
}

// Beitrag einer Lampe aus ihrem Pixel [l] im Ausschnitt.
vec3 lampDelta(vec4 l, vec4 factor, vec2 uv) {
  vec4 ref = factor.w > 0.5 ? texture(uRoom, uv) : texture(uBase, uv);
  return (hdrOf(l) - hdrOf(ref)) * factor.rgb;
}

bool inside(vec2 q) {
  return q.x >= 0.0 && q.y >= 0.0 && q.x <= 1.0 && q.y <= 1.0;
}

// Ein Pixel; main() weist nur zu (mehrere return in main() mit Texturen
// machen auf Windows Probleme, flutter/flutter#190809).
vec4 shade(vec2 uv) {
  if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
    return vec4(0.0);
  }
  vec4 start = uLit > 0.5 ? texture(uRoom, uv) : texture(uBase, uv);
  if (start.a <= 0.0) {
    return vec4(0.0);
  }
  vec2 px = uv * uImage;
  vec3 hdr = hdrOf(start);
  if (uCount > 0.5) {
    vec2 q = (px - uRect0.xy) / uRect0.zw;
    if (inside(q)) hdr += lampDelta(texture(uLamp0, q), uFactor0, uv);
  }
  if (uCount > 1.5) {
    vec2 q = (px - uRect1.xy) / uRect1.zw;
    if (inside(q)) hdr += lampDelta(texture(uLamp1, q), uFactor1, uv);
  }
  if (uCount > 2.5) {
    vec2 q = (px - uRect2.xy) / uRect2.zw;
    if (inside(q)) hdr += lampDelta(texture(uLamp2, q), uFactor2, uv);
  }
  if (uCount > 3.5) {
    vec2 q = (px - uRect3.xy) / uRect3.zw;
    if (inside(q)) hdr += lampDelta(texture(uLamp3, q), uFactor3, uv);
  }
  if (uCount > 4.5) {
    vec2 q = (px - uRect4.xy) / uRect4.zw;
    if (inside(q)) hdr += lampDelta(texture(uLamp4, q), uFactor4, uv);
  }
  if (uCount > 5.5) {
    vec2 q = (px - uRect5.xy) / uRect5.zw;
    if (inside(q)) hdr += lampDelta(texture(uLamp5, q), uFactor5, uv);
  }
  if (uCount > 6.5) {
    vec2 q = (px - uRect6.xy) / uRect6.zw;
    if (inside(q)) hdr += lampDelta(texture(uLamp6, q), uFactor6, uv);
  }
  if (uCount > 7.5) {
    vec2 q = (px - uRect7.xy) / uRect7.zw;
    if (inside(q)) hdr += lampDelta(texture(uLamp7, q), uFactor7, uv);
  }
  vec3 c = toSrgb(tone(max(hdr, vec3(0.0))));
  return vec4(c * start.a, start.a);
}

void main() {
  fragColor = shade((FlutterFragCoord().xy - uOrigin) / uSize);
}
