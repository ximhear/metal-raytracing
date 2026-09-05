//
//  Engine.swift
//  터보팬 제트엔진 커터웨이.
//
//  **축 = X.** 앞(흡입구) = -x, 뒤(배기) = +x. 반경 방향은 YZ 평면.
//  로컬 단위 = 10 cm. 팬 지름 20 = 2.0 m 급 터보팬(CFM56 정도), 전장 약 32 = 3.2 m.
//
//  **왜 이 모델인가 — 엔진이 가장 잘하는 세 가지가 한 물체에 다 있다**
//  1. 블레이드가 축 둘레로 반복된다 → 오브젝트 1개 + 인스턴스 수십 개.
//     단(stage) 하나가 오브젝트 하나이고, 날개 수만큼 회전 배치한다.
//     **절대 한 단을 통째로 오브젝트 하나로 만들지 않는다** — 원주 방향 레이가
//     날개를 수십 장 지나며 `CSG_MAX_INTERVALS`(6)를 그 자리에서 넘긴다.
//  2. 나셀·카울·케이싱이 전부 회전체다 → `CSG.lathe` 가 그대로 맞는다.
//  3. **커터웨이**: 사분면 상자 하나를 빼면 내부가 통째로 드러난다.
//     메시였다면 잘린 단면을 손으로 막아야 하지만, CSG 는 차집합의 절단면이
//     **자르는 쪽 재질을 물려받으므로** 단면 색까지 공짜로 나온다.
//     실제 전시용 컷어웨이 모형이 단면을 붉게 칠하는 것과 같다.
//

import Foundation
import simd

enum Engine {

    // MARK: - 축 방향 주요 스테이션

    static let inletX: Float = -14.5        // 흡입구 립
    static let fanX: Float = -10.5          // 팬
    static let fanRadius: Float = 10.0
    static let fanCowlBackX: Float = 8.5    // 팬 카울(바이패스 노즐) 후단
    static let coreBackX: Float = 17.6      // 코어 카울(1차 노즐) 후단
    static let exhaustX: Float = 24.5       // 배기 콘 끝

    struct Materials {
        let cowl: Int         // 도장된 카울 외피
        let duct: Int         // 바이패스 덕트 안쪽
        let fanBlade: Int     // 연마 티타늄 — 이 엔진의 얼굴이라 진짜 거울로
        let compressor: Int   // 압축기 블레이드
        let turbine: Int      // 열에 그을린 니켈 초합금
        let combustor: Int    // 연소기 라이너
        let shaft: Int        // 강철 축
        let hub: Int          // 스피너 · 로터 드럼
        /// **절단면 전용.** 커터웨이로 자른 자리에 이 색이 남아 층이 한눈에 읽힌다.
        let cut: Int
    }

    // MARK: - 커터웨이

    /// 잘라낼 90° 쐐기. 축 둘레로 `cutRoll` 만큼 굴려 **정수리(파일런 자리)를 비켜 간다** —
    /// 파일런을 반으로 자르면 열린 베이 위에 붉은 지느러미가 얹힌 꼴이 된다.
    /// 쐐기는 방위각 -35°~55° 를 차지하므로 살짝 위-앞에서 보면 속이 그대로 들어온다.
    ///
    /// **회전 부품(블레이드·로터 드럼·축)에는 쓰지 않는다.** 날개까지 잘라 내면
    /// 열린 창 안에 아무것도 없어 기계가 읽히지 않는다. 실제 컷어웨이도 카울만 걷어낸다.
    /// 흡입구 립도 남긴다 — 앞에서 봤을 때 **온전한 원형 흡입구**가 있어야 엔진으로 읽힌다.
    /// 립까지 잘라 내면 욕조처럼 보인다 (첫 렌더가 그랬다).
    static let cutRoll: Float = 35

    static func cutQuadrant(_ m: Materials) -> CSG {
        let big: Float = 90
        let x0 = inletX + 3.2, x1: Float = 60
        return CSG.box(.rotateX(cutRoll)
                       * .translate((x0 + x1) / 2, big / 2, big / 2)
                       * .scale((x1 - x0) / 2, big / 2, big / 2), material: m.cut)
    }

