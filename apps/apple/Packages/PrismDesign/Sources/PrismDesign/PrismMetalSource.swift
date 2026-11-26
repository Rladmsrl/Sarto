import Foundation

/// Runtime-compiled MSL 3.0 shader library for Sarto (macOS 15+ & iOS 18+).
/// Compiled once on the system Metal GPU driver via MTLDevice.makeLibrary(source:options:),
/// its optical look inspired by Obsidian Prism (`https://github.com/RMvdesi/obsidian-prism`), none of
/// whose code it holds; see `THIRD_PARTY_NOTICES.md`.
enum PrismMetalSource {
    static var librarySource: String { msl }

    static let msl: String = """
    #include <metal_stdlib>
    using namespace metal;

    inline float pk_sq(float x) { return x * x; }

    struct VertexOut {
        float4 position [[position]];
        float2 uv; // (0,0) top-left -> (1,1) bottom-right
    };

    struct PrismUniforms {
        float4 resTimeDark;    // x: width(pt), y: height(pt), z: time(s), w: isDark
        float4 pointerAccent;  // x: ptrX(pt), y: ptrY(pt), z: proximity/alpha, w: accentCode(0..5)
        float4 params;         // shader-specific p0..p3
        float4 extra;          // shader-specific e0..e3
        float4 wave[6];        // vial: 24-node wave heights; nebula: lobes in wave[1..3] (see PrismNebulaLobes)
    };

    vertex VertexOut pk_fullscreen_vertex(uint vid [[vertex_id]]) {
        // Oversized single triangle covering [-1, 1] NDC cleanly
        float2 pos[3] = {
            float2(-1.0f, -1.0f),
            float2( 3.0f, -1.0f),
            float2(-1.0f,  3.0f)
        };
        float2 p = pos[vid];
        VertexOut out;
        out.position = float4(p, 0.0f, 1.0f);
        // Flip Y so uv=(0,0) is top-left in SwiftUI point coordinates
        out.uv = float2(p.x * 0.5f + 0.5f, 0.5f - p.y * 0.5f);
        return out;
    }

    // MARK: - Shared Math & Spectral Helpers

    static inline float2 pk_hash22(float2 p) {
        float3 p3 = fract(float3(p.x, p.y, p.x) * float3(0.1031f, 0.1030f, 0.0973f));
        p3 += dot(p3, p3.yzx + 33.33f);
        return fract((p3.xx + p3.yz) * p3.zy);
    }

    static inline float pk_hash21(float2 p) {
        float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031f);
        p3 += dot(p3, p3.yzx + 33.33f);
        return fract((p3.x + p3.y) * p3.z);
    }

    static inline float pk_vNoise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * (3.0f - 2.0f * f);
        return mix(
            mix(pk_hash21(i), pk_hash21(i + float2(1.0f, 0.0f)), u.x),
            mix(pk_hash21(i + float2(0.0f, 1.0f)), pk_hash21(i + float2(1.0f, 1.0f)), u.x),
            u.y
        );
    }

    static inline float pk_fbm3(float2 p) {
        float v = 0.0f;
        float a = 0.5f;
        for (int i = 0; i < 3; i++) {
            v += a * pk_vNoise(p);
            p = p * 2.04f + float2(11.3f, 7.9f);
            a *= 0.5f;
        }
        return v;
    }

    static inline float pk_sdCapsuleBox(float2 p, float2 halfSize, float radius) {
        float2 q = abs(p) - (halfSize - float2(radius));
        return length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - radius;
    }

    static inline float3 pk_decodeCustomAccent(float accent) {
        uint hex = uint(round(-accent - 1.0f));
        return float3(
            float((hex >> 16u) & 0xFFu) / 255.0f,
            float((hex >> 8u) & 0xFFu) / 255.0f,
            float(hex & 0xFFu) / 255.0f
        );
    }

    static inline float3 pk_shiftHue(float3 col, float angleRad) {
        const float3 k = float3(0.57735027f);
        float c = cos(angleRad);
        float s = sin(angleRad);
        return clamp(col * c + cross(k, col) * s + k * dot(k, col) * (1.0f - c), 0.0f, 1.0f);
    }

    static inline float3 pk_cauchySpectrum(float t, float accent) {
        float u = clamp(t, 0.0f, 1.0f);
        if (accent < -0.5f) {
            float3 base = pk_decodeCustomAccent(accent);
            float3 c0 = clamp(pk_shiftHue(base, -0.32f) * 0.72f, 0.0f, 1.0f);
            float3 c1 = base;
            float3 c2 = clamp(mix(pk_shiftHue(base, 0.28f), float3(1.0f), 0.24f), 0.0f, 1.0f);
            float3 c3 = clamp(mix(pk_shiftHue(base, 0.45f), float3(1.0f), 0.58f), 0.0f, 1.0f);
            float s = u * 3.0f;
            if (s < 1.0f) return mix(c0, c1, s);
            if (s < 2.0f) return mix(c1, c2, s - 1.0f);
            return mix(c2, c3, s - 2.0f);
        }
        if (accent > 4.5f) {
            return mix(float3(0.760f, 0.800f, 0.865f), float3(0.975f, 0.985f, 1.010f), u);
        }
        float3 c0 = float3(0.298f, 0.553f, 0.965f);
        float3 c1 = float3(0.608f, 0.447f, 0.796f);
        float3 c2 = float3(0.851f, 0.396f, 0.439f);
        float3 c3 = float3(0.949f, 0.722f, 0.294f);
        if (accent > 3.5f) {
            c0 = float3(0.706f, 0.325f, 0.035f); c1 = float3(0.851f, 0.467f, 0.024f);
            c2 = float3(0.949f, 0.722f, 0.294f); c3 = float3(0.992f, 0.902f, 0.541f);
        } else if (accent > 2.5f) {
            c0 = float3(0.427f, 0.157f, 0.851f); c1 = float3(0.545f, 0.361f, 0.965f);
            c2 = float3(0.647f, 0.541f, 0.973f); c3 = float3(0.867f, 0.839f, 0.996f);
        } else if (accent > 1.5f) {
            c0 = float3(0.114f, 0.306f, 0.847f); c1 = float3(0.192f, 0.525f, 1.000f);
            c2 = float3(0.361f, 0.776f, 0.988f); c3 = float3(0.549f, 0.878f, 1.000f);
        } else if (accent > 0.5f) {
            c0 = float3(0.761f, 0.349f, 0.204f); c1 = float3(0.851f, 0.467f, 0.341f);
            c2 = float3(0.898f, 0.576f, 0.467f); c3 = float3(0.965f, 0.741f, 0.376f);
        }
        float s = u * 3.0f;
        if (s < 1.0f) return mix(c0, c1, s);
        if (s < 2.0f) return mix(c1, c2, s - 1.0f);
        return mix(c2, c3, s - 2.0f);
    }

    static inline float3 pk_horizonSpectrum(float t, float lightMode, float mode) {
        float f = fract(t) * 4.0f;
        float3 c0 = float3(0.298f, 0.553f, 0.965f); float3 c1 = float3(0.608f, 0.447f, 0.796f);
        float3 c2 = float3(0.851f, 0.396f, 0.439f); float3 c3 = float3(0.949f, 0.722f, 0.294f);
        float3 l0 = float3(0.145f, 0.388f, 0.922f); float3 l1 = float3(0.486f, 0.227f, 0.929f);
        float3 l2 = float3(0.918f, 0.263f, 0.208f); float3 l3 = float3(0.851f, 0.467f, 0.024f);
        if (mode < -0.5f) {
            float3 base = pk_decodeCustomAccent(mode);
            c0 = clamp(pk_shiftHue(base, -0.38f) * 0.62f, 0.0f, 1.0f);
            c1 = base;
            c2 = clamp(mix(pk_shiftHue(base, 0.30f), float3(1.0f), 0.22f), 0.0f, 1.0f);
            c3 = clamp(mix(pk_shiftHue(base, 0.48f), float3(1.0f), 0.52f), 0.0f, 1.0f);
            l0 = clamp(pk_shiftHue(base, -0.32f) * 0.72f, 0.0f, 1.0f);
            l1 = clamp(base * 0.88f, 0.0f, 1.0f);
            l2 = clamp(pk_shiftHue(base, 0.26f) * 0.94f, 0.0f, 1.0f);
            l3 = clamp(mix(pk_shiftHue(base, 0.44f), float3(1.0f), 0.16f), 0.0f, 1.0f);
        } else if (mode > 4.5f) {
            c0 = float3(0.392f, 0.455f, 0.545f); c1 = float3(0.580f, 0.639f, 0.722f);
            c2 = float3(0.796f, 0.835f, 0.882f); c3 = float3(0.945f, 0.961f, 0.976f);
            l0 = float3(0.118f, 0.161f, 0.231f); l1 = float3(0.200f, 0.255f, 0.333f);
            l2 = float3(0.278f, 0.333f, 0.412f); l3 = float3(0.392f, 0.455f, 0.545f);
        } else if (mode > 3.5f) {
            c0 = float3(0.573f, 0.251f, 0.055f); c1 = float3(0.851f, 0.467f, 0.024f);
            c2 = float3(0.949f, 0.722f, 0.294f); c3 = float3(0.992f, 0.902f, 0.541f);
            l0 = float3(0.471f, 0.208f, 0.059f); l1 = float3(0.706f, 0.325f, 0.035f);
            l2 = float3(0.851f, 0.467f, 0.024f); l3 = float3(0.918f, 0.345f, 0.047f);
        } else if (mode > 2.5f) {
            c0 = float3(0.357f, 0.129f, 0.714f); c1 = float3(0.545f, 0.361f, 0.965f);
            c2 = float3(0.647f, 0.541f, 0.973f); c3 = float3(0.867f, 0.839f, 0.996f);
            l0 = float3(0.298f, 0.114f, 0.584f); l1 = float3(0.427f, 0.157f, 0.851f);
            l2 = float3(0.486f, 0.227f, 0.929f); l3 = float3(0.576f, 0.200f, 0.918f);
        } else if (mode > 1.5f) {
            c0 = float3(0.106f, 0.286f, 0.698f); c1 = float3(0.192f, 0.525f, 1.000f);
            c2 = float3(0.361f, 0.776f, 0.988f); c3 = float3(0.549f, 0.878f, 1.000f);
            l0 = float3(0.114f, 0.306f, 0.847f); l1 = float3(0.145f, 0.388f, 0.922f);
            l2 = float3(0.008f, 0.518f, 0.780f); l3 = float3(0.220f, 0.741f, 0.973f);
        } else if (mode > 0.5f) {
            c0 = float3(0.580f, 0.290f, 0.204f); c1 = float3(0.851f, 0.467f, 0.341f);
            c2 = float3(0.933f, 0.608f, 0.478f); c3 = float3(0.965f, 0.741f, 0.376f);
            l0 = float3(0.604f, 0.204f, 0.071f); l1 = float3(0.761f, 0.349f, 0.204f);
            l2 = float3(0.851f, 0.467f, 0.341f); l3 = float3(0.851f, 0.467f, 0.024f);
        }
        float3 d, l;
        if (f < 1.0f) { d = mix(c0, c1, f); l = mix(l0, l1, f); }
        else if (f < 2.0f) { d = mix(c1, c2, f - 1.0f); l = mix(l1, l2, f - 1.0f); }
        else if (f < 3.0f) { d = mix(c2, c3, f - 2.0f); l = mix(l2, l3, f - 2.0f); }
        else { d = mix(c3, c0, f - 3.0f); l = mix(l3, l0, f - 3.0f); }
        return mix(d, l, lightMode);
    }

    // MARK: - 1. Voronoi Cut-Crystal Effort / Orchestrator Slider

    static inline void pk_facetVoronoi(float2 p, thread float2 &cellId, thread float2 &nbId, thread float2 &edgeN, thread float &edgeD) {
        float2 n = floor(p);
        float2 f = fract(p);
        float2 mg = float2(0.0f);
        float2 mr = float2(0.0f);
        float md = 8.0f;
        for (int j = -1; j <= 1; j++) {
            for (int i = -1; i <= 1; i++) {
                float2 g = float2(float(i), float(j));
                float2 o = 0.12f + 0.76f * pk_hash22(n + g);
                float2 r = g + o - f;
                float d = dot(r, r);
                if (d < md) { md = d; mr = r; mg = g; }
            }
        }
        cellId = n + mg;
        nbId = cellId;
        edgeN = float2(1.0f, 0.0f);
        edgeD = 8.0f;
        for (int j = -2; j <= 2; j++) {
            for (int i = -2; i <= 2; i++) {
                float2 g = mg + float2(float(i), float(j));
                float2 o = 0.12f + 0.76f * pk_hash22(n + g);
                float2 r = g + o - f;
                float2 dr = r - mr;
                if (dot(dr, dr) > 0.00001f) {
                    float2 nn = normalize(dr);
                    float d = dot(0.5f * (mr + r), nn);
                    if (d < edgeD) { edgeD = d; edgeN = nn; nbId = n + g; }
                }
            }
        }
    }

    static inline float pk_etchedLockMask(float2 q, float halfStroke, float aa) {
        float dBody = abs(pk_sdCapsuleBox(q - float2(0.0f, -2.65f), float2(3.6f, 2.45f), 1.2f)) - halfStroke;
        float2 qs = q - float2(0.0f, 1.5f);
        float dShackle = (qs.y >= 0.0f
            ? abs(length(qs) - 2.25f)
            : length(float2(abs(qs.x) - 2.25f, max(0.0f, -0.2f - q.y)))) - halfStroke;
        float dKey = length(q - float2(0.0f, -2.55f)) - 0.75f;
        return 1.0f - smoothstep(-aa, aa, min(min(dBody, dShackle), dKey));
    }

    static inline float3 pk_iceRamp(float l, float isDark) {
        float3 abyss = isDark > 0.5f ? float3(0.036f, 0.036f, 0.044f) : float3(0.25f, 0.28f, 0.34f);
        float3 steel = isDark > 0.5f ? float3(0.38f, 0.43f, 0.53f) : float3(0.63f, 0.69f, 0.78f);
        float3 ice   = isDark > 0.5f ? float3(0.84f, 0.88f, 0.95f) : float3(0.90f, 0.93f, 0.975f);
        float3 white = float3(1.02f, 1.03f, 1.05f);
        l = clamp(l, 0.0f, 1.2f);
        if (l < 0.42f) return mix(abyss, steel, smoothstep(0.0f, 0.42f, l));
        if (l < 0.85f) return mix(steel, ice, smoothstep(0.42f, 0.85f, l));
        return mix(ice, white, clamp((l - 0.85f) / 0.35f, 0.0f, 1.0f));
    }

    fragment float4 pk_cut_crystal_frag(VertexOut in [[stage_in]], constant PrismUniforms &u [[buffer(0)]]) {
        float2 cssRes = max(u.resTimeDark.xy, float2(4.0f));
        float time = u.resTimeDark.z;
        float isDark = u.resTimeDark.w;
        float2 pointerPos = u.pointerAccent.xy;
        float proximity = u.pointerAccent.z;
        float accent = u.pointerAccent.w;
        float modeParam = u.params.x;
        float ambient = u.params.y;
        float2 wake = u.params.zw;

        float2 position = in.uv * cssRes;
        float2 vUv = float2(in.uv.x, 1.0f - in.uv.y);
        float2 px = (vUv - 0.5f) * cssRes;
        float2 halfSize = cssRes * 0.5f;
        float capR = min(halfSize.x, halfSize.y);
        float dpr = 2.0f;

        float sdf = pk_sdCapsuleBox(px, halfSize, capR);
        float alphaMask = clamp(0.5f - sdf * dpr, 0.0f, 1.0f);
        if (alphaMask < 0.002f) return float4(0.0f);
        float rimD = max(0.0f, -sdf);

        float ch = cssRes.y * 0.66f;
        float cw = ch * 2.2f;
        float sh = 0.38f;
        float2 gp = float2(px.x / cw + (px.y / ch) * sh, px.y / ch) + float2(3.17f, 1.41f);
        float2 cellId, nbId, edgeNg;
        float edgeDg;
        pk_facetVoronoi(gp, cellId, nbId, edgeNg, edgeDg);

        float2 edgeNpx = float2(edgeNg.x / cw, edgeNg.x * sh / ch + edgeNg.y / ch);
        float edgeScale = max(length(edgeNpx), 1e-5f);
        float pxD = edgeDg / edgeScale;
        float2 nE = edgeNpx / edgeScale;

        float h1 = pk_hash21(cellId);
        float h2 = pk_hash21(cellId + float2(17.3f, 9.1f));
        float h3 = pk_hash21(cellId + float2(5.7f, 31.4f));

        float yN = clamp(px.y / max(1.0f, halfSize.y), -1.0f, 1.0f);
        float cylEnd = clamp((abs(px.x) - (halfSize.x - capR)) / max(1.0f, capR), 0.0f, 1.0f);
        float3 Nrod = float3(sign(px.x) * cylEnd * 0.55f, yN * 0.62f, 1.0f);
        float2 tilt = float2((h1 - 0.5f) * 1.10f, (h2 - 0.5f) * 0.70f);
        float3 N = normalize(Nrod + float3(tilt, 0.0f));
        float3 V = float3(0.0f, 0.0f, 1.0f);
        float3 Lk = normalize(float3(-0.38f, 0.62f, 0.68f));
        float3 Hk = normalize(Lk + V);
        float3 refrDir = refract(-V, N, 1.0f / 1.54f);

        float crown = smoothstep(-0.20f, 0.80f, yN);
        float pav = (1.0f - smoothstep(-0.95f, -0.15f, yN));
        float lit = clamp((dot(N, Lk) - 0.62f) * 2.6f, -1.0f, 1.0f);

        float interior = sin((px.x + refrDir.x * 42.0f) * 0.040f + (px.y + refrDir.y * 30.0f) * 0.11f + 1.3f);
        float lum = 0.48f + 0.34f * crown + 0.30f * lit + 0.09f * interior - 0.10f * pav;
        float crownBand = exp(-pk_sq((yN - 0.58f) / 0.20f));
        lum += crownBand * (0.20f + 0.12f * lit);

        float tirSel = smoothstep(0.50f, 0.85f, h3) * (1.0f - smoothstep(-0.35f, 0.15f, lit + 0.2f * crown));
        float tir = clamp(pav * (0.30f + 0.75f * tirSel), 0.0f, 1.0f);
        lum = mix(lum, lum * 0.10f, tir * (isDark > 0.5f ? 0.92f : 0.70f));

        float3 col = pk_iceRamp(lum, isDark);
        float clearZone = (1.0f - crown) * (1.0f - pav) * smoothstep(0.30f, 0.70f, lum);
        float3 clearTint = accent > 4.5f
            ? float3(0.84f, 0.87f, 0.92f)
            : ((accent > 0.5f || accent < -0.5f) ? mix(float3(0.82f, 0.85f, 0.90f), pk_cauchySpectrum(0.55f, accent), 0.55f) : float3(0.72f, 0.82f, 0.97f));
        col = mix(col, clearTint * (0.55f + 0.5f * lum), clearZone * (isDark > 0.5f ? 0.22f : 0.16f) * (0.35f + 0.65f * ambient));
        col += float3(0.92f, 0.95f, 1.0f) * pow(max(dot(N, Hk), 0.0f), 38.0f) * (isDark > 0.5f ? 0.55f : 0.35f);

        if (ambient > 0.01f) {
            for (int k = 0; k < 3; k++) {
                float fk = float(k);
                float cx = (k == 0 ? 0.27f : (k == 1 ? 0.555f : 0.775f)) - 0.5f;
                float strength = (k == 0 ? 1.0f : (k == 1 ? 0.78f : 0.56f)) * ambient;
                float d = (px.x + refrDir.x * 16.0f) - cx * cssRes.x - px.y * (0.80f + 0.12f * fk);
                float band = exp(-d * d / 4.5f);
                float vfade = 1.0f - smoothstep(0.55f, 0.95f, abs(yN));
                float3 tint = accent > 4.5f
                    ? float3(0.86f, 0.89f, 0.94f)
                    : ((accent > 0.5f || accent < -0.5f) ? pk_cauchySpectrum(d < 0.0f ? 0.28f : 0.72f, accent) : (d < 0.0f ? float3(0.50f, 0.68f, 1.00f) : float3(0.68f, 0.58f, 0.98f)));
                col = mix(col, tint * (0.62f + 0.40f * clamp(lum, 0.0f, 1.0f)), 0.15f * band * vfade * strength);
                col += float3(0.86f, 0.90f, 0.98f) * exp(-d * d / 0.45f) * vfade * strength * 0.10f;
            }
        }

        float3 Nb = normalize(float3(nE * 0.45f, 0.89f) + float3(Nrod.xy * 0.12f, 0.0f));
        float ridgeSpec = pow(max(dot(Nb, Hk), 0.0f), 12.0f);
        float fresMacro = 0.55f + 0.45f * pk_sq(abs(yN));
        float edgeHash = pk_hash21(cellId + nbId);
        float edgeGain = mix(0.18f, 1.0f, step(0.32f, edgeHash));
        float aaPx = 0.6f / dpr;
        float blade = 1.0f - smoothstep(0.9f - aaPx, 0.9f + aaPx, pxD);
        float hair = 1.0f - smoothstep(0.0f, 0.55f + aaPx, pxD);
        col += float3(0.96f, 0.98f, 1.0f) * blade * ridgeSpec * edgeGain * fresMacro * (isDark > 0.5f ? 1.55f : 1.10f);
        col *= 1.0f - hair * (1.0f - ridgeSpec) * edgeGain * (isDark > 0.5f ? 0.20f : 0.12f);

        if (proximity > 0.004f && pointerPos.x > -2000.0f) {
            float2 ptrLocal = float2(pointerPos.x - halfSize.x, halfSize.y - pointerPos.y);
            float2 dp = px - ptrLocal;
            float spotR = max(cssRes.y * 3.0f, 84.0f);
            float spot = pow(max(1.0f - smoothstep(0.0f, spotR, length(dp * float2(0.85f, 1.2f))), 0.0f), 1.5f);
            float react = proximity * (0.22f + 0.78f * spot);
            float3 Lp = normalize(float3(-dp, capR * 2.6f));
            float3 Hp = normalize(Lp + V);

            col += float3(0.94f, 0.97f, 1.0f) * (pow(max(dot(N, Hp), 0.0f), 26.0f) * 0.42f + spot * 0.10f) * react;
            float fireT = fract(h1 * 1.7f + dot(N.xy, Lp.xy) * 1.4f + 0.2f);
            float fireMask = smoothstep(0.60f, 0.95f, dot(N, Lp)) * (0.30f + 0.70f * h2);
            float3 fire = pk_cauchySpectrum(fireT, accent);
            col = mix(col, col * mix(float3(1.0f), fire * 1.55f, 0.40f), fireMask * react * (accent > 4.5f ? 0.18f : 0.38f));

            float eLit = pow(max(dot(Nb, Hp), 0.0f), 9.0f) * edgeGain;
            float fringeT = (pxD - 0.55f) / 2.2f;
            float fringeMask = smoothstep(0.0f, 0.12f, fringeT) * (1.0f - smoothstep(0.82f, 1.0f, fringeT));
            col += pk_cauchySpectrum(fringeT, accent) * fringeMask * eLit * react * (accent > 4.5f ? 0.25f : 1.0f) * (0.6f + 0.8f * spot) * (isDark > 0.5f ? 1.70f : 1.25f);
            col += float3(1.0f) * blade * eLit * react * 0.55f;
        }

        float glintU[4] = { 0.14f, 0.39f, 0.64f, 0.85f };
        float glintV[4] = { 0.28f, 0.68f, 0.26f, 0.58f };
        float glintFreq[4] = { 0.31f, 0.47f, 0.23f, 0.37f };
        float glintPhase[4] = { 0.4f, 2.1f, 3.9f, 5.2f };
        bool reduced = (modeParam > 0.5f && modeParam < 1.5f) || modeParam > 3.5f;
        for (int i = 0; i < 4; i++) {
            float waveVal = 0.5f + 0.5f * sin(time * glintFreq[i] * 6.283185f + glintPhase[i]);
            float gi = (reduced ? (i % 2 == 0 ? 0.38f : 0.22f) : pow(max(waveVal, 0.0f), 5.5f)) * ambient;
            if (gi > 0.01f) {
                float2 anchor = float2((glintU[i] - 0.5f) * cssRes.x, (0.5f - glintV[i]) * cssRes.y);
                float2 g = px - anchor;
                float2 rg = float2(g.x * 0.956f - g.y * 0.292f, g.x * 0.292f + g.y * 0.956f);
                float sx = abs(rg.x), sy = abs(rg.y);
                float spikeX = exp(-rg.y * rg.y * 2.4f) * exp(-sx * 0.24f);
                float spikeY = exp(-rg.x * rg.x * 2.4f) * exp(-sy * 0.40f);
                float core = exp(-dot(g, g) * 0.42f) + exp(-length(g) * 0.55f) * 0.30f;
                float tipMix = accent > 4.5f ? 0.0f : 0.70f;
                float3 tipX = mix(float3(1.0f), pk_cauchySpectrum(fract(sx * 0.085f + float(i) * 0.23f), accent) * 1.25f, smoothstep(2.5f, 7.0f, sx) * tipMix);
                float3 tipY = mix(float3(1.0f), pk_cauchySpectrum(fract(sy * 0.120f + float(i) * 0.31f), accent) * 1.25f, smoothstep(2.0f, 5.0f, sy) * tipMix);
                col += (float3(0.96f, 0.98f, 1.0f) * core * 1.20f + tipX * spikeX * 0.78f + tipY * spikeY * 0.62f) * gi * (isDark > 0.5f ? 1.15f : 0.80f);
            }
        }

        if (wake.y > 0.001f) {
            float sxPos = (wake.x - 0.5f) * cssRes.x;
            float d = px.x - sxPos - px.y * 0.55f;
            float sweep = exp(-d * d / 60.0f) * 0.55f + exp(-d * d / 1.6f) * 0.80f;
            col += float3(0.90f, 0.95f, 1.0f) * sweep * wake.y;
        }

        float2 rimN = normalize(float2(sign(px.x) * max(0.0f, abs(px.x) - (halfSize.x - capR)), px.y) + float2(0.0001f));
        float rimLit = 0.20f + 0.80f * smoothstep(-0.3f, 0.85f, dot(rimN, normalize(Lk.xy)));
        float wallShade = 1.0f - smoothstep(0.0f, 3.2f, rimD);
        float rimLine = 1.0f - smoothstep(0.9f, 1.9f, rimD);
        if (isDark > 0.5f) {
            col *= 1.0f - wallShade * 0.38f;
            col += float3(0.90f, 0.94f, 1.0f) * rimLine * rimLit * 0.55f;
        } else {
            col *= 1.0f - wallShade * 0.20f;
            col += float3(1.0f) * (1.0f - smoothstep(1.0f, 2.2f, rimD)) * smoothstep(0.6f, 1.1f, rimD) * rimLit * 0.40f;
            col = mix(col, float3(0.47f, 0.52f, 0.59f), (1.0f - smoothstep(0.8f - aaPx, 0.8f + aaPx, rimD)) * 0.88f);
        }

        if (modeParam > 1.5f) {
            float fillU = clamp(modeParam > 3.5f ? (modeParam - 4.0f) : (modeParam - 2.0f), 0.0f, 1.0f);
            float actMask = 1.0f - smoothstep(fillU - 0.012f, fillU + 0.012f, vUv.x);
            float3 specTint = accent > 4.5f ? float3(0.90f, 0.95f, 1.0f) : pk_cauchySpectrum(clamp(vUv.x * 0.82f + 0.08f, 0.0f, 1.0f), accent);
            float topShadow = smoothstep(0.14f, 0.96f, yN);
            float wallShadow = 1.0f - smoothstep(0.0f, 5.2f, rimD);
            float botBevel = exp(-pk_sq((yN + 0.86f) / 0.14f));
            float knobCast = exp(-pk_sq(max(0.0f, vUv.x - fillU) / 0.065f));
            float bedWire = (1.0f - smoothstep(0.0f, 1.15f + aaPx, pxD)) * (0.30f + 0.50f * edgeGain);
            float tLiq = modeParam > 3.5f ? 0.0f : time * 0.65f;
            float w1 = sin(px.x * 0.056f - tLiq * 1.15f + sin(px.y * 0.16f + tLiq * 0.72f) * 1.35f);
            float w2 = sin(px.x * 0.094f + px.y * 0.13f + tLiq * 0.84f + h1 * 1.5f);
            float liqFlow = 0.5f + 0.5f * (w1 * 0.58f + w2 * 0.42f);
            float liqCaustic = pow(max(min(liqFlow, 1.0f), 0.0f), 2.8f);
            float liqBand = exp(-pk_sq((yN + 0.10f - 0.16f * sin(px.x * 0.044f - tLiq)) / 0.48f));
            float liqAmp = 0.32f + 0.68f * ambient;
            float3 liqTint = mix(float3(0.36f, 0.52f, 0.82f), specTint, accent > 4.5f ? 0.15f : 0.42f);

            float3 grooveCol;
            if (isDark > 0.5f) {
                grooveCol = mix(float3(0.092f, 0.108f, 0.152f), float3(0.040f, 0.048f, 0.072f), topShadow * 0.86f);
                grooveCol += float3(0.030f, 0.036f, 0.054f) * (h1 - 0.5f);
                grooveCol += float3(0.28f, 0.36f, 0.52f) * bedWire * (0.20f + 0.24f * liqFlow) * (1.0f - topShadow * 0.45f);
                grooveCol += liqTint * (liqCaustic * 0.22f + liqFlow * 0.07f) * liqBand * liqAmp;
                grooveCol *= 1.0f - wallShadow * 0.48f;
                grooveCol *= 1.0f - knobCast * 0.52f;
                grooveCol += float3(0.28f, 0.35f, 0.48f) * botBevel * 0.24f * (1.0f - knobCast * 0.68f);
            } else {
                grooveCol = mix(float3(0.75f, 0.79f, 0.87f), float3(0.58f, 0.64f, 0.74f), topShadow * 0.78f);
                grooveCol += float3(0.035f) * (h1 - 0.5f);
                grooveCol -= float3(0.10f, 0.12f, 0.16f) * bedWire * 0.24f;
                grooveCol += mix(float3(0.88f, 0.94f, 1.0f), liqTint, 0.35f) * liqCaustic * liqBand * 0.18f * liqAmp;
                grooveCol *= 1.0f - wallShadow * 0.20f;
                grooveCol *= 1.0f - knobCast * 0.24f;
                grooveCol += float3(1.0f) * botBevel * 0.28f;
            }

            float eBoost = 0.25f + 0.75f * fillU;
            float glossMul = isDark > 0.5f ? 1.0f : 0.72f;
            float3 actCol = pow(max(col, float3(0.0f)), float3(1.06f)) * (isDark > 0.5f ? 1.08f : 1.02f);
            float topBroad = exp(-pk_sq((yN - 0.52f - N.x * 0.14f) / 0.14f));
            float topKnife = exp(-pk_sq((yN - 0.65f - N.x * 0.07f) / 0.036f));
            float botBounce = exp(-pk_sq((yN + 0.72f - N.x * 0.06f) / 0.085f));
            actCol += float3(0.96f, 0.985f, 1.0f) * (topBroad * 0.14f + topKnife * 0.38f) * glossMul;
            actCol += mix(float3(0.72f, 0.86f, 1.0f), specTint, 0.50f) * botBounce * 0.26f * eBoost * glossMul;
            actCol += float3(0.98f, 0.99f, 1.0f) * blade * ridgeSpec * edgeGain * (isDark > 0.5f ? 0.68f : 0.44f);
            actCol += specTint * (0.10f + 0.16f * eBoost) * (0.40f + 0.60f * crown) * (0.35f + 0.65f * ambient) * glossMul;
            float seam = exp(-pk_sq(max(0.0f, fillU - vUv.x) / 0.07f)) * actMask;
            actCol += mix(float3(0.90f, 0.96f, 1.0f), specTint, 0.42f) * seam * (isDark > 0.5f ? 0.26f : 0.16f);
            col = mix(grooveCol, actCol, actMask);
        }

        col = max(col, float3(0.0f));
        col = col / (1.0f + col * 0.12f);

        float2 lockCenter = float2(halfSize.x - 15.5f, 0.0f);
        if (modeParam < 1.5f && abs(px.x - lockCenter.x) < 6.5f && abs(px.y) < 7.2f) {
            float lockAa = max(0.35f, 0.68f / dpr);
            float shMask = pk_etchedLockMask(px - (lockCenter + float2(0.6f, -0.8f)), 0.625f, lockAa);
            col = mix(col, isDark > 0.5f ? float3(0.024f, 0.031f, 0.063f) : float3(0.094f, 0.133f, 0.227f), shMask * (isDark > 0.5f ? 0.56f : 0.20f));
            float etMask = pk_etchedLockMask(px - lockCenter, 0.525f, lockAa);
            float etAlpha = isDark > 0.5f ? (0.54f + proximity * 0.28f) : (0.50f + proximity * 0.224f);
            col = mix(col, isDark > 0.5f ? float3(0.933f, 0.961f, 1.0f) : float3(0.149f, 0.188f, 0.282f), clamp(etMask * etAlpha, 0.0f, 1.0f));
        }

        col += (pk_hash21(position + float2(17.0f, 59.0f)) - 0.5f) * (2.0f / 255.0f);
        float3 finalRgb = clamp(col, 0.0f, 1.0f);
        return float4(finalRgb * alphaMask, alphaMask);
    }

    // MARK: - 2. Starfield Cosmic Effort Track

    fragment float4 pk_starfield_track_frag(VertexOut in [[stage_in]], constant PrismUniforms &u [[buffer(0)]]) {
        float2 res = max(u.resTimeDark.xy, float2(4.0f));
        float time = u.resTimeDark.z;
        float isDark = u.resTimeDark.w;
        float accent = u.pointerAccent.w;
        float progress = u.params.x;
        float energy = u.params.y;

        float2 uv = in.uv;
        float2 position = uv * res;
        float2 halfSize = res * 0.5f;
        float2 px = position - halfSize;
        float capR = min(halfSize.x, halfSize.y);
        float sdf = pk_sdCapsuleBox(px, halfSize, capR);
        float alpha = clamp(0.5f - sdf * 2.0f, 0.0f, 1.0f);
        if (alpha < 0.002f) return float4(0.0f);

        float activeMask = 1.0f - smoothstep(progress - 0.015f, progress + 0.015f, uv.x);
        float3 inactiveBase = isDark > 0.5f
            ? mix(float3(0.075f, 0.082f, 0.115f), float3(0.115f, 0.125f, 0.165f), uv.y)
            : mix(float3(0.84f, 0.87f, 0.93f), float3(0.90f, 0.92f, 0.96f), uv.y);

        float3 lowCol = accent > 4.5f ? float3(0.42f, 0.46f, 0.54f) : (accent > 3.5f ? float3(0.78f, 0.45f, 0.08f) : float3(0.302f, 0.576f, 0.973f));
        float3 midCol = accent > 4.5f ? float3(0.62f, 0.66f, 0.74f) : (accent > 3.5f ? float3(0.94f, 0.68f, 0.22f) : float3(0.576f, 0.200f, 0.918f));
        float3 hiCol  = accent > 4.5f ? float3(0.28f, 0.31f, 0.38f) : (accent > 3.5f ? float3(0.58f, 0.24f, 0.04f) : float3(0.298f, 0.114f, 0.584f));
        if (accent < -0.5f) {
            float3 base = pk_decodeCustomAccent(accent);
            lowCol = clamp(base * 0.86f, 0.0f, 1.0f);
            midCol = clamp(mix(pk_shiftHue(base, 0.28f), float3(1.0f), 0.22f), 0.0f, 1.0f);
            hiCol  = clamp(pk_shiftHue(base, -0.32f) * 0.58f, 0.0f, 1.0f);
        }

        float3 activeCol = mix(lowCol, midCol, smoothstep(0.0f, 0.65f, energy));
        activeCol = mix(activeCol, hiCol, smoothstep(0.55f, 1.0f, energy) * (1.0f - 0.35f * uv.x));

        float plasma = pk_fbm3(float2(uv.x * 4.5f - time * (0.45f + energy * 0.65f), uv.y * 2.2f));
        activeCol += mix(midCol, float3(0.76f, 0.58f, 1.0f), 0.55f) * smoothstep(0.35f, 0.85f, plasma) * (0.28f + 0.42f * energy);

        float sweepX = fract(time * 0.32f) * 1.4f - 0.2f;
        float sweep = exp(-pk_sq((uv.x - sweepX) / 0.14f)) * smoothstep(0.45f, 1.0f, energy);
        activeCol += float3(0.86f, 0.80f, 1.0f) * sweep * 0.35f;

        float speed = 1.0f + energy * 1.8f;
        int starCount = int(clamp(energy * 22.0f + 4.0f, 0.0f, 22.0f));
        for (int i = 0; i < 22; i++) {
            if (i >= starCount) break;
            float fi = float(i);
            float2 seed = pk_hash22(float2(fi * 3.17f + 1.1f, fi * 7.43f + 2.9f));
            float sx = (0.04f + seed.x * 0.90f) * max(0.15f, progress) * res.x;
            float sy = (0.18f + seed.y * 0.64f) * res.y;
            float2 d = position - float2(sx, sy);
            float twinkle = 0.28f + 0.72f * pow(max(0.5f + 0.5f * sin(time * (2.1f + seed.x * 2.4f) * speed + fi * 1.9f), 0.0f), 2.2f);
            float core = exp(-dot(d, d) * 0.85f);
            float crossX = exp(-d.y * d.y * 3.8f) * exp(-abs(d.x) * 0.45f);
            float crossY = exp(-d.x * d.x * 3.8f) * exp(-abs(d.y) * 0.45f);
            activeCol += float3(0.95f, 0.94f, 1.0f) * (core * 1.1f + (crossX + crossY) * 0.55f) * twinkle * (0.55f + 0.45f * energy);
        }

        float topGlint = exp(-pk_sq((uv.y - 0.14f) / 0.11f));
        activeCol += float3(1.0f) * topGlint * (isDark > 0.5f ? 0.18f : 0.30f);

        float3 col = mix(inactiveBase, activeCol, activeMask);
        float rim = 1.0f - smoothstep(0.0f, 1.4f, -sdf);
        float3 rimCol = mix(
            isDark > 0.5f ? float3(0.24f) : float3(0.05f, 0.06f, 0.10f),
            mix(midCol, float3(0.92f, 0.86f, 1.0f), 0.5f),
            activeMask * energy * 0.75f
        );
        col = mix(col, rimCol, rim * 0.65f);
        return float4(clamp(col, 0.0f, 1.0f) * alpha, alpha);
    }

    // MARK: - 3. 512K Borosilicate Optical Vial

    static inline void pk_layerOver(thread float3 &col, thread float &alpha, float3 srcCol, float srcA) {
        float a = clamp(srcA, 0.0f, 1.0f);
        if (a <= 1e-4f) return;
        float outA = a + alpha * (1.0f - a);
        col = (srcCol * a + col * alpha * (1.0f - a)) / max(outA, 1e-4f);
        alpha = outA;
    }

    static inline float pk_capsuleHalfWidth(float yPx, float topY, float botY, float rSide, float rc) {
        if (yPx < topY || yPx > botY) return 0.0f;
        float cyT = topY + rc;
        if (yPx < cyT) { float dt = cyT - yPx; return rSide - rc + sqrt(max(0.0f, rc * rc - dt * dt)); }
        float cyB = botY - rc;
        if (yPx > cyB) { float db = yPx - cyB; return rSide - rc + sqrt(max(0.0f, rc * rc - db * db)); }
        return rSide;
    }

    static inline float pk_readWaveIdx(constant PrismUniforms &u, int idx) {
        int c = clamp(idx, 0, 23);
        float4 v = u.wave[c >> 2];
        int rem = c & 3;
        if (rem == 0) return v.x;
        if (rem == 1) return v.y;
        if (rem == 2) return v.z;
        return v.w;
    }

    static inline float pk_sampleWave24(float uNorm, constant PrismUniforms &u) {
        float t = clamp((uNorm + 1.0f) * 0.5f, 0.0f, 1.0f) * 23.0f;
        int i1 = int(clamp(floor(t), 0.0f, 22.0f));
        float f = t - float(i1);
        float p0 = pk_readWaveIdx(u, i1 - 1);
        float p1 = pk_readWaveIdx(u, i1);
        float p2 = pk_readWaveIdx(u, i1 + 1);
        float p3 = pk_readWaveIdx(u, i1 + 2);
        return 0.5f * (2.0f * p1
            + (-p0 + p2) * f
            + (2.0f * p0 - 5.0f * p1 + 4.0f * p2 - p3) * f * f
            + (-p0 + 3.0f * p1 - 3.0f * p2 + p3) * f * f * f);
    }

    static inline float3 pk_evalVialSpectrum(float hFrac, float isDark, float accent, float critical, float fill) {
        float h = clamp(hFrac, 0.0f, 1.0f);
        const float3 ION_DEEP = float3(0.059f, 0.090f, 0.227f);
        const float3 ION_SYS  = float3(0.106f, 0.286f, 0.698f);
        const float3 ION_CONV = float3(0.192f, 0.525f, 1.000f);
        const float3 ION_TOOL = float3(0.361f, 0.776f, 0.988f);
        const float3 CRIT_DEEP = float3(0.360f, 0.145f, 0.035f);
        const float3 CRIT_SYS  = float3(0.740f, 0.330f, 0.075f);
        const float3 CRIT_CONV = float3(0.945f, 0.600f, 0.070f);
        const float3 CRIT_TOOL = float3(0.995f, 0.835f, 0.310f);

        if (isDark > 0.5f) {
            float3 crit = mix(CRIT_DEEP, CRIT_SYS, smoothstep(0.0f, 0.36f, h));
            crit = mix(crit, CRIT_CONV, smoothstep(0.30f, 0.76f, h));
            crit = mix(crit, CRIT_TOOL, smoothstep(0.68f, 1.00f, h));
            if (accent < -0.5f) {
                float3 base = pk_decodeCustomAccent(accent);
                float3 s = mix(base * 0.28f, base * 0.66f, smoothstep(0.0f, 0.40f, h));
                s = mix(s, base, smoothstep(0.34f, 0.78f, h));
                s = mix(s, clamp(mix(pk_shiftHue(base, 0.24f), float3(1.0f), 0.38f), 0.0f, 1.0f), smoothstep(0.70f, 1.00f, h));
                return mix(s, crit, critical);
            }
            if (accent > 4.5f) {
                float3 s = mix(float3(0.110f, 0.115f, 0.128f), float3(0.310f, 0.320f, 0.345f), smoothstep(0.0f, 0.40f, h));
                s = mix(s, float3(0.580f, 0.595f, 0.625f), smoothstep(0.34f, 0.78f, h));
                s = mix(s, float3(0.865f, 0.875f, 0.895f), smoothstep(0.70f, 1.00f, h));
                return mix(s, crit, critical);
            }
            if (accent > 3.5f) {
                float3 s = mix(float3(0.215f, 0.095f, 0.025f), float3(0.580f, 0.270f, 0.055f), smoothstep(0.0f, 0.40f, h));
                s = mix(s, float3(0.851f, 0.467f, 0.024f), smoothstep(0.34f, 0.78f, h));
                s = mix(s, float3(0.984f, 0.749f, 0.141f), smoothstep(0.70f, 1.00f, h));
                return mix(s, crit, critical);
            }
            if (accent > 2.5f) {
                float3 s = mix(float3(0.110f, 0.055f, 0.255f), float3(0.310f, 0.165f, 0.720f), smoothstep(0.0f, 0.40f, h));
                s = mix(s, float3(0.545f, 0.361f, 0.965f), smoothstep(0.34f, 0.78f, h));
                s = mix(s, float3(0.768f, 0.620f, 0.992f), smoothstep(0.70f, 1.00f, h));
                return mix(s, crit, critical);
            }
            if (accent > 0.5f && accent < 1.5f) {
                float3 s = mix(float3(0.24f, 0.11f, 0.08f), float3(0.62f, 0.30f, 0.20f), smoothstep(0.0f, 0.40f, h));
                s = mix(s, float3(0.851f, 0.467f, 0.341f), smoothstep(0.34f, 0.78f, h));
                s = mix(s, float3(0.965f, 0.741f, 0.42f), smoothstep(0.70f, 1.00f, h));
                return mix(s, crit, critical);
            }
            float3 sea = mix(ION_DEEP, ION_SYS, smoothstep(0.0f, 0.38f, h));
            sea = mix(sea, ION_CONV, smoothstep(0.30f, 0.78f, h));
            sea = mix(sea, ION_TOOL, smoothstep(0.68f, 1.00f, h));
            return mix(sea, crit, critical);
        }

        const float3 DAY_ROYAL = float3(0.114f, 0.306f, 0.847f);
        const float3 DAY_COBALT = float3(0.145f, 0.388f, 0.922f);
        const float3 DAY_SKY = float3(0.008f, 0.518f, 0.780f);
        const float3 DAY_CROWN = float3(0.055f, 0.600f, 0.885f);
        const float3 DAY_VIOLET = float3(0.486f, 0.227f, 0.929f);
        const float3 DAY_AMBER_RED = float3(0.918f, 0.345f, 0.047f);

        float3 dayCrit = mix(DAY_VIOLET * 0.86f, DAY_VIOLET, smoothstep(0.0f, 0.34f, h));
        dayCrit = mix(dayCrit, DAY_AMBER_RED, smoothstep(0.28f, 0.80f, h));
        dayCrit = mix(dayCrit, float3(0.960f, 0.560f, 0.065f), smoothstep(0.76f, 1.00f, h));
        if (accent < -0.5f) {
            float3 base = pk_decodeCustomAccent(accent);
            float3 s = mix(base * 0.68f, base * 0.92f, smoothstep(0.0f, 0.50f, h));
            s = mix(s, clamp(mix(pk_shiftHue(base, 0.22f), float3(1.0f), 0.22f), 0.0f, 1.0f), smoothstep(0.45f, 1.00f, h));
            return mix(s, dayCrit, critical);
        }
        if (accent > 4.5f) {
            float3 s = mix(float3(0.153f, 0.153f, 0.165f), float3(0.322f, 0.322f, 0.357f), smoothstep(0.0f, 0.50f, h));
            s = mix(s, float3(0.455f, 0.455f, 0.490f), smoothstep(0.45f, 1.00f, h));
            return mix(s, dayCrit, critical);
        }
        if (accent > 3.5f) {
            float3 s = mix(float3(0.706f, 0.325f, 0.035f), float3(0.851f, 0.467f, 0.024f), smoothstep(0.0f, 0.50f, h));
            s = mix(s, float3(0.961f, 0.620f, 0.043f), smoothstep(0.45f, 1.00f, h));
            return mix(s, dayCrit, critical);
        }
        if (accent > 2.5f) {
            float3 s = mix(float3(0.357f, 0.129f, 0.714f), float3(0.486f, 0.227f, 0.929f), smoothstep(0.0f, 0.50f, h));
            s = mix(s, float3(0.659f, 0.333f, 0.969f), smoothstep(0.45f, 1.00f, h));
            return mix(s, dayCrit, critical);
        }
        if (accent > 0.5f && accent < 1.5f) {
            float3 s = mix(float3(0.58f, 0.22f, 0.12f), float3(0.78f, 0.39f, 0.26f), smoothstep(0.0f, 0.50f, h));
            s = mix(s, float3(0.88f, 0.52f, 0.34f), smoothstep(0.45f, 1.00f, h));
            return mix(s, dayCrit, critical);
        }
        float3 daySea = mix(DAY_ROYAL, DAY_COBALT, smoothstep(0.0f, 0.48f, h));
        daySea = mix(daySea, DAY_SKY, smoothstep(0.42f, 0.88f, h));
        daySea = mix(daySea, DAY_CROWN, smoothstep(0.82f, 1.00f, h));
        float warnShift = smoothstep(0.68f, 0.85f, fill);
        daySea = mix(daySea, mix(DAY_ROYAL, DAY_VIOLET, smoothstep(0.10f, 0.78f, h)), warnShift * 0.68f);
        return mix(daySea, dayCrit, critical);
    }

    fragment float4 pk_optical_vial_frag(VertexOut in [[stage_in]], constant PrismUniforms &u [[buffer(0)]]) {
        float time = u.resTimeDark.z;
        float isDark = u.resTimeDark.w;
        float accent = u.pointerAccent.w;
        float fill = u.params.x;
        float tilt = u.params.y;
        float hoverSlice = u.params.z;
        float wet = u.params.w;
        float3 ratios = u.extra.xyz;

        // The vial is drawn on a 68-unit-wide canvas whose height follows the view's aspect (at least
        // 96 units), so its caps stay round at any size; the hem and floor keep their offsets from the
        // bottom of the original 68x220 canvas.
        float2 res = max(u.resTimeDark.xy, float2(4.0f));
        float unitsPerPoint = max(68.0f / res.x, 96.0f / res.y);
        float2 canvas = res * unitsPerPoint;
        float2 px = in.uv * canvas;
        float CX = canvas.x * 0.5f;
        const float R_OUT = 23.0f;
        const float R_IN = 20.8f;
        const float TOP_OUT = 12.0f;
        const float TOP_IN = 14.2f;
        const float LIP_Y = 12.0f;
        float HEM_Y = canvas.y - 38.0f;
        float FLOOR_OUT = canvas.y - 14.0f;
        float FLOOR_IN = canvas.y - 17.2f;
        const float RC_OUT = 15.5f;
        const float RC_IN = 13.4f;
        float H_BOX_OUT = (FLOOR_OUT - TOP_OUT) * 0.5f;
        float Y_MID_OUT = (FLOOR_OUT + TOP_OUT) * 0.5f;
        float H_BOX_IN = (FLOOR_IN - TOP_IN) * 0.5f;
        float Y_MID_IN = (FLOOR_IN + TOP_IN) * 0.5f;

        const float3 ION_DEEP = float3(0.059f, 0.090f, 0.227f);
        const float3 ION_CONV = float3(0.192f, 0.525f, 1.000f);
        const float3 ION_TOOL = float3(0.361f, 0.776f, 0.988f);
        const float3 ION_HAZE = float3(0.690f, 0.875f, 1.000f);
        const float3 DAY_AIR  = float3(0.880f, 0.920f, 0.980f);
        const float3 DAY_RIM_REF = float3(0.118f, 0.251f, 0.686f);
        const float3 DAY_ROYAL = float3(0.114f, 0.306f, 0.847f);
        const float3 DAY_COBALT = float3(0.145f, 0.388f, 0.922f);
        const float3 DAY_SKY = float3(0.008f, 0.518f, 0.780f);
        const float3 DAY_MENISCUS = float3(0.016f, 0.275f, 0.635f);
        const float3 DAY_VIOLET = float3(0.486f, 0.227f, 0.929f);
        const float3 DAY_AMBER_RED = float3(0.918f, 0.345f, 0.047f);
        const float3 CRIT_DEEP = float3(0.360f, 0.145f, 0.035f);
        const float3 CRIT_CONV = float3(0.945f, 0.600f, 0.070f);
        const float3 CRIT_TOOL = float3(0.995f, 0.835f, 0.310f);

        float dx = px.x - CX;
        float sdfOut = pk_sdCapsuleBox(float2(dx, px.y - Y_MID_OUT), float2(R_OUT, H_BOX_OUT), RC_OUT);
        float distOut = -sdfOut;
        if (distOut <= -0.8f) return float4(0.0f);

        float sdfIn = pk_sdCapsuleBox(float2(dx, px.y - Y_MID_IN), float2(R_IN, H_BOX_IN), RC_IN);
        float distIn = -sdfIn;
        float rOutAtY = pk_capsuleHalfWidth(px.y, TOP_OUT, FLOOR_OUT, R_OUT, RC_OUT);
        float rInAtY = pk_capsuleHalfWidth(px.y, TOP_IN, FLOOR_IN, R_IN, RC_IN);
        bool inInnerBore = distIn > -0.6f;

        float critical = smoothstep(0.82f, 0.94f, fill);
        float3 col = float3(0.0f);
        float alpha = 0.0f;

        float topChamber = LIP_Y + 8.0f;
        float botChamber = HEM_Y + 14.0f;
        float baseSurfY = botChamber - fill * (botChamber - topChamber);
        float uIn = (rInAtY > 0.5f) ? clamp(dx / rInAtY, -1.0f, 1.0f) : clamp(dx / R_IN, -1.0f, 1.0f);
        float au = abs(uIn);
        float slopeTilt = tan(tilt) * dx;
        float waveDisp = pk_sampleWave24(uIn, u);
        float capillary = -1.65f * pow(max(au, 0.0f), 3.0f);

        float surfCenterY = baseSurfY + slopeTilt + waveDisp + capillary;
        float perspAmp = (rInAtY > 0.0f) ? (0.215f * rInAtY * sqrt(max(0.0f, 1.0f - uIn * uIn))) : 0.0f;
        float surfBackY = surfCenterY - perspAmp;
        float surfFrontY = surfCenterY + perspAmp;

        float sumR = max(1e-3f, ratios.x + ratios.y + ratios.z);
        float colH = max(12.0f, FLOOR_IN - baseSurfY);
        float hFrac = clamp((FLOOR_IN - (px.y - slopeTilt * 0.72f - waveDisp * 0.45f)) / colH, 0.0f, 1.0f);
        float3 ionBase = pk_evalVialSpectrum(hFrac, isDark, accent, critical, fill);
        float3 surfTint = pk_evalVialSpectrum(0.96f, isDark, accent, critical, fill);

        float bodyAA = smoothstep(-0.55f, 0.45f, distOut);
        float uOut = clamp(dx / max(1.0f, rOutAtY), -1.0f, 1.0f);
        float lensCurve = pow(max(abs(uOut), 0.0f), 2.6f);
        float3 airBackCol = isDark > 0.5f ? float3(0.045f, 0.068f, 0.125f) : DAY_AIR;
        float airBackA = isDark > 0.5f ? 0.14f * (0.30f + 0.70f * pow(max(abs(uOut), 0.0f), 3.4f)) : mix(0.26f, 0.44f, lensCurve);
        pk_layerOver(col, alpha, airBackCol, airBackA * bodyAA);

        if (isDark <= 0.5f) {
            float wallBand = (1.0f - smoothstep(0.8f, 3.4f, distOut)) * bodyAA;
            float sideRefract = smoothstep(0.66f, 0.98f, abs(uOut)) * bodyAA;
            float capArc = ((1.0f - smoothstep(TOP_OUT + 1.2f, TOP_OUT + 6.5f, px.y)) + smoothstep(FLOOR_OUT - 7.5f, FLOOR_OUT - 1.2f, px.y)) * bodyAA;
            pk_layerOver(col, alpha, DAY_RIM_REF, clamp(max(wallBand * 0.85f, sideRefract * 0.92f) + capArc * 0.42f, 0.0f, 1.0f) * 0.28f);
        }

        if (px.y < TOP_OUT + RC_OUT) {
            float domeGlow = exp(-pk_sq((px.y - (TOP_OUT + 2.8f)) / 2.2f) - pk_sq((dx + 5.0f) / 10.5f)) * bodyAA;
            pk_layerOver(col, alpha, isDark > 0.5f ? mix(ION_HAZE, float3(1.0f), 0.5f) : mix(DAY_COBALT, DAY_SKY, 0.45f), domeGlow * mix(0.26f, 0.34f, isDark));
        }

        if (inInnerBore && px.y >= surfBackY - 0.6f) {
            float boreMask = smoothstep(-0.45f, 0.55f, distIn) * smoothstep(-0.5f, 0.5f, px.y - surfBackY);
            float depthPx = max(0.0f, px.y - surfCenterY);
            float nz = sqrt(max(0.0f, 1.0f - uIn * uIn));
            float plasma = pk_fbm3(float2(dx / 25.0f, (px.y + time * 10.5f) / 38.0f) + float2(sin(time * 0.38f) * 0.22f, 0.0f));
            float field = smoothstep(0.18f, 0.84f, plasma) * (0.42f + 0.58f * nz);

            float3 ionBody;
            if (isDark > 0.5f) {
                float3 deepBody = mix(mix(ION_DEEP * 0.84f, CRIT_DEEP, critical), ionBase, 0.28f + 0.66f * nz);
                ionBody = deepBody * (0.74f + 0.26f * nz) * (0.88f + 0.20f * field);
                ionBody += surfTint * exp(-depthPx / 7.5f) * (0.35f + 0.65f * nz) * 0.18f;
                float subRim = (1.0f - smoothstep(0.35f, 2.4f, distIn)) * smoothstep(-0.2f, 0.5f, distIn);
                ionBody = mix(ionBody, mix(surfTint, ION_HAZE, 0.30f), subRim * 0.38f);
                ionBody += mix(ION_CONV, CRIT_CONV, critical) * exp(-pk_sq(dx / 11.0f) - pk_sq((px.y - (FLOOR_IN - 3.0f)) / 3.6f)) * 0.18f;
            } else {
                float3 richBody = mix(mix(DAY_ROYAL * 0.72f, DAY_VIOLET * 0.68f, critical), ionBase, 0.32f + 0.68f * nz);
                ionBody = richBody * (0.88f + 0.16f * nz) * (0.92f + 0.14f * field);
                ionBody = mix(ionBody, mix(surfTint, float3(0.75f, 0.92f, 1.0f), 0.36f), exp(-depthPx / 8.5f) * (0.40f + 0.60f * nz) * 0.28f);
                float subRim = (1.0f - smoothstep(0.35f, 2.6f, distIn)) * smoothstep(-0.2f, 0.5f, distIn);
                ionBody = mix(ionBody, mix(DAY_RIM_REF, DAY_MENISCUS, 0.45f), subRim * 0.42f);
                ionBody += mix(DAY_COBALT, DAY_AMBER_RED, critical) * exp(-pk_sq(dx / 11.5f) - pk_sq((px.y - (FLOOR_IN - 3.2f)) / 3.8f)) * 0.18f;
            }
            pk_layerOver(col, alpha, clamp(ionBody, 0.0f, 1.0f), boreMask * mix(0.93f, 0.92f, isDark));

            if (depthPx > 1.8f) {
                float arcX = asin(clamp(uIn, -0.96f, 0.96f)) * R_IN;
                float pTime = px.y - (slopeTilt * 0.85f + waveDisp * 0.75f) + time * 6.8f;
                float2 stardustUv = float2(arcX / 5.8f, pTime / 5.8f);
                float2 cellId = floor(stardustUv);
                float2 cellF = fract(stardustUv) - 0.5f;
                float rnd = pk_hash21(cellId + float2(3.7f, 9.1f));
                float2 starOff = cellF - float2((rnd - 0.5f) * 0.28f, sin(rnd * 6.283f + time * 1.2f) * 0.12f);
                float dotRad = mix(0.09f, 0.20f, smoothstep(0.18f, 0.95f, rnd));
                float dotMask = 1.0f - smoothstep(dotRad - 0.07f, dotRad + 0.03f, length(starOff));
                float vis = dotMask * step(0.34f, rnd) * (0.32f + 0.68f * exp(-depthPx / 54.0f)) * (0.65f + 0.35f * sin(time * 2.1f + rnd * 12.566f)) * nz * smoothstep(0.6f, 2.5f, distIn) * boreMask;
                float3 starCol = mix(isDark > 0.5f ? mix(ION_TOOL, ION_HAZE, 0.62f) : float3(0.92f, 0.98f, 1.0f), CRIT_TOOL, critical);
                pk_layerOver(col, alpha, min(starCol * 1.22f, float3(1.0f)), vis * mix(0.62f, 0.72f, isDark));
            }
        }

        if (inInnerBore) {
            float boreMask = smoothstep(-0.35f, 0.55f, distIn);
            if (px.y >= surfBackY - 0.5f && px.y <= surfFrontY + 0.5f) {
                float discV = clamp((px.y - surfBackY) / max(0.8f, surfFrontY - surfBackY), 0.0f, 1.0f);
                float wSlope = pk_sampleWave24(min(1.0f, uIn + 0.06f), u) - pk_sampleWave24(max(-1.0f, uIn - 0.06f), u);
                float excite = smoothstep(0.08f, 0.40f, abs(wSlope) + abs(tilt) * 0.6f);
                float3 discCol = isDark > 0.5f
                    ? mix(surfTint * 0.78f, mix(surfTint, ION_HAZE, 0.45f), 0.32f + 0.68f * discV)
                    : mix(mix(DAY_ROYAL, DAY_SKY, 0.58f), mix(DAY_SKY, float3(0.76f, 0.93f, 1.0f), 0.52f), 0.28f + 0.72f * discV);
                discCol = mix(discCol, float3(0.90f, 0.96f, 1.0f), excite * 0.28f);
                float discMask = smoothstep(-0.45f, 0.45f, px.y - surfBackY) * smoothstep(-0.45f, 0.45f, surfFrontY - px.y) * boreMask;
                pk_layerOver(col, alpha, discCol, discMask * mix(0.68f, 0.58f, isDark));
            }

            float backArc = (1.0f - smoothstep(0.18f, 0.82f, abs(px.y - surfBackY))) * boreMask;
            pk_layerOver(col, alpha, isDark > 0.5f ? mix(surfTint, ION_HAZE, 0.55f) : mix(DAY_MENISCUS, DAY_SKY, 0.45f), backArc * mix(0.64f, 0.54f, isDark));

            float underShadow = (1.0f - smoothstep(0.2f, 0.92f, abs(px.y - (surfFrontY + 1.2f)))) * boreMask * step(px.y, FLOOR_IN - 0.5f);
            pk_layerOver(col, alpha, isDark > 0.5f ? ION_DEEP : DAY_ROYAL * 0.58f, underShadow * mix(0.52f, 0.46f, isDark));

            float dFront = abs(px.y - surfFrontY);
            float laserHalo = exp(-pk_sq(dFront / 2.2f)) * boreMask;
            float laserBlade = (1.0f - smoothstep(0.30f, 0.95f, dFront)) * boreMask;
            if (isDark > 0.5f) {
                float3 laserCol = critical > 0.5f ? mix(CRIT_TOOL, float3(1.0f, 0.97f, 0.86f), 0.48f) : mix(surfTint, ION_HAZE, 0.65f);
                pk_layerOver(col, alpha, laserCol, laserHalo * 0.40f);
                pk_layerOver(col, alpha, mix(laserCol, float3(0.97f, 0.99f, 1.0f), 0.48f), laserBlade * 0.94f);
            } else {
                float3 dayBlade = critical > 0.5f ? mix(float3(0.76f, 0.25f, 0.04f), DAY_AMBER_RED, 0.5f) : DAY_MENISCUS;
                pk_layerOver(col, alpha, dayBlade, laserHalo * 0.38f);
                pk_layerOver(col, alpha, dayBlade, laserBlade * 0.95f);
                float specLine = (1.0f - smoothstep(0.15f, 0.58f, abs(px.y - (surfFrontY - 0.55f)))) * boreMask * (1.0f - 0.45f * au);
                pk_layerOver(col, alpha, float3(0.94f, 0.99f, 1.0f), specLine * 0.72f);
            }
        }

        if (inInnerBore && px.y < surfCenterY && wet > 0.01f) {
            float wetSpan = 48.0f;
            if (px.y > surfCenterY - wet * wetSpan) {
                float wRatio = 1.0f - clamp((surfCenterY - px.y) / (wet * wetSpan), 0.0f, 1.0f);
                float wallMask = (1.0f - smoothstep(0.3f, 2.0f, distIn)) * smoothstep(-0.2f, 0.3f, distIn);
                pk_layerOver(col, alpha, isDark > 0.5f ? mix(surfTint, ION_HAZE, 0.48f) : mix(DAY_COBALT, DAY_SKY, 0.5f), wallMask * wRatio * 0.52f);
            }
        }

        if (px.y > TOP_OUT + 9.0f && px.y < FLOOR_OUT - 9.0f) {
            bool submerged = px.y >= surfCenterY;
            float fineAxisX = CX - R_OUT * 0.72f + (submerged ? 1.15f : 0.0f);
            float fineThread = (1.0f - smoothstep(0.18f, 0.85f, abs(px.x - fineAxisX)))
                * smoothstep(TOP_OUT + 9.0f, TOP_OUT + 22.0f, px.y)
                * (1.0f - smoothstep(FLOOR_OUT - 22.0f, FLOOR_OUT - 9.0f, px.y))
                * smoothstep(0.8f, 1.8f, distOut);
            float3 threadCol = isDark > 0.5f ? float3(0.78f, 0.89f, 1.0f) : (submerged ? float3(0.95f, 0.99f, 1.0f) : mix(DAY_RIM_REF, DAY_COBALT, 0.42f));
            pk_layerOver(col, alpha, threadCol, fineThread * (isDark > 0.5f ? 0.35f : (submerged ? 0.58f : 0.34f)));
        }

        if (hoverSlice >= -0.5f) {
            float midFrac = hoverSlice < 0.5f
                ? (ratios.x * 0.5f) / sumR
                : (hoverSlice < 1.5f ? (ratios.x + ratios.y * 0.5f) / sumR : (ratios.x + ratios.y + ratios.z * 0.5f) / sumR);
            float sliceY = FLOOR_IN - colH * midFrac;
            float hRing = (1.0f - smoothstep(0.25f, 1.15f, abs(px.y - (sliceY + 0.14f * max(0.0f, rOutAtY - abs(dx)))))) * bodyAA;
            pk_layerOver(col, alpha, isDark > 0.5f ? ION_HAZE : float3(1.0f), hRing * 0.88f);
        }

        float rimMask = (1.0f - smoothstep(0.95f, 1.65f, distOut)) * smoothstep(-0.35f, 0.35f, distOut);
        float prismGrad = 0.5f + 0.5f * sin(px.y * 0.032f - time * 0.40f + dx * 0.04f);
        float3 darkRimLeft = mix(float3(0.72f, 0.85f, 0.98f), mix(float3(0.22f, 0.48f, 0.92f), float3(0.48f, 0.56f, 0.92f), prismGrad), 0.30f);
        float3 rimCol = isDark > 0.5f ? mix(darkRimLeft, float3(0.20f, 0.30f, 0.46f), smoothstep(-0.6f, 0.7f, uOut)) : mix(DAY_RIM_REF, float3(0.118f, 0.161f, 0.231f), 0.52f + 0.25f * smoothstep(-0.6f, 0.7f, uOut));
        pk_layerOver(col, alpha, rimCol, rimMask * mix(0.84f, 0.86f, isDark));

        float dither = (pk_hash21(px + fract(time * 7.0f) * 31.0f) - 0.5f) / 255.0f;
        float finalA = clamp(alpha + dither * step(0.01f, alpha), 0.0f, 1.0f);
        float3 finalRgb = clamp(col + float3(dither), 0.0f, 1.0f);
        return float4(finalRgb * finalA, finalA);
    }

    // MARK: - 4. Volumetric 3-Lobe Nebula & Conversation Bottom Horizon Aura

    // Lobe kinematics come from the CPU (PrismNebulaLobes) in u.wave[1..3] as (centerU, centerV, strength, hue),
    // so their 8.4 / 10.8 / 12.8 s cycles never jump when the Float32 shader clock wraps.
    static inline void pk_nebulaAccumulate(float2 position, float2 res, constant PrismUniforms &u, float lightMode, float spectrumMode, thread float3 &accum, thread float &totalW) {
        float diag = length(res);
        accum = float3(0.0f);
        totalW = 0.0f;
        for (int i = 0; i < 3; i++) {
            float4 lobe = u.wave[i + 1];
            float str = lobe.z;
            float rad = diag * (0.34f + 0.08f * str);
            float2 rel = position - lobe.xy * res;
            float rn = length(rel) / max(1.0f, rad);
            if (rn < 1.0f) {
                float w1 = 1.0f - rn;
                float s = w1 * w1 * (3.0f - 2.0f * w1);
                float wi = s * (0.30f + 0.70f * s) * str;
                float nang = atan2(rel.y, rel.x + 1e-5f) * 0.15915494f;
                accum += pk_horizonSpectrum(lobe.w + nang * 0.22f - rn * 0.26f, lightMode, spectrumMode) * wi;
                totalW += wi;
            }
        }
    }

    fragment float4 pk_horizon_aura_frag(VertexOut in [[stage_in]], constant PrismUniforms &u [[buffer(0)]]) {
        float2 res = max(u.resTimeDark.xy, float2(1.0f));
        float time = u.resTimeDark.z;
        float isDark = u.resTimeDark.w;
        float spectrumMode = u.pointerAccent.w;
        float intensity = u.params.x;
        float semanticMode = u.params.y;
        float bottomFocus = u.params.z;

        float2 uv = in.uv;
        float2 position = uv * res;
        float lightMode = 1.0f - isDark;

        if (bottomFocus < 0.5f) {
            float3 accum;
            float totalW;
            pk_nebulaAccumulate(position, res, u, lightMode, spectrumMode, accum, totalW);
            float alpha = clamp(totalW * (isDark > 0.5f ? 0.15f : 0.11f) * intensity, 0.0f, 0.30f);
            float3 col = totalW > 1e-4f ? (accum / totalW) : float3(0.0f);
            float dither = (pk_hash21(position + fract(time) * 19.0f) - 0.5f) / 255.0f;
            col = clamp(col + dither, 0.0f, 1.0f);
            return float4(col * alpha, alpha);
        }

        float yFromBottom = 1.0f - uv.y;
        float reach = (semanticMode > 0.5f && semanticMode < 1.5f) ? 0.90f : 0.70f;
        float verticalEnv = pow(max(min(1.0f - yFromBottom / reach, 1.0f), 0.0f), 2.1f);
        float xDist = abs(uv.x - 0.5f) * 2.0f;
        float horizEnv = exp(-xDist * xDist * 1.45f);
        float breath = 0.86f + 0.14f * sin(time * 2.1f + uv.x * 2.4f);

        float3 auraCol;
        if (semanticMode > 1.5f && semanticMode < 2.5f) {
            auraCol = mix(float3(0.949f, 0.722f, 0.294f), float3(0.851f, 0.467f, 0.024f), yFromBottom);
            breath = 0.92f + 0.08f * sin(time * 1.4f);
        } else if (semanticMode > 2.5f && semanticMode < 3.5f) {
            auraCol = mix(float3(0.918f, 0.325f, 0.294f), float3(0.75f, 0.18f, 0.22f), yFromBottom);
            breath = 1.0f;
        } else if (semanticMode > 3.5f) {
            auraCol = mix(float3(0.361f, 0.776f, 0.988f), float3(0.314f, 0.639f, 0.482f), uv.x);
            breath = 0.72f;
        } else {
            float drift = uv.x * 0.65f - time * (semanticMode > 0.5f ? 0.34f : 0.16f) + yFromBottom * 0.25f;
            auraCol = pk_horizonSpectrum(drift, lightMode, spectrumMode);
        }

        float baseGain = isDark > 0.5f ? 0.36f : 0.24f;
        if (semanticMode > 0.5f && semanticMode < 1.5f) baseGain *= 1.38f;
        float alpha = clamp(verticalEnv * (0.45f + 0.55f * horizEnv) * breath * baseGain * intensity, 0.0f, 0.54f);
        float dither = (pk_hash21(position + fract(time * 3.0f) * 17.0f) - 0.5f) / 255.0f;
        auraCol = clamp(auraCol + dither, 0.0f, 1.0f);
        return float4(auraCol * alpha, alpha);
    }

    // MARK: - 5. Input-Only Pointer-Tracking 220pt Rainbow Prism Specular Rim

    fragment float4 pk_prism_rim_frag(VertexOut in [[stage_in]], constant PrismUniforms &u [[buffer(0)]]) {
        float2 size = max(u.resTimeDark.xy, float2(4.0f));
        float time = u.resTimeDark.z;
        float isDark = u.resTimeDark.w;
        float2 pointerPos = u.pointerAccent.xy;
        float pointerAlpha = u.pointerAccent.z;
        float accent = u.pointerAccent.w;
        float cornerRadius = u.params.x;

        float2 position = in.uv * size;
        float2 halfSize = size * 0.5f;
        float sdf = pk_sdCapsuleBox(position - halfSize, halfSize, cornerRadius);
        float borderDist = abs(sdf + 0.75f);
        float borderMask = 1.0f - smoothstep(0.55f, 1.45f, borderDist);
        if (borderMask <= 0.002f || pointerAlpha <= 0.002f) return float4(0.0f);

        float2 lightPos = pointerPos.x > -2000.0f
            ? pointerPos
            : float2(size.x * (0.28f + 0.22f * sin(time * 0.65f)), 4.0f);

        float t = clamp(length(position - lightPos) / 220.0f, 0.0f, 1.0f);
        if (t >= 1.0f) return float4(0.0f);

        float3 col;
        float falloff = 1.0f - smoothstep(0.74f, 1.0f, t);
        if (isDark > 0.5f) {
            float3 s0 = float3(1.0f, 1.0f, 1.0f);
            float3 s1 = pk_cauchySpectrum(0.05f, accent);
            float3 s2 = pk_cauchySpectrum(0.40f, accent);
            float3 s3 = pk_cauchySpectrum(0.75f, accent);
            float3 s4 = pk_cauchySpectrum(0.98f, accent);
            if (t < 0.24f) col = mix(s0, s1, t / 0.24f);
            else if (t < 0.50f) col = mix(s1, s2, (t - 0.24f) / 0.26f);
            else if (t < 0.74f) col = mix(s2, s3, (t - 0.50f) / 0.24f);
            else col = mix(s3, s4, (t - 0.74f) / 0.26f);
        } else {
            float3 s0 = pk_cauchySpectrum(0.05f, accent);
            float3 s1 = pk_cauchySpectrum(0.38f, accent);
            float3 s2 = pk_cauchySpectrum(0.72f, accent);
            float3 s3 = pk_cauchySpectrum(0.98f, accent);
            if (t < 0.32f) col = mix(s0, s1, t / 0.32f);
            else if (t < 0.64f) col = mix(s1, s2, (t - 0.32f) / 0.32f);
            else col = mix(s2, s3, (t - 0.64f) / 0.36f);
        }

        float a = borderMask * falloff * pointerAlpha * (isDark > 0.5f ? 0.96f : 0.85f);
        return float4(col * a, a);
    }

    // MARK: - 6. Stage Backdrop: 3-Lobe Nebula + GPU ASCII Ripple Sea + Bottom Aura

    // Reduced-resolution nebula pass. The nebula is soft enough to shade at a fraction of the drawable
    // size into a half-float target (no banding) that pk_ascii_sea_frag upsamples bilinearly.
    // Output is premultiplied (color * alpha, alpha).
    fragment float4 pk_ascii_nebula_frag(VertexOut in [[stage_in]], constant PrismUniforms &u [[buffer(0)]]) {
        float2 res = max(u.resTimeDark.xy, float2(1.0f));
        float isDark = u.resTimeDark.w;
        float nebulaIntensity = u.params.x;
        if (nebulaIntensity <= 0.005f) return float4(0.0f);
        float3 accum;
        float totalW;
        pk_nebulaAccumulate(in.uv * res, res, u, 1.0f - isDark, u.pointerAccent.w, accum, totalW);
        if (totalW <= 1e-4f) return float4(0.0f);
        float nebA = clamp(totalW * (isDark > 0.5f ? 0.15f : 0.11f) * nebulaIntensity, 0.0f, 0.30f);
        return float4((accum / totalW) * nebA, nebA);
    }

    fragment float4 pk_ascii_sea_frag(
        VertexOut in [[stage_in]],
        constant PrismUniforms &u [[buffer(0)]],
        texture2d<float> glyphAtlas [[texture(0)]],
        texture2d<float> cellGrid [[texture(1)]],
        texture2d<float> nebulaLayer [[texture(2)]]
    ) {
        constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);
        constexpr sampler nearestClamp(coord::normalized, address::clamp_to_edge, filter::nearest);

        float2 res = max(u.resTimeDark.xy, float2(1.0f));
        float time = u.resTimeDark.z;
        float isDark = u.resTimeDark.w;
        float2 pointerPos = u.pointerAccent.xy;
        float pointerAlpha = u.pointerAccent.z;
        float spectrumMode = u.pointerAccent.w;

        float nebulaIntensity = u.params.x;
        float asciiIntensity = u.params.y;
        float bottomAuraIntensity = u.params.z;
        float semanticMode = u.params.w;

        float cols = max(8.0f, u.extra.x);
        float rows = max(6.0f, u.extra.y);
        float calmCenter = u.extra.z;
        float glyphCount = max(1.0f, u.extra.w);

        float2 uv = in.uv;
        float2 position = uv * res;
        float lightMode = 1.0f - isDark;
        float diag = length(res);

        // 1) 3-Lobe Volumetric Nebula, shaded at reduced resolution by pk_ascii_nebula_frag
        float3 outCol = float3(0.0f);
        float outA = 0.0f;
        if (nebulaIntensity > 0.005f) {
            float4 neb = nebulaLayer.sample(linearClamp, uv);
            if (neb.a > 1e-4f) {
                outCol = neb.rgb / neb.a;
                outA = neb.a;
            }
        }

        // 2) GPU-Accelerated 96x42 Interactive ASCII Ripple Sea
        if (asciiIntensity > 0.005f) {
            float2 gridCoord = uv * float2(cols, rows);
            float2 cellIdx = floor(gridCoord);
            float2 cellF = fract(gridCoord);
            float2 gridUv = (cellIdx + 0.5f) / float2(cols, rows);

            float4 cellData = cellGrid.sample(nearestClamp, gridUv);
            float h = (cellData.r - 0.5f) * 5.0f;
            float cloud = cellData.g;
            float baseGlyph = floor(cellData.b * 255.0f + 0.5f);
            float calm = mix(1.0f, cellData.a, calmCenter);
            float waveAbs = abs(h);

            float auraW = 0.0f;
            if (pointerAlpha > 0.01f && pointerPos.x > -2000.0f) {
                float2 dp = position - pointerPos;
                float d = length(dp);
                if (d < 210.0f) {
                    float w = 1.0f - d / 210.0f;
                    auraW = w * w * (3.0f - 2.0f * w) * pointerAlpha;
                }
            }

            float cellAlpha = clamp(
                (cloud * (isDark > 0.5f ? 0.145f : 0.135f) * calm
                 + min(0.75f, waveAbs * 0.62f)
                 + auraW * (isDark > 0.5f ? 0.36f : 0.30f)) * asciiIntensity,
                0.0f,
                0.86f
            );

            if (cellAlpha > 0.025f) {
                // Keep glyphs neatly centered inside each cell with subtle breathing padding
                float2 local = (cellF - 0.5f) * float2(1.32f, 1.24f) + 0.5f;
                if (local.x >= 0.0f && local.x <= 1.0f && local.y >= 0.0f && local.y <= 1.0f) {
                    float tick = floor(time * 2.1f);
                    float shift = floor(waveAbs * 14.0f) + (auraW > 0.2f ? (tick + cellIdx.x + cellIdx.y) : floor(tick * 0.25f));
                    float gIdx = fmod(baseGlyph + shift, glyphCount);
                    if (gIdx < 0.0f) gIdx += glyphCount;
                    float atlasU = (gIdx + local.x) / glyphCount;
                    float glyphMask = glyphAtlas.sample(linearClamp, float2(atlasU, local.y)).r;

                    if (glyphMask > 0.02f) {
                        // Nebula weight and hue under this glyph, from the same CPU lobes as the nebula pass
                        float asciiNebW = 0.0f;
                        float asciiHueAcc = 0.0f;
                        for (int i = 0; i < 3; i++) {
                            float4 lobe = u.wave[i + 1];
                            float rn = length(position - lobe.xy * res) / max(1.0f, diag * (0.34f + 0.08f * lobe.z));
                            if (rn < 1.0f) {
                                float w1 = 1.0f - rn;
                                float s = w1 * w1 * (3.0f - 2.0f * w1);
                                asciiNebW += s * lobe.z;
                                asciiHueAcc += lobe.w * s * lobe.z;
                            }
                        }
                        float3 baseInk = isDark > 0.5f ? float3(0.62f, 0.65f, 0.72f) : float3(0.28f, 0.36f, 0.50f);
                        float3 ink = baseInk;
                        if (auraW > 0.02f || waveAbs > 0.06f || asciiNebW > 0.08f) {
                            float slopeHue = fract(cellIdx.x * 0.015f + h * 0.45f + time * 0.08f);
                            float chosenHue = (auraW > 0.05f || waveAbs > 0.12f)
                                ? slopeHue
                                : (asciiNebW > 0.001f ? fract(asciiHueAcc / asciiNebW) : 0.12f);
                            float3 spec = pk_horizonSpectrum(chosenHue, lightMode, spectrumMode);
                            float tintMix = clamp(auraW * 0.85f + waveAbs * 0.88f + min(1.0f, asciiNebW) * 0.48f, 0.0f, 0.92f);
                            ink = mix(baseInk, spec, tintMix);
                        }
                        pk_layerOver(outCol, outA, ink, glyphMask * cellAlpha);
                    }
                }
            }
        }

        // 3) Conversation Bottom Horizon Aura (merged into same GPU pass -> zero extra MTKView!)
        if (bottomAuraIntensity > 0.005f) {
            float yPxFromBottom = (1.0f - uv.y) * res.y;
            float bandH = 240.0f;
            if (yPxFromBottom < bandH) {
                float yNorm = yPxFromBottom / bandH;
                float reach = (semanticMode > 0.5f && semanticMode < 1.5f) ? 0.92f : 0.72f;
                float verticalEnv = pow(max(min(1.0f - yNorm / reach, 1.0f), 0.0f), 2.1f);
                float xDist = abs(uv.x - 0.5f) * 2.0f;
                float horizEnv = exp(-xDist * xDist * 1.45f);
                float breath = 0.86f + 0.14f * sin(time * 2.1f + uv.x * 2.4f);

                float3 auraCol;
                if (semanticMode > 1.5f && semanticMode < 2.5f) {
                    auraCol = mix(float3(0.949f, 0.722f, 0.294f), float3(0.851f, 0.467f, 0.024f), yNorm);
                    breath = 0.92f + 0.08f * sin(time * 1.4f);
                } else if (semanticMode > 2.5f && semanticMode < 3.5f) {
                    auraCol = mix(float3(0.918f, 0.325f, 0.294f), float3(0.75f, 0.18f, 0.22f), yNorm);
                    breath = 1.0f;
                } else if (semanticMode > 3.5f) {
                    auraCol = mix(float3(0.361f, 0.776f, 0.988f), float3(0.314f, 0.639f, 0.482f), uv.x);
                    breath = 0.72f;
                } else {
                    float drift = uv.x * 0.65f - time * (semanticMode > 0.5f ? 0.34f : 0.16f) + yNorm * 0.25f;
                    auraCol = pk_horizonSpectrum(drift, lightMode, spectrumMode);
                }

                float baseGain = isDark > 0.5f ? 0.34f : 0.22f;
                if (semanticMode > 0.5f && semanticMode < 1.5f) baseGain *= 1.38f;
                float auraA = clamp(verticalEnv * (0.45f + 0.55f * horizEnv) * breath * baseGain * bottomAuraIntensity, 0.0f, 0.52f);
                pk_layerOver(outCol, outA, auraCol, auraA);
            }
        }

        float dither = (pk_hash21(position + fract(time * 3.0f) * 19.0f) - 0.5f) / 255.0f;
        if (u.wave[0].w > 0.5f) {
            float3 composited = u.wave[0].xyz * (1.0f - outA) + outCol * outA;
            composited = clamp(composited + dither, 0.0f, 1.0f);
            return float4(composited, 1.0f);
        }
        outCol = clamp(outCol + dither, 0.0f, 1.0f);
        return float4(outCol * outA, outA);
    }
    """
}
