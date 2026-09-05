//
//  Bus.swift
//  현대 슈퍼 에어로시티 CNG (서울 지선버스) 를 부품 조립으로 만든 것.
//
//  **로컬 좌표 = 미터.** 실차 치수를 그대로 쓴다:
//  전장 10.64 · 전폭 2.49 · 전고 3.00 m (지붕 CNG 커버까지 3.33), 축간거리 5.40 m,
//  타이어 지름 1.06 m. 장난감처럼 보이는 원인은 대개 비율이라 여기서부터 맞춘다.
//
//      X  길이   앞 = -5.32, 뒤 = +5.32
//      Y  높이   지면 = -1.70, 차체 바닥 = -1.35, 지붕 마루 = +1.30
//      Z  폭     운전석(좌) = +1.245, 승객문(우) = -1.245
//
//  한국은 우측통행이라 승객문은 -z 쪽이다 (앞을 -x 로 보면 오른쪽이 -z).
//
//  **왜 오브젝트를 여덟으로 쪼개나**
//  구간 리스트 한계(CSG_MAX_INTERVALS = 6)는 오브젝트 단위로 적용된다.
//  길이 방향으로 스쳐 가는 레이가 창틀 · 좌석 · 범퍼 · 바퀴를 모두 가로지르면 6구간을 우습게 넘고,
//  넘친 만큼 조용히 사라진다. 그래서 차체 / 창틀 / 유리 / 실내 / 외장띠 / 앞면 / 뒷면 / 바퀴로
//  나누고 같은 변환으로 겹쳐 배치한다. 각 함수 주석에 그 오브젝트의 최악 구간 수를 적어 뒀다.
//

import Foundation
import simd

enum Bus {

    // MARK: - 치수 (미터)

    static let halfLength: Float = 5.32
    static let halfWidth:  Float = 1.245
    static let roofY:      Float = 1.30       // 지붕 마루 (CNG 커버 제외)
    static let floorY:     Float = -1.35      // 차체 바닥(스커트) 밑면
    static let groundY:    Float = -1.70

    /// 차체 모서리 반지름. 평면도 코너이자 지붕 어깨이자 꼭짓점 구면의 반지름 — **하나로 통일**된다.
    /// 크게 잡으면 앞면이 좁아져서 헤드램프·번호판 놓을 자리가 줄어든다.
    static let bodyCorner: Float = 0.45
    static var planCorner: Float { bodyCorner }

    /// 아래쪽 라운드를 차체 밖으로 밀어내는 양. 지붕은 크게 둥글고 바닥은 살짝만 깎이게 한다.
    private static let bodyDrop: Float = 0.18
    static var bodyHalf: SIMD3<Float> { [halfLength, (roofY - floorY) / 2 + bodyDrop, halfWidth] }
    static var bodyCenterY: Float { sideMidY - bodyDrop }
    static var bodyInner: SIMD3<Float> { bodyHalf - SIMD3<Float>(repeating: bodyCorner) }

    static let wheelRadius: Float = 0.53      // 275/70R22.5 ≈ 지름 1.06 m
    static let tireHalfWidth: Float = 0.145
    static var axleY: Float { groundY + wheelRadius }
    static let frontAxleX: Float = -2.85
    static let rearAxleX:  Float = 2.55       // 축간거리 5.40 m

    /// 지면에 닿는 로컬 y. 배치할 때 이 값으로 높이를 맞춘다.
    static var groundOffset: Float { groundY }

    /// 둥근 평면도에서 주어진 x 의 최대 |z|.
    /// 앞뒤 끝에 붙이는 램프·번호판은 이 값 안에 있어야 한다 — 차폭으로 계산하면
    /// 코너가 안으로 말려 들어간 만큼 부품이 허공에 떠 버린다.
    static func halfWidth(atX x: Float) -> Float {
        let d = abs(x) - (halfLength - planCorner)
        guard d > 0 else { return halfWidth }
        let r2 = planCorner * planCorner - d * d
        return r2 > 0 ? (halfWidth - planCorner) + r2.squareRoot() : 0
    }

    /// 옆면 볼록의 최대 지점 (차체 높이 중간)
    static var sideMidY: Float { (roofY + floorY) / 2 }

    /// 실내 바닥
    static let cabinBottom: Float = -1.20

    /// 차체 벽 두께. 실내는 둥근 상자를 이만큼 안으로 줄인 것 (= 반지름만 줄어든 둥근 상자).
    static let wallThickness: Float = 0.085

    /// 실내의 주어진 (x, y) 에서의 최대 |z|.
    /// **실내에 넣는 상자는 이 값 안에 있어야 한다** — 앞뒤 코너가 말려 들어가는 만큼 좁아지므로
    /// 차폭으로 계산하면 상자가 코너를 뚫고 나와 차체 밖에 판이 서 있는 것처럼 보인다.
    static func cabinHalfWidth(atX x: Float, y: Float) -> Float {
        let r = bodyCorner - wallThickness
        let b = bodyInner
        let dx = max(abs(x) - b.x, 0)
        let dy = max(abs(y - bodyCenterY) - b.y, 0)
        let s = r * r - dx * dx - dy * dy
        return b.z + (s > 0 ? s.squareRoot() : 0)
    }

