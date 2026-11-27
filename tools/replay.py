#!/usr/bin/env python3
"""폰어라운드 주행 기록 → 분석 보고서 + 재생 영상.

앱이 하는 노면 기억 계산을 numpy 로 다시 돌린다 (ARKit 자세·내부 파라미터를 그대로 사용).

  .venv/bin/python tools/replay.py data/sessions/20261126_081500 [--out DIR] [--fps 10] [--no-video]

출력 (기본 <기록>/analysis/):
  report.md / report.json  요약 (추적 상태, ARKit 속도 vs GPS 속도, 방향 보정, 프레임 누락, 인식 수, 표시 지점)
  track.png                ARKit 경로 vs GPS 경로 (GPS 에 맞춰 회전), 표시 지점
  speed.png                ARKit 속도 / GPS 속도
  replay.mp4               왼쪽 카메라(세로) + 오른쪽 위에서 본 노면 기억, 인식 물체·노면 표시
  flag_<n>.jpg             사용자가 깃발 누른 순간의 재생 화면
  overview.jpg             전체 경로 노면 모자이크
"""
import argparse
import json
import math
import sys
from pathlib import Path

import cv2
import numpy as np

ap = argparse.ArgumentParser()
ap.add_argument("session")
ap.add_argument("--out")
ap.add_argument("--fps", type=float, default=10, help="재생 영상 프레임 수 (초당)")
ap.add_argument("--ppm", type=float, default=10, help="노면 기억 해상도 (px/m)")
ap.add_argument("--no-video", action="store_true")
ap.add_argument("--max-sec", type=float, default=0, help="앞에서부터 이 초까지만")
a = ap.parse_args()

S = Path(a.session)
OUT = Path(a.out) if a.out else S / "analysis"
OUT.mkdir(parents=True, exist_ok=True)


def jl(name):
    p = S / f"{name}.jsonl"
    out = []
    if p.exists():
        for line in p.open():
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    pass  # 앱이 꺼지며 잘린 마지막 줄
    return out


meta = json.loads((S / "meta.json").read_text())
frames = jl("frames")
gps = [g for g in jl("gps") if "lat" in g]
dets = jl("det")
marks = jl("marks")
events = jl("events")
if not frames:
    sys.exit("frames.jsonl 이 비어 있습니다")
t0 = meta.get("t0", frames[0]["t"])
if a.max_sec:
    frames = [f for f in frames if f["t"] - t0 <= a.max_sec]
prefs = meta.get("prefs", {})
mount = prefs.get("mountHeight", 1.25)
hood = prefs.get("hoodCut", 0.3)
car_front, car_rear, car_w = prefs.get("carFront", 2.0), prefs.get("carRear", 2.8), prefs.get("carWidth", 1.85)
max_dist = prefs.get("maxDistance", 22.0)
flags = [e for e in events if e.get("e") == "flag"]

ft = np.array([f["t"] - t0 for f in frames])
spd = np.array([f.get("spd", 0) for f in frames])
okm = np.array([bool(f.get("ok")) for f in frames])
pos = np.array([[f["T"][12], f["T"][14]] for f in frames])

# ---------------------------------------------------------------- 요약
rep = {"session": S.name, "device": meta.get("device"), "app": meta.get("app"), "prefs": prefs}
dur = ft[-1] - ft[0] if len(ft) > 1 else 0
rep["duration_s"] = round(float(dur), 1)
rep["frames"] = len(frames)
rep["fps"] = round(len(frames) / dur, 1) if dur else None
rep["video_frames"] = sum(1 for f in frames if f.get("v", -1) >= 0)
rep["dropped_video"] = len(frames) - rep["video_frames"]
trk = {}
for f in frames:
    trk[f["trk"]] = trk.get(f["trk"], 0) + 1
rep["tracking"] = {k: round(v / len(frames) * 100, 1) for k, v in sorted(trk.items(), key=lambda x: -x[1])}
# 추적 끊김 구간
gaps, cur = [], None
for f in frames:
    if not f.get("ok"):
        cur = cur or [f["t"] - t0, f["t"] - t0, f["trk"]]
        cur[1] = f["t"] - t0
    elif cur:
        if cur[1] - cur[0] > 0.3:
            gaps.append([round(cur[0], 1), round(cur[1], 1), cur[2]])
        cur = None
