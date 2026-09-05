//
//  PartyRoom.swift
//  샹들리에가 달린 파티룸 — 바닥·벽, 긴 테이블, 샴페인 잔·병, 2단 케이크, 선물 상자,
//  풍선 다발, 전구 줄, 삼각 깃발 장식. 반복되는 것은 전부 오브젝트 하나 + 인스턴스.
//
//  단위 = 10 cm. 원점 = 샹들리에 중심. 바닥 y = −18 (샹들리에 아래가 바닥에서 1.4 m).
//  **천장은 그리지 않는다** — 이 렌더러의 키 라이트는 지향광이라 천장이 있으면 방 전체가
//  그림자에 잠긴다. 전구 줄·풍선 높이로 천장을 암시한다.
//

import Foundation
import simd

enum PartyRoom {
    typealias B = CSG.Blob

    static let floorY: Float = -18
    static let tableTop: Float = -10.6          // 바닥에서 74 cm
    static let backZ: Float = -34, sideX: Float = 36

    struct Materials {
        let floor: Int, wall: Int, panel: Int, cloth: Int, wood: Int
        let glass: Int, champagne: Int, bottle: Int, foil: Int
        let cream: Int, pink: Int, candle: Int, flame: Int
        let bulb: Int, wire: Int, ribbon: Int
        let balloons: [Int]                       // 색별
        let flags: [Int]
        let gifts: [Int]
    }

    // MARK: - 방

    static func room(_ m: Materials) -> [CSG] {
        [
            CSG.box(.translate(0, floorY - 0.5, 0) * .scale(80, 0.5, 80), material: m.floor),
            CSG.box(.translate(0, -2, backZ - 0.5) * .scale(60, 18, 0.5), material: m.wall),      // 뒷벽
            CSG.box(.translate(-sideX - 0.5, -2, 0) * .scale(0.5, 18, 60), material: m.wall),     // 옆벽
            CSG.box(.translate( sideX + 0.5, -2, 0) * .scale(0.5, 18, 60), material: m.wall),
            // 걸레받이 · 체어레일 몰딩 · 아랫벽 패널
            CSG.box(.translate(0, floorY + 0.5, backZ + 0.15) * .scale(sideX, 0.5, 0.3), material: m.wood),
            CSG.box(.translate(0, floorY + 9.5, backZ + 0.15) * .scale(sideX, 0.25, 0.3), material: m.wood),
            CSG.box(.translate(0, floorY + 5.0, backZ + 0.05) * .scale(sideX, 4.2, 0.1), material: m.panel),
            CSG.box(.translate(-sideX + 0.15, floorY + 9.5, 0) * .scale(0.3, 0.25, 60), material: m.wood),
            CSG.box(.translate( sideX - 0.15, floorY + 9.5, 0) * .scale(0.3, 0.25, 60), material: m.wood),
            CSG.box(.translate(-sideX + 0.05, floorY + 5.0, 0) * .scale(0.1, 4.2, 60), material: m.panel),
            CSG.box(.translate( sideX - 0.05, floorY + 5.0, 0) * .scale(0.1, 4.2, 60), material: m.panel),
        ]
    }

    // MARK: - 테이블

    static func table(_ m: Materials) -> CSG {
        let cloth = CSG.roundBox(half: [13, 0.35, 5.5], radius: 0.3, .translate(0, tableTop - 0.35, 0), material: m.cloth)
        // 테이블보가 옆으로 늘어진다 — 얇은 판
        let drape = CSG.roundBox(half: [13.2, 2.2, 5.7], radius: 0.3, .translate(0, tableTop - 2.3, 0), material: m.cloth)
                  - CSG.box(.translate(0, tableTop - 2.4, 0) * .scale(12.8, 2.5, 5.3), material: m.cloth)
        var legs: [CSG] = []
        for (x, z) in [(-11.5, -4.2), (11.5, -4.2), (-11.5, 4.2), (11.5, 4.2)] as [(Float, Float)] {
            legs.append(CSG.cylinder(.translate(x, (floorY + tableTop - 2.5) / 2, z)
                                     * .scale(0.35, (tableTop - 2.5 - floorY) / 2, 0.35), material: m.wood))
        }
        return CSG.unionAll([cloth, drape] + legs)
    }

