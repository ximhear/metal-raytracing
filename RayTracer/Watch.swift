//
//  Watch.swift
//  기계식 손목시계 무브먼트 — 이 렌더러가 가장 잘하는 것을 몰아넣은 모델.
//
//  **로컬 좌표 = mm.** 무브먼트 지름 30 mm (반지름 15).
//  Y 가 두께 방향이고, 뒤판(트레인 쪽)에서 내려다보는 배치다.
//
//      y = 0        메인 플레이트 윗면
//      y = 0.5      기어 트레인 (휠 두께 0.45)
//      y = 1.35     브리지 (두께 0.7)
//      y = 1.9      나사 머리 · 밸런스
//
//  **왜 시계인가**: 시계 부품은 전부 선반·밀링 가공물이라 불리언(∪ ∩ −)과 일대일로 맞는다.
//  기어 = 원판 ∪ 톱니 − 구멍, 브리지 = 피벗 보스 ∪ 웹 − 나사구멍, 나사 = 원기둥 − 홈.
//  메시였다면 톱니 하나하나를 테셀레이션해야 하지만 여기서는 전부 수식이다.
//
//  **구간 한계 설계**: `CSG_MAX_INTERVALS = 6` 은 오브젝트 단위다.
//  기어를 전부 한 덩어리로 묶으면 평면 방향 레이가 톱니를 줄줄이 지나 한계를 넘는다.
//  그래서 **기어 하나 = 오브젝트 하나**로 두고, 보석·나사처럼 같은 모양은 인스턴스로 반복한다.
//

import Foundation
import simd

enum Watch {

    // MARK: - 치수 (mm)

    static let plateRadius: Float = 15
    static let plateThickness: Float = 1.4
    static let wheelThickness: Float = 0.26
    /// 트레인 한 단(段) 높이
    static let levelStep: Float = 0.30
    /// i 번째 휠의 높이. **휠마다 한 단씩 올라간다.**
    /// 전부 같은 높이에 두면 뒤 휠이 앞 휠을 통째로 파고들어 한 덩어리로 뭉친다 —
    /// 실제 무브먼트는 휠을 층으로 쌓고 **피니언만 아래층으로 내려가** 앞 휠과 맞물린다.
    static func wheelY(_ i: Int) -> Float { 0.22 + Float(i) * levelStep }
    static var topWheelY: Float { wheelY(train.count - 1) }

    static let bridgeThickness: Float = 0.60
    /// **브리지마다 높이가 다르다.** 하나로 통일하면 배럴 브리지가 배럴 위 1.3 mm 에 붕 뜬다 —
    /// 실물은 각 브리지가 자기가 덮는 휠 바로 위에 앉는다.
    static var barrelBridgeY: Float { wheelY(1) + wheelThickness / 2 + bridgeThickness / 2 + 0.12 }
    static var bridgeY: Float { topWheelY + wheelThickness / 2 + bridgeThickness / 2 + 0.12 }
    static var cockY: Float { bridgeY + 0.52 }
    /// 래칫·크라운 휠은 배럴 브리지 위에 얹힌다
    static var upperWheelY: Float { barrelBridgeY + bridgeThickness / 2 + 0.21 }

    struct Materials {
        let plate: Int        // 메인 플레이트 (로듐 도금 뉴실버)
        let bridge: Int       // 브리지
        let wheel: Int        // 황동 금도금 휠
        let pinion: Int       // 강철 피니언 · 아버
        let ruby: Int         // 인조 루비 보석
        let blueSteel: Int    // 블루 스틸 나사
        let chrome: Int
        let crystal: Int      // 사파이어 글라스
        let chaton: Int       // 보석을 물고 있는 금 샤통
    }

    // MARK: - 기어

