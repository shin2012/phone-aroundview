#!/usr/bin/env python3
"""내려받은 원본(assets/source) → 앱에 넣을 가공본(ios/AroundView/Assets3D, RoadMarks).

3D 모델: 한 덩어리로 합치고, 위 = +Y, 앞 = -Z(SceneKit 기준), 바닥 가운데 = 원점, 단위 m 로 맞춘다.
면 색을 밝기로 나눠 'body'(차체) / 'trim'(유리·타이어) 두 재질만 남긴다 (테슬라식 단색 표현).
노면 표시: SVG 에서 필요한 기호만 잘라 흰색 + 투명 PNG 로 만들고, 실제 크기(m)를 marks.json 에 적는다.

실행: .venv/bin/python tools/build_assets.py [--preview out.jpg]
필요: trimesh pygltflib fast-simplification cairosvg scipy pillow numpy
"""
import io, json, math, sys, pathlib
import numpy as np
import trimesh

ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = ROOT / "assets/source"
OUT3D = ROOT / "ios/AroundView/Assets3D"
OUTMK = ROOT / "ios/AroundView/RoadMarks"


# ---------------------------------------------------------------- 3D
def rot(axis, deg):
    return trimesh.transformations.rotation_matrix(math.radians(deg), axis)


def face_colors(m, tex=None):
    """면마다 대표 색: 텍스처가 있으면 면 중심 UV 에서 뽑고, 없으면 재질 기본색."""
    v = m.visual
    img = tex if tex is not None else getattr(getattr(v, "material", None), "image", None)
    uv = getattr(v, "uv", None)
    if img is not None and uv is not None and len(uv) == len(m.vertices):
        arr = np.asarray(img.convert("RGB"), dtype=float) / 255
        h, w = arr.shape[:2]
        fuv = uv[m.faces].mean(1) % 1.0
        px = np.clip((fuv[:, 0] * (w - 1)).astype(int), 0, w - 1)
        py = np.clip(((1 - fuv[:, 1]) * (h - 1)).astype(int), 0, h - 1)
        return arr[py, px]
    mat = getattr(v, "material", None)
    if any(k in (getattr(mat, "name", "") or "").lower() for k in ("window", "glass", "bottom", "tire", "wheel")):
        return np.zeros((len(m.faces), 3))
    for attr in ("diffuse", "main_color", "baseColorFactor"):
        col = getattr(mat, attr, None)
        if col is not None:
            col = np.asarray(col, dtype=float)[:3]
            if col.max() > 1: col = col / 255
            return np.tile(col, (len(m.faces), 1))
    return np.ones((len(m.faces), 3))


def load_obj(path, tex=None):
    from PIL import Image
    img = Image.open(SRC / tex) if tex else None
    sc = trimesh.load(path, force="scene", process=False)
    vs, fs, cs, off = [], [], [], 0
    for g in sc.dump():
        vs.append(g.vertices); fs.append(g.faces + off); cs.append(face_colors(g, img)); off += len(g.vertices)
    return np.vstack(vs), np.vstack(fs), np.vstack(cs)


