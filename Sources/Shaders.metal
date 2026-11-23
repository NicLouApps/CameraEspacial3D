#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

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
    float aspectFitMode;
};

vertex VertexOut lenticularVertex(uint vid [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    float2 uvs[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

static inline float2 mapCameraUV(
    float2 viewUV,
    float viewAspect,
    float texAspect,
    float zoom,
    float2 shift,
    float aspectFitMode
) {
    float2 p = viewUV - float2(0.5, 0.5);
    float safeViewAspect = max(viewAspect, 0.001);
    float safeTexAspect = max(texAspect, 0.001);

    if (aspectFitMode > 0.5) {
        // Aspect-Fit (Proporcao Real): mostra 100% do sensor na proporcao original sem esticar e sem cortar
        if (safeViewAspect > safeTexAspect) {
            p.x *= (safeViewAspect / safeTexAspect);
        } else {
            p.y *= (safeTexAspect / safeViewAspect);
        }
    } else {
        // Aspect-Fill (Tela Cheia): preenche a tela sem deformar a proporcao
        if (safeViewAspect > safeTexAspect) {
            p.y *= (safeTexAspect / safeViewAspect);
        } else {
            p.x *= (safeViewAspect / safeTexAspect);
        }
    }

    p /= max(zoom, 0.1);
    return p + float2(0.5, 0.5) + shift;
}

static inline float3 sampleClamped(texture2d<float> tex, sampler s, float2 uv) {
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return float3(0.0, 0.0, 0.0);
    }
    return tex.sample(s, uv).rgb;
}

// Matriz oficial de Anaglifo Dubois (Red-Cyan)
static inline float3 applyDuboisAnaglyph(float3 L, float3 R) {
    float3 cL = clamp(L, 0.0, 1.0);
    float3 cR = clamp(R, 0.0, 1.0);

    float outR =  0.456100 * cL.r + 0.500484 * cL.g + 0.176381 * cL.b
                - 0.0434706 * cR.r - 0.0879388 * cR.g - 0.00155529 * cR.b;

    float outG = -0.0400822 * cL.r - 0.0378246 * cL.g - 0.0157589 * cL.b
                + 0.378476 * cR.r + 0.733640 * cR.g - 0.0184503 * cR.b;

    float outB = -0.0152161 * cL.r - 0.0205971 * cL.g - 0.00546856 * cL.b
                - 0.0721527 * cR.r - 0.112961 * cR.g + 1.226400 * cR.b;

    return clamp(float3(outR, outG, outB), 0.0, 1.0);
}

fragment float4 lenticularFragment(
    VertexOut in [[stage_in]],
    texture2d<float> wideTex [[texture(0)]],
    texture2d<float> ultraTex [[texture(1)]],
    constant LenticularUniforms &u [[buffer(0)]]
) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    float viewW = max(u.viewportWidth, 1.0);
    float viewH = max(u.viewportHeight, 1.0);
    float screenAspect = viewW / viewH;

    // Modo 1: SBS (Lado a Lado Espacial 3D)
    if (u.viewMode > 0.5 && u.viewMode < 1.5) {
        bool isLeftHalf = (in.uv.x < 0.5);
        float2 localUV = float2(isLeftHalf ? (in.uv.x * 2.0) : ((in.uv.x - 0.5) * 2.0), in.uv.y);
        float halfAspect = (viewW * 0.5) / viewH;

        float2 uvWide = mapCameraUV(localUV, halfAspect, u.wideAspect, 1.0, float2(-u.convergeX * 0.5, 0.0), u.aspectFitMode);
        float2 uvUltra = mapCameraUV(localUV, halfAspect, u.ultraAspect, u.ultraZoom, float2(u.convergeX * 0.5, u.alignY), u.aspectFitMode);

        float3 colWide = sampleClamped(wideTex, s, uvWide);
        float3 colUltra = sampleClamped(ultraTex, s, uvUltra);

        bool useWide = (u.swapEyes > 0.5) ? (!isLeftHalf) : isLeftHalf;
        float3 rgb = useWide ? colWide : colUltra;
        return float4(rgb, 1.0);
    }

    float2 uvWide = mapCameraUV(in.uv, screenAspect, u.wideAspect, 1.0, float2(-u.convergeX * 0.5, 0.0), u.aspectFitMode);
    float2 uvUltra = mapCameraUV(in.uv, screenAspect, u.ultraAspect, u.ultraZoom, float2(u.convergeX * 0.5, u.alignY), u.aspectFitMode);

    float3 colWide = sampleClamped(wideTex, s, uvWide);
    float3 colUltra = sampleClamped(ultraTex, s, uvUltra);

    float3 leftEye = (u.swapEyes > 0.5) ? colUltra : colWide;
    float3 rightEye = (u.swapEyes > 0.5) ? colWide : colUltra;

    // Modo 2: Anaglifo Dubois (Red-Cyan)
    if (u.viewMode >= 1.5) {
        float3 dubois = applyDuboisAnaglyph(leftEye, rightEye);
        return float4(dubois, 1.0);
    }

    // Modo 0: 3D Lenticular (75 LPI) com faixa de guarda anti-fantasma
    float2 fragPx = in.position.xy;
    float rad = u.angleDeg * (3.14159265359 / 180.0);
    float cosA = cos(rad);
    float sinA = sin(rad);

    float primaryCoord = (u.orientHoriz > 0.5)
        ? (fragPx.y * cosA - fragPx.x * sinA)
        : (fragPx.x * cosA + fragPx.y * sinA);

    float safePitch = max(u.pitch, 0.5);
    float phase = fract((primaryCoord / safePitch) + u.offset);
    if (phase < 0.0) {
        phase += 1.0;
    }

    float halfPhase = (phase < 0.5) ? (phase * 2.0) : ((phase - 0.5) * 2.0);
    float distFromBorder = min(halfPhase, 1.0 - halfPhase);
    float guardThreshold = clamp(u.guardPct / 100.0, 0.0, 0.48);

    float weight = 1.0;
    if (guardThreshold > 0.001) {
        weight = smoothstep(0.0, guardThreshold, distFromBorder);
    }

    bool isFirstHalf = (phase < 0.5);
    float3 chosen = isFirstHalf ? leftEye : rightEye;
    return float4(chosen * weight, 1.0);
}
