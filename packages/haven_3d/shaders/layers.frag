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

// Beitrag einer Lampe aus ihrem Pixel [l] im Ausschnitt [q], Bezug ist
// das Grundbild [base] oder „Raum an“ [room]; außerhalb und für freie
// Plätze (n ≥ uCount) null.
vec3 lampDelta(vec4 l, vec2 q, vec4 factor, float n, vec4 base, vec4 room) {
  bool on = uCount > n + 0.5 && q.x >= 0.0 && q.y >= 0.0 && q.x <= 1.0 &&
      q.y <= 1.0;
  vec4 ref = factor.w > 0.5 ? room : base;
  return on ? (hdrOf(l) - hdrOf(ref)) * factor.rgb : vec3(0.0);
}

vec2 lampUv(vec2 px, vec4 rect) {
  return (px - rect.xy) / rect.zw;
}

// Ein Pixel. Alle Texturen werden immer gelesen (außerhalb jeder
// Verzweigung): verkleinert wird mit Mipmaps, und deren Stufe hängt an
// den Ableitungen benachbarter Pixel. main() weist nur zu (mehrere return
// in main() mit Texturen machen auf Windows Probleme, flutter/flutter#190809).
vec4 shade(vec2 uv) {
  vec2 px = uv * uImage;
  vec2 q0 = lampUv(px, uRect0);
  vec2 q1 = lampUv(px, uRect1);
  vec2 q2 = lampUv(px, uRect2);
  vec2 q3 = lampUv(px, uRect3);
  vec2 q4 = lampUv(px, uRect4);
  vec2 q5 = lampUv(px, uRect5);
  vec2 q6 = lampUv(px, uRect6);
  vec2 q7 = lampUv(px, uRect7);
  vec4 base = texture(uBase, uv);
  vec4 room = texture(uRoom, uv);
  vec4 l0 = texture(uLamp0, q0);
  vec4 l1 = texture(uLamp1, q1);
  vec4 l2 = texture(uLamp2, q2);
  vec4 l3 = texture(uLamp3, q3);
  vec4 l4 = texture(uLamp4, q4);
  vec4 l5 = texture(uLamp5, q5);
  vec4 l6 = texture(uLamp6, q6);
  vec4 l7 = texture(uLamp7, q7);
  vec4 start = uLit > 0.5 ? room : base;
  vec3 hdr = hdrOf(start);
  hdr += lampDelta(l0, q0, uFactor0, 0.0, base, room);
  hdr += lampDelta(l1, q1, uFactor1, 1.0, base, room);
  hdr += lampDelta(l2, q2, uFactor2, 2.0, base, room);
  hdr += lampDelta(l3, q3, uFactor3, 3.0, base, room);
  hdr += lampDelta(l4, q4, uFactor4, 4.0, base, room);
  hdr += lampDelta(l5, q5, uFactor5, 5.0, base, room);
  hdr += lampDelta(l6, q6, uFactor6, 6.0, base, room);
  hdr += lampDelta(l7, q7, uFactor7, 7.0, base, room);
  vec3 c = toSrgb(tone(max(hdr, vec3(0.0))));
  bool visible = start.a > 0.0 && uv.x >= 0.0 && uv.y >= 0.0 &&
      uv.x <= 1.0 && uv.y <= 1.0;
  return visible ? vec4(c * start.a, start.a) : vec4(0.0);
}

void main() {
  fragColor = shade((FlutterFragCoord().xy - uOrigin) / uSize);
}
