#version 460 core
// Mytify full screen visualizations. One program; uMode picks the scene:
// 0 plasma, 1 ribbons, 2 vortex, 3 retro, 4 space flight, 5 sea, 6 aurora,
// 7 prism club, 8 strobe (opt-in only), 9 retro Amiga.
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
// Palette: the Mytify colours, or three colours of the current cover.
uniform vec3 uColA;
uniform vec3 uColB;
uniform vec3 uColC;

out vec4 fragColor;

#define TEAL uColA
#define GREEN uColB
#define PURPLE uColC
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

// New Mytify scenes. Uses the current visualizer.frag uniform contract.
// Modes 0..3 remain unchanged; modes 4..9 are the new themes.
const float PI2 = 6.28318530718;
float extraStars(vec2 p, float t) {
  vec2 grid = p * 95.0;
  vec2 cell = floor(grid);
  vec2 pos = fract(grid) - 0.5;
  float seed = hash(cell);
  float star = exp(-dot(pos, pos) * 380.0);
  return star * step(0.88, seed) * (0.65 + 0.35 * sin(seed * 100.0 + t * 1.5));
}
// Forward flight: projected stars and independently receding galaxy layers.
// t must remain an INTEGRATED scene clock. Never multiply t by the current bass.
float flightSegment(vec2 p, vec2 a, vec2 b) {
  vec2 pa=p-a, ba=b-a;
  return length(pa-ba*clamp(dot(pa,ba)/max(dot(ba,ba),0.000001),0.0,1.0));
}
vec3 extraCosmos(vec2 p, float t) {
  vec2 camera = vec2(0.015*sin(t*0.37),0.012*cos(t*0.29));
  vec2 view = p-camera;
  vec3 col = vec3(0.004,0.007,0.021);
  col += extraStars(view*0.5,t*0.08)*vec3(0.15,0.19,0.30);
  // Galaxies lie beside the flight path. They grow and move past the screen edge.
  // The camera does not rotate around a single central spiral.
  for(int j=0;j<3;j++) {
    float k=float(j);
    float phase=fract(0.65+k*0.31-t*0.09);
    float depth=0.55+phase*5.0;
    vec2 center=j==0?vec2(1.25,0.35):(j==1?vec2(-1.5,-0.55):vec2(0.90,-0.80));
    vec2 q=view*depth-center;
    float angle=0.25+k*1.10;
    q=mat2(cos(angle),-sin(angle),sin(angle),cos(angle))*q;
    q.y*=2.3;
    float r=length(q)+0.018;
    float a=atan(q.y,q.x);
    float spiral=a*2.0+log(r+0.045)*4.5+k;
    float arms=pow(0.5+0.5*cos(spiral),4.0);
    float grain=0.60+0.40*sin(q.x*18.0+sin(q.y*12.0))*cos(q.y*19.0);
    float cloud=exp(-r*r*2.8)*(0.11+arms*grain);
    vec3 tint=mix(vec3(0.48,0.16,0.85),vec3(0.05,0.55,0.85),0.5+0.5*sin(a+k*2.0));
    float fade=smoothstep(0.0,0.09,phase)*(1.0-smoothstep(0.92,1.0,phase));
    col += (cloud*tint*(0.9+uEnergy*0.6)+exp(-r*25.0)*vec3(0.9,0.78,0.61))*fade;
  }
  // 80 projected stars. Constant bounded loop; no volumetric raymarch or textures.
  for(int i=0;i<80;i++) {
    float k=float(i);
    vec2 seed=vec2(hash(vec2(k,11.3)),hash(vec2(k,37.9)));
    vec2 world=(seed-0.5)*vec2(5.2,3.1);
    float z=fract(hash(vec2(k,73.1))-t*0.22);
    float depth=0.12+z*3.8;
    vec2 point=world/depth;
    vec2 direction=point/max(length(point),0.0001);
    float near=1.0-z;
    float width=0.0011+0.0035*near*near;
    float streak=0.002+(0.015+0.16*uBass)*near*near;
    float d=flightSegment(view,point-direction*streak,point);
    float core=exp(-pow(d/width,2.0));
    float halo=exp(-pow(d/(width*3.0),2.0))*0.16;
    float fade=smoothstep(0.01,0.09,z)*(1.0-smoothstep(0.88,1.0,z));
    vec3 tint=mix(vec3(0.46,0.67,1.0),vec3(1.0,0.90,0.74),seed.y);
    col += tint*(core+halo)*fade*(0.40+0.50*near+uHigh*0.25);
  }
  return col;
}

