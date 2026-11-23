#include <metal_stdlib>
using namespace metal;

struct LenticularUniforms {
    float viewportWidth;
    float viewportHeight;
    float pitch;
    float angleDeg;
    float offset;
    float guardPct;
    float swapEyes;
    float orientHoriz;
    float ultraZoom;
    float convergeX;
    float alignY;
    float viewMode;
    float wideAspect;
    float ultraAspect;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut vertex_fullscreen(uint vid [[vertex_id]]) {
    constexpr float2 pos[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    VertexOut out;
    float2 p = pos[vid];
    out.position = float4(p, 0.0, 1.0);
    out.uv = float2(p.x * 0.5 + 0.5, 1.0 - (p.y * 0.5 + 0.5));
    return out;
}

static inline float2 fitAspectUV(float2 uv, float targetAspect, float texAspect) {
    float2 c = uv - 0.5;
    if (texAspect > targetAspect) {
        c.x *= targetAspect / texAspect;
    } else {
        c.y *= texAspect / targetAspect;
    }
    return c + 0.5;
}

static inline float4 sampleWide(texture2d<float> tex, sampler s, float2 uv, float targetAspect, constant LenticularUniforms &u) {
    float2 wuv = fitAspectUV(uv, targetAspect, max(0.1, u.wideAspect));
    wuv.x += u.convergeX * 0.5;
    if (wuv.x < 0.0 || wuv.x > 1.0 || wuv.y < 0.0 || wuv.y > 1.0) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    return tex.sample(s, wuv);
}

static inline float4 sampleUltra(texture2d<float> tex, sampler s, float2 uv, float targetAspect, constant LenticularUniforms &u) {
    float2 uuv = fitAspectUV(uv, targetAspect, max(0.1, u.ultraAspect));
    uuv = (uuv - 0.5) / max(1.0, u.ultraZoom) + 0.5;
    uuv.x -= u.convergeX * 0.5;
    uuv.y += u.alignY;
    if (uuv.x < 0.0 || uuv.x > 1.0 || uuv.y < 0.0 || uuv.y > 1.0) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    return tex.sample(s, uuv);
}

fragment float4 fragment_lenticular(VertexOut in [[stage_in]],
                                    texture2d<float> texWide [[texture(0)]],
                                    texture2d<float> texUltra [[texture(1)]],
                                    constant LenticularUniforms &u [[buffer(0)]]) {
    constexpr sampler linSamp(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float screenAspect = max(0.1, u.viewportWidth / max(1.0, u.viewportHeight));

    // Modo 1: Side-by-Side (SBS)
    if (u.viewMode > 0.5 && u.viewMode < 1.5) {
        float targetAspect = screenAspect * 0.5;
        bool isRightHalf = in.uv.x >= 0.5;
        float2 subUV = float2(isRightHalf ? (in.uv.x - 0.5) * 2.0 : in.uv.x * 2.0, in.uv.y);
        bool pickUltra = isRightHalf;
        if (u.swapEyes > 0.5) pickUltra = !pickUltra;
        return pickUltra
            ? sampleUltra(texUltra, linSamp, subUV, targetAspect, u)
            : sampleWide(texWide, linSamp, subUV, targetAspect, u);
    }

    // Modo 2: Anaglifo Vermelho/Ciano para conferir alinhamento sem a folha
    if (u.viewMode >= 1.5) {
        float4 colW = sampleWide(texWide, linSamp, in.uv, screenAspect, u);
        float4 colU = sampleUltra(texUltra, linSamp, in.uv, screenAspect, u);
        float4 leftCol = (u.swapEyes > 0.5) ? colU : colW;
        float4 rightCol = (u.swapEyes > 0.5) ? colW : colU;
        return float4(leftCol.r, rightCol.g, rightCol.b, 1.0);
    }

    // Modo 0: 3D Lenticular calibrado em pixels fisicos
    float glY = u.viewportHeight - in.position.y;
    float effAngle = u.angleDeg + (u.orientHoriz > 0.5 ? 90.0 : 0.0);
    float rad = effAngle * 0.017453292519943295;
    float coord = in.position.x * cos(rad) + glY * sin(rad);
    float phase = fract((coord / max(0.5, u.pitch)) + u.offset);

    float guard = clamp(u.guardPct * 0.01, 0.0, 0.48);
    float halfPos = fract(phase * 2.0);
    float margin = guard * 0.5;
    if (guard > 0.001 && (halfPos < margin || halfPos > 1.0 - margin)) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    float useRight = step(0.5, phase);
    if (u.swapEyes > 0.5) {
        useRight = 1.0 - useRight;
    }

    float4 colL = sampleWide(texWide, linSamp, in.uv, screenAspect, u);
    float4 colU = sampleUltra(texUltra, linSamp, in.uv, screenAspect, u);
    return mix(colL, colU, useRight);
}