    // MARK: - 회전체 (나셀 · 카울 · 케이싱)

    /// Y축 회전체를 만들어 **엔진 축(X)** 으로 눕힌다.
    /// `rotateZ(-90)` 이 (0, y, 0) → (y, 0, 0) 이므로 프로파일의 y 를 그대로 x 스테이션으로 쓴다.
    static func revolve(_ profile: [(y: Float, r: Float)], material m: Int) -> CSG {
        CSG.lathe(profile, material: m).transformed(.rotateZ(-90))
    }

    /// 바깥 윤곽 − 안쪽 윤곽 = 껍데기. 두 프로파일을 따로 주므로 **두께가 위치마다 달라도 된다**
    /// (덕트는 얇고 흡입구 립은 두꺼운 실제 나셀이 그렇다).
    /// `inside` 를 주면 안쪽 면이 다른 재질이 된다 — 차집합의 절단면은 **자르는 쪽** 재질을 쓴다.
    ///
    /// ⚠︎ **안쪽 윤곽은 반드시 양 끝에서 바깥보다 튀어나와 있어야 한다.**
    /// 두 회전체의 끝 캡이 정확히 같은 평면에 있으면 `A − B` 가 부동소수점 오차만큼의
    /// **머리카락 같은 원판**을 남기고, 그것이 픽셀마다 맞았다 안 맞았다 하며 화면 전체에
    /// 소금후추 얼룩으로 나타난다. 흡입구 안쪽이 통째로 지글거려서 한참 헤맸다.
    static func shell(outer: [(y: Float, r: Float)], inner: [(y: Float, r: Float)],
                      material m: Int, inside: Int? = nil) -> CSG {
        revolve(outer, material: m) - revolve(extended(inner), material: inside ?? m)
    }

    /// 윤곽 하나에서 두께 `wall` 만큼 안으로 판 껍데기
    static func shell(_ profile: [(y: Float, r: Float)], wall: Float,
                      material m: Int, inside: Int? = nil) -> CSG {
        shell(outer: profile,
              inner: profile.map { ($0.y, max($0.r - wall, 0.03)) },
              material: m, inside: inside)
    }

    /// 양 끝을 조금 늘려 바깥 윤곽의 캡과 같은 평면에 놓이지 않게 한다
    private static func extended(_ p: [(y: Float, r: Float)], by e: Float = 0.08)
        -> [(y: Float, r: Float)] {
        [(p[0].y - e, p[0].r)] + p + [(p[p.count - 1].y + e, p[p.count - 1].r)]
    }

    /// 프로파일에서 임의의 x 지점 반지름을 선형 보간한다. 이음매 깊이를 **표면 기준**으로
    /// 잡으려면 그 자리의 반지름을 알아야 한다 — 상수로 박아 두면 프로파일을 고치는 순간 어긋난다.
    static func radius(_ p: [(y: Float, r: Float)], at x: Float) -> Float {
        if x <= p[0].y { return p[0].r }
        for i in 0..<(p.count - 1) where x <= p[i + 1].y {
            let (y0, r0) = p[i], (y1, r1) = p[i + 1]
            return r0 + (r1 - r0) * (x - y0) / (y1 - y0)
        }
        return p[p.count - 1].r
    }

    /// 나셀 이음매 — 얇은 고리 홈. 팬 카울 도어 · 역추진 슬리브의 분할선이다.
    /// **이게 없으면 옆에서 봤을 때 그냥 흰 통이다** — 커터웨이가 아닌 쪽 면을 살리는 건 이것뿐이다.
    ///
    /// 바깥 원기둥에서 안쪽 원기둥을 뺀 얇은 고리를 카울에서 빼낸다.
    /// `surface` 는 **그 자리의 겉면 반지름**이다. 여기에 큰 상수를 넣고 거기서 depth 를 빼면
    /// 고리가 모델 바깥 허공에 생겨 아무 일도 일어나지 않는다 (한참 못 알아챘다).
    /// 안쪽 원기둥을 축 방향으로 길게 빼는 이유는 끝 캡이 같은 평면에 겹치지 않게 하려는 것.
    static func seam(atX x: Float, surface: Float, depth: Float = 0.22,
                     halfWidth w: Float = 0.15, material m: Int) -> CSG {
        let ro = surface + 2
        return CSG.cylinder(.translate(x, 0, 0) * .rotateZ(90) * .scale(ro, w, ro), material: m)
             - CSG.cylinder(.translate(x, 0, 0) * .rotateZ(90)
                            * .scale(surface - depth, w * 4, surface - depth), material: m)
    }