def load_glb_posed(path, anim="Idle", t=0.0):
    """스키닝된 캐릭터를 애니메이션 한 장면 자세로 굳혀서 반환 (T 자세 대신)."""
    import pygltflib
    g = pygltflib.GLTF2().load(str(path))
    blob = g.binary_blob()

    def acc(i):
        a = g.accessors[i]; bv = g.bufferViews[a.bufferView]
        n = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}[a.type]
        dt = np.dtype({5126: np.float32, 5123: np.uint16, 5121: np.uint8, 5125: np.uint32}[a.componentType])
        start = (bv.byteOffset or 0) + (a.byteOffset or 0)
        stride = bv.byteStride or n * dt.itemsize
        rows = [np.frombuffer(blob, dt, count=n, offset=start + k * stride) for k in range(a.count)] \
            if stride != n * dt.itemsize else [np.frombuffer(blob, dt, count=n * a.count, offset=start)]
        out = (np.vstack(rows) if len(rows) > 1 else rows[0]).reshape(a.count, n)
        out = out.astype(np.float64) if dt == np.float32 else out.astype(np.int64)
        if a.normalized and dt == np.uint8: out = out / 255
        if a.normalized and dt == np.uint16: out = out / 65535
        return out

    def quat_mat(q):
        x, y, z, w = q
        return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                         [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                         [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])

    trs = {}
    for i, n in enumerate(g.nodes):
        if n.matrix:
            trs[i] = ("M", np.array(n.matrix).reshape(4, 4).T)
        else:
            trs[i] = ["TRS", np.array(n.translation or [0, 0, 0], float), np.array(n.rotation or [0, 0, 0, 1], float),
                      np.array(n.scale or [1, 1, 1], float)]
    an = next(a for a in g.animations if a.name == anim)
    for ch in an.channels:
        s = an.samplers[ch.sampler]
        times = acc(s.input)[:, 0]; vals = acc(s.output)
        k = int(np.searchsorted(times, t, side="right") - 1); k = max(0, min(k, len(times) - 1))
        v = vals[k]
        node = ch.target.node; path = ch.target.path
        if trs[node][0] != "TRS": continue
        if path == "translation": trs[node][1] = v
        elif path == "rotation": trs[node][2] = v / np.linalg.norm(v)
        elif path == "scale": trs[node][3] = v

    def local(i):
        e = trs[i]
        if e[0] == "M": return e[1]
        M = np.eye(4); M[:3, :3] = quat_mat(e[2]) * e[3]; M[:3, 3] = e[1]; return M

    parent = {}
    for i, n in enumerate(g.nodes):
        for c in n.children or []: parent[c] = i
    cache = {}

    def world(i):
        if i not in cache:
            cache[i] = (world(parent[i]) @ local(i)) if i in parent else local(i)
        return cache[i]

    vs, fs, cs, off = [], [], [], 0
    for ni, n in enumerate(g.nodes):
        if n.mesh is None: continue
        if any(g.nodes[k].name in ("Pistol", "Gun", "Sword") for k in (parent.get(ni),) if k is not None):
            continue  # 손에 든 소품 제외
        for p in g.meshes[n.mesh].primitives:
            pos = acc(p.attributes.POSITION)
            idx = acc(p.indices)[:, 0].reshape(-1, 3)
            col = np.array((g.materials[p.material].pbrMetallicRoughness.baseColorFactor or [1, 1, 1, 1])[:3]) \
                if p.material is not None else np.ones(3)
            if n.skin is not None and p.attributes.JOINTS_0 is not None:
                sk = g.skins[n.skin]
                ibm = acc(sk.inverseBindMatrices).reshape(-1, 4, 4).transpose(0, 2, 1)
                jm = np.array([world(j) @ ibm[k] for k, j in enumerate(sk.joints)])
                J = acc(p.attributes.JOINTS_0).astype(int); W = acc(p.attributes.WEIGHTS_0)
                W = W / np.maximum(W.sum(1, keepdims=True), 1e-9)
                ph = np.c_[pos, np.ones(len(pos))]
                out = np.zeros((len(pos), 4))
                for c in range(4):
                    out += W[:, c:c + 1] * np.einsum("nij,nj->ni", jm[J[:, c]], ph)
                pos = out[:, :3]
            else:
                pos = (np.c_[pos, np.ones(len(pos))] @ world(ni).T)[:, :3]
            vs.append(pos); fs.append(idx + off); cs.append(np.tile(col, (len(idx), 1))); off += len(pos)
    return np.vstack(vs), np.vstack(fs), np.vstack(cs)


# 이름: (원본, 텍스처(OBJ 에 연결 안 된 경우), 밝기 기준(이하 = trim), 목표 삼각형 수)
QCAR_TRIM = [(0.459, 0.439, 0.561), (0.353, 0.922, 0.922)]  # 회보라(타이어·하부), 하늘색(유리)
MODELS = {
    "ego":        ("quaternius-cars/SimpleCarShort.obj", "quaternius-cars/CarTexture.png", QCAR_TRIM, None),
    "car":        ("quaternius-cars/BasicCar.obj", "quaternius-cars/CarTexture.png", QCAR_TRIM, None),
    "truck":      ("kenney-car-kit/delivery.obj", None, 0.30, None),
    "bus":        ("quaternius-public-transport/Bus.obj", None, 0.30, None),
    "motorbike":  ("grab3d-motorcycle/motorcycle.obj", "grab3d-motorcycle/motorcycle_body_basecolor.jpg", 0.22, 5000),
    "bicycle":    ("quaternius-public-transport/SquareFrameBicycle.obj", None, 0.0, None),
    "person":     ("quaternius-characters/Suit_Male.glb", None, 0.0, None),
}
ORIENT = json.loads((ROOT / "tools/orient.json").read_text()) if (ROOT / "tools/orient.json").exists() else {}