    /// 실내 형상(벽 두께만큼 줄인 둥근 상자 ∩ 바닥 위) 안쪽인가.
    /// 실내에 넣는 부품의 AABB 꼭짓점이 전부 여기 들어가야 한다.
    static func isInsideCabin(_ p: SIMD3<Float>, margin: Float = 0) -> Bool {
        guard p.y >= cabinBottom - margin else { return false }
        let q = simd_abs(p - SIMD3<Float>(0, bodyCenterY, 0)) - bodyInner
        let d = simd_length(simd_max(q, SIMD3<Float>(repeating: 0)))
        return d <= (bodyCorner - wallThickness) + margin
    }

    /// 차체(껍데기) 안쪽인가
    static func isInsideBody(_ p: SIMD3<Float>, margin: Float = 0) -> Bool {
        guard p.y >= floorY - margin, p.y <= roofY + margin else { return false }
        let q = simd_abs(p - SIMD3<Float>(0, bodyCenterY, 0)) - bodyInner
        return simd_length(simd_max(q, SIMD3<Float>(repeating: 0))) <= bodyCorner + margin
    }

    /// 표면에 붙는 부품(램프·몰딩·간판)이 차체에서 **떨어져 붕 떠 있는지** 검사한다.
    /// 앞뒤 코너가 말려 들어가는 만큼 고정 좌표로 둔 부품은 허공에 뜬다.
    ///
    /// 판정은 **연결성**으로 한다: 차체에 닿았거나, 이미 붙은 다른 부품과 겹치면 붙은 것이다.
    /// 사이드미러처럼 팔에 매달린 구조(차체 ← 팔 ← 기둥 ← 거울)를 오탐하지 않으려면 이래야 한다.
    static func floatingViolations(_ m: Materials) -> [String] {
        var out: [String] = []
        // 앞뒤 끝 부품은 범퍼(차체보다 3.5cm 바깥) 위에 붙으므로 여유를 더 준다
        for (name, obj, margin) in [("trim", trim(m), Float(0.02)),
                                    ("frontEnd", frontEnd(m), Float(0.09)),
                                    ("rearEnd", rearEnd(m), Float(0.09))] {
            let boxes = obj.partBounds()
            // 1) 차체에 직접 닿은 부품
            var attached = boxes.map { bb -> Bool in
                for a in 0...3 {
                    for b in 0...3 {
                        for c in 0...3 {
                            let f = SIMD3<Float>(Float(a), Float(b), Float(c)) / 3
                            if isInsideBody(bb.min + (bb.max - bb.min) * f, margin: margin) {
                                return true
                            }
                        }
                    }
                }
                return false
            }
            // 2) 붙은 부품에 겹치면 그것도 붙은 것 — 변화가 없을 때까지 전파
            var changed = true
            while changed {
                changed = false
                for i in boxes.indices where !attached[i] {
                    for j in boxes.indices where attached[j] {
                        let a = boxes[i], b = boxes[j]
                        let overlap = all(a.min .<= b.max + 0.01) && all(b.min .<= a.max + 0.01)
                        if overlap { attached[i] = true; changed = true; break }
                    }
                }
            }
            for i in boxes.indices where !attached[i] {
                let ctr = (boxes[i].min + boxes[i].max) / 2
                out.append(String(format: "%@ 부품 %d 이 차체에서 떠 있음: 중심 (%.2f, %.2f, %.2f)",
                                  name, i, ctr.x, ctr.y, ctr.z))
            }
        }
        return out
    }

    /// 실내 부품이 둥근 차체를 뚫고 나가는지 검사한다.
    /// **각진 상자를 둥근 껍데기에 넣으면 코너가 말려 들어간 만큼 튀어나온다** —
    /// 이 저장소에서 지붕·뒤 코너·엔진실로 세 번 겪었다. 눈으로 찾지 말고 여기서 잡는다.
    static func interiorViolations(_ m: Materials) -> [String] {
        var out: [String] = []
        for (name, obj) in [("interior", interior(m)), ("seats", seats(m))] {
            for (i, bb) in obj.partBounds().enumerated() {
                var worst: SIMD3<Float>? = nil
                for x in [bb.min.x, bb.max.x] {
                    for y in [bb.min.y, bb.max.y] {
                        for z in [bb.min.z, bb.max.z] {
                            let p = SIMD3<Float>(x, y, z)
                            if !isInsideCabin(p, margin: 0.02) { worst = p }
                        }
                    }
                }
                if let w = worst {
                    out.append(String(format: "%@ 부품 %d 이 차체 밖으로: (%.2f, %.2f, %.2f)",
                                      name, i, w.x, w.y, w.z))
                }
            }
        }
        return out
    }

    /// 주어진 (x, z) 에서의 지붕 바깥면 높이.
    /// 둥근 상자는 안쪽 상자에서 반지름 r 만큼 부풀린 것이므로 **두 축 모두** 고려해야 한다 —
    /// z 만 보면 앞뒤 끝(구면 꼭짓점)에서 실제보다 높게 나온다.
    static func roofTop(atX x: Float, z: Float) -> Float {
        let b = bodyInner
        let dx = max(abs(x) - b.x, 0), dz = max(abs(z) - b.z, 0)
        let s = bodyCorner * bodyCorner - dx * dx - dz * dz
        return bodyCenterY + b.y + (s > 0 ? s.squareRoot() : 0)
    }

    // 창 띠 — 실측 비율(전고의 45~78%)에 맞춘다
    static let windowBottom: Float = -0.06
    static let windowTop:    Float = 0.78
    private static var windowMidY:  Float { (windowBottom + windowTop) / 2 }
    private static var windowHalfY: Float { (windowTop - windowBottom) / 2 }

