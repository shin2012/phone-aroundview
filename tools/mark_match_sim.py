#!/usr/bin/env python3
"""노면 표시 인식 시험 (앱의 Metal 매칭과 같은 계산을 numpy 로).

가짜 노면(차선 점선·실선·화살표·횡단보도·잡음·기록 빈 곳)을 만들고, 앱과 같은 방식으로
템플릿(5 px/m, 회전 3개)을 만들어 정규화 상관을 계산해 맞은 것 / 틀린 것을 센다.
실행: .venv/bin/python tools/mark_match_sim.py [--seed N] [--png out.png]
"""
import json, math, sys, pathlib
import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[1]
MK = ROOT / "ios/AroundView/RoadMarks"
PPM = 5.0                      # 패치 해상도 (앱 RoadMarkDetector.ppm)
X0, X1, Z0, Z1 = -6.0, 6.0, -12.0, 24.0
ANGLES = (-6.0, 0.0, 6.0)      # 도
MARGIN = 0.4                   # 템플릿 바깥 여백 (m)
THRESH = 0.62                  # 앱 RoadMarkDetector.threshold 와 같게
RADIUS = 1.6                   # 겹침 제거 거리 (m)
DISTRACT = {"_dash": (0.15, 3.0), "_line": (0.15, 6.0)}


def load_alpha(name):
    im = Image.open(MK / f"mark_{name}.png").convert("RGBA")
    return np.asarray(im, dtype=float)[..., 3] / 255


def raster(alpha, w_m, l_m, ppm, ang_deg, margin=MARGIN, ss=4):
    """앱 RoadMarkDetector.rasterize 와 같은 계산. 행 = 앞쪽(+Z) 증가, 열 = 오른쪽(+X) 증가."""
    th = math.radians(ang_deg)
    c, s = math.cos(th), math.sin(th)
    hw, hl = w_m / 2, l_m / 2
    ex = abs(hw * c) + abs(hl * s) + margin
    ez = abs(hw * s) + abs(hl * c) + margin
    W = int(math.ceil(2 * ex * ppm)) | 1
    H = int(math.ceil(2 * ez * ppm)) | 1
    ah, aw = alpha.shape
    out = np.zeros((H, W))
    for j in range(H):
        for i in range(W):
            acc = 0.0
            for sj in range(ss):
                for si in range(ss):
                    X = (i + (si + 0.5) / ss) / ppm - W / (2 * ppm)
                    Z = (j + (sj + 0.5) / ss) / ppm - H / (2 * ppm)
                    # 회전 역변환: (u, v) = R(-th) (X, Z)
                    u = X * c + Z * s
                    v = -X * s + Z * c
                    px = (u + hw) / w_m * aw
                    py = (hl - v) / l_m * ah     # 그림 위쪽 = 앞(+v)
                    if 0 <= px < aw and 0 <= py < ah:
                        acc += alpha[int(py), int(px)]
            out[j, i] = acc / (ss * ss)
    return out


def normalize(t):
    t = t - t.mean()
    n = np.sqrt((t * t).sum())
    return t / n if n > 0 else t


def stamp(patch, alpha, w, l, X, Z, ang):
    t = raster(alpha, w, l, PPM, ang, margin=0)
    H, W = t.shape
    ci = int(round((X - X0) * PPM)); cj = int(round((Z - Z0) * PPM))
    for j in range(H):
        for i in range(W):
            y, x = cj - H // 2 + j, ci - W // 2 + i
            if 0 <= y < patch.shape[0] and 0 <= x < patch.shape[1]:
                patch[y, x] = max(patch[y, x], t[j, i])


def ncc(patch, tpl):
    H, W = patch.shape
    h, w = tpl.shape
    out = np.zeros((H, W))
    for y in range(H):
        for x in range(W):
            y0, x0 = y - h // 2, x - w // 2
            if y0 < 0 or x0 < 0 or y0 + h > H or x0 + w > W:
                continue
            win = patch[y0:y0 + h, x0:x0 + w]
            valid = win >= 0
            if (~valid).sum() > w * h // 10:
                continue
            p = np.where(valid, win, 0)
            n = valid.sum()
            var = (p * p).sum() - p.sum() ** 2 / n
            if var > 1e-3:
                out[y, x] = (tpl * p).sum() / math.sqrt(var)
    return out


