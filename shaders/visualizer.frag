#version 460 core
// Mytify full screen visualizations. One program, four scenes picked by uMode.
// Inputs come from real band levels of the output; nothing here invents rhythm.
#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;
uniform float uTime;   // scene time, advanced faster by louder music
uniform float uBass;   // 0..1, smoothed
uniform float uMid;
uniform float uHigh;
uniform float uEnergy;
uniform float uBeat;   // 1 on a bass onset, decays
uniform float uMode;   // 0 plasma, 1 ribbons, 2 vortex, 3 retro

out vec4 fragColor;

const vec3 TEAL = vec3(0.0, 0.78, 0.74);
const vec3 GREEN = vec3(0.0, 0.90, 0.46);
const vec3 PURPLE = vec3(0.42, 0.24, 0.98);
const vec3 DEEP = vec3(0.012, 0.024, 0.035);

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
             mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  mat2 r = mat2(0.8, 0.6, -0.6, 0.8);
  for (int i = 0; i < 4; i++) {
    v += a * noise(p);
    p = r * p * 2.03 + vec2(1.7, 9.2);
    a *= 0.5;
  }
  return v;
}

vec3 tint(float x) {
  // Deep teal through green to violet, the Mytify palette.
  x = clamp(x, 0.0, 1.0);
  vec3 c = mix(TEAL, GREEN, smoothstep(0.0, 0.5, x));
  return mix(c, PURPLE, smoothstep(0.55, 1.0, x));
}

vec3 plasma(vec2 uv, float t) {
  // Large, slow folds: low frequencies and few contour lines keep it calm.
  float warp = 1.1 + uBass * 3.2 + uBeat * 1.2;
  vec2 q = vec2(fbm(uv * 0.9 + vec2(0.0, t * 0.08)), fbm(uv * 0.9 + vec2(5.2, -t * 0.07)));
  vec2 r = vec2(fbm(uv * 0.8 + warp * q + vec2(1.7, 9.2) + t * 0.10),
                fbm(uv * 0.8 + warp * q + vec2(8.3, 2.8) - t * 0.08));
  float f = fbm(uv * 0.7 + (1.3 + uMid * 2.2) * r);
  // Glowing contour lines of the warped field.
  float x = f * 4.5;
  float d = abs(fract(x) - 0.5);
  float sharp = 320.0 - uHigh * 200.0;
  float line = exp(-d * d * sharp);
  float halo = exp(-d * 9.0) * 0.22;
  vec3 col = DEEP + tint(f * 1.3 - 0.15) * 0.10 * (0.6 + uEnergy);
  col += tint(length(r) * 0.9 + uMid * 0.3) * (line * (0.35 + 1.6 * uEnergy + uBeat * 0.8) + halo * (0.6 + uEnergy * 1.5));
  // Small rings where the field folds, brighter on beats.
  float ring = exp(-pow(abs(length(q - 0.5) - 0.08), 2.0) * 3000.0);
  col += GREEN * ring * (0.15 + uBeat * 0.6);
  return col;
}

vec3 ribbons(vec2 uv, float t) {
  vec3 col = DEEP;
  for (int i = 0; i < 6; i++) {
    float fi = float(i);
    float band = fi < 2.0 ? uBass : (fi < 4.0 ? uMid : uHigh);
    float amp = 0.04 + 0.38 * band;
    float y = 0.13 * sin(uv.x * (1.3 + fi * 0.33) + t * (0.45 + fi * 0.11) + fi * 1.3)
            + amp * sin(uv.x * (2.6 + fi * 0.45) - t * (0.7 + 0.09 * fi))
            + 0.08 * (fbm(vec2(uv.x * 1.1 + fi * 3.1, t * 0.18)) - 0.5)
            + (fi - 2.5) * 0.045;
    float d = abs(uv.y - y);
    float core = exp(-d * d * (5200.0 - band * 3500.0));
    float halo = exp(-d * 22.0) * 0.28;
    // Ribbons fade at the screen edges instead of ending abruptly.
    float edge = smoothstep(1.05, 0.25, abs(uv.x));
    col += mix(TEAL, PURPLE, fi / 5.0) * (core * 0.95 + halo) * (0.3 + 1.5 * band + uBeat * 0.5) * edge;
  }
  return col;
}

vec3 vortex(vec2 uv, float t) {
  float r = length(uv) + 1e-4;
  float a = atan(uv.y, uv.x);
  float twist = 4.0 + uBass * 6.0 + uBeat * 2.0;
  float s = a * 5.0 + log(r) * twist - t * 1.6 + (fbm(uv * 2.5 + t * 0.15) - 0.5) * 2.2;
  float arms = exp(-abs(sin(s)) * (7.0 - uHigh * 3.0));
  float fade = smoothstep(0.02, 0.18, r) * smoothstep(1.25, 0.25, r);
  vec3 col = DEEP + mix(PURPLE, TEAL, smoothstep(0.1, 0.8, r)) * arms * fade * (0.3 + 1.6 * uEnergy + uBeat * 0.6);
  col += GREEN * exp(-r * (10.0 - uBass * 6.0)) * (0.25 + uBass * 1.4 + uBeat * 0.9);
  return col;
}

vec3 retro(vec2 uv, float t) {
  // Classic colour plasma in the spirit of old desktop players.
  vec2 p = uv * 3.0;
  float v = sin(p.x * 2.2 + t);
  v += sin(2.0 * (p.x * sin(t * 0.5) + p.y * cos(t * 0.33)) + t);
  vec2 c = p + vec2(1.5 * sin(t * 0.2), 1.5 * cos(t * 0.33));
  v += sin(sqrt(4.0 * dot(c, c) + 1.0) * (1.0 + uBass * 2.5) + t);
  v *= 1.0 + uMid * 1.2;
  float hue = t * 0.15 + uBeat * 0.8;
  vec3 col = 0.5 + 0.5 * vec3(sin(v * 3.1416 + hue), sin(v * 3.1416 + hue + 2.094), sin(v * 3.1416 + hue + 4.188));
  return col * (0.25 + 1.1 * uEnergy + uBeat * 0.3);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = (frag - 0.5 * uSize) / min(uSize.x, uSize.y);
  float t = uTime;
  vec3 col;
  if (uMode < 0.5) {
    col = plasma(uv, t);
  } else if (uMode < 1.5) {
    col = ribbons(uv, t);
  } else if (uMode < 2.5) {
    col = vortex(uv, t);
  } else {
    col = retro(uv, t);
  }
  // Beat flash and vignette.
  col *= 1.0 + uBeat * 0.35;
  vec2 v = frag / uSize - 0.5;
  col *= 1.0 - dot(v, v) * 1.1;
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
