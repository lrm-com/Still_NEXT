#version 460 core

#include <flutter/runtime_effect.glsl>

precision mediump float;

uniform vec2 uResolution;
uniform float uTime;
uniform vec3 uColor;
uniform float uEnergy;

out vec4 fragColor;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    mat2 rot = mat2(cos(0.5), sin(0.5), -sin(0.5), cos(0.5));
    for (int i = 0; i < 4; i++) {
        v += a * noise(p);
        p = rot * p * 2.0 + vec2(100.0);
        a *= 0.5;
    }
    return v;
}

void main() {
    vec2 uv = FlutterFragCoord().xy / uResolution;
    float t = uTime * 0.25;
    float energy = clamp(uEnergy, 0.0, 1.0);

    float aspect = uResolution.x / uResolution.y;
    vec2 q = uv * vec2(aspect, 1.0);

    vec3 col1 = uColor;
    vec3 col2 = uColor * 0.6 + vec3(0.15, 0.08, 0.12);
    vec3 col3 = uColor * 0.4 + vec3(0.05, 0.1, 0.15);

    float n1 = fbm(q * 1.2 + vec2(t * 0.3, t * 0.15) + energy * 0.3);
    float n2 = fbm(q * 1.8 + vec2(-t * 0.2, t * 0.25) + n1 * 0.5);
    float n3 = fbm(q * 0.8 + vec2(t * 0.15, -t * 0.1) + n2 * 0.3);

    vec3 color = mix(col1, col2, n1);
    color = mix(color, col3, n2 * 0.6);
    color += vec3(n3 * 0.15);

    float vignette = 1.0 - length((uv - 0.5) * 1.4);
    vignette = clamp(vignette, 0.0, 1.0);
    color *= mix(0.45, 0.65, vignette);

    fragColor = vec4(color, 1.0);
}