    /// 평기어: 원판 ∪ 톱니 − 보어 − 경량화 구멍.
    ///
    /// 톱니는 인볼류트 대신 **끝을 둥글린 상자**로 근사한다 — 이 크기에서는 구분이 안 되고,
    /// `roundBox` 라 톱니 끝이 매끈하게 빛을 받는다.
    /// 살(spoke) 대신 실제 시계 휠처럼 **둥근 경량화 구멍**을 뚫는다.
    static func gear(teeth n: Int, pitchRadius rp: Float, thickness th: Float,
                     bore: Float, crossings: Int = 0, toothLength: Float = 1,
                     material m: Int) -> CSG {
        let module = 2 * rp / Float(n)
        let root = rp - 0.55 * module * toothLength
        let outer = rp + 0.62 * module * toothLength
        let hy = th / 2
        let toothHalfLen = (outer - root) / 2
        let rMid = (outer + root) / 2
        let toothHalfW = module * 0.30

        var parts: [CSG] = [CSG.cylinder(.scale(root, hy, root), material: m)]
        for i in 0..<n {
            let a = Float(i) / Float(n) * 360
            parts.append(CSG.roundBox(half: [toothHalfLen, hy, toothHalfW],
                                      radius: min(min(toothHalfLen, toothHalfW), hy) * 0.5,
                                      .rotateY(a) * .translate(rMid, 0, 0), material: m))
        }

        var g = CSG.unionAll(parts)
                - CSG.cylinder(.scale(bore, th, bore), material: m)

        // 크로싱(살) — 실제 시계 휠은 림과 허브를 살 몇 개로만 잇는다.
        // 큰 원을 파내면 살 끝이 둥글게 남는데, 고급 무브먼트 휠이 정확히 그 모양이다.
        if crossings >= 3 {
            let hub = max(bore * 2.0, 0.42)
            let rim = root - module * 1.5
            if rim > hub + 0.12 {
                let rc = (hub + rim) / 2
                let spacing = 2 * Float.pi * rc / Float(crossings)
                let hr = min((rim - hub) * 0.48, spacing * 0.36)
                g = g - CSG.unionAll((0..<crossings).map { i in
                    CSG.cylinder(.rotateY(Float(i) / Float(crossings) * 360) * .translate(rc, 0, 0)
                                 * .scale(hr, th, hr), material: m)
                })
            }
        }
        return g
    }

    /// 피니언 — 이가 굵고 적은 강철 소치차. 아버(축)까지 함께 만든다.
    static func pinion(leaves n: Int, pitchRadius rp: Float, thickness th: Float,
                       arborRadius ar: Float, arborTop: Float, material m: Int) -> CSG {
        let module = 2 * rp / Float(n)
        let hy = th / 2
        var parts: [CSG] = [CSG.cylinder(.scale(rp - 0.5 * module, hy, rp - 0.5 * module), material: m)]
        for i in 0..<n {
            let a = Float(i) / Float(n) * 360
            parts.append(CSG.roundBox(half: [module * 0.62, hy, module * 0.36],
                                      radius: min(module * 0.30, hy) * 0.8,
                                      .rotateY(a) * .translate(rp, 0, 0), material: m))
        }
        // 아버 — 브리지까지 올라가 보석에 물린다
        parts.append(CSG.cylinder(.translate(0, (arborTop - hy) / 2, 0)
                                  * .scale(ar, (arborTop + hy) / 2, ar), material: m))
        return CSG.unionAll(parts)
    }

    // MARK: - 기어 트레인 배치
    //
    // 중심거리 = (앞 휠 피치 반지름) + (뒤 휠 피니언 반지름) 으로 잡아 **실제로 맞물리게** 한다.
    // 눈에 잘 안 띌 것 같지만, 안 맞으면 톱니가 겹치거나 뜨는 게 바로 보인다.

    struct Wheel {
        let name: String
        let center: SIMD2<Float>      // (x, z)
        let teeth: Int
        let pitch: Float
        let pinionLeaves: Int
        let pinionPitch: Float
        let crossings: Int
    }

    /// 트레인 전체를 플레이트 중앙으로 옮기는 보정.
    /// 배럴이 한쪽으로 크게 튀어나오는 구조라, 이게 없으면 반대쪽 판이 휑하게 남는다.
    static let layoutShift: SIMD2<Float> = [1.9, 1.7]

