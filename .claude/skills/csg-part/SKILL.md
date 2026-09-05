---
name: csg-part
description: Add a new analytic primitive (part) to the Metal CSG ray tracer — sphere/box/torus-style shapes that the shader intersects mathematically. Use when the task is "새 도형 추가", "add a shape/primitive/part", "이런 모양 만들어줘" for a shape that is not expressible by combining existing parts, or when editing the CSG_PART_* enum, cand* intersection functions, or partIntervals dispatch.
---

# 새 부품(analytic primitive) 추가하기

부품 하나는 **로컬 좌표계에서 단위 크기**로 한 번만 정의하고, 배치·크기는 전부 변환 행렬로 처리한다.
구를 비균등 스케일하면 타원체가 되는 식이라, 새 부품은 "스케일로 못 만드는 형상"일 때만 추가한다.

## 먼저 판단: 정말 새 부품이 필요한가

| 원하는 형상 | 방법 |
|---|---|
| 타원체, 납작한 원기둥 | 기존 부품 + `.scale(x,y,z)` |
| 임의의 볼록 다각형 기둥 | `CSG.polygon(points)` / `CSG.ngonPrism(n)` — 코드 수정 불필요 |
| 임의 반지름 원뿔대 | `CSG.frustum(bottom:top:)` — 코드 수정 불필요 |
| 회전체 | `CSG.lathe(profile)` — 원뿔대 조각 합집합 |
| 볼록 다면체 (평면 n개로 표현 가능) | `candPlanes` 에 상수 평면 테이블만 추가 — 아래 A 경로 |
| 곡면 (새 대수방정식이 필요) | 새 `cand*` 함수 — 아래 B 경로 |
| 모서리가 둥근 덩어리 | `CSG.roundBox(half:radius:)` — 진짜 둥근 상자, 부품 1개 |
| 여러 부품의 조합 | `CSG.swift` 의 복합 부품(예: `roundedBox`, `bolt`, `tube`) 처럼 CSG 식으로 |
| **유기적 형상** (인체·동물, 이음매가 있으면 안 되는 것) | `CSG.blob` — smooth-min SDF 를 구 추적하는 부품. 불리언이 아니라 **거리장**이다. `smooth-surfaces` 스킬 참고 |

**매끄러운 곡면**(라운드·필렛·법선 연속성)을 다룰 때는 `smooth-surfaces` 스킬을 먼저 본다 —
법선을 케이스별로 나누면 경계에서 어긋나고, 그게 "부자연스럽다" 의 대부분이다.

## 건드려야 하는 4곳 (순서대로)

### 1. `RayTracer/ShaderTypes.h` — enum + 주석

```c
CSG_PART_MYSHAPE = 18,   // 다음 번호. 불리언 연산은 100 이상이므로 그 아래로만
```
파일 상단 주석 표에 **로컬 좌표계 기준 크기**를 한 줄 적는다. 이게 유일한 사양 문서다.

### 2. `RayTracer/CSG.swift` — `PartKind` + 생성 함수

```swift
case myShape = 18            // 반드시 ShaderTypes.h 와 같은 숫자
```
`extent` 가 `[1,1,1]` 이 아니면 (토러스처럼 로컬 반폭이 1을 넘거나 작으면) `PartKind.extent` 에 케이스를 추가한다.
**여기를 빼먹으면 AABB 가 형상보다 작아져서 가장자리가 잘려 나간다** — 증상이 미묘하니 주의.

```swift
static func myShape(_ t: float4x4 = .identity, material: Int) -> CSG {
    .part(.myShape, t, material: material, data: [])
}
```
런타임 파라미터가 필요하면 `data:` 에 `SIMD4<Float>` 배열을 실어 보낸다
(`polygon` 의 평면 배열, `frustum(bottom:top:)` 의 `(a, b)` 가 예시). 셰이더에서는
`partData[node.reserved0 ..< +node.reserved1]` 로 읽는다.

### 3. `RayTracer/Shaders.metal` — `cand*` 함수

레이 ↔ 형상의 **모든 경계 교차점**을 `addCand(c, t, n)` 로 넣는다. `n` 은 로컬 공간 법선(정규화 전이어도 됨).
`o`, `d` 는 이미 부품 로컬 공간으로 변환된 상태이고 `d` 는 정규화돼 있지 않다.

**A. 볼록 다면체** — 평면 테이블만 추가:
```metal
constant float3 kMyN[5] = { ... };   // 바깥 방향 법선
constant float  kMyH[5] = { ... };   // 평면: dot(n, p) = h
static void candMyShape(float3 o, float3 d, thread Cands& c) { candPlanes(o, d, kMyN, kMyH, 5, c); }
```

**B. 곡면** — 직접 방정식을 푼다. `candSphere`(2차), `candTorus`(4차, `solveQuartic`),
`candConeGeneric`(측면 2차 + 캡 평면) 이 참고 템플릿이다.
캡이 있는 형상은 **측면 해 + 캡 평면 해를 모두** 넣되, 각각 반대쪽 조건으로 걸러야 한다
(`candCylinder` 가 정석: 측면 해는 `|y| ≤ 1` 일 때만, 캡 해는 `x²+z² ≤ 1` 일 때만).

후보는 최대 `MAX_CANDS`(6) 개다. 그보다 많이 나오는 형상이면 이 값을 올린다.

### 4. `RayTracer/Shaders.metal` — `partIntervals` 의 switch

```metal
case CSG_PART_MYSHAPE: candMyShape(lo, ld, c); break;
```

**비볼록이면 `convex = false` 를 반드시 같이 넣는다** (`CSG_PART_TORUS`, `CSG_PART_RING` 참고).
`convex = true` 는 정렬된 후보의 **첫 개와 마지막 개**만 써서 구간 1개를 만든다 —
가운데가 빈 형상(고리, 토러스)에 이걸 쓰면 구멍이 메워진 채로 보인다.
`convex = false` 는 정렬된 후보를 (진입, 탈출) 쌍으로 묶으므로 후보 개수가 **항상 짝수**여야 한다.
접선 케이스에서 홀수 개가 나오면 구간이 통째로 어긋나니, 판별식 경계에서 중복 해를 넣거나 빼는 처리를 확인할 것.

## 검증

```bash
make snapshot OUT=out/part.png
```
그리고 `out/frame.png` 를 Read 로 열어 확인한다. 새 부품을 씬에 넣기 전이라면
`RayTracer/Scene.swift` 에 임시 오브젝트 하나를 카메라 근처(`.translate(0, -1.5, 3)` 정도)에 배치해서 본다.

**CSG 로 검증하기**: 새 부품이 `-` (차집합) 의 오른쪽에 왔을 때 구멍이 제대로 뚫리는지가
구간이 옳은지 보는 가장 빠른 테스트다. 겉면만 맞고 내부 구간이 틀린 부품은 합집합에서는 멀쩡해 보인다.