    /// 승객문 (오른쪽 = -z). 앞문은 앞축 앞, 중문은 축 사이.
    private static let doors: [(x: Float, half: Float)] = [(-4.20, 0.55), (0.60, 0.62)]
    private static let doorBottom: Float = -1.28
    private static var doorMidY:  Float { (doorBottom + windowTop) / 2 }
    private static var doorHalfY: Float { (windowTop - doorBottom) / 2 }

    /// 창 띠 구간 (시작 x, 끝 x).
    /// 왼쪽(운전석)은 운전석 쪽창 + 통유리, 오른쪽은 문 두 짝 사이로 두 장.
    private static let leftBands:  [(Float, Float)] = [(-4.85, -3.90), (-3.30, 4.75)]
    private static let rightBands: [(Float, Float)] = [(-3.30, -0.30), (1.50, 4.75)]

    /// 휠 아치 (중심 x, z 중심, z 반폭). 뒤는 복륜이라 더 넓다.
    private static var arches: [(x: Float, zc: Float, zh: Float)] {
        [(frontAxleX, 0.98, 0.42), (rearAxleX, 0.84, 0.58)]
    }
    private static let archRadius: Float = 0.64   // 타이어 0.53 + 여유 0.11

    // 앞유리 — 실차는 범퍼 바로 위부터 지붕 근처까지 올라오는 대형 1매 유리다.
    // (지면 기준 1.50 ~ 2.75 m)
    private static let windshieldMidY:  Float = 0.475
    private static let windshieldHalfY: Float = 0.575
    private static let windshieldHalfZ: Float = 0.84
    /// 행선판은 별도 외부 패널이 아니라 **앞유리 안쪽 위**에 붙어 있다
    private static let signMidY: Float = 0.87
    private static let signHalfY: Float = 0.155

    struct Materials {
        let paint: Int          // 지선버스 초록
        let black: Int          // 창틀 · 범퍼 하단 · 고무
        /// 실내 벽면. 차집합의 절단면은 자르는 쪽 재질을 물려받으므로 이게 실내 색이 된다.
        /// 검게 두면 앞유리 너머가 새까매서 유리가 아니라 구멍처럼 보인다.
        let cabin: Int
        let stripe: Int         // 창 아래 흰 띠
        let glass: Int          // 짙게 선팅한 측면 유리
        let clearGlass: Int     // 앞유리
        let tire: Int
        let rim: Int
        let chrome: Int
        let seat: Int
        let headLight: Int
        let amber: Int          // 방향지시등 · LED 행선판
        let tailLight: Int
        let plate: Int          // 노란 번호판
        let rail: Int           // 실내 손잡이 봉 — 한국 버스는 노란색이다
        let acCover: Int        // 지붕 에어컨
    }

    // MARK: - 차체   (길이 방향 최악 5구간)

    static func body(_ m: Materials) -> CSG {
        let L = halfLength, W = halfWidth

        // 옆면을 아주 살짝 볼록하게 만드는 대반경 원기둥 (축 = X, 좌우 하나씩).
        // **완전한 평면이면 법선이 일정해서 빛이 전혀 흐르지 않는다** — 아무리 조명을 잘 줘도
        // 큰 옆면이 단색 판때기로 보인다. 반경 22 m 면 위아래 끝에서 4 cm 들어가는 정도라
        // 실루엣은 그대로면서 지평선 반사가 띠처럼 지나간다.
        let sideR: Float = 22
        func sideBulge(_ sign: Float) -> CSG {
            CSG.cylinder(.translate(0, sideMidY, sign * -(sideR - W)) * .rotateZ(90)
                         * .scale(sideR, L + 0.2, sideR), material: m.paint)
        }

        // 평면도(위에서)와 옆모습(측면) 양쪽을 둥근 사각형으로 잘라내면
        // 앞뒤 · 위아래 모서리가 전부 부드러워진다. roundedBox(27부품) 없이 부품 2개로 끝난다.
        // **진짜 둥근 상자 하나**. 세 방향 윤곽을 교차하던 예전 방식은 모서리는 둥글어도
        // 세 면이 만나는 꼭짓점이 구면이 아니라(원기둥 두 개의 교선) 대각선 능선이 남았다.
        // bodyDrop 만큼 아래로 키워 달아서 바닥 라운드는 대부분 차체 밖에서 일어나게 하고,
        // 아래는 상자로 잘라 평평하게 만든다 (범퍼·휠 아치가 붙는 면).
        let hull = CSG.roundBox(half: bodyHalf, radius: bodyCorner,
                                .translate(0, bodyCenterY, 0), material: m.paint)
                 & CSG.box(.translate(0, (roofY + 0.2 + floorY) / 2, 0)
                           * .scale(L + 0.2, (roofY + 0.2 - floorY) / 2, W + 0.2), material: m.paint)
                 & sideBulge(1) & sideBulge(-1)

        // 실내를 파내는 형상은 **껍데기와 같은 모양이어야 한다.**
        // 각진 상자로 파면 둥근 지붕·코너 밖으로 상자 모서리가 삐져나와 껍데기에 슬롯이 뚫린다
        // (예전에 지붕에서, 그다음 뒤 코너에서 실제로 겪었다).
        //
        // 둥근 상자를 두께 t 만큼 안으로 줄이면 **또 하나의 둥근 상자**가 된다
        // (안쪽 상자는 그대로, 반지름만 r - t). 그래서 벽 두께가 어디서나 정확히 t 로 일정하다.
        let cabin = CSG.roundBox(half: bodyHalf - SIMD3<Float>(repeating: wallThickness),
                                 radius: bodyCorner - wallThickness,
                                 .translate(0, bodyCenterY, 0), material: m.cabin)
                  & CSG.box(.translate(0, (roofY + 1 + cabinBottom) / 2, 0)
                            * .scale(L, (roofY + 1 - cabinBottom) / 2, W), material: m.cabin)

        var cuts: [CSG] = []

        // 측면 창 띠 — 기둥은 따로 세우고 여기서는 길게 한 번에 뚫는다.
        // **실차 창은 모서리가 둥글다.** roundedPanel 이면 각진 상자와 같은 부품 1개다.
        for (bands, sign) in [(leftBands, Float(1)), (rightBands, Float(-1))] {
            for (x0, x1) in bands {
                cuts.append(CSG.roundedPanel(halfX: (x1 - x0) / 2, halfY: windowHalfY, halfZ: 0.3,
                                             corner: min(0.13, (x1 - x0) / 2 - 0.01),
                                             .translate((x0 + x1) / 2, windowMidY, sign * W),
                                             material: m.black))
            }
        }
        // 승객문
        for d in doors {
            cuts.append(CSG.roundedPanel(halfX: d.half, halfY: doorHalfY, halfZ: 0.3, corner: 0.10,
                                         .translate(d.x, doorMidY, -W), material: m.black))
        }
        // 앞유리 — 실차처럼 크고 살짝 뒤로 젖힌다
        cuts.append(CSG.roundedPanel(halfX: 0.35, halfY: windshieldHalfY, halfZ: windshieldHalfZ,
                                     corner: 0.16,
                                     .translate(-L + 0.05, windshieldMidY, 0),
                                     material: m.black))
        // 뒷유리 — 엔진실 위쪽만
        cuts.append(CSG.roundedPanel(halfX: 0.35, halfY: 0.34, halfZ: 0.82, corner: 0.14,
                                     .translate(L, 0.55, 0), material: m.black))

        // 휠 아치 — 양옆만 파낸다. 폭 전체를 관통시키면 바닥이 통째로 뚫린다.
        for a in arches {
            for s in [-1, 1] as [Float] {
                cuts.append(CSG.cylinder(.translate(a.x, axleY, s * a.zc) * .rotateX(90)
                                         * .scale(archRadius, a.zh, archRadius), material: m.black))
            }
        }

        return (hull - cabin) - CSG.unionAll(cuts)
    }