float oceanHeight(vec2 q, float t) {
  return 0.16 * sin(q.y * 1.6 - t * 2.0) + 0.07 * sin(q.x * 1.4 + q.y * 1.1 + t * 2.0) + 0.025 * sin(q.x * 3.3 - q.y * 3.8 - t * 4.0);
}
vec3 extraOcean(vec2 uv, float t) {
  float horizon = 0.36;
  vec3 sky = vec3(0.025, 0.045, 0.10) + exp(-pow((uv.y-horizon)/0.17,2.0))*vec3(0.12,0.14,0.22);
  vec2 moon = (uv - vec2(0.60,0.15)) * vec2(uSize.x/uSize.y,1.0);
  sky += (1.0-smoothstep(0.024,0.027,length(moon))) * vec3(0.5,0.57,0.64);
  if (uv.y < horizon) return sky;
  vec2 plane = vec2((uv.x-0.5)*2.0, uv.y-horizon);
  float dy = 0.02 + plane.y*1.1;
  float distanceToWater = 1.6/dy;
  vec2 q = vec2(plane.x*distanceToWater*0.7, -distanceToWater);
  for(int i=0;i<3;i++) {
    distanceToWater = (1.6-oceanHeight(q,t)*(0.7+uBass*0.4))/dy;
    q = vec2(plane.x*distanceToWater*0.7,-distanceToWater);
  }
  float eps = 0.025;
  float hh = oceanHeight(q,t);
  vec3 n = normalize(vec3((hh-oceanHeight(q+vec2(eps,0.0),t))/eps,1.0,(hh-oceanHeight(q+vec2(0.0,eps),t))/eps));
  vec3 v = normalize(vec3(-plane.x*0.7,dy,1.0));
  float fresnel = pow(1.0-max(dot(n,v),0.0),3.0);
  float diffuse = max(0.0,dot(n,normalize(vec3(-0.2,0.8,0.55))));
  float foam = pow(0.5+0.5*sin(q.y*1.6-t*2.0),16.0) * (0.15+0.10*uHigh);
  float glitter = pow(max(dot(reflect(-normalize(vec3(0.2,0.65,0.55)),n),v),0.0),48.0);
  return vec3(0.006,0.10,0.16)+vec3(0.0,0.20,0.24)*diffuse + fresnel*vec3(0.08,0.16,0.22)+foam*vec3(0.20,0.55,0.58)+glitter*vec3(0.5,0.65,0.75);
}
vec3 extraAurora(vec2 p, float t) {
  vec3 col=vec3(0.012,0.025,0.055);
  vec2 uv=p*0.5+0.5;
  for(int i=0;i<4;i++) {
    float k=float(i);
    float curve=0.28+0.105*sin(p.x*2.3+t*0.35+k*0.4)+0.07*sin(p.x*4.7-t*0.5+k*0.6)+k*0.035;
    float d=uv.y-curve;
    float curtain=exp(-max(-d,0.0)*55.0)*exp(-max(d,0.0)/(0.13+k*0.015));
    float rays=0.32+0.68*pow(0.5+0.5*sin(p.x*97.0+0.9*sin(p.x*27.0+t)+k),2.0);
    vec3 c=i==0?vec3(0.02,0.67,0.39):(i==1?vec3(0.01,0.29,0.49):(i==2?vec3(0.32,0.12,0.52):vec3(0.02,0.35,0.25)));
    col+=c*curtain*rays*(0.65+uMid*0.25);
  }
  float mountain=0.79+0.035*sin(uv.x*22.0)+0.018*sin(uv.x*51.0)+0.025*cos(uv.x*13.0);
  col+=extraStars(p,t)*0.5;
  return mix(col,vec3(0.01,0.025,0.035),smoothstep(mountain,mountain+0.004,uv.y));
}
float extraSegment(vec2 p, vec2 a, vec2 b) {
  vec2 pa=p-a, ba=b-a;
  return length(pa-ba*clamp(dot(pa,ba)/dot(ba,ba),0.0,1.0));
}
vec3 extraPrism(vec2 p,float t) {
  vec3 col=vec3(0.018,0.006,0.045);
  p-=vec2(sin(t)*0.05,cos(t)*0.035);
  for(int i=0;i<15;i++) {
    float j=float(i), depth=fract(j/15.0+t/PI2);
    float r=0.04+depth*depth*2.5;
    float angle=sin(t)*0.12+j*0.018;
    vec2 a=vec2(cos(angle-1.5708),sin(angle-1.5708))*r;
    vec2 b=vec2(cos(angle+0.5236),sin(angle+0.5236))*r;
    vec2 c=vec2(cos(angle+2.6180),sin(angle+2.6180))*r;
    float dist=min(extraSegment(p,a,b),min(extraSegment(p,b,c),extraSegment(p,c,a)));
    vec3 tint=mod(j,2.0)<0.5?vec3(0.04,0.45,0.95):vec3(0.95,0.03,0.53);
    col+=tint*(exp(-dist*420.0)+0.22*exp(-dist*45.0))*(0.4+uEnergy*0.45+uBeat*0.12);
  }
  return col;
}
vec3 extraStrobe(vec2 uv,float t) {
  // Restrained spatial beams. No full-field white flash and no global beat multiplier.
  // Host must offer an explicit opt-in, intensity and tempo control.
  float phase=fract(t*0.95);
  float pulse=exp(-pow((phase-0.14)/0.16,2.0));
  vec3 col=vec3(0.026,0.015,0.046)+pulse*vec3(0.03,0.026,0.045);
  float beams=0.0;
  for(int j=0;j<7;j++) {
    float a=(float(j)-3.0)*0.17+0.05*sin(t);
    float bx=0.5+a*(uv.y+0.35);
    beams+=exp(-pow((uv.x-bx)/(0.014+0.035*uv.y),2.0))*exp(-uv.y*0.7);
  }
  col+=beams*vec3(0.34,0.29,0.48)*(0.25+0.7*pulse)*(0.7+0.2*uMid);
  return min(col,vec3(0.58));
}
vec3 extraAmiga(vec2 uv,float t) {
  // Pixel quantization is part of this theme, not an application-wide setting.
  vec2 q=(floor(uv*uSize/2.0)*2.0)/uSize;
  vec3 col=vec3(0.04,0.02,0.11)+exp(-pow((q.y-0.43)/0.3,2.0))*vec3(0.10,0.035,0.21);
  for(int i=0;i<4;i++) {
    float k=float(i),center=0.16+k*0.065+0.025*sin(t+k*0.7);
    col+=exp(-pow((q.y-center)/0.012,2.0))*mix(vec3(0.35,0.06,0.48),vec3(0.04,0.45,0.50),k/3.0)*0.6;
  }
  if(q.y>0.61) {
    float z=1.0/max(0.02,q.y-0.61+0.03);
    float checks=mod(floor((q.x-0.5)*2.0*z*0.9)+floor(z*0.5+t*2.0/3.14159),2.0);
    col=mix(vec3(0.19,0.07,0.30),vec3(0.36,0.25,0.51),checks)*clamp((q.y-0.61)*1.8+0.18,0.1,1.0);
  }
  vec2 center=vec2(0.48+0.20*sin(t),0.34+0.12*abs(sin(t)));
  vec2 nxy=(q-center)*vec2(uSize.x/uSize.y,1.0)/0.19;
  float r2=dot(nxy,nxy);
  if(r2<1.0) {
    float nz=sqrt(max(0.0,1.0-r2));
    float theta=atan(nxy.x,nz)+t;
    float phi=acos(clamp(-nxy.y,-1.0,1.0));
    float checker=mod(floor(theta/3.14159*8.0)+floor(phi/3.14159*9.0),2.0);
    float light=clamp(-nxy.x*0.36-nxy.y*0.45+nz*0.67,0.1,1.0);
    col=mix(vec3(0.89,0.10,0.22),vec3(0.93,0.94,0.96),checker)*(0.30+0.7*light);
  }
  return col;
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
  } else if(uMode < 3.5) {
    col = retro(uv,t);
  } else if(uMode < 4.5) {
    col = extraCosmos(uv*1.2,t);
  } else if(uMode < 5.5) {
    col = extraOcean(frag/uSize,t);
  } else if(uMode < 6.5) {
    col = extraAurora((frag/uSize)*2.0-1.0,t);
  } else if(uMode < 7.5) {
    col = extraPrism(uv*2.0,t);
  } else if(uMode < 8.5) {
    col = extraStrobe(frag/uSize,t);
  } else {
    col = extraAmiga(frag/uSize,t);
  }
  // Beat flash and vignette.
  if(uMode < 3.5) col *= 1.0 + uBeat * 0.35;
  vec2 v = frag / uSize - 0.5;
  col *= 1.0 - dot(v, v) * 1.1;
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
