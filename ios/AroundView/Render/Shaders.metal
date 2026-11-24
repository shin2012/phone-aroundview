#include <metal_stdlib>
using namespace metal;

// ---------- 공통 ----------
constant float4x4 ycbcrToRGB = float4x4(
    float4(+1.0000f, +1.0000f, +1.0000f, +0.0000f),
    float4(+0.0000f, -0.3441f, +1.7720f, +0.0000f),
    float4(+1.4020f, -0.7141f, +0.0000f, +0.0000f),
    float4(-0.7010f, +0.5291f, -0.8860f, +1.0000f));

static float3 sampleCamera(texture2d<float> y, texture2d<float> cbcr, float2 uv) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float4 ycc = float4(y.sample(s, uv).r, cbcr.sample(s, uv).rg, 1.0);
    return (ycbcrToRGB * ycc).rgb;
}

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);   // (0,0) (2,0) (0,2)
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0, 1);
    o.uv = float2(p.x, 1.0 - p.y);                 // 좌상단 원점
    return o;
}

// ---------- 1) 노면 기록 (카메라 → 월드 격자) ----------
struct WriteU {
    float4x4 worldToCam;
    float4 intr;   // fx fy cx cy
    float4 img;    // W H groundY time
    float4 aff0;   // a c tx   (이미지 정규 → 세로 화면 정규 x)
    float4 aff1;   // b d ty   (… y)
    float4 cam;    // camX camZ maxDist hoodCut
    float4 grid;   // originCellX originCellZ ppm N
    float4 misc;   // boxCount
};

