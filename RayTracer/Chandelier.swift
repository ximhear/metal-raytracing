//
//  Chandelier.swift
//  크리스털 샹들리에 — 이 엔진이 잘하는 것만 모았다:
//   · 황동 기둥·보베슈(촛대 접시) = 회전체(lathe)
//   · 팔 = 베지에 튜브 blob 하나를 8번 인스턴싱
//   · 프리즘 펜던트·팔각 비즈 = 오브젝트 하나씩을 수백 번 인스턴싱 (팔각기둥 ∩ 타원체 = 깎은 크리스털)
//   · 촛불 = 발광
//  어두운 스튜디오에서 유리마다 소프트박스가 반사·굴절로 얽힌다.
//
//  단위 = 10 cm. 원점 = 팔이 붙는 기둥 중심. y 위가 천장.
//

import Foundation
import simd

enum Chandelier {
    typealias B = CSG.Blob

    struct Materials {
        let brass: Int
        let crystal: Int
        let candle: Int
        let flame: Int
    }

    static let armCount = 8
    static let armR: Float = 3.6           // 보베슈(촛대) 반지름 위치
    static let bobecheY: Float = 0.30

    // MARK: - 황동 기둥

    /// 가운데 기둥 — 마디(knop)가 있는 회전체. 위는 천장 체인, 아래는 피니얼.
    static func stem(_ m: Materials) -> CSG {
        let profile: [(y: Float, r: Float)] = [
            (-4.4, 0.05), (-4.1, 0.24), (-3.85, 0.16), (-3.7, 0.30),
            (-1.7, 0.20), (-1.3, 0.55), (-0.9, 0.58), (-0.6, 0.24),
            (-0.3, 0.26), ( 0.0, 0.62), ( 0.4, 0.66), ( 0.8, 0.30),
            ( 1.6, 0.22), ( 2.0, 0.50), ( 2.4, 0.52), ( 2.7, 0.24),
            ( 3.2, 0.20), ( 3.5, 0.44), ( 3.9, 0.40), ( 4.3, 0.16), ( 5.2, 0.14),
        ]
        var parts: [CSG] = [CSG.lathe(profile, material: m.brass)]
        // 팔 고리·크라운 고리·아래 펜던트 고리 — 토러스
        parts.append(CSG.torus(.translate(0, 3.45, 0) * .scale(1.15, 1.15, 1.15) * .scale(1, 0.18, 1), material: m.brass))
        parts.append(CSG.torus(.translate(0, -1.15, 0) * .scale(1.35, 1.35, 1.35) * .scale(1, 0.14, 1), material: m.brass))
        parts.append(CSG.torus(.translate(0, 0.15, 0) * .scale(0.85, 0.85, 0.85) * .scale(1, 0.16, 1), material: m.brass))
        return CSG.unionAll(parts)
    }

    /// 천장 체인 — 고리 하나를 번갈아 90° 돌려 쌓는다 (인스턴스)
    static func chainLink(_ m: Materials) -> CSG {
        CSG.torus(.scale(0.20, 0.20, 0.20) * .scale(1, 0.25, 1) * .scale(1, 1, 1.4), material: m.brass)
    }

    // MARK: - 팔 (오브젝트 하나, 8번 인스턴싱)

    /// 기둥에서 S 자로 나가 촛대까지. 로컬: +x 방향으로 뻗는다.
    static func arm(_ m: Materials) -> CSG {
        let tube = CSG.blob([
            // 기둥 → 아래로 처졌다 → 바깥 위로
            B.curve([0.55, 0.10, 0], via: [1.9, -1.55, 0], [armR - 0.5, -0.45, 0], 0.10, 0.085, blend: 0.03),
            B.curve([armR - 0.5, -0.45, 0], via: [armR + 0.15, 0.0, 0], [armR, bobecheY - 0.15, 0], 0.085, 0.09, blend: 0.03),
            // 장식 컬 — 팔 중간에서 안쪽 위로 말린다
            B.curve([1.9, -1.15, 0], via: [1.35, -0.35, 0], [1.85, -0.05, 0], 0.06, 0.035, blend: 0.02),
            B.curve([1.85, -0.05, 0], via: [2.2, 0.1, 0], [2.05, -0.35, 0], 0.035, 0.02, blend: 0.02),
            // 팔 뿌리 마디
            B.ell([0.62, 0.10, 0], [0.18, 0.14, 0.14], blend: 0.05),
        ], maxSteps: 100, material: m.brass)   // 가는 튜브 — 스텝을 아껴야 중앙에서 8개가 겹쳐도 스레드가 안 죽는다
        // 보베슈 — 얕은 접시 + 촛대 컵 (회전체)
        let bobeche = CSG.lathe([(-0.10, 0.10), (0.0, 0.16), (0.06, 0.62), (0.14, 0.66), (0.12, 0.50),
                                 (0.10, 0.22), (0.30, 0.20), (0.70, 0.22), (0.78, 0.24)],
                                .translate(armR, bobecheY, 0), material: m.brass)
        let candle = CSG.cylinder(.translate(armR, bobecheY + 1.30, 0) * .scale(0.15, 0.62, 0.15), material: m.candle)
        // 불꽃 전구 — 물방울 발광
        let flame = CSG.blob([B.ell([armR, bobecheY + 2.08, 0], [0.11, 0.21, 0.11], blend: 0.05),
                              B.ell([armR, bobecheY + 1.92, 0], [0.07, 0.07, 0.07], blend: 0.05)],
                             material: m.flame)
        return CSG.unionAll([tube, bobeche, candle, flame])
    }

