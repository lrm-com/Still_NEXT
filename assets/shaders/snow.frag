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
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

void main() {
    vec2 uv = FlutterFragCoord().xy / uResolution;
    vec3 col = vec3(0.0);

    float density = clamp(uDensity, 0.0, 1.0);
    float particleCount = mix(20.0, 80.0, density);
    float speed = mix(0.05, 0.4, uSpeed);
    float t = uTime * speed;

    for (float i = 0.0; i < 80.0; i++) {
        if (i >= particleCount) break;

        float id = i + 0.5;
        float rndX = hash(vec2(id, 1.0));
        float rndY = hash(vec2(id, 2.0));
        float rndSize = hash(vec2(id, 3.0));
        float rndDrift = hash(vec2(id, 4.0));

        float x = rndX + sin(uTime * 3.14159 * 2.0 + id) * 0.015;
        float y = mod(rndY + t * mix(0.3, 1.0, rndDrift), 1.1) - 0.05;

        float radius = mix(1.0, 3.5, rndSize) + uEnergy * 0.8;
        radius /= uResolution.y;

        float d = length(uv - vec2(x, y));
        float alpha = smoothstep(radius, radius * 0.3, d) * 0.55;

        col += vec3(alpha);
    }

    fragColor = vec4(col, 0.0);
}