    static let train: [Wheel] = {
        let centerWheel = Wheel(name: "center", center: layoutShift, teeth: 64, pitch: 3.60,
                                pinionLeaves: 12, pinionPitch: 0.90, crossings: 4)
        // 배럴은 센터 휠 피니언을 돌린다
        let d0 = centerWheel.pinionPitch + 5.40
        let barrel = Wheel(name: "barrel",
                           center: layoutShift + [cosd(142) * d0, sind(142) * d0],
                           teeth: 76, pitch: 5.40,
                           pinionLeaves: 0, pinionPitch: 0, crossings: 5)

        let d1 = centerWheel.pitch + 0.78
        let third = Wheel(name: "third", center: layoutShift + [cosd(-18) * d1, sind(-18) * d1],
                          teeth: 54, pitch: 2.60, pinionLeaves: 10, pinionPitch: 0.78, crossings: 4)

        let d2 = third.pitch + 0.66
        let fourth = Wheel(name: "fourth",
                           center: third.center + [cosd(-78) * d2, sind(-78) * d2],
                           teeth: 48, pitch: 2.10, pinionLeaves: 10, pinionPitch: 0.66,
                           crossings: 4)

        let d3 = fourth.pitch + 0.55
        let escape = Wheel(name: "escape",
                           center: fourth.center + [cosd(172) * d3, sind(172) * d3],
                           teeth: 15, pitch: 1.45, pinionLeaves: 8, pinionPitch: 0.55,
                           crossings: 0)
        return [barrel, centerWheel, third, fourth, escape]
    }()

    static var barrel: Wheel  { train[0] }
    static var escape: Wheel  { train[4] }
    /// 팔레트 포크 회전축 — 이스케이프 휠 옆
    static var palletCenter: SIMD2<Float> { escape.center + [cosd(-108) * 3.1, sind(-108) * 3.1] }
    /// 밸런스 중심
    static var balanceCenter: SIMD2<Float> { palletCenter + [cosd(-170) * 5.2, sind(-170) * 5.2] }
    static let balanceRadius: Float = 4.3

    private static func cosd(_ d: Float) -> Float { cos(d * .pi / 180) }
    private static func sind(_ d: Float) -> Float { sin(d * .pi / 180) }

    /// 휠 하나(기어 + 피니언 + 아버). 오브젝트 하나로 쓴다.
    /// 휠 하나(기어 + 피니언 + 아버). 로컬 원점이 **휠 자신의 높이**이고,
    /// 피니언은 `levelStep` 만큼 아래 — 즉 **앞 휠과 같은 층**에 있어야 맞물린다.
    static func wheelAssembly(_ w: Wheel, index i: Int, _ m: Materials) -> CSG {
        let g = gear(teeth: w.teeth, pitchRadius: w.pitch, thickness: wheelThickness,
                     bore: max(w.pinionPitch, 0.45) * 0.52,
                     crossings: w.crossings,
                     toothLength: w.teeth <= 20 ? 1.9 : 1,   // 이스케이프 휠은 길고 성기다
                     material: m.wheel)
        guard w.pinionLeaves > 0 else {
            // 배럴은 피니언 대신 통(barrel drum) 이 아래로 내려간다
            let drumH = (wheelY(i) - 0.06) / 2
            let arborTop = upperWheelY - wheelY(i) + 0.30
            return g | CSG.cylinder(.translate(0, -wheelY(i) / 2, 0)
                                    * .scale(w.pitch - 0.30, drumH, w.pitch - 0.30), material: m.wheel)
                     | CSG.cylinder(.translate(0, arborTop / 2, 0)
                                    * .scale(0.30, arborTop / 2, 0.30), material: m.pinion)
        }
        let p = pinion(leaves: w.pinionLeaves, pitchRadius: w.pinionPitch,
                       thickness: wheelThickness + 0.10, arborRadius: 0.22,
                       arborTop: bridgeY + bridgeThickness / 2 - wheelY(i) + 0.10, material: m.pinion)
        return g | p.transformed(.translate(0, -levelStep, 0))
    }

    // MARK: - 메인 플레이트

    /// 원판에서 톱니·피벗 자리를 파낸다. 실물도 이렇게 깎는다.
    static func mainPlate(_ m: Materials) -> CSG {
        let hy = plateThickness / 2
        var cuts: [CSG] = []
        // 각 휠 아래로 여유 구멍 (실제 무브먼트의 자리파기)
        for w in train {
            cuts.append(CSG.cylinder(.translate(w.center.x, 0, w.center.y)
                                     * .scale(w.pitch + 0.35, hy * 2, w.pitch + 0.35), material: m.plate))
        }
        cuts.append(CSG.cylinder(.translate(balanceCenter.x, 0, balanceCenter.y)
                                 * .scale(balanceRadius + 0.5, hy * 2, balanceRadius + 0.5),
                                 material: m.plate))
        // 가장자리 나사·기둥 자리
        for i in 0..<3 {
            let a = Float(i) / 3 * 360 + 30
            cuts.append(CSG.cylinder(.rotateY(a) * .translate(plateRadius - 1.6, 0, 0)
                                     * .scale(0.55, hy * 2, 0.55), material: m.plate))
        }
        let disc = CSG.cylinder(.translate(0, -hy, 0) * .scale(plateRadius, hy, plateRadius),
                                material: m.plate)
        return disc - CSG.unionAll(cuts).transformed(.translate(0, -hy, 0))
    }

