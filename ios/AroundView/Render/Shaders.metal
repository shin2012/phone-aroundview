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

/// 노면 기억 조회. grid = (ppm, N, 현재 시각, 기억 시간)
static bool lookup(float2 w, texture2d<float> color, texture2d<float> meta, float4 grid,
                   thread float3 &rgb, thread float &age) {
    constexpr sampler rs(address::repeat, filter::linear);
    float ppm = grid.x; int N = int(grid.y);
    int2 cell = int2(floor(w * ppm));
    uint2 idx = uint2(((cell % N) + N) % N);
    float4 m = meta.read(idx);
    if (m.x != float(cell.x) || m.y != float(cell.y)) return false;
    age = grid.z - m.z;
    if (age > grid.w || age < -1.0) return false;
    rgb = color.sample(rs, w * ppm / float(N), level(0)).rgb;
    return true;
}

static float luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

/// 차선 도색 정도: 주변 평균보다 밝고(흰색) 충분히 밝은 곳. 화면 그리기와 노면 표시 인식이 같이 씀
static float paintScore(float2 w, float3 rgb, texture2d<float> color, texture2d<float> meta, float4 grid) {
    float l = luma(rgb);
    float sum = 0; float n = 0;
    float2 offs[4] = { float2(0.7, 0), float2(-0.7, 0), float2(0, 0.7), float2(0, -0.7) };
    for (int i = 0; i < 4; i++) {
        float3 c2; float a2;
        if (lookup(w + offs[i], color, meta, grid, c2, a2)) { sum += luma(c2); n += 1; }
    }
    float mean = n > 0 ? sum / n : l;
    return smoothstep(0.06, 0.16, l - mean) * smoothstep(0.30, 0.45, l);
}

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
    bool ok = lookup(g.world, color, meta, u.grid, rgb, age);
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
        float paint = paintScore(g.world, rgb, color, meta, u.grid);
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

// ---------- 3) 노면 표시 인식 ----------
// 차 기준 정렬 패치: 열 = 오른쪽(X) 증가, 행 = 앞쪽(Z) 증가. 값 = 도색 정도(0~1), 기록 없음 = -1
struct PatchU {
    float4 car;    // originX originZ fwdX fwdZ
    float4 grid;   // ppm N time memorySec
    float4 patch;  // X0 Z0 patchPPM 0
};

kernel void paintPatch(texture2d<float> color [[texture(0)]],
                       texture2d<float> meta  [[texture(1)]],
                       texture2d<float, access::write> out [[texture(2)]],
                       constant PatchU &u [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float2 f = u.car.zw;
    float2 r = float2(-f.y, f.x);
    float step = 1.0 / u.patch.z;
    // 2×2 표본 평균 (패치가 노면 기억보다 성김)
    float acc = 0; float n = 0;
    for (int sy = 0; sy < 2; sy++) for (int sx = 0; sx < 2; sx++) {
        float X = u.patch.x + (float(gid.x) + 0.25 + 0.5 * sx) * step;
        float Z = u.patch.y + (float(gid.y) + 0.25 + 0.5 * sy) * step;
        float2 w = u.car.xy + r * X + f * Z;
        float3 rgb; float age;
        if (lookup(w, color, meta, u.grid, rgb, age)) { acc += paintScore(w, rgb, color, meta, u.grid); n += 1; }
    }
    out.write(float4(n >= 2 ? acc / n : -1.0), gid);
}

struct TplInfo { int offset; int w; int h; int pad; };

// 위치마다·템플릿마다 정규화 상관. 템플릿은 평균 0, 길이 1 로 미리 맞춰 둠
kernel void matchMarks(texture2d<float> patch [[texture(0)]],
                       constant float *tpl [[buffer(0)]],
                       constant TplInfo *info [[buffer(1)]],
                       device float *scores [[buffer(2)]],
                       constant uint4 &dims [[buffer(3)]],   // W H T 0
                       uint3 gid [[thread_position_in_grid]]) {
    uint W = dims.x, H = dims.y, T = dims.z;
    if (gid.x >= W || gid.y >= H || gid.z >= T) return;
    TplInfo ti = info[gid.z];
    int x0 = int(gid.x) - ti.w / 2, y0 = int(gid.y) - ti.h / 2;
    float score = 0;
    if (x0 >= 0 && y0 >= 0 && x0 + ti.w <= int(W) && y0 + ti.h <= int(H)) {
        float n = 0, sp = 0, sp2 = 0, stp = 0; int bad = 0;
        for (int j = 0; j < ti.h; j++) {
            for (int i = 0; i < ti.w; i++) {
                float p = patch.read(uint2(x0 + i, y0 + j)).r;
                if (p < 0) { bad++; continue; }
                float t = tpl[ti.offset + j * ti.w + i];
                n += 1; sp += p; sp2 += p * p; stp += t * p;
            }
        }
        if (bad <= ti.w * ti.h / 10 && n > 0) {
            float var = sp2 - sp * sp / n;
            if (var > 1e-3) score = stp / sqrt(var);
        }
    }
    scores[(gid.z * H + gid.y) * W + gid.x] = score;
}

// ---------- 4) 카메라 미리보기 ----------
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