    // MARK: - 창틀   (길이 방향 최악 5구간 = 왼쪽 기둥 5개)

    /// 실차의 창은 **검은 프레임 띠 하나로 보인다** — 기둥도 검고, 위아래로 검은 레일이 지난다.
    /// 차체와 분리해야 구간 수가 안 터진다.
    static func windowFrames(_ m: Materials) -> CSG {
        let W = halfWidth
        var parts: [CSG] = []

        for (bands, sign) in [(leftBands, Float(1)), (rightBands, Float(-1))] {
            for (x0, x1) in bands {
                // 기둥 — 1.4 m 남짓 간격
                let count = max(0, Int(((x1 - x0) / 1.45).rounded()) - 1)
                if count > 0 {
                    for i in 1...count {
                        let x = x0 + (x1 - x0) * Float(i) / Float(count + 1)
                        parts.append(CSG.box(.translate(x, windowMidY, sign * (W - 0.02))
                                             * .scale(0.07, windowHalfY, 0.05), material: m.black))
                    }
                }
                // 창 둘레 — 둥근 모서리 테두리 (창 구멍과 같은 코너 반지름)
                let cr = min(0.13, (x1 - x0) / 2 - 0.01)
                parts.append(CSG.roundedPanel(halfX: (x1 - x0) / 2 + 0.04,
                                              halfY: windowHalfY + 0.04, halfZ: 0.016,
                                              corner: cr + 0.035,
                                              .translate((x0 + x1) / 2, windowMidY, sign * (W + 0.004)),
                                              material: m.black)
                           - CSG.roundedPanel(halfX: (x1 - x0) / 2 - 0.004,
                                              halfY: windowHalfY - 0.004, halfZ: 0.06,
                                              corner: cr,
                                              .translate((x0 + x1) / 2, windowMidY, sign * (W + 0.004)),
                                              material: m.black))
            }
        }
        /// 가운데를 파낸 **둥근 테두리**. 속이 찬 판으로 두면 유리를 통째로 덮어 새까맣게 보인다.
        func frame(_ t: float4x4, halfX: Float, halfY: Float, halfZ: Float,
                   corner: Float, border: Float) -> CSG {
            CSG.roundedPanel(halfX: halfX, halfY: halfY, halfZ: halfZ,
                             corner: corner + border, t, material: m.black)
          - CSG.roundedPanel(halfX: halfX - border, halfY: halfY - border, halfZ: halfZ * 3,
                             corner: corner, t, material: m.black)
        }

        // 문틀 + 두 짝 사이 세로 분할선
        for d in doors {
            parts.append(frame(.translate(d.x, doorMidY, -(W + 0.004)),
                               halfX: d.half + 0.03, halfY: doorHalfY + 0.03, halfZ: 0.016,
                               corner: 0.10, border: 0.055))
            parts.append(CSG.roundedPanel(halfX: 0.035, halfY: doorHalfY - 0.05, halfZ: 0.035,
                                          corner: 0.03, .translate(d.x, doorMidY, -(W - 0.01)),
                                          material: m.black))
        }
        // 앞유리 둘레 — 검은 고무 몰딩
        parts.append(frame(.translate(-halfLength + 0.03, windshieldMidY, 0) * .rotateY(90),
                           halfX: windshieldHalfZ + 0.05, halfY: windshieldHalfY + 0.05,
                           halfZ: 0.022, corner: 0.16, border: 0.07))
        return CSG.unionAll(parts)
    }

