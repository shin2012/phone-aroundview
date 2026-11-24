"""Phone dashcam -> pseudo around-view (BEV mosaic) prototype.

Pipeline: ground-plane IPM (flat road assumption) -> sparse optical flow on road ROI
-> 2D rigid ego-motion (RANSAC) -> accumulate BEV patches into a world mosaic
-> render ego-centric around view (car icon, past imagery shown beside/behind).
"""
import argparse, json, math
import cv2
import numpy as np

ap = argparse.ArgumentParser()
ap.add_argument('video')
ap.add_argument('--out', default='out')
ap.add_argument('--h', type=float, default=1.2, help='camera height (m)')
ap.add_argument('--hfov_long', type=float, default=65.0, help='FOV along long image side (deg)')
ap.add_argument('--vy', type=float, default=622.0, help='horizon y (px)')
ap.add_argument('--vx', type=float, default=None, help='vanishing x (px); auto if omitted')
ap.add_argument('--roi', default='645,780', help='usable road rows y0,y1 (above hood)')
ap.add_argument('--step', type=int, default=1)
ap.add_argument('--max_frames', type=int, default=0)
a = ap.parse_args()

cap = cv2.VideoCapture(a.video)
FPS = cap.get(cv2.CAP_PROP_FPS) or 30
frames = []
while True:
    ok, f = cap.read()
    if not ok: break
    frames.append(f)
    if a.max_frames and len(frames) >= a.max_frames: break
H_IMG, W_IMG = frames[0].shape[:2]
f_px = (max(H_IMG, W_IMG) / 2) / math.tan(math.radians(a.hfov_long / 2))
cx, cy = W_IMG / 2, H_IMG / 2
K = np.array([[f_px, 0, cx], [0, f_px, cy], [0, 0, 1]])
Kinv = np.linalg.inv(K)
Y0, Y1 = map(int, a.roi.split(','))
print(f'{len(frames)} frames {W_IMG}x{H_IMG} fps={FPS} f={f_px:.0f}px', flush=True)


def make_R(vx, vy):
    fwd = np.array([(vx - cx) / f_px, (vy - cy) / f_px, 1.0]); fwd /= np.linalg.norm(fwd)
    ey = np.array([0, 1.0, 0]); down = ey - ey.dot(fwd) * fwd; down /= np.linalg.norm(down)
    right = np.cross(down, fwd)
    return np.stack([right, down, fwd], 1)  # world->cam: p_cam = R @ p_world


def img2ground(pts, R):
    uv1 = np.c_[pts, np.ones(len(pts))]
    d = (R.T @ (Kinv @ uv1.T)).T  # rays in world
    t = a.h / d[:, 1]
    return np.c_[t * d[:, 0], t * d[:, 2]], d[:, 1]  # X (right), Z (forward)


def ground2img_maps(R, xs, zs):
    X, Z = np.meshgrid(xs, zs)
    P = np.stack([X, np.full_like(X, a.h), Z], -1) @ R.T
    P = P @ K.T
    u = P[..., 0] / P[..., 2]; v = P[..., 1] / P[..., 2]
    bad = (P[..., 2] <= 0) | (v < Y0) | (v > Y1) | (u < 0) | (u >= W_IMG)
    u[bad] = -1; v[bad] = -1
    return u.astype(np.float32), v.astype(np.float32)


lk = dict(winSize=(21, 21), maxLevel=3, criteria=(cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 30, 0.01))
mask = np.zeros((H_IMG, W_IMG), np.uint8); mask[Y0:Y1, :] = 255
grays = [cv2.cvtColor(f, cv2.COLOR_BGR2GRAY) for f in frames]


def raw_flows(idx):
    """pixel correspondences between frame i and i+step on the road ROI"""
    out = {}
    for i in idx:
        g0, g1 = grays[i], grays[i + a.step]
        p0 = cv2.goodFeaturesToTrack(g0, 400, 0.005, 6, mask=mask)
        if p0 is None or len(p0) < 8: continue
        p1, st, _ = cv2.calcOpticalFlowPyrLK(g0, g1, p0, None, **lk)
        pb, stb, _ = cv2.calcOpticalFlowPyrLK(g1, g0, p1, None, **lk)
        good = (st[:, 0] == 1) & (stb[:, 0] == 1) & (np.linalg.norm((pb - p0)[:, 0], axis=1) < 1.0)
        good &= (p1[:, 0, 1] > Y0) & (p1[:, 0, 1] < Y1)
        if good.sum() >= 8: out[i] = (p0[good, 0], p1[good, 0])
    return out


def motion(pair, R):
    g0, _ = img2ground(pair[0], R); g1, _ = img2ground(pair[1], R)
    M, inl = cv2.estimateAffinePartial2D(g0, g1, method=cv2.RANSAC, ransacReprojThreshold=0.15, maxIters=3000)
    if M is None or inl.sum() < 6: return None
    th = math.atan2(M[1, 0], M[0, 0])
    c, s = math.cos(th), math.sin(th)
    Rm = np.array([[c, -s], [s, c]])
    gi0, gi1 = g0[inl[:, 0] == 1], g1[inl[:, 0] == 1]
    t = (gi1 - gi0 @ Rm.T).mean(0)  # rigid refit, scale forced to 1
    return th, t, int(inl.sum())