    /// 팬 카울 — 흡입구 립에서 부풀었다가 뒤로 좁아지는 바이패스 덕트.
    /// 바깥은 도장, 안쪽(덕트 벽)은 다른 재질을 줘서 열린 단면에서 층이 구분된다.
    static let fanCowlOuter: [(y: Float, r: Float)] = [
        (inletX,        9.90),
        (inletX + 0.6, 11.10),
        (inletX + 2.0, 11.90),
        (fanX + 1.5,   12.15),
        (-1.0,         11.95),
        ( 4.0,         11.35),
        (fanCowlBackX, 10.20),
    ]

    static func fanCowl(_ m: Materials) -> CSG {
        let outer = fanCowlOuter
        // 덕트 벽 — 팬 팁(10.0) 바로 바깥을 지나며 뒤로 좁아진다
        let inner: [(y: Float, r: Float)] = [
            (inletX,        9.50),
            (inletX + 0.9,  9.15),
            (fanX - 0.8,    9.70),
            (fanX,         10.25),
            (fanX + 2.5,   10.45),
            ( 1.0,         10.15),
            (fanCowlBackX, 9.35),
        ]
        return shell(outer: outer, inner: inner, material: m.cowl, inside: m.duct)
             - cutQuadrant(m)
             - fanCowlSeam(-12.6, m)      // 흡입구 립 ↔ 카울
             - fanCowlSeam(-10.6, m)      // 팬 케이스 앞 플랜지
             - fanCowlSeam( -2.0, m)      // 팬 카울 도어 ↔ 역추진 슬리브
             - fanCowlSeam(  4.6, m)      // 역추진 슬리브 ↔ 노즐
    }

    private static func fanCowlSeam(_ x: Float, _ m: Materials) -> CSG {
        seam(atX: x, surface: radius(fanCowlOuter, at: x), material: m.duct)
    }

    static let coreCowlProfile: [(y: Float, r: Float)] = [
        (fanX + 1.6, 4.55),
        (fanX + 3.4, 5.05),
        ( 1.0,       5.05),
        ( 8.5,       4.80),
        (13.0,       4.30),
        (coreBackX,  3.30),          // 1차(코어) 노즐로 좁아진다
    ]

    /// 코어 카울 — 바이패스 덕트의 안쪽 벽이자 코어를 감싸는 몸통
    static func coreCowl(_ m: Materials) -> CSG {
        let p = coreCowlProfile
        return shell(p, wall: 0.30, material: m.cowl, inside: m.duct)
             - cutQuadrant(m)
             - seam(atX: 10.5, surface: radius(p, at: 10.5), depth: 0.16,
                    halfWidth: 0.11, material: m.duct)
    }

    /// 코어 케이싱 — 압축기·터빈 날개 끝을 감싸는 안쪽 케이싱.
    /// 카울과 케이싱이 **두 겹으로 잘려 보이는 것**이 커터웨이의 핵심 그림이다.
    static func coreCasing(_ m: Materials) -> CSG {
        let p: [(y: Float, r: Float)] = [
            (fanX - 0.2, 4.60),
            (-8.2,       4.55),
            (-4.4,       4.45),
            (-3.5,       4.35),
            ( 2.5,       3.00),
            ( 2.9,       4.35),          // 연소기 둘레는 다시 부푼다
            ( 6.4,       4.30),
            ( 6.8,       3.50),
            ( 9.0,       3.70),
            (14.8,       4.75),
            (15.8,       4.55),
        ]
        return shell(p, wall: 0.22, material: m.cowl, inside: m.duct) - cutQuadrant(m)
    }

