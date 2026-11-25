#!/usr/bin/env python3
"""시험용 가짜 주행 기록 만들기 (앱 기록 형식과 같음).

평평한 도로(차선·횡단보도·정지선)를 ARKit 카메라 규약으로 직접 그려 video.mov(HEVC)와
frames/gps/motion/det/marks/events.jsonl, meta.json 을 만든다. replay.py 와 업로드 서버 시험용.

  .venv/bin/python tools/make_fake_session.py /tmp/fake/20260101_000000 --sec 12
"""
import argparse
import json
import math
import subprocess
from pathlib import Path

import numpy as np

ap = argparse.ArgumentParser()
ap.add_argument("out")
ap.add_argument("--sec", type=float, default=12)
ap.add_argument("--fps", type=int, default=30)
ap.add_argument("--speed", type=float, default=30, help="km/h")
ap.add_argument("--mount", type=float, default=1.25)
ap.add_argument("--pitch", type=float, default=8, help="광축이 아래로 기운 각도 (deg)")
a = ap.parse_args()

D = Path(a.out)
D.mkdir(parents=True, exist_ok=True)
W, H = 1280, 960
K1920 = [1450.0, 1450.0, 960.0, 720.0]  # fx fy cx cy (1920×1440 기준, 앱과 같음)
s = W / 1920
fx, fy, cx, cy = K1920[0] * s, K1920[1] * s, K1920[2] * s, K1920[3] * s
uu, vv = np.meshgrid(np.arange(W) + 0.5, np.arange(H) + 0.5)
dir_cam = np.stack([(uu - cx) / fx, -(vv - cy) / fy, -np.ones_like(uu)], -1)
rng = np.random.default_rng(1)
noise = (rng.random((512, 512)) * 30).astype(np.float32)


def texture(x, z):
    """도로 색 (BGR). 도로는 -z 방향으로 뻗음, 폭 ±7m."""
    g = 70 + noise[(np.floor(x * 8).astype(int)) % 512, (np.floor(z * 8).astype(int)) % 512]
    img = np.stack([g, g, g + 3], -1)
    white = np.zeros_like(x, bool)
    for lx in (-1.75, 1.75):  # 점선
        white |= (np.abs(x - lx) < 0.075) & (np.mod(-z, 12) < 4)
    for lx in (-5.25, 5.25):  # 실선
        white |= np.abs(x - lx) < 0.075
    white |= (np.abs(z + 90) < 0.25) & (x > -5.25) & (x < 0)  # 정지선
    white |= (z < -92) & (z > -97) & (np.mod(x + 10, 1.0) < 0.5) & (np.abs(x) < 5.25)  # 횡단보도
    # 직진 화살표 (몸통 + 머리)
    ax, az = -3.5, -70
    white |= (np.abs(x - ax) < 0.15) & (z > az) & (z < az + 3)
    white |= (z <= az) & (z > az - 1.5) & (np.abs(x - ax) < (z - (az - 1.5)) * 0.4)
    img[white] = (235, 235, 235)
    off = np.abs(x) > 7
    img[off] = (60, 110, 60)
    return img


def cam_pose(t):
    v = a.speed / 3.6
    zc = -v * t
    xc = 1.75 + 0.3 * math.sin(t * 0.6) - 3.5 * 0  # 오른쪽 차로 가운데 (+x = 오른쪽)
    yaw = 0.3 * 0.6 * math.cos(t * 0.6) / v  # 진행 방향 미세 변화
    fwd = np.array([math.sin(yaw), 0, -math.cos(yaw)])
    p = math.radians(a.pitch)
    look = math.cos(p) * fwd + math.sin(p) * np.array([0, -1, 0])
    down = np.array([0, -1, 0.0])
    xcam = down - look * (down @ look)
    xcam /= np.linalg.norm(xcam)  # 세로 거치: 이미지 오른쪽 = 땅 쪽
    zcam = -look
    ycam = np.cross(zcam, xcam)
    R = np.stack([xcam, ycam, zcam], 1)
    pos = np.array([xc, a.mount, zc])
    return R, pos, fwd, v


ff = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", f"{W}x{H}",
                       "-r", str(a.fps), "-i", "-", "-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
                       "-tag:v", "hvc1", str(D / "video.mov")], stdin=subprocess.PIPE)