idx_all = list(range(0, len(frames) - a.step, a.step))
flows = raw_flows(idx_all)
print('flow pairs', len(flows), flush=True)

# --- auto yaw calibration: car moves along its own axis (no sideslip) ---
if a.vx is None:
    sample = [i for i in flows if i % (3 * a.step) == 0]
    best = None
    for vx in np.arange(60, 661, 10):
        R = make_R(vx, a.vy); lat = []
        for i in sample:
            m = motion(flows[i], R)
            if m and abs(m[1][1]) > 0.1:  # moving
                lat.append(m[1][0] / -m[1][1])
        if len(lat) < 10: continue
        sc = abs(np.median(lat))
        if best is None or sc < best[0]: best = (sc, vx, len(lat))
    a.vx = best[1]
    print(f'auto vx={a.vx} (median sideslip ratio {best[0]:.3f}, n={best[2]})', flush=True)
R = make_R(a.vx, a.vy)

# --- ego poses: world frame, x right, y forward ; pose = (x, y, heading rad, ccw) ---
poses = {0: (0.0, 0.0, 0.0)}
x = y = hd = 0.0
speeds = []
last = 0
for i in idx_all:
    m = motion(flows[i], R) if i in flows else None
    if m is None:
        dth, dX, dZ = 0.0, 0.0, (speeds[-1] if speeds else 0) / FPS * a.step  # coast
    else:
        th, t, n = m
        # ground point motion in car frame: g1 = Rot(th) g0 + t  => car moved by inverse
        dth = -th
        c, s = math.cos(-th), math.sin(-th)
        inv_t = -np.array([[c, -s], [s, c]]) @ t
        dX, dZ = inv_t
    # Kalman-ish sanity clamp
    sp = dZ * FPS / a.step
    if speeds and abs(sp - speeds[-1]) > 4.0:  # >4 m/s jump per step is implausible
        dZ = speeds[-1] / FPS * a.step; dX = 0; sp = speeds[-1]
    speeds.append(sp)
    # integrate (car frame X right, Z fwd ; world heading ccw from +y)
    hd += dth
    x += dX * math.cos(hd) - dZ * math.sin(hd)
    y += dX * math.sin(hd) + dZ * math.cos(hd)
    poses[i + a.step] = (x, y, hd)
sp = np.array(speeds) * 3.6
print(f'speed km/h: median {np.median(sp):.1f}, p90 {np.percentile(sp, 90):.1f}, max {sp.max():.1f}; '
      f'path {sum(np.hypot(np.diff([p[0] for p in poses.values()]), np.diff([p[1] for p in poses.values()]))):.0f} m, '
      f'heading change {math.degrees(hd):.0f} deg')

# --- BEV patch params (car frame) ---
PPM = 20  # px per meter
XS = np.arange(-9, 9, 1 / PPM)
ZS = np.arange(5, 22, 1 / PPM)
mapu, mapv = ground2img_maps(R, XS, ZS)
valid = (mapu >= 0).astype(np.uint8) * 255
near_z = ZS.min()
print('nearest visible ground ~', float(ZS[np.argmax((mapu >= 0).any(1))]), 'm ahead of camera', flush=True)

# world canvas
allp = np.array(list(poses.values()))
pad = 30
minx, maxx = allp[:, 0].min() - pad, allp[:, 0].max() + pad
miny, maxy = allp[:, 1].min() - pad, allp[:, 1].max() + pad
CW, CH = int((maxx - minx) * PPM), int((maxy - miny) * PPM)
print('canvas', CW, CH, flush=True)
canvas = np.zeros((CH, CW, 3), np.uint8)
filled = np.zeros((CH, CW), np.uint8)


def car2canvas(pose):
    """affine mapping BEV patch pixel (col,row) -> canvas pixel"""
    px, py, h = pose
    # patch pixel (c, r) -> car (X=XS[0]+c/PPM, Z=ZS[0]+r/PPM)
    c, s = math.cos(h), math.sin(h)
    # world = (px + X c - Z s, py + X s + Z c) ; canvas col=(wx-minx)*PPM, row=(maxy-wy)*PPM
    A = np.array([[c, -s], [-s, -c]])  # (X,Z)->(col,row) direction (row flips y)
    off = np.array([(px - minx) * PPM, (maxy - py) * PPM]) + A @ np.array([XS[0], ZS[0]]) * PPM
    return np.c_[A, off].astype(np.float32)


# ego view
VW, VH = 360, 640  # px ; 18m x 32m at 20ppm
CAR_L_FRONT, CAR_L_REAR, CAR_W = 1.9, 2.9, 1.85  # camera ~ behind windshield