rep["tracking_gaps"] = gaps[:50]
rep["distance_arkit_m"] = round(float(np.sum(np.linalg.norm(np.diff(pos, axis=0), axis=1))), 1)
learned = next((f["t"] - t0 for f in frames if f.get("offn", 0) > 30), None)
rep["heading_learned_at_s"] = None if learned is None else round(learned, 1)
rep["heading_offset_deg_final"] = round(math.degrees(frames[-1].get("off", 0)), 1)
rep["reset_events"] = sum(1 for e in events if e.get("e") == "reset")
rep["interruptions"] = sum(1 for e in events if e.get("e") == "interrupted")
rep["thermal_max"] = max((f.get("th", 0) for f in frames), default=0)
# 0.4.0~: 노면 기록을 쉰 프레임과 이유, 후진으로 판정된 비율, 거치 비뚤어짐
skips = {}
for f in frames:
    if f.get("ok") and not f.get("w", True):
        skips[f.get("why", "?")] = skips.get(f.get("why", "?"), 0) + 1
rep["ground_skip_frames"] = skips
rep["reverse_frames"] = sum(1 for f in frames if f.get("spd", 0) < -0.7)
if any("gy" in f for f in frames):
    gy = np.array([f["gy"] for f in frames if f.get("ok") and "gy" in f])
    raw = np.array([f["T"][13] - mount for f in frames if f.get("ok") and "gy" in f])
    rep["ground_height_jitter_cm"] = {"raw": round(float(np.std(np.diff(raw))) * 100, 2),
                                      "filtered": round(float(np.std(np.diff(gy))) * 100, 2)}

# GPS 비교
gps_cmp = None
if gps:
    gt = np.array([g["t"] - t0 for g in gps])
    gs = np.array([g["spd"] for g in gps])
    good = (gs >= 0) & (gt >= ft[0]) & (gt <= ft[-1])
    if good.sum() > 5:
        ar_at = np.interp(gt[good], ft, np.abs(spd))
        moving = gs[good] > 3
        gps_cmp = {
            "gps_points": int(good.sum()),
            "gps_hacc_median_m": round(float(np.median([g["hacc"] for g in gps])), 1),
            "speed_mae_kmh": round(float(np.mean(np.abs(ar_at - gs[good])) * 3.6), 2),
            "speed_ratio_moving": round(float(np.median(ar_at[moving] / gs[good][moving])), 3) if moving.sum() > 5 else None,
        }
        # 거리 비교 (위경도 → 평면)
        lat0 = math.radians(gps[0]["lat"])
        en = np.array([[(g["lon"] - gps[0]["lon"]) * 111320 * math.cos(lat0), (g["lat"] - gps[0]["lat"]) * 110540] for g in gps])
        gps_cmp["distance_gps_m"] = round(float(np.sum(np.linalg.norm(np.diff(en, axis=0), axis=1))), 1)
rep["gps"] = gps_cmp

kinds = {}
for d in dets:
    for b in d.get("boxes", []):
        if b.get("c", 0) > 0.35:
            kinds[b["k"]] = kinds.get(b["k"], 0) + 1
rep["detections"] = {"runs": len(dets), "boxes_by_kind": kinds}
mk = {}
for m in marks:
    for d in m.get("dets", []):
        mk[d["k"]] = mk.get(d["k"], 0) + 1
rep["road_marks"] = {"runs": len(marks), "dets_by_kind": mk,
                     "final_tracks": len(marks[-1]["tracks"]) if marks else 0}
rep["flags"] = [{"n": e.get("n"), "t_s": round(e["t"] - t0, 1)} for e in flags]
(OUT / "report.json").write_text(json.dumps(rep, ensure_ascii=False, indent=2))

