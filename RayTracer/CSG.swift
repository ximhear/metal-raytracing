//
//  CSG.swift
//  부품 조립 DSL: 부품(구/박스/원기둥/원뿔) + 변환 + 불리언 연산자 (| & -)
//

import Foundation
import simd

enum PartKind: UInt32 {
    case sphere = 0, box = 1, cylinder = 2, cone = 3, torus = 4, capsule = 5, prism = 6
    case hexPrism = 7, octPrism = 8, wedge = 9, tetra = 10, octa = 11, pyramid = 12
    case frustum = 13, hemisphere = 14, ring = 15
    case poly = 16, frustumGeneric = 17, roundBox = 18
    /// 부드럽게 섞이는 타원체 덩어리 (메타볼). **rawValue 는 ShaderTypes.h 와 항상 같이 바꾼다.**
    case blob = 19

    /// 로컬 좌표계에서의 반폭 (AABB 계산용)
    var extent: SIMD3<Float> {
        switch self {
        case .torus:      return [1.35, 0.35, 1.35]
        case .capsule:    return [1, 2, 1]
        case .hemisphere: return [1, 1, 1]      // y ∈ [0,1] 이지만 대칭 박스로 충분
        default:          return [1, 1, 1]
        }
    }
}

indirect enum CSG {
    /// 단위 부품을 localToWorld(오브젝트 공간 기준)로 배치. data 는 POLY/FRUSTUM_GENERIC 용 추가 파라미터
    case part(PartKind, float4x4, material: Int, data: [SIMD4<Float>])
    case union(CSG, CSG)
    case intersect(CSG, CSG)
    case subtract(CSG, CSG)

    // MARK: 부품 생성 편의 함수

    static func sphere(_ t: float4x4 = .identity, material: Int) -> CSG   { .part(.sphere,   t, material: material, data: []) }
    static func box(_ t: float4x4 = .identity, material: Int) -> CSG      { .part(.box,      t, material: material, data: []) }
    static func cylinder(_ t: float4x4 = .identity, material: Int) -> CSG { .part(.cylinder, t, material: material, data: []) }
    static func cone(_ t: float4x4 = .identity, material: Int) -> CSG     { .part(.cone,     t, material: material, data: []) }
    /// 대반지름 1, 소반지름 0.35, y축 중심
    static func torus(_ t: float4x4 = .identity, material: Int) -> CSG    { .part(.torus,    t, material: material, data: []) }
    /// 반지름 1, 직선부 y ∈ [-1,1] (전체 높이 4)
    static func capsule(_ t: float4x4 = .identity, material: Int) -> CSG  { .part(.capsule,  t, material: material, data: []) }
    /// 단위원 내접 정삼각형(꼭짓점 +x 방향)을 y ∈ [-1,1] 로 압출
    static func prism(_ t: float4x4 = .identity, material: Int) -> CSG    { .part(.prism,    t, material: material, data: []) }
    /// 단위원 내접 정육각형 압출, y ∈ [-1,1]
    static func hexPrism(_ t: float4x4 = .identity, material: Int) -> CSG { .part(.hexPrism, t, material: material, data: []) }
    /// 단위원 내접 정팔각형 압출, y ∈ [-1,1]
    static func octPrism(_ t: float4x4 = .identity, material: Int) -> CSG { .part(.octPrism, t, material: material, data: []) }
    /// 직각삼각형 (-1,-1),(1,-1),(-1,1) in xy 를 z ∈ [-1,1] 로 압출 (경사면이 +x+y 방향)
    static func wedge(_ t: float4x4 = .identity, material: Int) -> CSG    { .part(.wedge,    t, material: material, data: []) }
    /// 정사면체 (꼭짓점 (1,1,1),(1,-1,-1),(-1,1,-1),(-1,-1,1))
    static func tetra(_ t: float4x4 = .identity, material: Int) -> CSG    { .part(.tetra,    t, material: material, data: []) }
    /// 정팔면체 |x|+|y|+|z| ≤ 1
    static func octa(_ t: float4x4 = .identity, material: Int) -> CSG     { .part(.octa,     t, material: material, data: []) }
    /// 사각뿔: 밑면 [-1,1]² (y=-1), 꼭짓점 (0,1,0)
    static func pyramid(_ t: float4x4 = .identity, material: Int) -> CSG  { .part(.pyramid,  t, material: material, data: []) }
    /// 잘린 원뿔: 밑면 y=-1 반지름 1, 윗면 y=1 반지름 0.5
    static func frustum(_ t: float4x4 = .identity, material: Int) -> CSG  { .part(.frustum,  t, material: material, data: []) }
    /// 반구: 반지름 1, y ≥ 0
    static func hemisphere(_ t: float4x4 = .identity, material: Int) -> CSG { .part(.hemisphere, t, material: material, data: []) }
    /// 고리: 바깥 1, 안쪽 0.6, y ∈ [-1,1]
    static func ring(_ t: float4x4 = .identity, material: Int) -> CSG     { .part(.ring,     t, material: material, data: []) }

    // MARK: 파라미터 부품

    /// 임의의 볼록 다각형(xz 평면, 점 순서 무관)을 y ∈ [-1,1] 로 압출
    static func polygon(_ points: [SIMD2<Float>], _ t: float4x4 = .identity, material: Int) -> CSG {
        precondition(points.count >= 3)
        let cx = points.map { $0.x }.reduce(0, +) / Float(points.count)
        let cz = points.map { $0.y }.reduce(0, +) / Float(points.count)
        var planes: [SIMD4<Float>] = []
        for i in 0..<points.count {
            let a = points[i], b = points[(i + 1) % points.count]
            let edge = b - a
            var n = simd_normalize(SIMD2<Float>(edge.y, -edge.x))     // 변에 수직
            if simd_dot(n, SIMD2<Float>(cx, cz) - a) > 0 { n = -n }  // 중심 반대쪽 = 바깥
            planes.append(SIMD4<Float>(n.x, 0, n.y, simd_dot(n, a)))
        }
        planes.append(SIMD4<Float>(0, 1, 0, 1))
        planes.append(SIMD4<Float>(0, -1, 0, 1))

        // data[0] 은 평면이 아니라 **국소 크기**다. 평면만 넘기면 AABB 를 [1,1,1] 로 가정할 수밖에 없어
        // 가늘고 긴 판이 정육면체만 한 상자를 갖게 된다 (성능 손해 + 검증 도구 오탐).
        // 셰이더는 `reserved0` 부터 `reserved1` 개를 읽으므로 flatten 이 오프셋을 +1 해 준다.
        let ex = points.map { abs($0.x) }.max() ?? 1
        let ez = points.map { abs($0.y) }.max() ?? 1
        return .part(.poly, t, material: material, data: [SIMD4<Float>(ex, 1, ez, 0)] + planes)
    }

    /// **진짜 둥근 상자** — 상자 ⊕ 반지름 r 구 (민코프스키 합).
    /// 면은 평평, 모서리는 원기둥, **꼭짓점은 구면**이라 법선이 어디서나 연속이다.
    ///
    /// 세 방향 윤곽(`roundedRectPrism` ∩ `roundedPanel` ∩ `roundedSection`)을 교차하는 방식과 달리
    /// 꼭짓점에 능선이 남지 않는다. 부품도 3개가 아니라 **1개**다.
    ///
    /// `half` 은 전체 반크기(라운드 포함), `radius` 는 모서리 반지름.
    /// 다른 부품과 달리 **크기를 변환이 아니라 인자로 받는다** — 비균등 스케일하면
    /// 꼭짓점이 타원체가 되어 매끈함이 깨지기 때문. `t` 는 배치(이동·회전)에만 쓴다.
    static func roundBox(half: SIMD3<Float>, radius: Float,
                         _ t: float4x4 = .identity, material: Int) -> CSG {
        let r = min(radius, min(half.x, min(half.y, half.z)) * 0.999)
        precondition(r > 0)
        let b = half - SIMD3<Float>(repeating: r)
        return .part(.roundBox, t, material: material, data: [SIMD4<Float>(b.x, b.y, b.z, r)])
    }

    /// 모서리(수직 변)를 둥글린 직사각 기둥. 볼록 다각형 압출이라 **부품 1개**다
    /// (`roundedBox` 는 27개). 버스·차체처럼 평면도가 둥근 사각형인 물체에 쓴다.
    ///
    /// 점은 `polygon` 의 AABB 가 단위 크기를 가정하므로 최대 반폭으로 나눠 넣고,
    /// 크기는 변환 행렬에서 **x·z 를 같은 배율로** 준다 — 그래야 모서리가 원형으로 남는다.
    static func roundedRectPrism(halfX: Float, halfZ: Float, corner r: Float,
                                 halfY: Float = 1, segments: Int = 4,
                                 _ t: float4x4 = .identity, material: Int) -> CSG {
        precondition(r > 0 && r < min(halfX, halfZ))
        let s = max(halfX, halfZ)
        let centers: [SIMD2<Float>] = [[ halfX - r,  halfZ - r], [-(halfX - r),  halfZ - r],
                                       [-(halfX - r), -(halfZ - r)], [ halfX - r, -(halfZ - r)]]
        var pts: [SIMD2<Float>] = []
        for (i, c) in centers.enumerated() {
            for k in 0...segments {
                let a = (Float(i) * 90 + Float(k) / Float(segments) * 90) * .pi / 180
                pts.append((c + SIMD2<Float>(cos(a), sin(a)) * r) / s)
            }
        }
        return polygon(pts, t * .scale(s, halfY, s), material: material)
    }

    /// xy 평면에서 모서리를 둥글린 판을 **z 방향으로** 압출. 창·문 구멍, 램프, 표지판처럼
    /// "정면에서 봤을 때 모서리가 둥근 사각형" 에 쓴다. `roundedRectPrism` 을 눕힌 것이라
    /// 마찬가지로 **부품 1개**다.
    ///
    /// 얇은 판(두께 halfZ 가 작아도)에 써도 된다 — 코너 반지름은 단면(halfX, halfY)만 제한한다.
    static func roundedPanel(halfX: Float, halfY: Float, halfZ: Float, corner: Float,
                             _ t: float4x4 = .identity, material: Int) -> CSG {
        roundedRectPrism(halfX: halfX, halfZ: halfY, corner: corner, halfY: halfZ,
                         t * .rotateX(90), material: material)
    }

    /// yz 평면에서 모서리를 둥글린 **단면**을 x 방향으로 압출.
    /// 차량 단면(지붕 어깨 · 바닥 가장자리)을 둥글리는 데 쓴다.
    ///
    /// 이 셋을 교차시키면 상자의 **모든 모서리**가 둥글어진다 — 부품 3개면 된다:
    /// `roundedRectPrism`(평면도 = 수직 모서리) ∩ `roundedPanel`(옆모습 = 앞뒤 위아래)
    /// ∩ `roundedSection`(단면 = 지붕 어깨 · 바닥)
    static func roundedSection(halfY: Float, halfZ: Float, halfX: Float, corner: Float,
                               _ t: float4x4 = .identity, material: Int) -> CSG {
        roundedRectPrism(halfX: halfY, halfZ: halfZ, corner: corner, halfY: halfX,
                         t * .rotateZ(90), material: material)
    }

    /// 정 n각 기둥 (단위원 내접)
    static func ngonPrism(_ n: Int, _ t: float4x4 = .identity, material: Int) -> CSG {
        let pts = (0..<n).map { i -> SIMD2<Float> in
            let a = 2 * Float.pi * Float(i) / Float(n)
            return SIMD2<Float>(cos(a), sin(a))
        }
        return polygon(pts, t, material: material)
    }

    /// 원뿔대: 밑면(y=-1) 반지름 r0, 윗면(y=1) 반지름 r1. r1 = 0 이면 원뿔, r0 = r1 이면 원기둥
    static func frustum(bottom r0: Float, top r1: Float, _ t: float4x4 = .identity, material: Int) -> CSG {
        let a = (r0 + r1) / 2, b = (r0 - r1) / 2
        return .part(.frustumGeneric, t, material: material, data: [SIMD4<Float>(a, b, 0, 0)])
    }

    // MARK: 부드럽게 섞이는 덩어리 (메타볼)

    /// BLOB 의 원소 하나. **타원체**(회전 가능) · **둥근 원뿔** · **베지에 튜브**.
    struct Blob {
        enum Kind: Float { case ellipsoid = 0, cone = 1, bezier = 2 }
        var p0: SIMD3<Float>
        var r0: SIMD3<Float>      // 타원체: 세 반지름 / 원뿔·베지에: (시작 반지름, -, -)
        var p1: SIMD3<Float> = .zero
        var r1: Float = 0
        var p2: SIMD3<Float> = .zero          // 베지에 제어점
        var rot = simd_quatf(angle: 0, axis: [0, 1, 0])   // 타원체 회전
        var kind: Kind = .ellipsoid
        /// 이웃과 섞이는 반경. **크면 뭉개지고 작으면 능선이 남는다.**
        /// 몸통처럼 큰 덩어리는 0.6~0.9, 콧날처럼 또렷해야 하는 것은 0.05~0.15.
        var blend: Float = 0.5
        /// 참이면 파낸다 (smooth-max). 눈두덩·배꼽·입선처럼 **음각**이 필요한 곳에.
        var negative = false

        /// 타원체. `tilt` 는 (축, 각도°) — 눈꼬리를 올리거나 광대를 비스듬히 놓을 때
        static func ell(_ c: SIMD3<Float>, _ r: SIMD3<Float>, blend: Float = 0.5,
                        negative: Bool = false,
                        tilt: (axis: SIMD3<Float>, degrees: Float)? = nil) -> Blob {
            var b = Blob(p0: c, r0: r, blend: blend, negative: negative)
            if let t = tilt {
                b.rot = simd_quatf(angle: t.degrees * .pi / 180, axis: simd_normalize(t.axis))
            }
            return b
        }
        /// 구
        static func ball(_ c: SIMD3<Float>, _ r: Float,
                         blend: Float = 0.5, negative: Bool = false) -> Blob {
            ell(c, SIMD3<Float>(repeating: r), blend: blend, negative: negative)
        }
        /// 둥근 원뿔 — **팔다리 마디는 반드시 이것.** 구를 줄줄이 꿰면
        /// 간격이 반지름의 1.5배만 넘어도 메타볼 사슬이 소시지처럼 울퉁불퉁해진다.
        static func cone(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ ra: Float, _ rb: Float,
                         blend: Float = 0.3, negative: Bool = false) -> Blob {
            Blob(p0: a, r0: [ra, ra, ra], p1: b, r1: rb, kind: .cone,
                 blend: blend, negative: negative)
        }
        /// 2차 베지에 튜브 — a 에서 출발해 제어점 c 쪽으로 휘어 b 에 닿는다. 반지름 ra→rb.
        /// **굽은 것은 전부 이것으로**: 눈썹, 입술 윤곽, 물결치는 머리 타래, 안경 다리.
        static func curve(_ a: SIMD3<Float>, via c: SIMD3<Float>, _ b: SIMD3<Float>,
                          _ ra: Float, _ rb: Float, blend: Float = 0.1,
                          negative: Bool = false) -> Blob {
            Blob(p0: a, r0: [ra, ra, ra], p1: b, r1: rb, p2: c, kind: .bezier,
                 blend: blend, negative: negative)
        }

        /// AABB 계산용 국소 범위 (회전 타원체는 최대 반지름의 구로 보수적으로)
        var lo: SIMD3<Float> {
            switch kind {
            case .ellipsoid:
                let m = SIMD3(repeating: r0.max())
                return p0 - m
            case .cone:
                return simd_min(p0 - SIMD3(repeating: r0.x), p1 - SIMD3(repeating: r1))
            case .bezier:
                let m = SIMD3(repeating: max(r0.x, r1))
                return simd_min(simd_min(p0, p1), p2) - m
            }
        }
        var hi: SIMD3<Float> {
            switch kind {
            case .ellipsoid:
                let m = SIMD3(repeating: r0.max())
                return p0 + m
            case .cone:
                return simd_max(p0 + SIMD3(repeating: r0.x), p1 + SIMD3(repeating: r1))
            case .bezier:
                let m = SIMD3(repeating: max(r0.x, r1))
                return simd_max(simd_max(p0, p1), p2) + m
            }
        }
    }

    /// **부드럽게 섞이는 덩어리.** 불리언 합집합과 달리 이어 붙는 자리에 능선이 남지 않아
    /// 인체·동물 같은 유기적 형상을 만들 수 있다. 원소 수만큼 SDF 를 평가하며 구 추적하므로
    /// 해석적 부품보다 비싸지만, 오브젝트 AABB 안에 들어온 레이만 돌기 때문에 감당된다.
    ///
    /// `inflate` 는 SDF 에서 그대로 빼는 값이라 **정확한 오프셋 표면**이 된다 —
    /// 같은 원소 목록에 `inflate` 만 줘서 몸에 딱 맞는 옷을 만드는 데 쓴다.
    ///
    /// 원소는 **로컬 원점 기준으로 다시 맞춰** 저장한다. AABB 가 원점 대칭을 가정하기 때문.
    /// `maxSteps` — 구 추적 스텝 상한 (셰이더 기본 160). 가는 튜브는 100 이면 충분하고,
    /// 무거운 씬에서 스레드가 너무 길어 GPU 가 스레드그룹을 죽일 때 가장 먼저 줄이는 값이다.
    static func blob(_ elements: [Blob], inflate: Float = 0, maxSteps: Int = 0,
                     _ t: float4x4 = .identity, material: Int) -> CSG {
        precondition(!elements.isEmpty && elements.count <= 48,
                     "BLOB 원소는 1~48개 (셰이더의 BLOB_MAX_ELEMS) — 지금 \(elements.count)개")
        // 양의 원소만 AABB 에 넣는다 — 음의 원소는 파내는 것이라 크기를 키우지 않는다
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for e in elements where !e.negative {
            let pad = SIMD3<Float>(repeating: e.blend + inflate)
            lo = simd_min(lo, e.lo - pad)
            hi = simd_max(hi, e.hi + pad)
        }
        let mid = (lo + hi) / 2
        let half = (hi - lo) / 2

        var data: [SIMD4<Float>] = [
            SIMD4<Float>(half.x, half.y, half.z, simd_length(half) + 0.01),
            SIMD4<Float>(Float(elements.count), inflate, Float(maxSteps), 0),
        ]
        for e in elements {
            let a = e.p0 - mid
            data.append(SIMD4<Float>(a.x, a.y, a.z, e.r0.x))
            switch e.kind {
            case .ellipsoid:
                data.append(SIMD4<Float>(e.r0.y, e.r0.z, 0, 0))
            case .cone, .bezier:
                let b = e.p1 - mid
                data.append(SIMD4<Float>(b.x, b.y, b.z, e.r1))
            }
            data.append(SIMD4<Float>(max(e.blend, 1e-4), e.negative ? -1 : 1,
                                     e.kind.rawValue, 0))
            switch e.kind {
            case .bezier:
                let c2 = e.p2 - mid
                data.append(SIMD4<Float>(c2.x, c2.y, c2.z, 0))
            default:
                let q = e.rot.vector      // (ix, iy, iz, r)
                data.append(SIMD4<Float>(q.x, q.y, q.z, q.w))
            }
        }
        return .part(.blob, t * .translate(mid.x, mid.y, mid.z), material: material, data: data)
    }

    /// 회전체(lathe): 프로파일 [(y, 반지름)] 을 y 순서로 주면 원뿔대 조각들의 합집합으로 만든다.
    ///
    /// **이웃한 조각은 반드시 겹쳐야 한다.** 조각의 끝 캡을 정확히 같은 평면에 두면
    /// 합집합이 부동소수점 오차만큼의 틈을 남기고, **축 방향 레이가 그 틈마다 구간을 하나씩**
    /// 만들어 `CSG_MAX_INTERVALS`(6)를 넘긴다 — 프로파일 점이 7개만 돼도 넘는다.
    /// 넘긴 구간은 조용히 버려져서 형상이 깨지는 게 아니라 **화면이 소금후추처럼 지글거린다**
    /// (터보팬 흡입구 안쪽이 통째로 그랬다. 픽셀마다 오차 방향이 달라 얼룩이 된다).
    ///
    /// 원뿔을 **제 기울기 그대로** 늘리므로 옆면은 이어진 채로 남고, 프로파일의 양 끝은
    /// 늘리지 않아 전체 크기도 그대로다.
    static func lathe(_ profile: [(y: Float, r: Float)], _ t: float4x4 = .identity, material: Int) -> CSG {
        precondition(profile.count >= 2)
        var parts: [CSG] = []
        for i in 0..<(profile.count - 1) {
            let (y0, r0) = profile[i], (y1, r1) = profile[i + 1]
            guard y1 > y0 else { continue }
            let slope = (r1 - r0) / (y1 - y0)
            let e = min((y1 - y0) * 0.25, 0.02)
            let a = (i == 0) ? y0 : y0 - e
            let b = (i == profile.count - 2) ? y1 : y1 + e
            let seg = frustum(bottom: r0 + slope * (a - y0), top: r0 + slope * (b - y0),
                              .translate(0, (a + b) / 2, 0) * .scale(1, (b - a) / 2, 1),
                              material: material)
            parts.append(seg)
        }
        return unionAll(parts).transformed(t)
    }

    // MARK: 복합 부품 (CSG 조합으로 만든 것)

    /// 둥근 모서리 박스. 반폭 1, 모서리 반지름 r (0 < r < 1). 부품 27개 합집합이라 무겁다.
    static func roundedBox(radius r: Float, material: Int) -> CSG {
        let i = 1 - r
        var parts: [CSG] = [
            .box(.scale(1, i, i), material: material),
            .box(.scale(i, 1, i), material: material),
            .box(.scale(i, i, 1), material: material),
        ]
        for sx in [-1, 1] as [Float] {
            for sy in [-1, 1] as [Float] {
                parts.append(.cylinder(.translate(sx * i, sy * i, 0) * .rotateX(90) * .scale(r, i, r), material: material))
                parts.append(.cylinder(.translate(sx * i, 0, sy * i) * .scale(r, i, r), material: material))
                parts.append(.cylinder(.translate(0, sx * i, sy * i) * .rotateZ(90) * .scale(r, i, r), material: material))
                for sz in [-1, 1] as [Float] {
                    parts.append(.sphere(.translate(sx * i, sy * i, sz * i) * .scale(r), material: material))
                }
            }
        }
        return unionAll(parts)
    }

    /// 볼트: 육각 머리(y ∈ [0, headH]) + 원통 축(y ∈ [-shaftL, 0]). 머리 반지름 1.
    static func bolt(headHeight: Float = 0.5, shaftLength: Float = 2.5, shaftRadius: Float = 0.45,
                     material: Int) -> CSG {
        let head  = CSG.hexPrism(.translate(0, headHeight / 2, 0) * .scale(1, headHeight / 2, 1), material: material)
        let shaft = CSG.cylinder(.translate(0, -shaftLength / 2, 0) * .scale(shaftRadius, shaftLength / 2, shaftRadius),
                                 material: material)
        return head | shaft
    }

    /// 둥근 모서리 링(튜브): 링 + 바깥/안쪽 가장자리 토러스
    static func tube(material: Int) -> CSG {
        let flat  = CSG.ring(.scale(1, 0.35, 1), material: material)
        let outer = CSG.torus(.scale(1.0), material: material)          // 대반지름 1, 소반지름 0.35
        let inner = CSG.torus(.scale(0.6, 1, 0.6), material: material)  // 안쪽은 스케일 다운
        return flat | outer | inner
    }

    // MARK: 연산자

    static func | (a: CSG, b: CSG) -> CSG { .union(a, b) }
    static func & (a: CSG, b: CSG) -> CSG { .intersect(a, b) }
    static func - (a: CSG, b: CSG) -> CSG { .subtract(a, b) }

    /// 조립체 전체를 변환 (모든 부품의 행렬에 앞에서 곱함)
    func transformed(_ t: float4x4) -> CSG {
        switch self {
        case .part(let k, let m, let mat, let d): return .part(k, t * m, material: mat, data: d)
        case .union(let a, let b):         return .union(a.transformed(t), b.transformed(t))
        case .intersect(let a, let b):     return .intersect(a.transformed(t), b.transformed(t))
        case .subtract(let a, let b):      return .subtract(a.transformed(t), b.transformed(t))
        }
    }

    /// 여러 조립체 합집합.
    ///
    /// **왼쪽으로 치우친 체인**으로 묶는다. 셰이더는 후위 표기를 스택 머신으로 평가하는데,
    /// `((a|b)|c)|d` 는 스택 깊이가 부품 수와 무관하게 항상 2인 반면
    /// 균형 트리는 log₂(n)+1 까지 커진다 (부품 27개짜리 `roundedBox` 가 6). 트리 모양만 다르고
    /// 노드 개수와 결과는 동일하다.
    static func unionAll(_ items: [CSG]) -> CSG {
        precondition(!items.isEmpty)
        return items.dropFirst().reduce(items[0]) { $0 | $1 }
    }

    // MARK: GPU 데이터로 변환

    /// 후위(postfix) 순서로 평탄화. 파라미터 부품의 추가 데이터는 partData 에 붙인다.
    func flatten(into nodes: inout [CSGNode], partData: inout [SIMD4<Float>]) {
        switch self {
        case .part(let k, let m, let mat, let d):
            let offset = UInt32(partData.count)
            partData.append(contentsOf: d)
            // POLY 는 data[0] 이 크기 정보라 평면은 그다음부터다
            let dataStart = (k == .poly) ? offset + 1 : offset
            let dataCount = (k == .poly) ? UInt32(d.count - 1) : UInt32(d.count)
            nodes.append(CSGNode(worldToLocal: m.inverse, type: k.rawValue,
                                 material: UInt32(mat), reserved0: dataStart, reserved1: dataCount))
        case .union(let a, let b):
            a.flatten(into: &nodes, partData: &partData); b.flatten(into: &nodes, partData: &partData)
            nodes.append(CSGNode(worldToLocal: .identity, type: CSG_OP_UNION.rawValue,
                                 material: 0, reserved0: 0, reserved1: 0))
        case .intersect(let a, let b):
            a.flatten(into: &nodes, partData: &partData); b.flatten(into: &nodes, partData: &partData)
            nodes.append(CSGNode(worldToLocal: .identity, type: CSG_OP_INTERSECT.rawValue,
                                 material: 0, reserved0: 0, reserved1: 0))
        case .subtract(let a, let b):
            a.flatten(into: &nodes, partData: &partData); b.flatten(into: &nodes, partData: &partData)
            nodes.append(CSGNode(worldToLocal: .identity, type: CSG_OP_SUBTRACT.rawValue,
                                 material: 0, reserved0: 0, reserved1: 0))
        }
    }

    /// 후위 표기로 평가할 때 필요한 최대 스택 깊이.
    /// 셰이더의 `CSG_MAX_STACK` 을 넘으면 부품이 조용히 사라지므로 `Renderer` 가 미리 검사한다.
    func stackDepth() -> Int {
        switch self {
        case .part: return 1
        case .union(let a, let b), .intersect(let a, let b), .subtract(let a, let b):
            return max(a.stackDepth(), 1 + b.stackDepth())
        }
    }

    /// 부품 하나의 AABB (오브젝트 공간)
    private static func partAABB(_ k: PartKind, _ m: float4x4,
                                 _ d: [SIMD4<Float>]) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var e = k.extent
        if k == .poly, let ex = d.first {
            e = [ex.x, ex.y, ex.z]                       // 실제 국소 크기 (data[0])
        }
        if k == .roundBox, let br = d.first {
            e = [br.x + br.w, br.y + br.w, br.z + br.w]   // 크기가 data 에 있다
        }
        if k == .blob, let ex = d.first {
            e = [ex.x, ex.y, ex.z]                       // data[0] 에 실제 반크기
        }
        if k == .frustumGeneric, let ab = d.first {
            let rmax = max(abs(ab.x - ab.y), abs(ab.x + ab.y))
            e = [rmax, 1, rmax]
        }
        for x in [-1, 1] as [Float] {
            for y in [-1, 1] as [Float] {
                for z in [-1, 1] as [Float] {
                    let p = (m * SIMD4<Float>(x * e.x, y * e.y, z * e.z, 1)).xyz
                    lo = simd_min(lo, p); hi = simd_max(hi, p)
                }
            }
        }
        return (lo, hi)
    }

    /// 트리 안의 **부품마다** AABB 를 하나씩 돌려준다 (검증·디버그용).
    /// 조립체 전체 AABB(`bounds()`)와 달리, 어느 부품이 껍데기를 뚫고 나가는지 짚어낼 수 있다.
    func partBounds() -> [(min: SIMD3<Float>, max: SIMD3<Float>)] {
        switch self {
        case .part(let k, let m, _, let d):
            return [CSG.partAABB(k, m, d)]
        case .union(let a, let b), .intersect(let a, let b), .subtract(let a, let b):
            return a.partBounds() + b.partBounds()
        }
    }

    /// 보수적인 AABB (오브젝트 공간). 모든 부품 바운드의 합집합.
    func bounds() -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        switch self {
        case .part(let k, let m, _, let d):
            return CSG.partAABB(k, m, d)
        case .union(let a, let b):
            let ba = a.bounds(), bb = b.bounds()
            return (simd_min(ba.min, bb.min), simd_max(ba.max, bb.max))

        case .intersect(let a, let b):
            // 교집합은 양쪽 안에 있으므로 AABB 도 교집합을 쓸 수 있다.
            // 합집합으로 잡으면 (예: 다각형 ∩ 상자) 실제보다 훨씬 큰 상자가 나와
            // 쓸데없는 레이가 전부 CSG 평가까지 들어온다.
            let ba = a.bounds(), bb = b.bounds()
            let lo = simd_max(ba.min, bb.min), hi = simd_min(ba.max, bb.max)
            return any(lo .> hi) ? (lo, lo) : (lo, hi)   // 비었으면 빈 상자

        case .subtract(let a, let b):
            _ = b                                        // A - B ⊆ A
            return a.bounds()
        }
    }
}

// MARK: - 변환 행렬 헬퍼

extension float4x4 {
    static var identity: float4x4 { matrix_identity_float4x4 }

    static func translate(_ x: Float, _ y: Float, _ z: Float) -> float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(x, y, z, 1)
        return m
    }

    static func scale(_ x: Float, _ y: Float, _ z: Float) -> float4x4 {
        float4x4(diagonal: SIMD4<Float>(x, y, z, 1))
    }

    static func scale(_ s: Float) -> float4x4 { scale(s, s, s) }

    static func rotate(axis: SIMD3<Float>, degrees: Float) -> float4x4 {
        let q = simd_quatf(angle: degrees * .pi / 180, axis: simd_normalize(axis))
        return float4x4(q)
    }

    static func rotateX(_ deg: Float) -> float4x4 { rotate(axis: [1, 0, 0], degrees: deg) }
    static func rotateY(_ deg: Float) -> float4x4 { rotate(axis: [0, 1, 0], degrees: deg) }
    static func rotateZ(_ deg: Float) -> float4x4 { rotate(axis: [0, 0, 1], degrees: deg) }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3<Float>(x, y, z) }
}