def build_model(name):
    src, tex, trim_luma, target = MODELS[name]
    p = SRC / src
    if p.suffix == ".glb":
        v, f, c = load_glb_posed(p, anim="Walk", t=0.25)
    else:
        v, f, c = load_obj(p, tex)
    m = trimesh.Trimesh(v, f, process=False)
    m.merge_vertices()
    for axis, deg in ORIENT.get(name, []):
        m.apply_transform(rot({"x": [1, 0, 0], "y": [0, 1, 0], "z": [0, 0, 1]}[axis], deg))
    if isinstance(trim_luma, (list, tuple)):  # 팔레트 색 지정 (유리·타이어 색)
        trim = np.zeros(len(c), bool)
        for col in trim_luma:
            trim |= np.abs(c - np.array(col)).max(1) < 0.06
    else:
        trim = c @ np.array([0.299, 0.587, 0.114]) <= trim_luma
    if target and len(m.faces) > target:
        import fast_simplification
        parts = []
        for sel in (~trim, trim):
            sub = trimesh.Trimesh(m.vertices, m.faces[sel], process=True)
            if len(sub.faces) == 0: parts.append((sub, sel)); continue
            ratio = 1 - target / len(m.faces)
            vv, ff = fast_simplification.simplify(sub.vertices, sub.faces, target_reduction=ratio)
            parts.append((trimesh.Trimesh(vv, ff), sel))
        body, tr = parts[0][0], parts[1][0]
        m = trimesh.util.concatenate([body, tr]); trim = np.r_[np.zeros(len(body.faces), bool), np.ones(len(tr.faces), bool)]
    # 바닥 가운데 원점
    b = m.bounds
    m.apply_translation([-(b[0][0] + b[1][0]) / 2, -b[0][1], -(b[0][2] + b[1][2]) / 2])
    return m, trim


def write_obj(name, m, trim):
    OUT3D.mkdir(parents=True, exist_ok=True)
    m.fix_normals() if False else None
    vn = m.vertex_normals
    lines = [f"# {name} — tools/build_assets.py 로 만든 가공본 (원본·라이선스: assets/SOURCES.md)",
             f"mtllib av_{name}.mtl", f"o {name}"]
    lines += [f"v {x:.4f} {y:.4f} {z:.4f}" for x, y, z in m.vertices]
    lines += [f"vn {x:.3f} {y:.3f} {z:.3f}" for x, y, z in vn]
    for mat, sel in (("body", ~trim), ("trim", trim)):
        if not sel.any(): continue
        lines += [f"g {mat}", f"usemtl {mat}"]
        lines += [f"f {a+1}//{a+1} {b+1}//{b+1} {c+1}//{c+1}" for a, b, c in m.faces[sel]]
    (OUT3D / f"av_{name}.obj").write_text("\n".join(lines) + "\n")
    (OUT3D / f"av_{name}.mtl").write_text("newmtl body\nKd 0.85 0.86 0.88\n\nnewmtl trim\nKd 0.12 0.13 0.15\n")
    e = m.extents
    return {"w": round(float(e[0]), 3), "h": round(float(e[1]), 3), "l": round(float(e[2]), 3),
            "faces": int(len(m.faces)), "trimFaces": int(trim.sum())}


# ---------------------------------------------------------------- 노면 표시
# 이름: (SVG, 고를 구성요소 번호들(800px 렌더 기준 연결요소, 1부터), 실제 길이(진행방향, m), 진행방향이 그림 위쪽인지)
MARKS = {
    "straight":       ("537_Proceeding_Direction", [1], 5.0),
    "left":           ("537_Proceeding_Direction", [2], 5.0),
    "right":          ("537_Proceeding_Direction", [3], 5.0),
    "straight_left":  ("538_Proceeding_Direction_2", [1], 5.0),
    "straight_right": ("538_Proceeding_Direction_2", [2], 5.0),
    "uturn":          ("539_Proceeding_Direction_3", [2], 5.0),
    "crosswalk_ahead": ("529_Crosswalk_Ahead", [1], 3.0),
    "stop_line":      ("530_Stop_Line", [1], None),        # 가로 3.2m 고정
    "crosswalk":      ("533_Crosswalk_2", [5, 6, 7], 4.0),       # 줄 3개 (넓은 길은 여러 번 인식돼 이어짐)
    "bicycle":        ("535_Bicycle_Only", "all", 1.8),
    "yield":          ("522_Yield", "all", 5.0),
}


