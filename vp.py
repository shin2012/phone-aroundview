import cv2, numpy as np
vys = []
for i in range(1, 9):
    g = cv2.imread(f'frames/f_0{i}.jpg', 0)[600:790]
    e = cv2.Canny(g, 60, 160)
    L = cv2.HoughLinesP(e, 1, np.pi/180, 40, minLineLength=40, maxLineGap=10)
    if L is None:
        continue
    segs = [s[0].astype(float) for s in L.reshape(-1,1,4) if 0.25 < abs((s[0][3]-s[0][1])/(s[0][2]-s[0][0]+1e-6)) < 3]
    pts = []
    for a in range(len(segs)):
        for b in range(a+1, len(segs)):
            x1, y1, x2, y2 = segs[a]; x3, y3, x4, y4 = segs[b]
            d = (x1-x2)*(y3-y4)-(y1-y2)*(x3-x4)
            if abs(d) < 1e-3: continue
            t = ((x1-x3)*(y3-y4)-(y1-y3)*(x3-x4))/d
            px, py = x1+t*(x2-x1), y1+t*(y2-y1)+600
            if 0 < px < 720 and 500 < py < 700: pts.append((px, py))
    if pts:
        p = np.median(pts, 0); print(i, len(segs), p.round()); vys.append(p)
print('median', np.median(vys, 0))