    /// 바이패스 덕트 이분벽 — 12시·6시에서 코어 카울과 나셀 안쪽 벽을 잇는 얇은 벽.
    /// 파일런으로 배관·배선이 지나가는 실제 구조다. **없으면 덕트가 텅 빈 고리로만 보여**
    /// 커터웨이의 절반이 허공이 된다. 오브젝트 하나를 위아래 두 번 배치한다.
    static func bifurcation(_ m: Materials) -> CSG {
        CSG.roundBox(half: [4.45, 2.50, 0.22], radius: 0.18,
                     .translate(-2.45, 7.50, 0), material: m.cowl)
      - cutQuadrant(m)
    }

    /// 배기 콘(플러그) — 터빈 뒤로 뾰족하게 빠진다
    static func exhaustCone(_ m: Materials) -> CSG {
        revolve([(15.0, 2.75), (19.0, 2.40), (exhaustX, 0.28)], material: m.turbine)
    }

    /// 스피너 — 팬 앞의 원뿔
    static func spinner(_ m: Materials) -> CSG {
        revolve([(fanX - 3.6, 0.22), (fanX - 2.2, 1.25), (fanX - 0.8, 2.10),
                 (fanX + 0.5, 2.55)], material: m.hub)
    }

    /// 로터 드럼 + 축. 압축기·터빈 날개가 박히는 몸통이다.
    /// **자르지 않는다** — 열린 창으로 들여다볼 알맹이가 바로 이것이다.
    static func rotorDrum(_ m: Materials) -> CSG {
        let drum = revolve([
            (fanX + 0.5,  2.55), (-7.9, 2.50), (-4.4, 2.60),
            (-3.5,        2.95), ( 2.5, 2.05), ( 3.0, 1.95),
            ( 6.0,        1.90), ( 8.5, 2.15), (14.6, 2.65),
            (15.4,        2.55),
        ], material: m.hub)
        let x0 = fanX - 3.4, x1 = exhaustX - 1.0
        let shaft = CSG.cylinder(.translate((x0 + x1) / 2, 0, 0) * .rotateZ(90)
                                 * .scale(0.9, (x1 - x0) / 2, 0.9), material: m.shaft)
        return drum | shaft
    }

    /// 연소기 — 환상형 라이너 두 겹. 바깥 라이너만 잘라 안쪽 화염통이 드러난다.
    static func combustor(_ m: Materials) -> CSG {
        let outer: [(y: Float, r: Float)] = [(2.9, 3.55), (3.5, 4.00), (5.1, 4.00), (5.9, 3.30)]
        let inner: [(y: Float, r: Float)] = [(2.9, 2.35), (3.5, 2.05), (5.1, 2.05), (5.9, 2.40)]
        return (shell(outer, wall: 0.20, material: m.combustor) - cutQuadrant(m))
             | shell(inner, wall: 0.20, material: m.combustor)
    }

    /// 연료 노즐 — 연소기 앞면에 빙 둘러 박힌다 (인스턴스).
    /// 로컬 프레임은 블레이드와 같다: 반경 방향 = +Y, 축 방향 = X.
    static func fuelNozzle(_ m: Materials) -> CSG {
        CSG.cylinder(.translate(0, 3.15, 0) * .rotateZ(90) * .scale(0.17, 0.60, 0.17),
                     material: m.shaft)
      | CSG.roundBox(half: [0.22, 0.42, 0.20], radius: 0.12,
                     .translate(-0.55, 3.15, 0), material: m.shaft)
    }

    // MARK: - 블레이드 (오브젝트 1개 + 인스턴스 수십 개)