def build_marks():
    import cairosvg
    from PIL import Image
    from scipy import ndimage
    OUTMK.mkdir(parents=True, exist_ok=True)
    meta = {}
    for name, (svg, comps, length) in MARKS.items():
        png = cairosvg.svg2png(url=str(SRC / "kr-road-marks" / f"{svg}.svg"), output_width=800)
        a = np.array(Image.open(io.BytesIO(png)).convert("RGBA")).astype(int)
        r, g, b, al = a[..., 0], a[..., 1], a[..., 2], a[..., 3]
        paint = (al > 128) & (((r > 200) & (g > 200) & (b > 200)) | ((r > 200) & (g > 120) & (b < 100)))
        lab, n = ndimage.label(paint)
        if comps == "all":
            sel = paint
        else:
            sel = np.isin(lab, comps)
        ys, xs = np.nonzero(sel)
        y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
        crop = sel[y0:y1, x0:x1]
        hpx, wpx = crop.shape
        if length is None:  # 정지선: 가로 막대 → 폭 3.2m 기준
            width_m = 3.2; length_m = width_m * hpx / wpx
        else:
            length_m = length; width_m = length * wpx / hpx
        # 2px 여백 + 긴 변 512px 이하로 축소
        img = Image.fromarray((crop * 255).astype(np.uint8), "L")
        scale = min(1.0, 512 / max(img.size))
        img = img.resize((max(1, round(img.width * scale)), max(1, round(img.height * scale))), Image.LANCZOS)
        pad = Image.new("L", (img.width + 8, img.height + 8), 0); pad.paste(img, (4, 4))
        rgba = Image.merge("RGBA", (Image.new("L", pad.size, 255),) * 3 + (pad,))
        rgba.save(OUTMK / f"mark_{name}.png", optimize=True)
        k = pad.width / img.width
        meta[name] = {"w": round(width_m * k, 3), "l": round(length_m * pad.height / img.height, 3),
                      "src": svg}
    (OUTMK / "marks.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1))
    return meta


def preview(path):
    sys.path.insert(0, str(ROOT / "tools"))
    from PIL import Image, ImageDraw
    ims = []
    for name in MODELS:
        m, trim = build_model(name)
        for yaw, lab in ((0, "앞(-Z)이 화면쪽"), (90, "옆: 앞=오른쪽")):
            ims.append((name + " " + str(yaw), render(m, trim, yaw)))
    W = 4; sheet = Image.new("RGB", (300 * W, 300 * ((len(ims) + W - 1) // W)))
    for k, (lab, im) in enumerate(ims):
        ImageDraw.Draw(im).text((4, 4), lab, fill=(255, 255, 0)); sheet.paste(im, ((k % W) * 300, (k // W) * 300))
    sheet.save(path)


def render(m, trim, yaw, size=300):
    """간이 소프트웨어 렌더: yaw=0 → 정면(-Z 쪽에서 봄), yaw=90 → 오른쪽(+X)에서 봄."""
    from PIL import Image, ImageDraw
    v = m.vertices - m.bounds.mean(0); f = m.faces
    a = math.radians(yaw); pitch = math.radians(20)
    # 카메라가 -Z 쪽(앞)에 있도록: 먼저 Y 축 180° 돌려 앞이 +Z(화면쪽) 되게
    R0 = rot([0, 1, 0], 180)[:3, :3]
    Ry = rot([0, 1, 0], -yaw)[:3, :3]
    Rx = rot([1, 0, 0], math.degrees(pitch))[:3, :3]
    p = v @ R0.T @ Ry.T @ Rx.T
    s = size * 0.45 / np.abs(p[:, :2]).max()
    xy = np.c_[p[:, 0] * s + size / 2, -p[:, 1] * s + size / 2]
    n = np.cross(p[f[:, 1]] - p[f[:, 0]], p[f[:, 2]] - p[f[:, 0]]); n /= np.linalg.norm(n, axis=1, keepdims=True) + 1e-9
    L = np.array([0.4, 0.7, 0.6]); L /= np.linalg.norm(L)
    sh = np.clip(np.abs(n @ L), 0.15, 1)
    order = np.argsort(p[f].mean(1)[:, 2])
    im = Image.new("RGB", (size, size), (40, 44, 52)); d = ImageDraw.Draw(im)
    for i in order:
        base = 60 if trim[i] else 200
        c = int(base * (0.35 + 0.65 * sh[i])); d.polygon([tuple(xy[j]) for j in f[i]], fill=(c, c, c))
    return im


if __name__ == "__main__":
    if "--preview" in sys.argv:
        preview(sys.argv[sys.argv.index("--preview") + 1]); sys.exit()
    info = {}
    for name in MODELS:
        m, trim = build_model(name)
        info[name] = write_obj(name, m, trim)
        print(name, info[name])
    (OUT3D / "models.json").write_text(json.dumps(info, indent=1))
    print(json.dumps(build_marks(), ensure_ascii=False))