    // MARK: - 유리   (길이 방향 최악 4구간)

    static func glazing(_ m: Materials) -> CSG {
        let L = halfLength, W = halfWidth
        let t: Float = 0.02

        var panes: [CSG] = []
        for (bands, sign) in [(leftBands, Float(1)), (rightBands, Float(-1))] {
            for (x0, x1) in bands {
                panes.append(CSG.roundedPanel(halfX: (x1 - x0) / 2, halfY: windowHalfY, halfZ: t,
                                              corner: min(0.13, (x1 - x0) / 2 - 0.01),
                                              .translate((x0 + x1) / 2, windowMidY, sign * (W - t)),
                                              material: m.glass))
            }
        }
        for d in doors {
            panes.append(CSG.roundedPanel(halfX: d.half - 0.05, halfY: doorHalfY - 0.08, halfZ: t,
                                          corner: 0.08,
                                          .translate(d.x, doorMidY + 0.04, -(W - t)),
                                          material: m.glass))
        }
        panes.append(CSG.roundedPanel(halfX: windshieldHalfZ - 0.02, halfY: windshieldHalfY - 0.02,
                                      halfZ: t, corner: 0.14,
                                      .translate(-L + 0.07, windshieldMidY, 0) * .rotateY(90),
                                      material: m.clearGlass))
        panes.append(CSG.roundedPanel(halfX: 0.80, halfY: 0.32, halfZ: t, corner: 0.12,
                                      .translate(L - 0.03, 0.55, 0) * .rotateY(90),
                                      material: m.glass))
        return CSG.unionAll(panes)
    }

    // MARK: - 실내   (길이 방향 최악 3구간)

    /// 뒷바퀴 위 단(段) 높이. 좌석은 여기보다 위에 있어야 휠 아치 구멍으로 안 비친다.
    static var rearPlatformY: Float { axleY + archRadius }

    /// 좌석 열 x 위치 (뒷바퀴 위 단). 실차 좌석 피치 0.8 m.
    private static let seatRowX: [Float] = [1.55, 2.40, 3.25]
    /// 통로 반폭 → 좌석 묶음 중심 z
    private static let seatZ: Float = 0.70
    private static let seatHalfZ: Float = 0.42

    /// 운전석 · 봉 · 엔진실 · 뒷단. 좌석은 `seats` 로 분리했다 (구간 수).
    static func interior(_ m: Materials) -> CSG {
        let W = halfWidth
        var parts: [CSG] = []

        // 뒷바퀴 위 단 — 좌석을 올려놓는 바닥
        let platHalfY = (rearPlatformY - cabinBottom) / 2
        parts.append(CSG.box(.translate(2.6, cabinBottom + platHalfY, 0)
                             * .scale(1.9, platHalfY, W - 0.12), material: m.black))
        // 후방 엔진실 — 없으면 뒷유리로 반대쪽이 훤히 비친다.
        // **뒤 코너가 말려 들어가는 만큼 안쪽으로 물려야 한다** — 그냥 두면 검은 상자가
        // 코너를 뚫고 나와 차체 밖에 검은 판이 서 있는 것처럼 보인다.
        let bayX: Float = 4.25, bayHalfX: Float = 0.65
        let bayHalfZ = cabinHalfWidth(atX: bayX + bayHalfX, y: -0.55) - 0.05
        parts.append(CSG.box(.translate(bayX, -0.55, 0) * .scale(bayHalfX, 0.65, bayHalfZ),
                             material: m.black))
        // 손잡이 봉 — **실차는 노란색**이고 선팅 너머로도 뚜렷하게 보인다.
        // 천장 레일 좌우 + 창 옆 가로 레일 + 세로 봉.
        for s in [-1, 1] as [Float] {
            parts.append(CSG.cylinder(.translate(0.4, 0.62, s * 0.52) * .rotateZ(90)
                                      * .scale(0.026, 4.6, 0.026), material: m.rail))
            parts.append(CSG.cylinder(.translate(0.6, -0.02, s * (W - 0.20)) * .rotateZ(90)
                                      * .scale(0.022, 4.2, 0.022), material: m.rail))
        }
        for x in [-2.6, -1.4, -0.2, 1.0, 2.2, 3.4] as [Float] {
            parts.append(CSG.cylinder(.translate(x, -0.15, 0.44) * .scale(0.026, 1.05, 0.026),
                                      material: m.rail))
        }
        // 운전석 — 칸막이 · 계기판 · 핸들 · 시트
        parts.append(CSG.roundedPanel(halfX: 0.40, halfY: 0.76, halfZ: 0.04, corner: 0.10,
                                      .translate(-3.55, -0.40, 0.72) * .rotateY(90),
                                      material: m.black))
        parts.append(CSG.roundedRectPrism(halfX: 0.40, halfZ: 0.50, corner: 0.12, halfY: 0.10,
                                          .translate(-4.60, -0.62, 0.60), material: m.black))
        parts.append(CSG.torus(.translate(-4.40, -0.34, 0.60) * .rotateZ(66) * .scale(0.24),
                               material: m.black))
        parts += seatUnit(x: -4.05, z: 0.62, floorY: -1.20, halfZ: 0.26, m)

        return CSG.unionAll(parts)
    }