    // MARK: - 크리스털 (인스턴스)

    /// 프리즘 펜던트(펜달로그) — 팔각기둥 ∩ 길쭉한 타원체 = 양 끝이 뾰족하게 깎인 크리스털.
    /// 로컬: 고리가 원점, 아래로 늘어진다. 길이 1.0.
    static func pendant(_ m: Materials) -> CSG {
        let body = CSG.ngonPrism(8, .translate(0, -0.55, 0) * .scale(0.17, 0.48, 0.17) * .rotateY(22.5), material: m.crystal)
                 & CSG.sphere(.translate(0, -0.55, 0) * .scale(0.20, 0.60, 0.20), material: m.crystal)
        let hook = CSG.torus(.translate(0, -0.02, 0) * .rotateX(90) * .scale(0.06, 0.06, 0.06) * .scale(1, 0.3, 1),
                             material: m.brass)
        return body | hook
    }

    /// 작은 팔각 비즈 — 체인용. 납작한 팔각 원반, 면이 z 를 향한다
    static func bead(_ m: Materials) -> CSG {
        CSG.ngonPrism(8, .rotateX(90) * .scale(0.11, 0.028, 0.11), material: m.crystal)
    }

    /// 아래 중앙의 큰 깎은 유리 구
    static func centerBall(_ m: Materials) -> CSG {
        let r: Float = 0.95
        var ball = CSG.sphere(.translate(0, -2.75, 0) * .scale(r), material: m.crystal)
        // 여섯 방향에서 평면으로 깎아 면을 세운다
        for k in 0..<6 {
            let a = Float(k) * 60
            ball = ball & CSG.box(.translate(0, -2.75, 0) * .rotateY(a) * .scale(r * 0.93, 2, 2), material: m.crystal)
        }
        return ball & CSG.box(.translate(0, -2.75, 0) * .scale(2, r * 0.9, 2), material: m.crystal)
    }

    // MARK: - 배치

    static func armPlacements() -> [float4x4] {
        (0..<armCount).map { .rotateY(Float($0) / Float(armCount) * 360) }
    }

    /// 펜던트 배치 — 보베슈 둘레 6개씩, 크라운 고리 16개, 아래 고리 20개
    static func pendantPlacements() -> [float4x4] {
        var out: [float4x4] = []
        for k in 0..<armCount {
            let ay = Float(k) / Float(armCount) * 360
            for j in 0..<8 {                                   // 보베슈 둘레 8개
                let t = Float(j) / 8 * 360 + 22.5
                let p = SIMD3<Float>(armR + 0.58 * cos(t * .pi / 180), bobecheY + 0.05, 0.58 * sin(t * .pi / 180))
                out.append(.rotateY(ay) * .translate(p.x, p.y, p.z) * .rotateY(t + 90) * .scale(0.85))
            }
            // 팔이 가장 낮게 처진 자리에서 늘어지는 긴 펜던트
            out.append(.rotateY(ay) * .translate(2.05, -1.25, 0) * .rotateY(90) * .scale(1.15))
            // 팔 사이 스와그 가운데에서 늘어지는 펜던트
            out.append(.rotateY(ay + 360 / Float(armCount) / 2) * .translate(armR * 0.92, bobecheY - 0.78, 0)
                       * .rotateY(90) * .scale(1.0))
        }
        for j in 0..<16 {
            let t = Float(j) / 16 * 360
            out.append(.rotateY(t) * .translate(1.15, 3.40, 0) * .scale(0.9))
        }
        for j in 0..<20 {
            let t = Float(j) / 20 * 360 + 9
            out.append(.rotateY(t) * .translate(1.35, -1.22, 0) * .scale(1.25))
        }
        return out
    }

    /// 비즈 체인 — 이웃한 보베슈 사이를 늘어진 곡선으로, 크라운 고리에서 팔로도
    static func beadPlacements() -> [float4x4] {
        var out: [float4x4] = []
        func chain(_ a: SIMD3<Float>, _ b: SIMD3<Float>, sag: Float, count: Int) {
            for i in 1..<count {
                let t = Float(i) / Float(count)
                var p = simd_mix(a, b, SIMD3<Float>(repeating: t))
                p.y -= sag * 4 * t * (1 - t)
                let d = simd_normalize(b - a)
                let yaw = atan2(d.x, d.z) * 180 / .pi       // 비즈 면이 체인 방향과 나란하지 않게
                out.append(.translate(p.x, p.y, p.z) * .rotateY(yaw + 90) * .rotateX(Float(i % 3) * 8))
            }
        }
        for k in 0..<armCount {
            let a0 = Float(k) / Float(armCount) * 2 * .pi
            let a1 = Float(k + 1) / Float(armCount) * 2 * .pi
            let pa = SIMD3<Float>(armR * cos(a0), bobecheY + 0.12, armR * sin(a0))
            let pb = SIMD3<Float>(armR * cos(a1), bobecheY + 0.12, armR * sin(a1))
            chain(pa, pb, sag: 0.9, count: 14)
            // 크라운 고리 → 보베슈
            let top = SIMD3<Float>(1.15 * cos(a0), 3.40, 1.15 * sin(a0))
            chain(top, pa, sag: 0.5, count: 16)
            // 보베슈 → 아래 고리 — 두 번째 스와그 (실제 샹들리에는 아래로도 체인이 흐른다)
            let low = SIMD3<Float>(1.35 * cos(a0), -1.10, 1.35 * sin(a0))
            chain(SIMD3<Float>(armR * cos(a0), bobecheY - 0.05, armR * sin(a0)), low, sag: 0.35, count: 12)
        }
        return out
    }
}