    // MARK: - 브리지
    //
    // 실제 브리지는 **피벗마다 둥근 보스가 있고 그 사이를 웹으로 이은** 모양이다.
    // 그대로 만든다: 점마다 원기둥 + 사이를 둥근 상자로 연결.

    private static func bridgeTier(_ pts: [SIMD2<Float>], radius r: Float, web: Float,
                                   y: Float, thickness th: Float, material m: Int) -> [CSG] {
        var parts: [CSG] = pts.map {
            CSG.cylinder(.translate($0.x, y, $0.y) * .scale(r, th / 2, r), material: m)
        }
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let d = b - a
            let len = simd_length(d) / 2
            let ang = -atan2(d.y, d.x) * 180 / .pi          // xz 평면에서의 방향
            parts.append(CSG.roundBox(half: [len, th / 2, web],
                                      radius: min(web, th / 2) * 0.7,
                                      .translate((a.x + b.x) / 2, y, (a.y + b.y) / 2)
                                      * .rotateY(ang), material: m))
        }
        return parts
    }

    /// 브리지를 **2단**으로 만든다 — 윗단을 조금 작게 얹으면 윤곽을 따라 단이 지고,
    /// 고급 무브먼트의 앙글라주(면취)처럼 빛을 받는 선이 생긴다. 밋밋한 흰 덩어리가 안 된다.
    static func bridgeThrough(_ pts: [SIMD2<Float>], radius r: Float, web: Float,
                              y: Float, thickness th: Float, material m: Int) -> CSG {
        let inset: Float = 0.20
        let topH: Float = 0.16
        return CSG.unionAll(
            bridgeTier(pts, radius: r, web: web, y: y, thickness: th, material: m)
          + bridgeTier(pts, radius: r - inset, web: max(web - inset, 0.15),
                       y: y + th / 2 + topH / 2, thickness: topH, material: m))
    }

    /// 배럴 + 센터 휠을 덮는 브리지
    static func barrelBridge(_ m: Materials) -> CSG {
        bridgeThrough([barrel.center, train[1].center], radius: 1.75, web: 0.95,
                      y: barrelBridgeY, thickness: bridgeThickness, material: m.bridge)
        - chatonHole(at: barrel.center, y: barrelBridgeY)
        - chatonHole(at: train[1].center, y: barrelBridgeY)
        - screwHoles([barrel.center + [-3.4, 2.2], train[1].center + [1.0, 2.9]], y: barrelBridgeY)
    }

    /// 서드 · 포스를 덮는 트레인 브리지. **이스케이프는 일부러 뺐다** —
    /// 탈진기가 무브먼트의 하이라이트인데 브리지로 덮으면 하나도 안 보인다.
    static func trainBridge(_ m: Materials) -> CSG {
        bridgeThrough([train[2].center, train[3].center], radius: 1.35, web: 0.80,
                      y: bridgeY, thickness: bridgeThickness, material: m.bridge)
        - chatonHole(at: train[2].center) - chatonHole(at: train[3].center)
        - screwHoles([train[2].center + [2.3, 1.2]])
    }

    /// 이스케이프 콕 — 피벗만 잡는 가느다란 팔. 휠이 그대로 보인다.
    static func escapeCock(_ m: Materials) -> CSG {
        let anchor = train[3].center + (escape.center - train[3].center) * 0.15
                   + SIMD2<Float>(0.6, 1.9)
        return bridgeThrough([escape.center, anchor], radius: 1.05, web: 0.48,
                             y: bridgeY, thickness: bridgeThickness, material: m.bridge)
             - chatonHole(at: escape.center)
             - screwHoles([anchor])
    }

    /// 팔레트 + 밸런스를 덮는 콕
    static func balanceCock(_ m: Materials) -> CSG {
        bridgeThrough([balanceCenter, palletCenter,
                       palletCenter + [3.0, 2.4]], radius: 1.55, web: 0.85,
                      y: cockY, thickness: bridgeThickness, material: m.bridge)
        - chatonHole(at: balanceCenter, y: cockY)
        - chatonHole(at: palletCenter, y: cockY)
        - screwHoles([palletCenter + [3.0, 2.4]], y: cockY)
    }

    /// 샤통(금 테)까지 들어가야 하므로 보석보다 넉넉히 뚫는다
    private static func chatonHole(at p: SIMD2<Float>, y: Float = bridgeY) -> CSG {
        CSG.cylinder(.translate(p.x, y, p.y) * .scale(0.96, bridgeThickness * 2, 0.96), material: 0)
    }

    private static func screwHoles(_ pts: [SIMD2<Float>], y: Float = bridgeY) -> CSG {
        CSG.unionAll(pts.map {
            CSG.cylinder(.translate($0.x, y, $0.y) * .scale(0.34, bridgeThickness, 0.34), material: 0)
        })
    }

    /// 래칫 휠 — 배럴 축 위. 손감기 무브먼트에서 가장 눈에 띄는 큰 톱니바퀴다.
    static func ratchetWheel(_ m: Materials) -> CSG {
        gear(teeth: 42, pitchRadius: 3.1, thickness: 0.42, bore: 0.55,
             crossings: 0, material: m.wheel)
    }

    /// 크라운 휠 — 래칫 휠과 맞물려 태엽을 감는다
    static func crownWheel(_ m: Materials) -> CSG {
        gear(teeth: 24, pitchRadius: 1.7, thickness: 0.40, bore: 0.42,
             crossings: 0, material: m.wheel)
    }

    static var ratchetCenter: SIMD2<Float> { barrel.center }
    /// 크라운 휠은 래칫 휠에 맞물린다 (중심거리 = 두 피치 반지름의 합)
    static var crownCenter: SIMD2<Float> {
        ratchetCenter + [cosd(58) * (3.1 + 1.7), sind(58) * (3.1 + 1.7)]
    }

    /// 클릭(역회전 방지 갈고리) — 래칫 휠 톱니를 문다
    static func click(_ m: Materials) -> CSG {
        let pivot = ratchetCenter + [cosd(-30) * 4.2, sind(-30) * 4.2]
        let toward = ratchetCenter - pivot
        let ang = -atan2(toward.y, toward.x) * 180 / .pi
        let y = upperWheelY
        return CSG.cylinder(.translate(pivot.x, y, pivot.y) * .scale(0.42, 0.20, 0.42),
                            material: m.pinion)
             | CSG.roundBox(half: [1.35, 0.18, 0.24], radius: 0.12,
                            .translate(pivot.x, y, pivot.y) * .rotateY(ang) * .translate(1.35, 0, 0),
                            material: m.pinion)
    }

    // MARK: - 탈진기 · 밸런스

    /// 팔레트 포크 — 두 개의 루비 팔레트가 이스케이프 휠 톱니를 번갈아 잡는다
    static func palletFork(_ m: Materials) -> CSG {
        let c = palletCenter
        let toEscape = escape.center - c
        let ang = -atan2(toEscape.y, toEscape.x) * 180 / .pi
        let y = wheelY(4) + 0.02
        let base = float4x4.translate(c.x, y, c.y) * .rotateY(ang)

        var parts: [CSG] = [
            CSG.cylinder(.translate(c.x, y, c.y) * .scale(0.55, 0.16, 0.55), material: m.pinion),
            // 두 갈래 팔
            CSG.roundBox(half: [1.5, 0.14, 0.22], radius: 0.10,
                         base * .rotateY(24) * .translate(1.5, 0, 0), material: m.pinion),
            CSG.roundBox(half: [1.5, 0.14, 0.22], radius: 0.10,
                         base * .rotateY(-24) * .translate(1.5, 0, 0), material: m.pinion),
            // 밸런스 쪽 꼬리
            CSG.roundBox(half: [1.9, 0.14, 0.18], radius: 0.09,
                         base * .rotateY(180) * .translate(1.9, 0, 0), material: m.pinion),
        ]
        // 루비 팔레트 두 개
        for s in [1, -1] as [Float] {
            parts.append(CSG.roundBox(half: [0.24, 0.13, 0.13], radius: 0.055,
                                      base * .rotateY(s * 24) * .translate(2.9, 0, 0) * .rotateY(-s * 24),
                                      material: m.ruby))
        }
        return CSG.unionAll(parts)
    }

    /// 밸런스 휠 — 링 + 살 + 아버. 림 나사는 인스턴스로 따로 박는다.
    static func balanceWheel(_ m: Materials) -> CSG {
        let c = balanceCenter
        let y = cockY - 0.42
        let rim = CSG.cylinder(.translate(c.x, y, c.y) * .scale(balanceRadius, 0.16, balanceRadius),
                               material: m.chrome)
                - CSG.cylinder(.translate(c.x, y, c.y)
                               * .scale(balanceRadius - 0.55, 0.4, balanceRadius - 0.55), material: m.chrome)
        var parts: [CSG] = [rim,
            CSG.cylinder(.translate(c.x, y, c.y) * .scale(0.42, 0.20, 0.42), material: m.pinion)]
        for i in 0..<2 {
            parts.append(CSG.roundBox(half: [balanceRadius - 0.2, 0.10, 0.20], radius: 0.08,
                                      .translate(c.x, y, c.y) * .rotateY(Float(i) * 90),
                                      material: m.chrome))
        }
        // 아버 — 콕의 보석까지
        parts.append(CSG.cylinder(.translate(c.x, y + 0.55, c.y) * .scale(0.16, 0.72, 0.16),
                                  material: m.pinion))
        return CSG.unionAll(parts)
    }

    /// 헤어스프링 — 아르키메데스 나선. 짧은 조각을 이어 붙여 근사한다.
    /// 조각이 많아 **평면 방향 레이가 여러 개를 지나므로 오브젝트를 따로 둔다.**
    static func hairspring(_ m: Materials) -> CSG {
        let c = balanceCenter
        let y = cockY - 0.12
        let turns: Float = 4.5, r0: Float = 0.55, r1: Float = 2.4
        let n = 150
        var parts: [CSG] = []
        for i in 0..<n {
            let t0 = Float(i) / Float(n), t1 = Float(i + 1) / Float(n)
            let a0 = t0 * turns * 2 * .pi, a1 = t1 * turns * 2 * .pi
            let rr0 = r0 + (r1 - r0) * t0, rr1 = r0 + (r1 - r0) * t1
            let p0 = SIMD2<Float>(cos(a0) * rr0, sin(a0) * rr0)
            let p1 = SIMD2<Float>(cos(a1) * rr1, sin(a1) * rr1)
            let d = p1 - p0
            let len = simd_length(d) / 2
            let ang = -atan2(d.y, d.x) * 180 / .pi
            parts.append(CSG.box(.translate(c.x + (p0.x + p1.x) / 2, y, c.y + (p0.y + p1.y) / 2)
                                 * .rotateY(ang) * .scale(len + 0.012, 0.075, 0.032),
                                 material: m.blueSteel))
        }
        return CSG.unionAll(parts)
    }

    // MARK: - 키리스 워크 (태엽 감기 · 시각 맞추기)

    /// 용두와 바깥으로 나온 스템.
    /// **키리스 워크 본체는 다이얼 쪽에 있어서 이 면(트레인 쪽)에서는 보이지 않는다** —
    /// 안쪽에 그려 넣으면 스템이 기어 트레인을 관통한다.
    static func crownAndStem(_ m: Materials) -> CSG {
        let stemAngle: Float = -34
        let y = wheelY(0) + 0.15
        let base = float4x4.rotateY(-stemAngle)
        return CSG.cylinder(base * .translate(plateRadius + 0.6, y, 0) * .rotateZ(90)
                            * .scale(0.26, 1.5, 0.26), material: m.pinion)
             | gear(teeth: 30, pitchRadius: 1.7, thickness: 1.15, bore: 0.26,
                    crossings: 0, material: m.pinion)
               .transformed(base * .translate(plateRadius + 2.4, y, 0) * .rotateZ(90))
    }

    // MARK: - 페를라주 (원형 결)

    /// 실물은 회전 연마로 파낸 자국이지만, 여기서는 **아주 낮은 원반을 겹쳐 얹어** 같은 인상을 낸다.
    /// 오브젝트 1개 + 인스턴스 수백 개라 구간 한계와 무관하고 비용도 거의 없다.
    static func perlageDisc(_ m: Materials) -> CSG {
        CSG.cylinder(.scale(0.78, 0.5, 0.78), material: m.plate)
    }

    /// 육각 격자로 촘촘히. **높이를 조금씩 다르게** 해야 겹친 윗면이 같은 평면이 되어
    /// 픽셀마다 이기는 쪽이 갈리는 얼룩(스티칭)이 생기지 않는다.
    static var perlagePlacements: [float4x4] {
        var out: [float4x4] = []
        let step: Float = 1.30
        let rows = Int(plateRadius / (step * 0.87)) + 1
        for j in -rows...rows {
            let z = Float(j) * step * 0.87
            let xOff = (j % 2 == 0) ? 0 : step / 2
            let cols = Int(plateRadius / step) + 1
            for i in -cols...cols {
                let x = Float(i) * step + xOff
                let r = (x * x + z * z).squareRoot()
                guard r < plateRadius - 0.6 else { continue }
                // 결정적 유사난수로 높이를 흔든다
                let h = fract(sin(x * 12.9898 + z * 78.233) * 43758.5453)
                // 윗면이 플레이트보다 조금 솟아야 원형 테두리가 빛을 받는다
                out.append(.translate(x, 0.03 - h * 0.020, z) * .scale(1, 0.10, 1))
            }
        }
        return out
    }

    private static func fract(_ v: Float) -> Float { v - v.rounded(.down) }

    // MARK: - 완급침 · 클릭 스프링

    /// 레귤레이터(완급침) — 밸런스 콕 위에서 헤어스프링 유효 길이를 조절하는 팔.
    /// 실물에서 가장 눈에 띄는 미세 부품이라, 없으면 콕이 그냥 판때기로 보인다.
    static func regulator(_ m: Materials) -> CSG {
        let c = balanceCenter
        let y = cockY + bridgeThickness / 2 + 0.24
        // 밸런스 축을 감싸는 링 + 길게 뻗은 지침 + 끝의 미세조정 핀 두 개
        var parts: [CSG] = [
            CSG.cylinder(.translate(c.x, y, c.y) * .scale(1.05, 0.09, 1.05), material: m.bridge)
          - CSG.cylinder(.translate(c.x, y, c.y) * .scale(0.72, 0.4, 0.72), material: m.bridge),
            CSG.roundBox(half: [1.7, 0.075, 0.20], radius: 0.06,
                         .translate(c.x, y, c.y) * .rotateY(-38) * .translate(1.7, 0, 0),
                         material: m.bridge),
        ]
        for s in [-1, 1] as [Float] {
            parts.append(CSG.cylinder(.translate(c.x, y, c.y) * .rotateY(-38)
                                      * .translate(3.05, 0, s * 0.13) * .scale(0.075, 0.24, 0.075),
                                      material: m.blueSteel))
        }
        return CSG.unionAll(parts)
    }

    /// 클릭 스프링 — 클릭을 래칫 휠 쪽으로 눌러 주는 얇은 판스프링.
    /// 짧은 조각 몇 개를 이어 곡선을 만든다.
    static func clickSpring(_ m: Materials) -> CSG {
        let pivot = ratchetCenter + [cosd(-30) * 4.2, sind(-30) * 4.2]
        let y = upperWheelY - 0.02
        var parts: [CSG] = []
        for i in 0..<5 {
            let t0 = Float(i) / 5, t1 = Float(i + 1) / 5
            let a0 = -30 + t0 * 62, a1 = -30 + t1 * 62
            let r0: Float = 4.2 + t0 * 1.5, r1: Float = 4.2 + t1 * 1.5
            let p0 = ratchetCenter + [cosd(a0) * r0, sind(a0) * r0]
            let p1 = ratchetCenter + [cosd(a1) * r1, sind(a1) * r1]
            let d = p1 - p0
            parts.append(CSG.roundBox(half: [simd_length(d) / 2 + 0.03, 0.075, 0.10], radius: 0.05,
                                      .translate((p0.x + p1.x) / 2, y, (p0.y + p1.y) / 2)
                                      * .rotateY(-atan2(d.y, d.x) * 180 / .pi),
                                      material: m.blueSteel))
        }
        parts.append(CSG.cylinder(.translate(pivot.x, y, pivot.y) * .scale(0.30, 0.10, 0.30),
                                  material: m.blueSteel))
        return CSG.unionAll(parts)
    }

    // MARK: - 반복 부품 (오브젝트 1개 + 인스턴스 N개)

    /// 금 샤통 — 보석을 물고 있는 테. 실물 고급기의 상징이고, 붉은 보석 둘레에
    /// 금빛 링이 생기면서 화면이 단숨에 "시계" 로 읽힌다.
    static func chaton(_ m: Materials) -> CSG {
        CSG.cylinder(.scale(0.94, 0.19, 0.94), material: m.chaton)
      - CSG.cylinder(.translate(0, 0.06, 0) * .scale(0.62, 0.16, 0.62), material: m.chaton)
      - CSG.cylinder(.scale(0.30, 0.5, 0.30), material: m.chaton)
    }

    /// 인조 루비 보석 — 가운데가 뚫린 원판
    static func jewel(_ m: Materials) -> CSG {
        CSG.cylinder(.scale(0.60, 0.16, 0.60), material: m.ruby)
      - CSG.cylinder(.scale(0.17, 0.5, 0.17), material: m.ruby)
    }

    /// 블루 스틸 나사 — 머리 + 일자 홈 + 나사부
    static func screw(_ m: Materials) -> CSG {
        let head = CSG.cylinder(.scale(0.42, 0.13, 0.42), material: m.blueSteel)
                 - CSG.box(.translate(0, 0.10, 0) * .scale(0.44, 0.06, 0.09), material: m.blueSteel)
        return head | CSG.cylinder(.translate(0, -0.45, 0) * .scale(0.20, 0.45, 0.20),
                                   material: m.blueSteel)
    }

    /// 보석 자리 — 브리지 구멍마다
    static var jewelPlacements: [float4x4] {
        var out: [float4x4] = []
        // 샤통 안쪽에 살짝 낮게 앉는다
        let drop: Float = 0.24
        for p in [barrel.center, train[1].center] {
            out.append(.translate(p.x, bridgeTopY(barrelBridgeY) - drop, p.y))
        }
        for p in [train[2].center, train[3].center, escape.center] {
            out.append(.translate(p.x, bridgeTopY(bridgeY) - drop, p.y))
        }
        out.append(.translate(balanceCenter.x, bridgeTopY(cockY) - drop, balanceCenter.y))
        out.append(.translate(palletCenter.x, bridgeTopY(cockY) - drop, palletCenter.y))
        // 플레이트 쪽 보석 (아래)
        for p in [train[1].center, train[2].center, train[3].center, escape.center] {
            out.append(.translate(p.x, -0.14, p.y))
        }
        return out
    }

    /// 브리지 윗면 높이. **여기에 맞춰야 샤통·보석이 두께 속에 파묻히지 않는다.**
    static func bridgeTopY(_ y: Float) -> Float { y + bridgeThickness / 2 + 0.16 }

    /// 샤통은 브리지에 박힌 보석에만 (플레이트 쪽 보석은 압입식이라 테가 없다).
    /// 샤통 윗면이 브리지 윗면과 같은 높이가 되도록 앉힌다.
    static var chatonPlacements: [float4x4] {
        let drop: Float = 0.19                       // 샤통 반두께
        return [barrel.center, train[1].center].map {
                   .translate($0.x, bridgeTopY(barrelBridgeY) - drop, $0.y) }
             + [train[2].center, train[3].center, escape.center].map {
                   .translate($0.x, bridgeTopY(bridgeY) - drop, $0.y) }
             + [balanceCenter, palletCenter].map {
                   .translate($0.x, bridgeTopY(cockY) - drop, $0.y) }
    }

    static var screwPlacements: [float4x4] {
        var out: [float4x4] = [
            .translate(barrel.center.x - 3.4, bridgeTopY(barrelBridgeY), barrel.center.y + 2.2),
            .translate(train[1].center.x + 1.0, bridgeTopY(barrelBridgeY), train[1].center.y + 2.9),
            .translate(train[2].center.x + 2.3, bridgeTopY(bridgeY), train[2].center.y + 1.2),
            .translate(palletCenter.x + 3.0, bridgeTopY(cockY), palletCenter.y + 2.4),
        ]
        for i in 0..<3 {
            let a = Float(i) / 3 * 360 + 30
            out.append(.rotateY(a) * .translate(plateRadius - 1.6, 0.06, 0))
        }
        return out
    }

    /// 밸런스 림 나사 — 실제 밸런스처럼 둘레를 따라 박힌다
    static var rimScrewPlacements: [float4x4] {
        (0..<8).map { i in
            let a = Float(i) / 8 * 360
            return float4x4.translate(balanceCenter.x, cockY - 0.42, balanceCenter.y)
                 * .rotateY(a) * .translate(balanceRadius - 0.02, 0, 0) * .rotateZ(90) * .scale(0.55)
        }
    }
}