    // MARK: - 좌석   (길이 방향 최악 4구간 = 좌석 3열 + 맨 뒷줄)

    /// 좌석 한 묶음: 방석 + 등받이 + 다리. 전부 모서리를 둥글린다.
    private static func seatUnit(x: Float, z: Float, floorY: Float, halfZ: Float,
                                 _ m: Materials) -> [CSG] {
        let seatH: Float = 0.44           // 바닥에서 방석 윗면까지
        return [
            // 방석 · 등받이 모두 진짜 둥근 상자 — 좌석은 모서리가 전부 둥근 물건이다
            CSG.roundBox(half: [0.23, 0.055, halfZ], radius: 0.05,
                         .translate(x, floorY + seatH, z), material: m.seat),
            CSG.roundBox(half: [0.045, 0.27, halfZ], radius: 0.04,
                         .translate(x + 0.20, floorY + seatH + 0.29, z) * .rotateZ(-7),
                         material: m.seat),
            // 다리
            CSG.cylinder(.translate(x, floorY + seatH * 0.5, z) * .scale(0.045, seatH * 0.5, 0.045),
                         material: m.chrome),
        ]
    }

    /// 승객 좌석. 실내와 나눠 둬야 길이 방향 레이가 등받이를 줄줄이 지나며 구간을 넘기지 않는다.
    static func seats(_ m: Materials) -> CSG {
        let W = halfWidth
        var parts: [CSG] = []

        // 뒷바퀴 위 단의 2인 좌석 3열 × 좌우
        for x in seatRowX {
            for s in [-1, 1] as [Float] {
                parts += seatUnit(x: x, z: s * seatZ, floorY: rearPlatformY,
                                  halfZ: seatHalfZ, m)
            }
        }
        // 맨 뒷줄 — 엔진실 위 벤치
        parts.append(CSG.roundedRectPrism(halfX: 0.42, halfZ: W - 0.22, corner: 0.10, halfY: 0.055,
                                          .translate(4.45, 0.24, 0), material: m.seat))
        parts.append(CSG.roundedPanel(halfX: W - 0.22, halfY: 0.26, halfZ: 0.05, corner: 0.10,
                                      .translate(4.85, 0.52, 0) * .rotateZ(-7) * .rotateY(90),
                                      material: m.seat))
        // 앞바퀴 뒤 세로 벤치 (저상 구간, 운전석 쪽).
        // **휠 아치 x 범위(축 ± 아치반지름)를 피해야** 아치 구멍으로 비치지 않는다.
        parts.append(CSG.roundedRectPrism(halfX: 0.88, halfZ: 0.24, corner: 0.08, halfY: 0.055,
                                          .translate(-1.20, -0.76, W - 0.36), material: m.seat))
        parts.append(CSG.roundedPanel(halfX: 0.88, halfY: 0.26, halfZ: 0.05, corner: 0.09,
                                      .translate(-1.20, -0.48, W - 0.13), material: m.seat))
        return CSG.unionAll(parts)
    }

    // MARK: - 외장 띠 · 지붕   (길이 방향 최악 4구간)