def ego_view(pose, live):
    px, py, h = pose
    c, s = math.cos(h), math.sin(h)
    # view pixel (u,v) -> car X=(u-VW/2)/PPM, Z=(VH*0.6 - v)/PPM -> canvas
    A = np.array([[c / PPM, s / PPM], [-s / PPM, c / PPM]])  # placeholder to build full affine below
    # car->canvas: col = (px + X c - Z s - minx)*PPM ; row = (maxy - (py + X s + Z c))*PPM
    # X = (u - VW/2)/PPM ; Z = (vz - v)/PPM
    vz = VH * 0.62
    M = np.array([
        [c, s, (px - minx) * PPM - c * VW / 2 - s * vz],
        [-s, c, (maxy - py) * PPM + s * VW / 2 - c * vz],
    ], np.float32)
    v = cv2.warpAffine(canvas, M, (VW, VH), flags=cv2.WARP_INVERSE_MAP | cv2.INTER_LINEAR)
    fm = cv2.warpAffine(filled, M, (VW, VH), flags=cv2.WARP_INVERSE_MAP | cv2.INTER_NEAREST)
    v[fm == 0] = (40, 40, 40)
    # live region tint border
    # car icon
    x0, x1 = int(VW / 2 - CAR_W / 2 * PPM), int(VW / 2 + CAR_W / 2 * PPM)
    y0, y1 = int(vz - CAR_L_FRONT * PPM), int(vz + CAR_L_REAR * PPM)
    ov = v.copy(); cv2.rectangle(ov, (x0, y0), (x1, y1), (230, 230, 230), -1)
    v = cv2.addWeighted(ov, 0.55, v, 0.45, 0)
    cv2.rectangle(v, (x0, y0), (x1, y1), (0, 200, 255), 2)
    cv2.line(v, (x0 + 4, y0 + 10), (x1 - 4, y0 + 10), (0, 200, 255), 2)
    # live FOV boundary
    zl = int(vz - ZS[np.argmax((mapu >= 0).any(1))] * PPM)
    cv2.line(v, (0, zl), (VW, zl), (0, 255, 0), 1)
    cv2.putText(v, 'LIVE', (6, zl - 6), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 255, 0), 1)
    cv2.putText(v, 'MEMORY', (6, zl + 16), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 200, 255), 1)
    return v


fourcc = cv2.VideoWriter_fourcc(*'mp4v')
OW = 405 + VW
vw = cv2.VideoWriter(f'{a.out}_raw.mp4', fourcc, FPS / a.step, (OW, 720))
for i in sorted(poses):
    if i >= len(frames): break
    fr = frames[i]
    patch = cv2.remap(fr, mapu, mapv, cv2.INTER_LINEAR, borderValue=0)
    M = car2canvas(poses[i])
    hh, ww = patch.shape[:2]
    cor = np.array([[0, 0, 1], [ww, 0, 1], [0, hh, 1], [ww, hh, 1]], np.float32) @ M.T
    c0, r0 = np.floor(cor.min(0)).astype(int) - 2
    c1, r1 = np.ceil(cor.max(0)).astype(int) + 2
    c0, r0 = max(c0, 0), max(r0, 0); c1, r1 = min(c1, CW), min(r1, CH)
    Ml = M.copy(); Ml[0, 2] -= c0; Ml[1, 2] -= r0
    w = cv2.warpAffine(patch, Ml, (c1 - c0, r1 - r0), flags=cv2.INTER_LINEAR)
    wm = cv2.warpAffine(valid, Ml, (c1 - c0, r1 - r0), flags=cv2.INTER_NEAREST)
    wm = cv2.erode(wm, np.ones((3, 3), np.uint8))
    sub = canvas[r0:r1, c0:c1]; sub[wm > 0] = w[wm > 0]
    filled[r0:r1, c0:c1] |= wm
    ev = ego_view(poses[i], patch)
    left = cv2.resize(fr, (405, 720))
    cv2.rectangle(left, (0, int(Y0 * 720 / H_IMG)), (404, int(Y1 * 720 / H_IMG)), (0, 255, 0), 1)
    right = cv2.copyMakeBorder(ev, 40, 40, 0, 0, cv2.BORDER_CONSTANT, value=(0, 0, 0))
    k = idx_all.index(i - a.step) if (i - a.step) in idx_all else 0
    cv2.putText(right, f'{speeds[k]*3.6 if speeds else 0:4.0f} km/h', (8, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 2)
    vw.write(np.hstack([left, right]))
vw.release()

# full mosaic with path
mos = canvas.copy(); mos[filled == 0] = (40, 40, 40)
pts = np.array([[(p[0] - minx) * PPM, (maxy - p[1]) * PPM] for p in poses.values()], np.int32)
cv2.polylines(mos, [pts], False, (0, 0, 255), 6)
sc = min(1.0, 4000 / max(mos.shape[:2])); mos = cv2.resize(mos, None, fx=sc, fy=sc, interpolation=cv2.INTER_AREA)
cv2.imwrite(f'{a.out}_mosaic.jpg', mos, [cv2.IMWRITE_JPEG_QUALITY, 88])
json.dump({'vx': float(a.vx), 'vy': a.vy, 'f': f_px, 'h': a.h,
           'poses': {int(k): [float(t) for t in v] for k, v in poses.items()}}, open(f'{a.out}_poses.json', 'w'))
print('done', flush=True)