def detect(patch, tpls):
    cands = []
    for (name, ang), t in tpls.items():
        sc = ncc(patch, t)
        for y in range(1, sc.shape[0] - 1):
            for x in range(1, sc.shape[1] - 1):
                v = sc[y, x]
                if v >= THRESH and v == sc[y - 1:y + 2, x - 1:x + 2].max():
                    cands.append((v, name, ang, X0 + (x + 0.5) / PPM, Z0 + (y + 0.5) / PPM))
    cands.sort(reverse=True)
    keep = []
    for c in cands:
        r = 0.9 if c[1] == "crosswalk" else RADIUS
        if all(math.hypot(c[3] - k[3], c[4] - k[4]) > (0.9 if (c[1] == k[1] == "crosswalk") else RADIUS) for k in keep):
            keep.append(c)
    return keep


def main():
    seed = int(sys.argv[sys.argv.index("--seed") + 1]) if "--seed" in sys.argv else 1
    rng = np.random.default_rng(seed)
    meta = json.loads((MK / "marks.json").read_text())
    alphas = {k: load_alpha(k) for k in meta}
    # 방해 템플릿(차선 점선·실선): 이기면 그 자리 후보를 지움 (그리지 않음)
    for k, (w, l) in DISTRACT.items():
        meta[k] = {"w": w, "l": l}; alphas[k] = np.ones((64, 8))
    tpls = {(k, a): normalize(raster(alphas[k], meta[k]["w"], meta[k]["l"], PPM, a)) for k in meta for a in ANGLES}

    H = int((Z1 - Z0) * PPM); W = int((X1 - X0) * PPM)
    patch = np.zeros((H, W))
    # 차선: 왼쪽 노란 실선 겹선(-5.3), 점선(-1.75, 1.75), 오른쪽 실선(5.2)
    def line(X, width, dash=None, gap=None, off=0.0):
        for j in range(H):
            Z = Z0 + (j + 0.5) / PPM
            if dash and ((Z + off) % (dash + gap)) > dash: continue
            for i in range(W):
                Xc = X0 + (i + 0.5) / PPM
                if abs(Xc - X) < width / 2: patch[j, i] = 1.0
    line(-5.3, 0.15); line(-5.0, 0.15); line(-1.75, 0.15, 3, 5); line(1.75, 0.15, 3, 5, 2.0); line(5.2, 0.2)
    truth = [("straight", 0.0, 6.0), ("left", -3.5, 7.0), ("straight_right", 3.5, 6.5), ("crosswalk_ahead", 0.0, -6.0),
             ("stop_line", 0.0, 17.0)]
    for name, X, Z in truth:
        stamp(patch, alphas[name], meta[name]["w"], meta[name]["l"], X, Z, rng.uniform(-3, 3))
    # 횡단보도 (19~23m, 전체 폭)
    for k in range(-5, 6):
        for j in range(H):
            Z = Z0 + (j + 0.5) / PPM
            if 19.5 < Z < 23.5:
                for i in range(W):
                    Xc = X0 + (i + 0.5) / PPM
                    if abs(Xc - k * 1.18) < 0.29: patch[j, i] = 1.0
    # 흐림 + 잡음 + 기록 빈 곳(좌측 아래)
    from scipy import ndimage
    patch = ndimage.gaussian_filter(patch, 0.6) * rng.uniform(0.6, 0.95)
    patch += rng.normal(0, 0.08, patch.shape)
    patch += (rng.random(patch.shape) < 0.01) * 0.7  # 점 잡음
    patch = np.clip(patch, 0, 1)
    patch[:20, :15] = -1

    found = [f for f in detect(patch, tpls) if not f[1].startswith("_")]
    hit, fp = set(), []
    for f in found:
        ok = [t for t in truth if t[0] == f[1] and math.hypot(t[1] - f[3], t[2] - f[4]) < 1.0]
        if f[1] == "crosswalk" and 19.5 < f[4] < 23.5: ok = [("crosswalk",)]
        if ok: hit.add(ok[0])
        else: fp.append(f)
        print(f"{'O' if ok else 'X'} {f[1]:<16} {f[2]:+.0f}° X={f[3]:+.1f} Z={f[4]:+.1f} 점수={f[0]:.2f}")
    miss = [t for t in truth if t not in hit]
    print(f"정답 {len(truth)} 중 찾음 {len([h for h in hit if len(h) > 1])}, 놓침 {miss}, 오인식 {len(fp)}, 횡단보도 {'O' if ('crosswalk',) in hit else 'X'}")
    if "--png" in sys.argv:
        img = (np.clip(np.where(patch < 0, 0.3, patch), 0, 1) * 255).astype(np.uint8)[::-1]
        Image.fromarray(img).resize((W * 4, H * 4), Image.NEAREST).save(sys.argv[sys.argv.index("--png") + 1])


if __name__ == "__main__":
    main()