# ---------------------------------------------------------------- 그림: 경로·속도
def plot_track():
    W = H = 900
    img = np.full((H, W, 3), 255, np.uint8)
    pts = [pos]
    gps_en = None
    if gps:
        lat0 = math.radians(gps[0]["lat"])
        gps_en = np.array([[(g["lon"] - gps[0]["lon"]) * 111320 * math.cos(lat0), (g["lat"] - gps[0]["lat"]) * 110540]
                           for g in gps])
        # ARKit (x, z) → 동·북 에 맞추기: 2D 회전+이동 최소제곱 (시간 맞춘 점끼리)
        gt = np.array([g["t"] - t0 for g in gps])
        sel = (gt >= ft[0]) & (gt <= ft[-1]) & (np.array([g["hacc"] for g in gps]) < 20)
        if sel.sum() > 5:
            A = np.stack([np.interp(gt[sel], ft, pos[:, 0]), -np.interp(gt[sel], ft, pos[:, 1])], 1)  # z 는 남쪽 → 부호
            B = gps_en[sel]
            ca, cb = A.mean(0), B.mean(0)
            U, _, Vt = np.linalg.svd((A - ca).T @ (B - cb))
            R = (U @ Vt).T
            if np.linalg.det(R) < 0:
                Vt[-1] *= -1
                R = (U @ Vt).T
            arp = (np.stack([pos[:, 0], -pos[:, 1]], 1) - ca) @ R.T + cb
            pts = [arp, gps_en]
        else:
            pts = [np.stack([pos[:, 0], -pos[:, 1]], 1)]
    else:
        pts = [np.stack([pos[:, 0], -pos[:, 1]], 1)]
    allp = np.concatenate(pts)
    lo, hi = allp.min(0) - 10, allp.max(0) + 10
    sc = min((W - 40) / max(hi[0] - lo[0], 1), (H - 80) / max(hi[1] - lo[1], 1))

    def px(p):
        return (int(20 + (p[0] - lo[0]) * sc), int(H - 40 - (p[1] - lo[1]) * sc))

    colors = [(200, 80, 0), (0, 160, 0)]
    for k, P in enumerate(pts):
        cv2.polylines(img, [np.array([px(p) for p in P], np.int32)], False, colors[k], 2, cv2.LINE_AA)
    for e in flags:
        i = int(np.searchsorted(ft, e["t"] - t0).clip(0, len(ft) - 1))
        p = px(pts[0][i])
        cv2.circle(img, p, 7, (0, 0, 255), -1)
        cv2.putText(img, f"#{e.get('n')}", (p[0] + 8, p[1] - 6), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 255), 2)
    cv2.putText(img, "blue=ARKit  green=GPS  red=flag", (20, 25), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 0), 1)
    cv2.putText(img, f"scale {1 / sc * 100:.1f} m/100px", (20, H - 12), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 0), 1)
    cv2.imwrite(str(OUT / "track.png"), img)


