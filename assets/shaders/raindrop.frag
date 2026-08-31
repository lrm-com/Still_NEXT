#version 460 core

#include <flutter/runtime_effect.glsl>

precision mediump float;

uniform vec2 uResolution;
uniform float uTime;
uniform float uDensity;
uniform float uSpeed;
uniform float uEnergy;

out vec4 fragColor;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
    vec2 uv = FlutterFragCoord().xy / uResolution;

    float density = clamp(uDensity, 0.0, 1.0);
    float particleCount = mix(15.0, 65.0, density);
    float speed = mix(0.2, 1.0, uSpeed);
    float t = uTime * speed;
    float energy = clamp(uEnergy, 0.0, 1.0);
    float alpha = 0.09 + energy * 0.04;

    for (float i = 0.0; i < 65.0; i++) {
        if (i >= particleCount) break;

        float id = i + 0.5;
        float rndX = hash(vec2(id, 1.1));
        float rndLen = hash(vec2(id, 2.2));
        float rndWidth = hash(vec2(id, 3.3));
        float rndSpeed = hash(vec2(id, 4.4));

        float x = rndX;
        float y = mod(hash(vec2(id, 0.5)) + t * mix(0.4, 1.2, rndSpeed), 1.2) - 0.1;

        float len = mix(0.025, 0.06, rndLen);
        float w = mix(0.8, 1.6, rndWidth) / uResolution.x;

        vec2 p1 = vec2(x, y);
        vec2 p2 = vec2(x - 0.005, y + len);

        vec2 pa = uv - p1;
        vec2 ba = p2 - p1;
        float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        float d = length(pa - ba * h);

        float line = smoothstep(w, w * 0.2, d);
        float fade = smoothstep(0.0, 0.15, 1.0 - h);
        line *= fade;

        alpha += line * 0.08;
    }

    alpha = clamp(alpha, 0.0, 0.4);
    fragColor = vec4(vec3(1.0), alpha);
}