    static func trim(_ m: Materials) -> CSG {
        let L = halfLength, W = halfWidth
        var parts: [CSG] = []

        /// 차체 평면도를 그대로 따라가는 띠.
        /// **직선 상자로 두면 둥근 앞뒤 코너에서 밖으로 삐져나온다.**
        func band(y: Float, halfY: Float, out: Float, material: Int) -> CSG {
            CSG.roundedRectPrism(halfX: L + out, halfZ: W + out, corner: planCorner + out,
                                 halfY: halfY, .translate(0, y, 0), material: material)
        }

        // 창 아래 흰 띠 (실차의 은색 몰딩)
        // 앞면에서는 앞유리 **아래**를 지나가야 한다 — 겹치면 유리를 가로지르는 흰 줄이 생긴다
        parts.append(band(y: windowBottom - 0.17, halfY: 0.045, out: 0.010, material: m.stripe))
        // 범퍼 — 검은 고무. 앞뒤 끝만 잘라내 코너를 감싼다.
        let bumper = band(y: floorY + 0.16, halfY: 0.20, out: 0.035, material: m.black)
        for x in [-L, L] as [Float] {
            parts.append(bumper & CSG.box(.translate(x, floorY + 0.16, 0)
                                          * .scale(0.62, 0.25, W + 0.2), material: m.black))
        }
        // 사이드 스커트 — 축 사이에만 (휠 아치를 가로지르면 안 된다)
        parts.append(CSG.box(.translate(-0.15, floorY + 0.07, 0) * .scale(2.4, 0.05, W + 0.012),
                             material: m.black))

        // 지붕 CNG 가스탱크 커버 — 이 차의 가장 큰 특징. 앞쪽 2/3 를 덮는 길고 둥근 융기.
        // 지붕 CNG 가스탱크 커버 — 차체와 같은 언어(진짜 둥근 상자)로.
        // 앞 끝은 x = -3.4 정도. 더 앞으로 오면 앞유리 위로 나와 실차에 없는 눈썹이 된다.
        let cngHalfX: Float = 2.70, cngX: Float = -0.70, cngTop = roofY + 0.23
        parts.append(CSG.roundBox(half: [cngHalfX, 0.40, 0.86], radius: 0.18,
                                  .translate(cngX, cngTop - 0.40, 0), material: m.paint))
        // 지붕 에어컨 — 커버 뒤쪽에 따로
        parts.append(CSG.roundBox(half: [1.15, 0.24, 0.80], radius: 0.16,
                                  .translate(3.35, roofY + 0.02, 0), material: m.acCover))

        // 사이드미러 — A필러에서 뻗은 팔 + 큰 거울
        // 사이드미러. **차체가 앞·위로 말려 들어가는 지점보다 뒤에 달아야 한다** —
        // 앞 코너(|x| > bodyInner.x)에 두면 팔 뿌리가 허공에 뜬다.
        for s in [-1, 1] as [Float] {
            let mx = -L + 0.47                       // 앞 코너가 시작되기 직전
            parts.append(CSG.cylinder(.translate(mx, 0.98, s * (W + 0.12)) * .rotateX(90)
                                      * .scale(0.028, 0.20, 0.028), material: m.black))
            parts.append(CSG.cylinder(.translate(mx, 0.82, s * (W + 0.28))
                                      * .scale(0.028, 0.20, 0.028), material: m.black))
            parts.append(CSG.roundedPanel(halfX: 0.10, halfY: 0.22, halfZ: 0.035, corner: 0.045,
                                          .translate(mx, 0.60, s * (W + 0.30)) * .rotateY(s * 16 + 90),
                                          material: m.black))
        }
        // 측면 표시등 (앞 호박색 / 뒤 적색)
        for (x, mat) in [(Float(-3.60), m.amber), (Float(-0.90), m.amber), (Float(3.95), m.tailLight)] {
            for s in [-1, 1] as [Float] {
                parts.append(CSG.roundedPanel(halfX: 0.12, halfY: 0.06, halfZ: 0.02, corner: 0.025,
                                              .translate(x, -0.92, s * (W + 0.012)), material: mat))
            }
        }
        // 뒤쪽 엔진 점검구 · 연료 주입구 — 밋밋한 하부를 갈라 준다
        parts.append(CSG.roundedPanel(halfX: 0.55, halfY: 0.34, halfZ: 0.015, corner: 0.07,
                                      .translate(4.05, -0.62, -(W + 0.010)), material: m.black))
        parts.append(CSG.roundedPanel(halfX: 0.22, halfY: 0.22, halfZ: 0.015, corner: 0.06,
                                      .translate(-1.85, -0.72, W + 0.010), material: m.black))
        return CSG.unionAll(parts)
    }

    // MARK: - 앞면   (길이 방향 최악 3구간 — 전부 앞쪽에 몰려 있다)

    static func frontEnd(_ m: Materials) -> CSG {
        let L = halfLength
        let faceX = -L + 0.02
        var parts: [CSG] = []

        // LED 행선판 — **앞유리 안쪽**. 실차는 밖에 붙은 패널이 아니라 유리 뒤 전광판이다.
        // 실내(cabin 앞면 x = -(L-0.10))보다 뒤에 둬야 유리 너머로 보인다.
        // rotateY(90) 를 빼면 판이 X 방향으로 누워 차체 안에 파묻힌다 (화면에서 사라진다)
        parts.append(CSG.roundedPanel(halfX: windshieldHalfZ - 0.06, halfY: signHalfY + 0.03,
                                      halfZ: 0.02, corner: 0.05,
                                      .translate(-L + 0.16, signMidY, 0) * .rotateY(90),
                                      material: m.black))
        parts.append(CSG.roundedPanel(halfX: windshieldHalfZ - 0.28, halfY: signHalfY, halfZ: 0.015,
                                      corner: 0.03,
                                      .translate(-L + 0.13, signMidY, -0.14) * .rotateY(90),
                                      material: m.amber))

        // 램프 자리는 **그 x 에서의 실제 반폭**에서 역산한다.
        // 평면도 코너를 키우면 앞면이 좁아져서, 고정 좌표로 두면 램프가 차체 밖으로 떠 버린다.
        let edge = halfWidth(atX: faceX) - 0.03
        let amberHalf: Float = 0.05, lampHalf: Float = 0.235, lampGap: Float = 0.02
        let amberZ = edge - amberHalf
        let lampZ = amberZ - amberHalf - lampGap - lampHalf

        // 앞이 -x 이므로 **렌즈의 앞면 x 가 베젤보다 작아야(더 앞이어야)** 가려지지 않는다.
        // 그리고 두 앞면이 같은 평면이면 픽셀마다 어느 부품이 이기는지 갈려 흑백 얼룩(스티칭)이 생긴다.
        let bezelX = faceX + 0.03, lensX = faceX          // 앞면 차이 0.04
        let clusterLo = lampZ - lampHalf, clusterHi = amberZ + amberHalf
        let bezelZ = (clusterLo + clusterHi) / 2
        let bezelHalf = (clusterHi - clusterLo) / 2 + 0.025

        for s in [-1, 1] as [Float] {
            // 헤드램프 — 실차는 앞면 **아래 모서리**에 크게 박혀 있고, 바깥쪽에 세로 방향지시등이 붙는다
            parts.append(CSG.roundedPanel(halfX: bezelHalf, halfY: 0.235, halfZ: 0.04, corner: 0.08,
                                          .translate(bezelX, -0.82, s * bezelZ) * .rotateY(90),
                                          material: m.black))
            parts.append(CSG.roundedPanel(halfX: lampHalf, halfY: 0.20, halfZ: 0.05, corner: 0.07,
                                          .translate(lensX, -0.82, s * lampZ) * .rotateY(90),
                                          material: m.headLight))
            parts.append(CSG.roundedPanel(halfX: amberHalf, halfY: 0.20, halfZ: 0.05, corner: 0.03,
                                          .translate(lensX, -0.82, s * amberZ) * .rotateY(90),
                                          material: m.amber))
            // 램프 안쪽으로 뻗는 크롬 윙
            parts.append(CSG.roundedPanel(halfX: 0.30, halfY: 0.060, halfZ: 0.045, corner: 0.028,
                                          .translate(faceX + 0.01, -0.50, s * (lampZ - 0.26)) * .rotateY(90),
                                          material: m.chrome))
            // 안개등 — 범퍼보다 앞으로 내야 보인다
            parts.append(CSG.cylinder(.translate(-L - 0.06, -1.20, s * 0.62) * .rotateZ(90)
                                      * .scale(0.075, 0.05, 0.075), material: m.headLight))
            // 지붕 앞 코너 마커등 (실차의 주황 표시등)
            parts.append(CSG.sphere(.translate(-L + 0.30,
                                               roofTop(atX: -L + 0.30, z: halfWidth - 0.20) - 0.02,
                                               s * (halfWidth - 0.20))
                                    * .scale(0.075, 0.06, 0.075), material: m.amber))
            // 와이퍼
            parts.append(CSG.cylinder(.translate(faceX - 0.05, 0.02, s * 0.40) * .rotateX(72)
                                      * .scale(0.022, 0.34, 0.022), material: m.black))
        }
        // 현대 엠블럼
        parts.append(CSG.sphere(.translate(faceX + 0.015, -0.52, 0) * .scale(0.06, 0.115, 0.20),
                                material: m.chrome))
        // 노란 번호판
        parts.append(CSG.roundedPanel(halfX: 0.24, halfY: 0.11, halfZ: 0.03, corner: 0.03,
                                      .translate(-L - 0.07, -1.18, -0.20) * .rotateY(90),
                                      material: m.plate))
        return CSG.unionAll(parts)
    }

