# phone-aroundview

차량 거치 폰 전방 영상 → 가짜 어라운드 뷰(탑뷰) 프로토타입.
방금 앞에서 찍힌 노면이 곧 차 옆·뒤가 된다는 점을 이용해, 지나온 노면을 탑뷰 지도에 누적하고 차 아이콘 주변에 표시한다.

## 파이프라인 (aroundview.py)
1. 평면 노면 가정 IPM — 카메라 높이 `--h`(기본 1.2m), FOV `--hfov_long`(65°), 수평선 `--vy`
2. 노면 ROI(`--roi`, 본넷 위 띠)에서 LK 옵티컬플로우 → 지면 좌표로 투영 → RANSAC 강체변환 = 자차 이동량
3. 폰 yaw(틀어진 거치 각도) 자동 보정: 차는 옆으로 미끄러지지 않는다는 조건으로 소실점 x 탐색
4. 탑뷰 패치를 월드 모자이크에 누적 → 자차 중심 뷰 렌더 (LIVE 영역 / MEMORY 영역)

## 실행
```
python3 -m venv .venv && .venv/bin/pip install opencv-python-headless numpy
.venv/bin/python aroundview.py input.mov --out out
```
출력: `out_raw.mp4`(원본|어라운드뷰 나란히), `out_mosaic.jpg`(전체 주행 탑뷰+경로), `out_poses.json`

## 알려진 한계
- 움직이는 물체(옆 버스·차)는 늘어나서 번짐 — 과거 영상이라 실시간 장애물 표시 불가
- 회전 추정 누적오차로 장거리 경로는 휘어짐(국소 뷰는 정상)
- 높이 있는 물체는 평면 가정으로 왜곡
