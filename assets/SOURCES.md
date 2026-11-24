# 내려받은 자료 출처

앱에 들어가는 3D 모델과 노면 표시 그림의 원본입니다. 원본은 `assets/source/`, 앱용 가공본은
`tools/build_assets.py` 가 `ios/AroundView/Assets3D/`, `ios/AroundView/RoadMarks/` 에 만듭니다.

## 3D 모델

| 앱 이름 | 원본 | 만든 곳 | 라이선스 |
|---|---|---|---|
| `ego` (자차) | Car Pack · SimpleCarShort | [Quaternius · OpenGameArt](https://opengameart.org/content/lowpoly-cars) | CC0 |
| `car` (승용차) | Car Pack · BasicCar | [Quaternius · OpenGameArt](https://opengameart.org/content/lowpoly-cars) | CC0 |
| `bus` (버스) | Public Transport · Bus | [Quaternius · OpenGameArt](https://opengameart.org/content/lowpoly-public-transport) | CC0 |
| `bicycle` (자전거) | Public Transport · SquareFrameBicycle | [Quaternius · OpenGameArt](https://opengameart.org/content/lowpoly-public-transport) | CC0 |
| `truck` (트럭) | Car Kit · delivery | [Kenney](https://kenney.nl/assets/car-kit) | CC0 |
| `motorbike` (오토바이) | Cozy Vehicles Kit · motorcycle | [Grab3D](https://grab3d.com/models/vehicles/motorcycle/) | CC0 |
| `person` (사람) | Ultimate Modular Men · Suit (걷기 동작 한 장면으로 고정, 권총 제외) | [Quaternius · Cinevva](https://app.cinevva.com/game-assets/free-3d-character-models) | CC0 |

가공: 한 덩어리로 합침 → 위 +Y, 앞 −Z, 바닥 가운데 원점 → 색을 차체(`body`) / 유리·타이어(`trim`) 두 재질로 나눔
(테슬라 화면처럼 단색으로 그리기 위해). 오토바이는 삼각형 25,644 → 약 5,000 개로 줄임.

## 노면 표시 그림

위키미디어 공용의 「Korea Traffic Safety Sign - Road Mark」 SVG (도로교통법 시행규칙 별표 6 노면표시, 퍼블릭 도메인).
파일별 주소·라이선스는 `assets/source/kr-road-marks/sources.json`.

| 앱 이름 | SVG | 실제 크기 가정 |
|---|---|---|
| `straight` `left` `right` | 537 진행방향 | 길이 5 m |
| `straight_left` `straight_right` | 538 진행방향 2 | 길이 5 m |
| `uturn` | 539 진행방향 3 | 길이 5 m |
| `crosswalk_ahead` | 529 횡단보도 예고 (마름모) | 길이 3 m |
| `stop_line` | 530 정지선 | 폭 3.2 m |
| `crosswalk` | 533 횡단보도 (줄 3개) | 길이 4 m |
| `bicycle` | 535 자전거 전용 | 길이 1.8 m |
| `yield` | 522 양보 | 길이 5 m |

그림 속 연결된 흰색(또는 노란색) 영역만 잘라 흰색 + 투명 PNG 로 만들고 실제 크기를 `marks.json` 에 적습니다.
같은 그림이 인식 템플릿(5 px/m, ±6° 회전)과 화면 그리기에 함께 쓰입니다.