def plot_speed():
    W, H = 1200, 360
    img = np.full((H, W, 3), 255, np.uint8)
    T = max(ft[-1], 1)
    vmax = max(float(np.abs(spd).max() * 3.6), max((g["spd"] * 3.6 for g in gps), default=0), 10)

    def px(t, v):
        return (int(40 + t / T * (W - 60)), int(H - 30 - v / vmax * (H - 60)))

    for v in range(0, int(vmax) + 1, 10):
        y = px(0, v)[1]
        cv2.line(img, (40, y), (W - 20, y), (230, 230, 230), 1)
        cv2.putText(img, str(v), (5, y + 4), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (120, 120, 120), 1)
    step = max(1, len(ft) // 3000)
    cv2.polylines(img, [np.array([px(t, abs(v) * 3.6) for t, v in zip(ft[::step], spd[::step])], np.int32)], False,
                  (200, 80, 0), 1, cv2.LINE_AA)
    if gps:
        gp = [px(g["t"] - t0, g["spd"] * 3.6) for g in gps if g["spd"] >= 0 and 0 <= g["t"] - t0 <= T]
        if len(gp) > 1:
            cv2.polylines(img, [np.array(gp, np.int32)], False, (0, 160, 0), 2, cv2.LINE_AA)
    for s, e, _ in gaps:
        cv2.rectangle(img, (px(s, 0)[0], 20), (px(e, 0)[0], H - 30), (180, 180, 255), -1)
    for e in flags:
        x = px(e["t"] - t0, 0)[0]
        cv2.line(img, (x, 20), (x, H - 30), (0, 0, 255), 1)
    cv2.putText(img, "km/h  blue=ARKit green=GPS pink=tracking lost red=flag", (40, 15), cv2.FONT_HERSHEY_SIMPLEX, 0.45,
                (0, 0, 0), 1)
    cv2.imwrite(str(OUT / "speed.png"), img)


plot_track()
plot_speed()

# ---------------------------------------------------------------- 노면 기억 재생
class Ground:
    """앱의 노면 기억과 같은 계산: 차 중심 격자를 매 프레임 카메라에 투영해 색을 채우고, 이동한 만큼 옮긴다."""

    def __init__(self, ppm, left=12, right=12, back=20, front=30):
        self.ppm = ppm
        self.X0, self.Z1 = -left, front
        self.w, self.h = int((left + right) * ppm), int((back + front) * ppm)
        cols, rows = np.meshgrid(np.arange(self.w), np.arange(self.h))
        self.X = (cols + 0.5) / ppm + self.X0
        self.Z = self.Z1 - (rows + 0.5) / ppm
        self.img = np.zeros((self.h, self.w, 3), np.uint8)
        self.age = np.full((self.h, self.w), 1e9, np.float32)
        self.prev = None  # (origin xz, forward xz)

    def world(self, o, f):
        r = np.array([-f[1], f[0]])
        wx = o[0] + r[0] * self.X + f[0] * self.Z
        wz = o[1] + r[1] * self.X + f[1] * self.Z
        return wx, wz

    def move(self, o, f, dt):
        if self.prev is not None:
            po, pf = self.prev
            wx, wz = self.world(o, f)
            pr = np.array([-pf[1], pf[0]])
            dx, dz = wx - po[0], wz - po[1]
            Xp = dx * pr[0] + dz * pr[1]
            Zp = dx * pf[0] + dz * pf[1]
            mx = ((Xp - self.X0) * self.ppm - 0.5).astype(np.float32)
            my = ((self.Z1 - Zp) * self.ppm - 0.5).astype(np.float32)
            self.img = cv2.remap(self.img, mx, my, cv2.INTER_LINEAR, borderValue=(0, 0, 0))
            self.age = cv2.remap(self.age, mx, my, cv2.INTER_NEAREST, borderValue=1e9) + dt
        self.prev = (np.array(o), np.array(f))

    def paint(self, frame_bgr, T, K, ground_y, o, f, hood_side):
        h_img, w_img = frame_bgr.shape[:2]
        sx = w_img / 1920.0  # K 는 1920×1440 기준
        fx, fy, cx, cy = K[0] * sx, K[1] * sx, K[2] * sx, K[3] * sx
        M = np.array(T, np.float64).reshape(4, 4).T  # 열 우선 → 행렬
        R, t = M[:3, :3], M[:3, 3]
        wx, wz = self.world(o, f)
        P = np.stack([wx - t[0], np.full_like(wx, ground_y) - t[1], wz - t[2]], -1) @ R  # 카메라 좌표
        zc = -P[..., 2]
        with np.errstate(divide="ignore", invalid="ignore"):
            u = fx * P[..., 0] / zc + cx
            v = cy - fy * P[..., 1] / zc
        dist = np.hypot(wx - t[0], wz - t[2])
        valid = (zc > 0.5) & (u >= 0) & (u < w_img - 1) & (v >= 0) & (v < h_img - 1) & (dist < max_dist)
        # 본넷 가림 (세로 화면 아래쪽 = 이미지에서 땅 쪽 가장자리)
        if hood_side == "right":
            valid &= u < w_img * (1 - hood)
        elif hood_side == "left":
            valid &= u > w_img * hood
        elif hood_side == "bottom":
            valid &= v < h_img * (1 - hood)
        else:
            valid &= v > h_img * hood
        mx = np.where(valid, u, -1).astype(np.float32)
        my = np.where(valid, v, -1).astype(np.float32)
        s = cv2.remap(frame_bgr, mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
        self.img[valid] = s[valid]
        self.age[valid] = 0
        return valid

    def car_px(self, X, Z):
        return int((X - self.X0) * self.ppm), int((self.Z1 - Z) * self.ppm)


def hood_side_of(T):
    """세로 거치에서 땅 방향이 이미지 어느 가장자리인지 (본넷 가림 위치)."""
    M = np.array(T, np.float64).reshape(4, 4).T
    down_cam = M[:3, :3].T @ np.array([0, -1, 0])  # 카메라 좌표의 아래 방향 (x 오른쪽, y 위)
    if abs(down_cam[0]) > abs(down_cam[1]):
        return "right" if down_cam[0] > 0 else "left"
    return "top" if down_cam[1] > 0 else "bottom"


def portrait(img, side):
    # 땅이 아래로 가도록 회전
    if side == "right":
        return cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
    if side == "left":
        return cv2.rotate(img, cv2.ROTATE_90_COUNTERCLOCKWISE)
    if side == "top":
        return cv2.rotate(img, cv2.ROTATE_180)
    return img


video_path = S / meta.get("video", {}).get("file", "video.mov")
if a.no_video or not video_path.exists():
    print("영상 없음/생략 — 요약만")
else:
    cap = cv2.VideoCapture(str(video_path))
    G = Ground(a.ppm)
    det_t = np.array([d["t"] - t0 for d in dets]) if dets else np.array([])
    mark_t = np.array([m["t"] - t0 for m in marks]) if marks else np.array([])
    flag_t = [(e["t"] - t0, e.get("n")) for e in flags]
    writer = None
    vi_next = 0
    last_out = -1e9
    last_t = None
    side = None
    overview = {}
    OV_PPM = 2.0
    frame_img = None
    for f in frames:
        v = f.get("v", -1)
        t = f["t"] - t0
        if v < 0:
            continue
        while vi_next <= v:
            ok, frame_img = cap.read()
            vi_next += 1
            if not ok:
                frame_img = None
                break
        if frame_img is None:
            break
        o = (f["o"][0], f["o"][2])
        fw = np.array(f["f"], np.float64)
        n = np.linalg.norm(fw)
        if n < 1e-6:
            continue
        fw /= n
        side = side or hood_side_of(f["T"])
        G.move(o, fw, 0 if last_t is None else t - last_t)
        last_t = t
        if f.get("ok") and f.get("w", True):   # 0.4.0~: 앱이 흔들림 등으로 쉰 프레임은 똑같이 건너뜀
            G.paint(frame_img, f["T"], f["K"], f["o"][1], o, fw, side)
        # 전체 경로 모자이크 (2px/m, 차 주변 앞쪽 띠만)
        if f.get("ok") and int(t * 2) != int((t - 1 / 30) * 2):
            ring = (G.age < 0.5)
            wx, wz = G.world(o, fw)
            ix = np.floor(wx[ring] * OV_PPM).astype(int)
            iz = np.floor(wz[ring] * OV_PPM).astype(int)
            cols = G.img[ring]
            for x_, z_, c_ in zip(ix[::7], iz[::7], cols[::7]):
                overview[(x_, z_)] = c_
        if t - last_out < 1 / a.fps:
            continue
        last_out = t
        # --- 화면 구성
        cam = portrait(cv2.resize(frame_img, (640, 480)), side)
        ch, cw = cam.shape[:2]
        y_h = int(ch * (1 - hood))
        cv2.line(cam, (0, y_h), (cw, y_h), (0, 0, 255), 1)
        bev = G.img.copy()
        fade = np.clip(G.age / max(prefs.get("memorySec", 120), 1), 0, 1)
        bev = (bev * (1 - 0.6 * fade[..., None])).astype(np.uint8)
        p1, p2 = G.car_px(-car_w / 2, car_front), G.car_px(car_w / 2, -car_rear)
        cv2.rectangle(bev, p1, p2, (255, 255, 255), 2)
        r_ = np.array([-fw[1], fw[0]])

        def to_car(px_, pz_):
            d_ = np.array([px_ - o[0], pz_ - o[1]])
            return float(d_ @ r_), float(d_ @ fw)

        if len(det_t):
            j = int(np.searchsorted(det_t, t))
            j = max(0, min(j, len(det_t) - 1))
            if abs(det_t[j] - t) < 0.25:
                d = dets[j]
                for b in d.get("boxes", []):
                    x, y, w, h = b["b"]
                    col = (0, 165, 255) if b["k"] == "person" else (255, 255, 0)
                    if b.get("c", 0) < 0.35:
                        col = (128, 128, 128)
                    cv2.rectangle(cam, (int(x * cw), int(y * ch)), (int((x + w) * cw), int((y + h) * ch)), col, 1)
                    if "g" in b:
                        X, Z = to_car(*b["g"])
                        cv2.circle(bev, G.car_px(X, Z), 4, col, -1)
                for tr in d.get("tracks", []):
                    if tr.get("hits", 0) >= 2:
                        X, Z = to_car(*tr["p"])
                        cv2.circle(bev, G.car_px(X, Z), 8, (0, 255, 0), 2)
        if len(mark_t):
            j = int(np.searchsorted(mark_t, t)) - 1
            if j >= 0:
                for tr in marks[j].get("tracks", []):
                    if tr.get("hits", 0) >= 2:
                        X, Z = to_car(*tr["p"])
                        q = G.car_px(X, Z)
                        cv2.drawMarker(bev, q, (255, 0, 255), cv2.MARKER_DIAMOND, 12, 2)
                        cv2.putText(bev, tr["k"][:8], (q[0] + 6, q[1]), cv2.FONT_HERSHEY_SIMPLEX, 0.35, (255, 0, 255), 1)
        scale = ch / bev.shape[0]
        bev = cv2.resize(bev, (int(bev.shape[1] * scale), ch))
        canvas = np.hstack([cam, bev])
        bar = np.zeros((40, canvas.shape[1], 3), np.uint8)
        txt = f"t={t:6.1f}s  {abs(f.get('spd', 0)) * 3.6:5.1f} km/h  trk={f['trk']}  off={math.degrees(f.get('off', 0)):+.1f}deg"
        cv2.putText(bar, txt, (8, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 1, cv2.LINE_AA)
        fl = [nf for tf, nf in flag_t if abs(tf - t) < 1.5]
        if fl:
            cv2.putText(bar, f"FLAG #{fl[0]}", (canvas.shape[1] - 130, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 255), 2)
            canvas = cv2.copyMakeBorder(canvas, 4, 4, 4, 4, cv2.BORDER_CONSTANT, value=(0, 0, 255))
            bar = cv2.resize(bar, (canvas.shape[1], 40))
        canvas = np.vstack([bar, canvas])
        for tf, nf in flag_t:
            if 0 <= t - tf < 1 / a.fps + 1e-6:
                cv2.imwrite(str(OUT / f"flag_{nf}.jpg"), canvas)
        if writer is None:
            writer = cv2.VideoWriter(str(OUT / "replay.mp4"), cv2.VideoWriter_fourcc(*"mp4v"), a.fps,
                                     (canvas.shape[1] // 2 * 2, canvas.shape[0] // 2 * 2))
            out_size = (canvas.shape[1] // 2 * 2, canvas.shape[0] // 2 * 2)
        writer.write(cv2.resize(canvas, out_size))
    if writer:
        writer.release()
    cap.release()
    if overview:
        ks = np.array(list(overview.keys()))
        lo, hi = ks.min(0), ks.max(0)
        Wd, Hd = hi - lo + 1
        if Wd * Hd < 12000 * 12000:
            ov = np.zeros((Hd, Wd, 3), np.uint8)
            for (x_, z_), c_ in overview.items():
                ov[z_ - lo[1], x_ - lo[0]] = c_
            ov = cv2.dilate(ov, np.ones((3, 3), np.uint8))
            ov = cv2.flip(ov, 0)  # z 남쪽 → 위쪽이 북쪽에 가깝게
            cv2.imwrite(str(OUT / "overview.jpg"), ov)
    rep["replay"] = {"side": side, "video": str(OUT / "replay.mp4")}

# ---------------------------------------------------------------- 보고서
L = [f"# 폰어라운드 기록 {S.name}", "",
     f"- 기기 {rep['device']} · 앱 {rep['app']}",
     f"- 길이 {rep['duration_s']}초 · 프레임 {rep['frames']} ({rep['fps']} fps) · 영상 누락 {rep['dropped_video']}",
     f"- ARKit 이동 거리 {rep['distance_arkit_m']} m",
     "- 추적 상태 " + ", ".join(f"{k} {v}%" for k, v in rep["tracking"].items()),
     f"- 추적 끊김 구간 {len(gaps)}개" + (": " + ", ".join(f"{s}~{e}s({k})" for s, e, k in gaps[:10]) if gaps else ""),
     f"- 방향 보정 완료 {rep['heading_learned_at_s']}초 · 최종 오프셋 {rep['heading_offset_deg_final']}°",
     f"- 초기화 {rep['reset_events']}회 · 중단 {rep['interruptions']}회 · 최고 발열 단계 {rep['thermal_max']}"]
if gps_cmp:
    L.append(f"- GPS {gps_cmp['gps_points']}점 (정확도 중앙값 {gps_cmp['gps_hacc_median_m']} m) · GPS 거리 {gps_cmp['distance_gps_m']} m")
    L.append(f"- 속도 오차 평균 {gps_cmp['speed_mae_kmh']} km/h · ARKit/GPS 속도 비 {gps_cmp['speed_ratio_moving']}")
L.append(f"- 물체 인식 {rep['detections']['runs']}회 · " + ", ".join(f"{k} {v}" for k, v in kinds.items()))
L.append(f"- 노면 표시 {rep['road_marks']['runs']}회 · " + ", ".join(f"{k} {v}" for k, v in mk.items()))
if flags:
    L.append("- 표시 지점 " + ", ".join(f"#{x['n']} {x['t_s']}s" for x in rep["flags"]))
(OUT / "report.md").write_text("\n".join(L) + "\n")
(OUT / "report.json").write_text(json.dumps(rep, ensure_ascii=False, indent=2))
print("\n".join(L))