T0 = 1000.0
n = int(a.sec * a.fps)
frames, dets, marks, gps, motion = [], [], [], [], []
for i in range(n):
    t = i / a.fps
    R, pos, fwd, v = cam_pose(t)
    d = dir_cam @ R.T
    with np.errstate(divide="ignore", invalid="ignore"):
        k = (0 - pos[1]) / d[..., 1]
    hit = (d[..., 1] < -1e-3) & (k > 0) & (k < 400)
    img = np.empty((H, W, 3), np.float32)
    img[:] = (230, 200, 160)
    xs = pos[0] + d[..., 0] * k
    zs = pos[2] + d[..., 2] * k
    img[hit] = texture(xs[hit], zs[hit])
    # 본넷 (세로 화면 아래 = 이미지 오른쪽 25%)
    img[:, int(W * 0.78):] = (25, 25, 30)
    ff.stdin.write(img.clip(0, 255).astype(np.uint8).tobytes())
    M = np.eye(4)
    M[:3, :3] = R
    M[:3, 3] = pos
    Tcol = M.T.reshape(-1).tolist()
    yaw_cam = math.atan2(-R[2, 2], -R[0, 2])
    frames.append({"i": i, "t": T0 + t, "v": i, "trk": "normal" if t > 0.5 else "init", "ok": t > 0.5,
                   "T": [round(x, 6) for x in Tcol], "K": K1920, "exp": 0.004, "ev": 0, "lux": 1000, "th": 0,
                   "o": [pos[0], 0.0, pos[2]], "f": [fwd[0], fwd[2]], "spd": v, "off": 0.0,
                   "offn": max(0, int((t - 2) * 30))})
    if i % 3 == 0:
        motion.append({"t": T0 + t, "q": [0, 0, 0, 1], "rr": [0, 0, 0], "ua": [0, 0, 0], "g": [0, -1, 0]})
    if i % 30 == 0:
        lat = 37.5 + (-pos[2]) / 110540
        lon = 127.0 + pos[0] / (111320 * math.cos(math.radians(37.5)))
        gps.append({"t": T0 + t, "lat": lat, "lon": lon, "alt": 30, "hacc": 5, "vacc": 3, "spd": v * 1.02, "sacc": 0.5,
                    "crs": 0, "cacc": 5, "date": 1.7e9 + t})
    if i % 3 == 0:
        # 앞 25m 에 정지한 차 한 대 (가짜 상자)
        car_world = np.array([-1.75, 0.0, -60.0])
        dets.append({"t": T0 + t, "boxes": [{"k": "car", "c": 0.8, "b": [0.4, 0.45, 0.1, 0.08],
                                             "g": [car_world[0], car_world[2]]}],
                     "tracks": [{"id": 1, "k": "car", "p": [car_world[0], car_world[2]], "vel": [0, 0], "w": 1.85,
                                 "hits": 5}]})
    if i % 15 == 0:
        marks.append({"t": T0 + t, "st": t, "o": [pos[0], pos[2]], "dets": [],
                      "tracks": [{"id": 1, "k": "straight", "p": [-3.5, -70.5], "h": [0, -1], "s": 2, "hits": 3}]})
ff.stdin.close()
ff.wait()


def wj(name, rows):
    with open(D / f"{name}.jsonl", "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")


wj("frames", frames)
wj("motion", motion)
wj("gps", gps)
wj("det", dets)
wj("marks", marks)
wj("events", [{"t": T0, "e": "start"}, {"t": T0 + a.sec * 0.6, "e": "flag", "n": 1}, {"t": T0 + a.sec, "e": "stop"}])
meta = {"format": 1, "start": "2026-01-01T00:00:00Z", "end": "2026-01-01T00:00:%02dZ" % int(a.sec), "device": "fake",
        "ios": "-", "app": "fake", "t0": T0, "video": {"file": "video.mov", "w": W, "h": H},
        "prefs": {"mountHeight": a.mount, "hoodCut": 0.22, "carFront": 2.0, "carRear": 2.8, "carWidth": 1.85,
                  "memorySec": 120, "maxDistance": 22, "detection": True, "roadMarks": True, "renderMode": 2},
        "frames": n, "videoFrames": n, "dropped": 0, "flags": 1, "complete": True}
(D / "meta.json").write_text(json.dumps(meta, indent=2))
print("ok", D, n, "frames")