    // MARK: - 뒷면   (길이 방향 최악 3구간)

    static func rearEnd(_ m: Materials) -> CSG {
        let L = halfLength
        let faceX = L - 0.02
        let z = halfWidth(atX: faceX) - 0.22
        var parts: [CSG] = []

        for s in [-1, 1] as [Float] {
            // 세로형 테일램프: 적색 · 호박색 · 후진등
            for (y, hy, mat) in [(Float(-0.42), Float(0.15), m.tailLight),
                                 (Float(-0.70), Float(0.11), m.amber),
                                 (Float(-0.90), Float(0.07), m.headLight)] {
                parts.append(CSG.roundedPanel(halfX: 0.17, halfY: hy, halfZ: 0.05, corner: 0.04,
                                              .translate(faceX, y, s * z) * .rotateY(90),
                                              material: mat))
            }
        }
        // 엔진 통풍 그릴
        parts.append(CSG.box(.translate(faceX, -0.60, 0)
                             * .scale(0.04, 0.26, halfWidth(atX: faceX) - 0.55), material: m.black))
        // 번호판
        parts.append(CSG.roundedPanel(halfX: 0.24, halfY: 0.11, halfZ: 0.03, corner: 0.03,
                                      .translate(L + 0.07, -1.10, 0.22) * .rotateY(90),
                                      material: m.plate))
        return CSG.unionAll(parts)
    }

    // MARK: - 바퀴 (오브젝트 1개 + 인스턴스 6개: 앞 2 + 뒤 복륜 4)

    static func wheel(_ m: Materials) -> CSG {
        // ring 은 바깥/안쪽 반지름 비가 0.6 인 고리 — 타이어 단면 그대로다
        var parts: [CSG] = [
            CSG.ring(.scale(wheelRadius, tireHalfWidth, wheelRadius), material: m.tire)
                .transformed(.rotateX(90)),
            CSG.cylinder(.rotateX(90) * .scale(wheelRadius * 0.66, tireHalfWidth * 0.86,
                                               wheelRadius * 0.66), material: m.rim),
            CSG.cylinder(.rotateX(90) * .scale(0.13, tireHalfWidth * 1.02, 0.13), material: m.rim),
        ]
        // 휠 너트 8개 — 실차 휠의 인상을 만드는 디테일
        for i in 0..<8 {
            let a = Float(i) / 8 * 2 * .pi
            parts.append(CSG.cylinder(.translate(cos(a) * 0.20, sin(a) * 0.20, 0) * .rotateX(90)
                                      * .scale(0.032, tireHalfWidth * 1.0, 0.032), material: m.chrome))
        }
        return CSG.unionAll(parts)
    }

    /// 버스 로컬 좌표 기준 바퀴 배치. 뒤는 복륜이라 한쪽에 두 짝씩.
    static var wheelPlacements: [float4x4] {
        var out: [float4x4] = []
        let outer = halfWidth - 0.15
        for s in [-1, 1] as [Float] {
            out.append(.translate(frontAxleX, axleY, s * outer))
            out.append(.translate(rearAxleX,  axleY, s * outer))
            out.append(.translate(rearAxleX,  axleY, s * (outer - 2 * tireHalfWidth - 0.03)))
        }
        return out
    }
}