    // MARK: - 테이블 위

    /// 샴페인 플루트 — 얇은 유리 회전체(속을 판다) + 호박색 액체
    static func flute(_ m: Materials) -> CSG {
        let outer: [(y: Float, r: Float)] = [(0.0, 0.36), (0.06, 0.36), (0.12, 0.12), (0.22, 0.05),
                                             (1.30, 0.05), (1.42, 0.12), (1.60, 0.28), (2.50, 0.33), (2.95, 0.30)]
        let inner: [(y: Float, r: Float)] = [(1.58, 0.10), (1.70, 0.22), (2.50, 0.29), (3.10, 0.27)]
        let glass = CSG.lathe(outer, material: m.glass) - CSG.lathe(inner, material: m.glass)
        let liquid = CSG.lathe([(1.62, 0.12), (1.75, 0.21), (2.20, 0.27), (2.24, 0.27)], material: m.champagne)
        return (glass | liquid).transformed(.scale(0.78))
    }

    static func bottle(_ m: Materials) -> CSG {
        let body = CSG.lathe([(0, 0.40), (0.08, 0.46), (2.0, 0.46), (2.45, 0.36), (2.85, 0.17), (3.25, 0.17)],
                             material: m.bottle)
        let foil = CSG.lathe([(2.35, 0.40), (2.5, 0.38), (2.9, 0.19), (3.30, 0.19), (3.35, 0.16)], material: m.foil)
        return body | foil
    }

    static func cake(_ m: Materials) -> CSG {
        var parts: [CSG] = [
            CSG.cylinder(.translate(0, 0.02, 0) * .scale(2.2, 0.04, 2.2), material: m.foil),            // 받침
            CSG.cylinder(.translate(0, 0.55, 0) * .scale(1.75, 0.50, 1.75), material: m.cream),
            CSG.torus(.translate(0, 1.05, 0) * .scale(1.72, 1.72, 1.72) * .scale(1, 0.09, 1), material: m.pink), // 크림 테두리
            CSG.cylinder(.translate(0, 1.50, 0) * .scale(1.20, 0.45, 1.20), material: m.pink),
            CSG.torus(.translate(0, 1.95, 0) * .scale(1.18, 1.18, 1.18) * .scale(1, 0.09, 1), material: m.cream),
        ]
        for k in 0..<6 {
            let a = Float(k) / 6 * 2 * .pi
            let x = 0.72 * cos(a), z = 0.72 * sin(a)
            parts.append(CSG.cylinder(.translate(x, 2.35, z) * .scale(0.06, 0.40, 0.06), material: m.candle))
            parts.append(CSG.blob([B.ell([x, 2.86, z], [0.045, 0.10, 0.045], blend: 0.03)], material: m.flame))
        }
        return CSG.unionAll(parts)
    }

    /// 선물 상자 — 둥근 상자 + 리본 띠 둘 + 매듭
    static func gift(size h: SIMD3<Float>, box: Int, ribbon: Int) -> CSG {
        CSG.roundBox(half: h, radius: 0.08, .translate(0, h.y, 0), material: box)
      | CSG.roundBox(half: [h.x + 0.03, h.y + 0.03, 0.14], radius: 0.02, .translate(0, h.y, 0), material: ribbon)
      | CSG.roundBox(half: [0.14, h.y + 0.03, h.z + 0.03], radius: 0.02, .translate(0, h.y, 0), material: ribbon)
      | CSG.torus(.translate(0.0, h.y * 2 + 0.16, 0) * .rotateX(90) * .scale(0.30, 0.30, 0.30) * .scale(1, 0.4, 1), material: ribbon)
    }

    // MARK: - 풍선 · 전구 줄 · 깃발

    /// 풍선 하나 — 살짝 길쭉한 구 + 매듭 + 아래로 늘어진 줄. 색마다 오브젝트 하나
    static func balloon(_ color: Int, string: Int) -> CSG {
        CSG.sphere(.scale(0.62, 0.74, 0.62), material: color)
      | CSG.cone(.translate(0, -0.78, 0) * .rotateX(180) * .scale(0.10, 0.10, 0.10), material: color)
      | CSG.cylinder(.translate(0, -3.6, 0) * .scale(0.012, 2.8, 0.012), material: string)
    }