    /// 비틀린 블레이드. 짧은 조각을 반경 방향으로 쌓으며 **비틀림·시위·두께를 함께 줄인다** —
    /// 실제 에어포일이 루트에서 크게 비틀리고 팁으로 갈수록 펴지는 것을 근사한다.
    ///
    /// 로컬 프레임: **스팬 = +Y, 시위 = X, 두께 = Z.** 축 둘레 배치는 `rotateX` 로 한다.
    ///
    /// 조각은 **자기 길이만큼 겹치게** 둔다. `roundBox` 의 둥근 끝이 이웃의 평평한 몸통 안에
    /// 완전히 파묻혀야 마디가 안 보인다 — 겹침이 얕으면 끝의 라운드끼리 만나
    /// **애벌레처럼 잘록잘록해진다.**
    /// 겹치기만 하면 합집합이 구간 하나로 합쳐지므로 **조각을 늘려도 구간은 늘지 않는다** —
    /// 매끄러움은 조각 수로 사고, 값은 겹침으로 치른다.
    ///
    /// `sweep` 은 팁이 축 방향(+x)으로 밀리는 양. 현대 팬 블레이드의 굽은 앞전이 여기서 나온다.
    ///
    /// **비틀림 각은 축(x)에서 잰 스태거각이다.** 루트는 원주속도가 느려 유동이 거의 축 방향이라
    /// 날개도 축에 가깝고(작은 각), 팁은 원주속도가 커서 회전면에 가깝게 눕는다(큰 각).
    /// **루트가 크고 팁이 작다고 넣으면 정반대가 되어** 정면에서 날개가 실처럼 보인다 (한 번 그랬다).
    static func blade(root r0: Float, tip r1: Float,
                      rootChord c0: Float, tipChord c1: Float,
                      rootThick t0: Float, tipThick t1: Float,
                      rootTwist a0: Float, tipTwist a1: Float,
                      sweep: Float = 0, segments n: Int, material m: Int) -> CSG {
        let halfY = (r1 - r0) / Float(n)                 // 조각 반높이 = 간격의 2배 → 50% 겹침
        let inner = (r1 - r0) - 2 * halfY                // 중심이 놓일 구간 (양 끝을 halfY 만큼 물린다)
        var parts: [CSG] = []
        for i in 0..<n {
            let u = n == 1 ? 0.5 : Float(i) / Float(n - 1)
            let r = r0 + halfY + inner * u
            let v = (r - r0) / (r1 - r0)                  // 시위·두께·비틀림은 실제 반경 기준
            let c = c0 + (c1 - c0) * v
            let th = t0 + (t1 - t0) * v
            let a = a0 + (a1 - a0) * v
            parts.append(CSG.roundBox(half: [c / 2, halfY, th / 2],
                                      radius: min(th, c) * 0.42,
                                      .translate(sweep * v * v, r, 0) * .rotateY(a), material: m))
        }
        return CSG.unionAll(parts)
    }

    // MARK: - 단(stage) 정의

    struct Stage {
        let x: Float
        let count: Int
        let root: Float, tip: Float
        let chord: Float, thick: Float
        let twistRoot: Float, twistTip: Float
        var sweep: Float = 0
        let segments: Int
    }

    static func bladeFor(_ s: Stage, _ material: Int) -> CSG {
        blade(root: s.root, tip: s.tip,
              rootChord: s.chord * 1.12, tipChord: s.chord * 0.86,
              rootThick: s.thick, tipThick: s.thick * 0.62,
              rootTwist: s.twistRoot, tipTwist: s.twistTip,
              sweep: s.sweep, segments: s.segments, material: material)
    }

    /// 축 둘레로 `count` 장을 돌려 놓는다. 단마다 x 위치만 다르다.
    static func ring(_ s: Stage, phase: Float = 0) -> [float4x4] {
        (0..<s.count).map { i in
            .translate(s.x, 0, 0) * .rotateX(Float(i) / Float(s.count) * 360 + phase)
        }
    }

    /// 팬 — 와이드 코드 22 장. 루트에서 58° 비틀린다.
    static let fan = Stage(x: fanX, count: 22, root: 2.35, tip: fanRadius,
                           chord: 3.6, thick: 0.62, twistRoot: 30, twistTip: 63,
                           sweep: 2.2, segments: 16)

    /// 바이패스 정익(OGV) — 팬 뒤에서 선회류를 편다. 반대로 비튼다.
    static let outletGuideVanes = Stage(x: fanX + 3.0, count: 46, root: 5.15, tip: 10.05,
                                        chord: 1.6, thick: 0.30,
                                        twistRoot: -20, twistTip: -36, segments: 8)