kernel void writeGround(texture2d<float, access::write> color [[texture(0)]],
                        texture2d<float, access::write> meta  [[texture(1)]],
                        texture2d<float> camY    [[texture(2)]],
                        texture2d<float> camCbCr [[texture(3)]],
                        constant WriteU &u [[buffer(0)]],
                        constant float4 *boxes [[buffer(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    float ppm = u.grid.z;
    int N = int(u.grid.w);
    int2 cell = int2(u.grid.xy) + int2(gid);
    float2 w = (float2(cell) + 0.5) / ppm;                 // 월드 x, z
    float2 rel = w - u.cam.xy;
    if (length(rel) > u.cam.z) return;

    float4 pc = u.worldToCam * float4(w.x, u.img.z, w.y, 1.0);
    float depth = -pc.z;
    if (depth < 0.8) return;
    float px = u.intr.z + u.intr.x * pc.x / depth;
    float py = u.intr.w - u.intr.y * pc.y / depth;
    float2 uv = float2(px / u.img.x, py / u.img.y);
    if (any(uv < 0.002) || any(uv > 0.998)) return;

    // 세로 화면 좌표: 본넷 가림·움직이는 물체 상자 제외
    float2 sp = float2(u.aff0.x * uv.x + u.aff0.y * uv.y + u.aff0.z,
                       u.aff1.x * uv.x + u.aff1.y * uv.y + u.aff1.z);
    if (sp.y > 1.0 - u.cam.w) return;
    int bc = int(u.misc.x);
    for (int i = 0; i < bc; i++) {
        float4 b = boxes[i];
        if (sp.x > b.x && sp.x < b.z && sp.y > b.y && sp.y < b.w) return;
    }

    float3 rgb = sampleCamera(camY, camCbCr, uv);
    uint2 idx = uint2(((cell % N) + N) % N);
    color.write(float4(rgb, 1.0), idx);
    meta.write(float4(float(cell.x), float(cell.y), u.img.w, depth), idx);
}

kernel void clearMeta(texture2d<float, access::write> meta [[texture(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    meta.write(float4(1e9, 1e9, -1e9, 0), gid);
}

// ---------- 2) 어라운드 뷰 ----------
struct RenderU {
    float4x4 invVP;
    float4 car;    // originX originZ fwdX fwdZ
    float4 grid;   // ppm N time memorySec
    float4 mode;   // mode(0 실사 1 가상 2 혼합)
};

struct Ground { bool hit; float2 world; float dist; };

static Ground castGround(float2 uv, constant RenderU &u) {
    float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    float4 a = u.invVP * float4(ndc, 0.0, 1.0);
    float4 b = u.invVP * float4(ndc, 1.0, 1.0);
    float3 p0 = a.xyz / a.w, p1 = b.xyz / b.w;
    float3 d = p1 - p0;
    Ground g; g.hit = false; g.world = 0; g.dist = 0;
    if (d.y > -1e-5) return g;
    float t = -p0.y / d.y;
    if (t < 0) return g;
    float3 h = p0 + d * t;                       // GL 차량 좌표 (x, 0, -Z)
    float X = h.x, Z = -h.z;
    float2 f = u.car.zw;
    float2 r = float2(-f.y, f.x);
    g.hit = true;
    g.world = u.car.xy + r * X + f * Z;
    g.dist = length(float2(X, Z));
    return g;
}

static bool lookup(float2 w, texture2d<float> color, texture2d<float> meta, constant RenderU &u,
                   thread float3 &rgb, thread float &age) {
    constexpr sampler rs(address::repeat, filter::linear);
    float ppm = u.grid.x; int N = int(u.grid.y);
    int2 cell = int2(floor(w * ppm));
    uint2 idx = uint2(((cell % N) + N) % N);
    float4 m = meta.read(idx);
    if (m.x != float(cell.x) || m.y != float(cell.y)) return false;
    age = u.grid.z - m.z;
    if (age > u.grid.w || age < -1.0) return false;
    rgb = color.sample(rs, w * ppm / float(N)).rgb;
    return true;
}

static float luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

fragment float4 aroundFragment(VOut in [[stage_in]],
                               texture2d<float> color [[texture(0)]],
                               texture2d<float> meta  [[texture(1)]],
                               constant RenderU &u [[buffer(0)]]) {
    float mode = u.mode.x;
    Ground g = castGround(in.uv, u);
    float3 sky = mix(float3(0.10, 0.11, 0.14), float3(0.03, 0.035, 0.05), in.uv.y);
    if (!g.hit) return float4(sky, 1);

    float3 unknown = float3(0.075, 0.08, 0.095);
    float3 asphalt = float3(0.17, 0.18, 0.20);
    float3 rgb; float age = 0;
    bool ok = lookup(g.world, color, meta, u, rgb, age);
    float fog = smoothstep(35.0, 90.0, g.dist);

    float3 outc;
    if (!ok) {
        // 기록 없는 곳: 가상 모드는 은은한 격자, 실사는 어두운 바탕
        float2 gw = fract(g.world / 2.0);
        float line = (min(gw.x, gw.y) < 0.02) ? 0.025 : 0.0;
        outc = unknown + line;
    } else {
        float fade = mix(1.0, 0.55, clamp(age / u.grid.w, 0.0, 1.0));
        // 차선 도색 판정: 주변 평균보다 밝고 채도 낮음(흰색) 또는 노란색
        float l = luma(rgb);
        float sum = 0; float n = 0;
        float2 offs[4] = { float2(0.7, 0), float2(-0.7, 0), float2(0, 0.7), float2(0, -0.7) };
        for (int i = 0; i < 4; i++) {
            float3 c2; float a2;
            if (lookup(g.world + offs[i], color, meta, u, c2, a2)) { sum += luma(c2); n += 1; }
        }
        float mean = n > 0 ? sum / n : l;
        float paint = smoothstep(0.06, 0.16, l - mean) * smoothstep(0.30, 0.45, l);
        bool yellow = (rgb.r - rgb.b) > 0.12 && (rgb.g - rgb.b) > 0.06;
        float3 paintCol = yellow ? float3(1.0, 0.78, 0.25) : float3(0.95, 0.96, 0.98);

        if (mode < 0.5) {            // 실사
            outc = rgb * fade;
        } else if (mode < 1.5) {     // 가상 (테슬라식)
            outc = mix(asphalt * mix(1.0, 0.8, clamp(age / u.grid.w, 0.0, 1.0)), paintCol, paint);
        } else {                     // 혼합: 흐린 실사 위에 차선 강조
            float3 gray = float3(luma(rgb));
            float3 base = mix(gray, rgb, 0.45) * 0.75 * fade;
            outc = mix(base, paintCol, paint * 0.85);
        }
    }
    outc = mix(outc, sky, fog);
    return float4(outc, 1);
}

// ---------- 3) 카메라 미리보기 ----------
struct PreviewU { float4 aff0; float4 aff1; };  // 세로 화면 정규 → 이미지 정규

fragment float4 previewFragment(VOut in [[stage_in]],
                                texture2d<float> camY [[texture(0)]],
                                texture2d<float> camCbCr [[texture(1)]],
                                constant PreviewU &u [[buffer(0)]]) {
    float2 p = in.uv;
    float2 uv = float2(u.aff0.x * p.x + u.aff0.y * p.y + u.aff0.z,
                       u.aff1.x * p.x + u.aff1.y * p.y + u.aff1.z);
    return float4(sampleCamera(camY, camCbCr, uv), 1);
}