    static func balloonPlacements() -> [(color: Int, xf: float4x4)] {
        var out: [(Int, float4x4)] = []
        let clusters: [SIMD3<Float>] = [[-26, 8.5, -22], [24, 9.0, -26], [-22, 7.5, 14], [27, 8.0, 10], [-4, 10.5, -30]]
        for (ci, c) in clusters.enumerated() {
            for j in 0..<7 {
                let h = Float((j * 7919 + ci * 104729) % 1000) / 1000
                let a = Float(j) / 7 * 2 * .pi + h
                let r: Float = j == 0 ? 0 : 0.95 + h * 0.4
                let p = c + [r * cos(a), (h - 0.5) * 1.4 + (j == 0 ? 0.9 : 0), r * sin(a)]
                out.append(((j + ci) % 4, .translate(p.x, p.y, p.z) * .rotateZ((h - 0.5) * 14)))
            }
        }
        return out
    }

    /// 늘어진 줄 위의 점 (catenary 근사)
    static func swag(_ a: SIMD3<Float>, _ b: SIMD3<Float>, sag: Float, t: Float) -> SIMD3<Float> {
        var p = simd_mix(a, b, SIMD3<Float>(repeating: t))
        p.y -= sag * 4 * t * (1 - t)
        return p
    }

    static let lightStrings: [(SIMD3<Float>, SIMD3<Float>)] = [
        ([-sideX, 11.0, -30], [sideX, 11.5, -30]),
        ([-sideX, 11.5, -10], [sideX, 11.0, -10]),
        ([-sideX, 11.0,  12], [sideX, 11.5,  12]),
    ]

    /// 전구 하나 — 발광 구 + 어두운 소켓
    static func bulb(_ m: Materials) -> CSG {
        CSG.sphere(.scale(0.13, 0.16, 0.13), material: m.bulb)
      | CSG.cylinder(.translate(0, 0.20, 0) * .scale(0.06, 0.07, 0.06), material: m.wire)
    }

    static func bulbPlacements() -> [float4x4] {
        var out: [float4x4] = []
        for (a, b) in lightStrings {
            for i in 1..<40 {
                let p = swag(a, b, sag: 2.2, t: Float(i) / 40)
                out.append(.translate(p.x, p.y - 0.2, p.z))
            }
        }
        return out
    }

    /// 전구 줄의 전선 — 늘어진 줄을 원뿔 사슬 blob 으로
    static func wires(_ m: Materials) -> CSG {
        var e: [B] = []
        for (a, b) in lightStrings {
            let n = 10
            for i in 0..<n {
                e.append(B.cone(swag(a, b, sag: 2.2, t: Float(i) / Float(n)),
                                swag(a, b, sag: 2.2, t: Float(i + 1) / Float(n)), 0.02, 0.02, blend: 0.01))
            }
        }
        return CSG.blob(e, maxSteps: 80, material: m.wire)
    }

    /// 삼각 깃발 — 아래로 뾰족한 삼각 판
    static func flag(_ color: Int) -> CSG {
        CSG.polygon([[-1, 0], [1, 0], [0, 1.6]], .rotateX(-90) * .scale(1.0, 0.012, 1.0), material: color)   // 20 cm 깃발
    }

    static let buntings: [(SIMD3<Float>, SIMD3<Float>, Float)] = [
        ([-sideX + 2, 9.0, backZ + 0.8], [sideX - 2, 9.0, backZ + 0.8], 3.0),
        ([-sideX + 0.6, 9.5, -16], [-sideX + 0.6, 9.5, 20], 2.4),
        ([ sideX - 0.6, 9.5, -16], [ sideX - 0.6, 9.5, 20], 2.4),
    ]

    static func flagPlacements() -> [(color: Int, xf: float4x4)] {
        var out: [(Int, float4x4)] = []
        for (bi, (a, b, sag)) in buntings.enumerated() {
            let n = 26
            let d = b - a
            let yaw = atan2(d.x, d.z) * 180 / .pi
            for i in 0..<n {
                let t = (Float(i) + 0.5) / Float(n)
                let p = swag(a, b, sag: sag, t: t)
                out.append(((i + bi) % 3, .translate(p.x, p.y, p.z) * .rotateY(yaw)))
            }
        }
        return out
    }
}