    /// 부스터(저압 압축기) — 동익·정익이 번갈아 선다
    static let boosterStages: [Stage] = [
        Stage(x: -7.9, count: 34, root: 2.50, tip: 4.30, chord: 1.00, thick: 0.22,
              twistRoot: 26, twistTip: 52, segments: 5),
        Stage(x: -7.2, count: 40, root: 2.50, tip: 4.28, chord: 0.84, thick: 0.18,
              twistRoot: -24, twistTip: -46, segments: 5),
        Stage(x: -6.4, count: 36, root: 2.52, tip: 4.26, chord: 0.94, thick: 0.20,
              twistRoot: 27, twistTip: 51, segments: 5),
        Stage(x: -5.7, count: 42, root: 2.52, tip: 4.24, chord: 0.80, thick: 0.17,
              twistRoot: -25, twistTip: -45, segments: 5),
        Stage(x: -4.9, count: 38, root: 2.55, tip: 4.22, chord: 0.90, thick: 0.19,
              twistRoot: 28, twistTip: 50, segments: 5),
    ]

    /// 고압 압축기 6단 — 뒤로 갈수록 지름·시위·두께가 모두 줄고 날개 수는 는다.
    /// 이 수축이 커터웨이에서 가장 기계처럼 읽히는 부분이다.
    static var hpcStages: [Stage] {
        var out: [Stage] = []
        let n = 6
        for i in 0..<n {
            let u = Float(i) / Float(n - 1)
            let x = -3.2 + u * 5.0
            let tip = 4.10 - u * 1.20
            let root = 2.90 - u * 0.95
            out.append(Stage(x: x, count: 38 + i * 4, root: root, tip: tip,
                             chord: 0.74 - u * 0.26, thick: 0.16 - u * 0.06,
                             twistRoot: 30 - u * 4, twistTip: 50 - u * 8, segments: 4))
            out.append(Stage(x: x + 0.45, count: 44 + i * 4, root: root, tip: tip - 0.05,
                             chord: 0.64 - u * 0.22, thick: 0.14 - u * 0.05,
                             twistRoot: -27 + u * 3, twistTip: -45 + u * 7, segments: 4))
        }
        return out
    }

    /// 터빈 — 짧고 두꺼운 날개. 고압 2단(작다) + 저압 4단(뒤로 갈수록 커진다).
    static var turbineStages: [Stage] {
        var out: [Stage] = []
        for i in 0..<2 {
            let x = 6.5 + Float(i) * 1.05
            out.append(Stage(x: x, count: 54, root: 1.90, tip: 3.05,
                             chord: 0.76, thick: 0.26, twistRoot: 24, twistTip: 46, segments: 4))
            out.append(Stage(x: x + 0.50, count: 48, root: 1.90, tip: 3.00,
                             chord: 0.66, thick: 0.22, twistRoot: -30, twistTip: -50, segments: 4))
        }
        for i in 0..<4 {
            let u = Float(i) / 3
            let x = 9.4 + Float(i) * 1.5
            out.append(Stage(x: x, count: 58, root: 2.15 + u * 0.42, tip: 3.30 + u * 0.82,
                             chord: 0.86 + u * 0.24, thick: 0.24,
                             twistRoot: 26, twistTip: 48, segments: 4))
            out.append(Stage(x: x + 0.70, count: 52, root: 2.15 + u * 0.42, tip: 3.25 + u * 0.82,
                             chord: 0.70 + u * 0.20, thick: 0.20,
                             twistRoot: -30, twistTip: -50, segments: 4))
        }
        return out
    }

    /// 연료 노즐 배치 — 연소기 앞면에 20개
    static var nozzlePlacements: [float4x4] {
        (0..<20).map { i in
            .translate(2.95, 0, 0) * .rotateX(Float(i) / 20 * 360 + 9)
        }
    }

    /// 파일런 스텁 — 날개에 매다는 기둥. 엔진만 떠 있으면 크기 감각이 안 잡힌다.
    static func pylon(_ m: Materials) -> CSG {
        CSG.roundBox(half: [4.6, 2.4, 0.62], radius: 0.45,
                     .translate(-2.5, 12.9, 0), material: m.cowl)
    }
}
