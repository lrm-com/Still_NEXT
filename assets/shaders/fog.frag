#version 460 core

#include <flutter/runtime_effect.glsl>

precision mediump float;

uniform vec2 uResolution;
uniform float uTime;
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
    vec2 shift = vec2(100.0);
    for (int i = 0; i < 4; i++) {
        v += a * noise(p);
        p = p * 2.0 + shift;
        a *= 0.5;
    }
    return v;
}

void main() {
    vec2 uv = FlutterFragCoord().xy / uResolution;
    float t = uTime * 0.3;
    float energy = clamp(uEnergy, 0.0, 1.0);

    float n = 0.0;
    for (float i = 0.0; i < 3.0; i++) {
        float fi = i * 0.7 + 1.0;
        float speed = mix(0.15, 0.35, i / 2.0);
        vec2 q = uv * vec2(uResolution.x / uResolution.y, 1.0) * fi;
        q += vec2(t * speed, t * speed * 0.3);
        n += fbm(q * 1.5) / fi;
    }

    float alpha = n * (0.04 + energy * 0.02);
    alpha = clamp(alpha, 0.0, 0.08);

    fragColor = vec4(vec3(1.0), alpha);
}
