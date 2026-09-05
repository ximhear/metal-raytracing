//
//  IronMan.swift
//  붉은색·금색 파워드 아머 (아이언맨풍). 참고: 코믹콘 코스프레 사진 (Mk4 계열).
//
//  로컬 단위 = 10 cm. 키 약 19 = 1.9 m. 발바닥 y = 0. 앞 = +z, 오른쪽 = +x.
//
//  **구조** — 인물상과 같은 골격 위에 갑옷 판을 얹는다:
//   - 언더슈트: 어두운 회색 blob (몸통·팔·다리). 판 사이 틈으로 이게 보여야 갑옷이 갑옷으로 읽힌다
//   - 갑옷 판: `roundBox` 위주 (기계다 — 능선이 있어야 한다). 판마다 언더슈트보다 바깥에
//   - 발광: 눈·아크 리액터·리펄서는 `MATERIAL_EMISSIVE`
//  팔·다리는 **어깨/엉덩관절을 원점으로, −y 로 늘어뜨린 표준 자세**로 만들고 배치 변환으로 돌린다.
//  그래야 판을 축 정렬 상자로 만들 수 있다.
//

import Foundation
import simd

enum IronMan {
    typealias B = CSG.Blob

    struct Materials {
        let red: Int
        let gold: Int
        let suit: Int      // 언더슈트 (어두운 회색)
        let glow: Int      // 눈 · 리펄서 (희게 타는 청백)
        let core: Int      // 아크 리액터 (푸른 발광)
        let steel: Int     // 볼트 · 이음쇠
    }

    // 골격 높이
    static let hipY: Float = 9.8, shoulderY: Float = 15.2, shoulderX: Float = 2.35
    static let headC = SIMD3<Float>(0, 17.75, 0.05)

    // MARK: - 디테일 헬퍼

    /// 판 표면에 **얕게 파낸 사각 패널** — 테두리가 남아 패널 라인이 된다.
    /// `face` 는 파는 면의 바깥 법선 (축 정렬만). 깊이 0.035.
    static func inset(_ half: SIMD2<Float>, at c: SIMD3<Float>, face: SIMD3<Float>,
                      depth: Float = 0.022, material: Int) -> CSG {
        // 파내는 상자는 면 바깥으로 넉넉히 뻗고 안으로 depth 만큼만 들어온다
        let t: Float = 0.3
        let center = c + face * (t - depth)
        let h: SIMD3<Float>
        if abs(face.x) > 0.5 { h = [t, half.x, half.y] }
        else if abs(face.y) > 0.5 { h = [half.x, t, half.y] }
        else { h = [half.x, half.y, t] }
        return CSG.roundBox(half: h, radius: 0.03, .translate(center.x, center.y, center.z), material: material)
    }

    /// 가는 홈 (축 정렬). `along` 방향으로 길이 `len`, 면 법선 `face`.
    static func groove(from c: SIMD3<Float>, along: SIMD3<Float>, len: Float, face: SIMD3<Float>,
                       width: Float = 0.035, depth: Float = 0.04, material: Int) -> CSG {
        let t: Float = 0.3
        let center = c + face * (t - depth)
        var h = SIMD3<Float>(repeating: width)
        if abs(along.x) > 0.5 { h.x = len / 2 } else if abs(along.y) > 0.5 { h.y = len / 2 } else { h.z = len / 2 }
        if abs(face.x) > 0.5 { h.x = t } else if abs(face.y) > 0.5 { h.y = t } else { h.z = t }
        return CSG.box(.translate(center.x, center.y, center.z) * .scale(h.x, h.y, h.z), material: material)
    }

    /// 볼트 — 육각 홈이 있는 강철 머리. 오브젝트 하나를 수십 번 인스턴싱한다.
    /// 로컬: 축 = +y, 머리 윗면이 y = 0.03. 배치 변환이 +y 를 판의 법선으로 돌린다.
    static func bolt(_ m: Materials) -> CSG {
        CSG.cylinder(.translate(0, 0.0, 0) * .scale(0.075, 0.03, 0.075), material: m.steel)
      - CSG.ngonPrism(6, .translate(0, 0.03, 0) * .scale(0.038, 0.014, 0.038), material: m.suit)
    }

    /// +y 를 `n` 으로 보내는 회전
    static func alignY(_ n: SIMD3<Float>) -> float4x4 {
        let d = simd_normalize(n)
        if d.y > 0.9999 { return .identity }
        if d.y < -0.9999 { return .rotateZ(180) }
        return .rotate(axis: simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), d)),
                       degrees: acos(d.y) * 180 / .pi)
    }

    /// (위치, 법선) 목록 → 볼트 배치 변환. `frame` 은 그 부위의 배치 변환.
    static func boltPlacements(_ list: [(SIMD3<Float>, SIMD3<Float>)], frame: float4x4 = .identity) -> [float4x4] {
        list.map { frame * .translate($0.0.x, $0.0.y, $0.0.z) * alignY($0.1) }
    }

    // MARK: - 언더슈트 몸통 (blob)

    static func torsoSuit(_ m: Materials) -> CSG {
        CSG.blob([
            B.ell([0, 10.0, 0.0], [1.55, 1.10, 1.00], blend: 0.6),    // 골반
            B.ell([0, 11.5, 0.0], [1.35, 1.00, 0.90], blend: 0.6),    // 허리
            B.ell([0, 13.4, 0.0], [1.95, 1.50, 1.15], blend: 0.6),    // 흉곽
            B.ell([0, 14.6, -0.1], [1.95, 0.70, 1.00], blend: 0.5),   // 윗가슴
            B.ell([ 1.4, 14.9, 0], [0.9, 0.6, 0.8], blend: 0.5),      // 승모근
            B.ell([-1.4, 14.9, 0], [0.9, 0.6, 0.8], blend: 0.5),
            B.cone([0, 15.3, 0.05], [0, 16.7, 0.05], 0.66, 0.60, blend: 0.3),   // 목 (짧고 굵게)
        ], material: m.suit)
    }

    // MARK: - 헬멧

    /// 헬멧 껍데기 원소 — 붉은 부분과 금 페이스플레이트가 **같은 껍데기를 나눠 쓴다.**
    /// 마스크 앞에 금 블록을 따로 붙이면 튀어나오고, 껍데기가 블록을 뚫고 나와 잡음이 낀다 (그랬다).
    static func helmetShell(_ mat: Int) -> CSG {
        let c = headC
        return CSG.blob([
            B.ell(c + [0,  0.00, -0.05], [1.00, 1.15, 1.05], blend: 0.22),
            B.ell(c + [0,  0.05, -0.32], [0.95, 1.00, 0.90], blend: 0.28),   // 뒤통수
            B.ell(c + [0, -0.85,  0.20], [0.86, 0.60, 0.88], blend: 0.18),   // 턱 — 각지게
            B.ell(c + [0,  0.40,  0.55], [0.86, 0.62, 0.62], blend: 0.18),   // 이마 융기
            B.ell(c + [0,  0.70,  0.00], [0.55, 0.60, 0.95], blend: 0.25),   // 정수리 능선
        ], material: mat)
        & CSG.roundBox(half: [1.02, 1.12, 1.15], radius: 0.30,
                       .translate(c.x, c.y - 0.05, c.z - 0.05), material: mat)   // 옆면·정수리를 평면으로
    }

    /// 페이스플레이트가 차지하는 영역 — 이마에서 턱으로 **좁아지는** 둥근 사다리꼴, 앞쪽 절반.
    /// 직사각형이면 우체통 투입구다. 이마 가운데에는 붉은 브로우가 살짝 내려오는 V 노치.
    static func faceMask(_ mat: Int, shrink: Float = 0) -> CSG {
        let c = headC
        var mask = CSG.roundBox(half: [0.76 - shrink, 0.94 - shrink, 1.0], radius: 0.16,
                                .translate(c.x, c.y - 0.20, c.z + 1.0), material: mat)
        for sgn: Float in [1, -1] {                     // 옆 가장자리를 턱 쪽으로 모은다
            mask = mask & CSG.box(.translate(c.x + 0.05 * sgn, c.y - 0.2, c.z + 1.0)
                                  * .rotateZ(9 * sgn) * .scale(0.78 - shrink, 1.6, 1.3), material: mat)
        }
        // 이마 가운데 V 노치 (붉은 브로우가 내려온다)
        return mask - CSG.box(.translate(c.x, c.y + 0.92, c.z + 1.0) * .rotateZ(45) * .scale(0.20, 0.20, 1.3),
                              material: mat)
    }

    /// 붉은 헬멧 = 껍데기 − 마스크 영역 (+ 귀 원판)
    static func helmet(_ m: Materials) -> CSG {
        let c = headC
        return (helmetShell(m.red) - faceMask(m.red))
          | CSG.cylinder(.translate(c.x + 1.02, c.y - 0.25, c.z) * .rotateZ(90) * .scale(0.32, 0.06, 0.32), material: m.steel)
          | CSG.cylinder(.translate(c.x - 1.02, c.y - 0.25, c.z) * .rotateZ(90) * .scale(0.32, 0.06, 0.32), material: m.steel)
    }

    /// 금 페이스플레이트 = 마스크 영역 ∩ **평면으로 깎은 다면체**. 껍데기보다 0.03 앞으로 나와
    /// 따로 끼운 판으로 읽힌다. 이마는 평평, 볼은 안쪽으로 기운 두 면, 턱은 뒤로 기운 면.
    static func faceplate(_ m: Materials) -> CSG {
        let c = headC
        let zf = c.z + 1.08                                  // 판 앞면
        var poly = CSG.box(.translate(c.x, c.y - 0.2, zf - 1.0) * .scale(1.2, 1.4, 1.0), material: m.gold)
        for sgn: Float in [1, -1] {                          // 볼 면
            poly = poly & CSG.box(.translate(c.x + 0.42 * sgn, c.y - 0.2, zf - 1.2)
                                  * .rotateY(-24 * sgn) * .scale(0.72, 1.6, 1.2), material: m.gold)
        }
        poly = poly & CSG.box(.translate(c.x, c.y + 0.35, zf - 1.3)                // 턱 면
                              * .rotateX(-20) * .scale(1.4, 1.6, 1.15), material: m.gold)
        poly = poly & CSG.box(.translate(c.x, c.y - 0.65, zf - 1.3)                // 이마 면
                              * .rotateX(16) * .scale(1.4, 1.6, 1.15), material: m.gold)
        let plate = poly & faceMask(m.gold, shrink: 0.02)
        let nose = CSG.roundBox(half: [0.13, 0.40, 0.12], radius: 0.05,
                                .translate(c.x, c.y - 0.28, zf - 0.02), material: m.gold)
        let mouth = CSG.roundBox(half: [0.28, 0.035, 0.40], radius: 0.02,
                                 .translate(c.x, c.y - 0.72, zf), material: m.suit)
        func eyeSlit(_ sgn: Float) -> CSG {
            CSG.roundBox(half: [0.30, 0.070, 0.45], radius: 0.03,
                         .translate(c.x + 0.40 * sgn, c.y - 0.04, zf) * .rotateZ(-12 * sgn),
                         material: m.suit)
        }
        return (plate | nose) - mouth - eyeSlit(1) - eyeSlit(-1)
    }

    /// 눈 — 틈 뒤에서 빛나는 판
    static func eyes(_ m: Materials) -> CSG {
        let c = headC
        return CSG.unionAll([1, -1].map { (s: Float) in
            CSG.roundBox(half: [0.30, 0.065, 0.06], radius: 0.03,
                         .translate(c.x + 0.40 * s, c.y - 0.04, c.z + 0.90) * .rotateZ(-12 * s),
                         material: m.glow)
        })
    }

    // MARK: - 가슴 · 배 · 등

    static func chest(_ m: Materials) -> CSG {
        var parts: [CSG] = []
        // 흉갑 — 상자 둘이 아니라 **조각한 덩어리**. 어깨에서 넓고 명치로 모이며,
        // 가슴 근육 자리가 살짝 부풀어야 갑옷이 몸을 따라 만들어진 것으로 읽힌다
        parts.append(CSG.blob([
            B.ell([ 1.05, 14.05, 0.75], [1.05, 0.85, 0.62], blend: 0.28, tilt: ([0, 0, 1], -12)),
            B.ell([-1.05, 14.05, 0.75], [1.05, 0.85, 0.62], blend: 0.28, tilt: ([0, 0, 1],  12)),
            B.ell([ 0.00, 14.65, 0.55], [1.90, 0.45, 0.55], blend: 0.25),   // 쇄골 선
            B.ell([ 0.00, 12.95, 0.70], [1.25, 0.55, 0.45], blend: 0.25),   // 명치
        ], material: m.red) & CSG.box(.translate(0, 13.7, 0.9) * .scale(3, 1.6, 0.9), material: m.red))
        // 가운데 금색 판 (리액터 자리) — 흉갑 위에 살짝 얹힌다. 세로 홈 둘로 V 를 암시
        parts.append(CSG.roundBox(half: [0.60, 0.92, 0.16], radius: 0.10,
                                  .translate(0, 13.55, 1.30), material: m.gold)
                   - groove(from: [ 0.36, 13.2, 1.46], along: [0, 1, 0], len: 1.2, face: [0, 0, 1], material: m.suit)
                   - groove(from: [-0.36, 13.2, 1.46], along: [0, 1, 0], len: 1.2, face: [0, 0, 1], material: m.suit))
        // 흉갑 위 패널 라인 — 가슴 근육 아래를 가로지르는 홈, 쇄골 아래 홈
        parts[0] = parts[0]
            - groove(from: [ 1.05, 13.25, 1.35], along: [1, 0, 0], len: 1.3, face: [0, 0, 1], depth: 0.6, material: m.suit)
            - groove(from: [-1.05, 13.25, 1.35], along: [1, 0, 0], len: 1.3, face: [0, 0, 1], depth: 0.6, material: m.suit)
        // 은색 겨드랑이·옆구리 부품
        for s: Float in [1, -1] {
            parts.append(CSG.roundBox(half: [0.30, 0.55, 0.55], radius: 0.10,
                                      .translate(2.05 * s, 14.25, -0.1), material: m.steel))
        }
        // 배 — 붉은 띠 셋, 사이로 언더슈트가 보인다
        for (i, y) in [12.35, 11.75, 11.15].enumerated() {
            let w: Float = 1.05 - Float(i) * 0.08
            parts.append(CSG.roundBox(half: [w, 0.24, 0.80], radius: 0.14,
                                      .translate(0, Float(y), 0.15), material: m.red))
        }
        // 목 갑옷(고짓) — 언더슈트 목이 그대로 드러나면 마네킹이다
        parts.append(CSG.cylinder(.translate(0, 15.55, 0.05) * .scale(1.0, 0.22, 0.9), material: m.red)
                   - CSG.cylinder(.translate(0, 15.55, 0.05) * .scale(0.68, 0.5, 0.62), material: m.red))
        // 등판
        parts.append(CSG.roundBox(half: [1.65, 1.55, 0.32], radius: 0.25,
                                  .translate(0, 13.5, -1.0), material: m.red))
        // 옆구리 금색 판 — 음각 패널
        for s: Float in [1, -1] {
            parts.append(CSG.roundBox(half: [0.28, 1.1, 0.75], radius: 0.12,
                                      .translate(1.95 * s, 13.2, 0.05), material: m.gold)
                       - inset([0.5, 0.75], at: [2.23 * s, 13.2, 0.05], face: [s, 0, 0], material: m.gold))
        }
        var body = CSG.unionAll(parts)
        // 배 띠 — 띠마다 가로 홈 하나
        for y in [12.35, 11.75, 11.15] as [Float] {
            body = body - groove(from: [0, y, 0.95], along: [1, 0, 0], len: 1.4, face: [0, 0, 1], material: m.suit)
        }
        return body
    }

    /// 아크 리액터 — 금테 + 푸른 발광 원판 + 흰 삼각형
    static func reactor(_ m: Materials) -> CSG {
        let p = SIMD3<Float>(0, 13.7, 1.50)
        let ring = CSG.cylinder(.translate(p.x, p.y, p.z) * .rotateX(90) * .scale(0.56, 0.06, 0.56),
                                material: m.gold)
                 - CSG.cylinder(.translate(p.x, p.y, p.z) * .rotateX(90) * .scale(0.44, 0.2, 0.44),
                                material: m.gold)
        let disc = CSG.cylinder(.translate(p.x, p.y, p.z - 0.02) * .rotateX(90) * .scale(0.45, 0.03, 0.45),
                                material: m.core)
        // 삼각형 — 정삼각 기둥, 위 꼭짓점이 아래로 (Mk6 계열)
        let tri = CSG.polygon([[0, -1], [0.87, 0.5], [-0.87, 0.5]],
                              .translate(p.x, p.y, p.z + 0.015) * .rotateX(90) * .scale(0.30, 0.035, 0.30)
                              * .rotateY(180), material: m.glow)
        return ring | disc | tri
    }

    /// 어깨 — 공이 아니라 **기울인 판 두 장이 겹친** 견갑. 위 판은 목 쪽으로 오르고 아래 판은 팔을 감싼다
    static func shoulders(_ m: Materials) -> CSG {
        CSG.unionAll([1, -1].map { (s: Float) in
            let x = shoulderX * s
            let upper = CSG.roundBox(half: [1.0, 0.42, 0.95], radius: 0.22,
                                     .translate(x, shoulderY + 0.35, 0) * .rotateZ(-14 * s), material: m.red)
                      - inset([0.6, 0.6], at: [x, shoulderY + 0.77, 0], face: [0, 1, 0], material: m.red)
            let lower = CSG.roundBox(half: [0.62, 0.80, 0.90], radius: 0.24,
                                     .translate(x + 0.55 * s, shoulderY - 0.35, 0) * .rotateZ(-10 * s),
                                     material: m.red)
                      - inset([0.55, 0.55], at: [x + 1.17 * s, shoulderY - 0.35, 0], face: [s, 0, 0], material: m.red)
            let bolt = CSG.cylinder(.translate(x + 1.12 * s, shoulderY - 0.35, 0) * .rotateZ(90)
                                    * .scale(0.16, 0.08, 0.16), material: m.steel)
            return upper | lower | bolt
        })
    }

    // MARK: - 팔 (표준 자세: 어깨 = 원점, −y 로 늘어뜨림)

    /// 팔 하나. `open` 이면 손바닥이 −y 를 향한 리펄서 자세, 아니면 주먹.
    static func arm(_ m: Materials, open: Bool) -> CSG {
        var parts: [CSG] = [
            CSG.blob([
                B.cone([0, 0, 0], [0, -3.0, 0], 0.62, 0.55, blend: 0.2),
                B.cone([0, -3.0, 0], [0, -5.8, 0], 0.55, 0.46, blend: 0.2),
            ], material: m.suit),
            // 위팔 판 (앞·바깥 음각 패널) + 금색 이두 띠
            CSG.roundBox(half: [0.78, 1.15, 0.78], radius: 0.30, .translate(0, -1.65, 0), material: m.red)
              - inset([0.42, 0.72], at: [0, -1.65, 0.78], face: [0, 0, 1], material: m.red)
              - inset([0.42, 0.72], at: [0.78, -1.65, 0], face: [1, 0, 0], material: m.red)
              - inset([0.42, 0.72], at: [-0.78, -1.65, 0], face: [-1, 0, 0], material: m.red),
            CSG.roundBox(half: [0.80, 0.22, 0.80], radius: 0.10, .translate(0, -0.55, 0), material: m.gold),
            // 팔꿈치 — 금 구 + 은색 관절 덮개
            CSG.sphere(.translate(0, -3.0, 0) * .scale(0.62), material: m.gold),
            CSG.roundBox(half: [0.52, 0.30, 0.40], radius: 0.12, .translate(0, -3.0, -0.45), material: m.steel),
            // 아래팔 건틀릿 (음각 패널 + 세로 홈) + 은색 안쪽 판 + 손목 띠
            CSG.roundBox(half: [0.72, 1.15, 0.74], radius: 0.28, .translate(0, -4.35, 0), material: m.red)
              - inset([0.40, 0.70], at: [0, -4.35, 0.74], face: [0, 0, 1], material: m.red)
              - groove(from: [0.72, -4.35, 0], along: [0, 1, 0], len: 1.5, face: [1, 0, 0], material: m.suit)
              - groove(from: [-0.72, -4.35, 0], along: [0, 1, 0], len: 1.5, face: [-1, 0, 0], material: m.suit),
            CSG.roundBox(half: [0.50, 0.80, 0.18], radius: 0.08, .translate(0, -4.3, -0.70), material: m.steel),
            CSG.roundBox(half: [0.68, 0.20, 0.70], radius: 0.10, .translate(0, -5.55, 0), material: m.gold),
        ]
        if open {
            // 손바닥을 −y 로 펼친 손 (팔을 앞으로 뻗으면 카메라를 향한다)
            parts.append(CSG.roundBox(half: [0.58, 0.18, 0.62], radius: 0.14,
                                      .translate(0, -6.05, 0.15), material: m.red))
            for (i, dx) in [-0.42, -0.14, 0.14, 0.42].enumerated() {
                let len: Float = [0.42, 0.50, 0.48, 0.38][i]
                parts.append(CSG.roundBox(half: [0.12, 0.13, len], radius: 0.10,
                                          .translate(Float(dx), -6.05, 0.72 + len), material: m.red))
            }
            parts.append(CSG.roundBox(half: [0.12, 0.13, 0.36], radius: 0.10,
                                      .translate(0.72, -6.05, 0.30) * .rotateY(-40), material: m.red))
            // 리펄서
            parts.append(CSG.cylinder(.translate(0, -6.25, 0.15) * .scale(0.28, 0.04, 0.28), material: m.glow))
        } else {
            // 주먹
            parts.append(CSG.roundBox(half: [0.54, 0.58, 0.40], radius: 0.18,
                                      .translate(0, -6.3, 0.05), material: m.red))
            for dx in [-0.39, -0.13, 0.13, 0.39] as [Float] {
                parts.append(CSG.roundBox(half: [0.11, 0.34, 0.18], radius: 0.08,
                                          .translate(dx, -6.65, 0.42), material: m.red))
            }
        }
        return CSG.unionAll(parts)
    }

    // MARK: - 다리 (표준 자세: 엉덩관절 = 원점, 발바닥 = −hipY)

    static func leg(_ m: Materials) -> CSG {
        let sole = -hipY
        return CSG.unionAll([
            CSG.blob([
                B.cone([0, 0, 0], [0, -4.8, 0.05], 0.86, 0.66, blend: 0.2),
                B.cone([0, -4.8, 0.05], [0, -8.9, 0], 0.66, 0.50, blend: 0.2),
            ], material: m.suit),
            // 허벅지: 금색 판 + 바깥쪽 붉은 판
            // 판 폭은 다리 반지름 + 0.1 이하 — 넓으면 두 다리가 한 덩어리로 붙는다 (그랬다)
            CSG.roundBox(half: [0.66, 2.0, 0.78], radius: 0.28, .translate(0, -2.45, 0.05), material: m.gold)
              - groove(from: [0, -2.45, 0.83], along: [0, 1, 0], len: 3.4, face: [0, 0, 1], material: m.suit)
              - inset([0.4, 0.5], at: [0, -3.9, 0.83], face: [0, 0, 1], material: m.gold),
            CSG.roundBox(half: [0.24, 1.6, 0.56], radius: 0.14, .translate(0.60, -2.3, 0.1), material: m.red)
              - inset([0.30, 1.1], at: [0.84, -2.3, 0.1], face: [1, 0, 0], material: m.red),
            CSG.roundBox(half: [0.24, 1.6, 0.56], radius: 0.14, .translate(-0.60, -2.3, 0.1), material: m.red)
              - inset([0.30, 1.1], at: [-0.84, -2.3, 0.1], face: [-1, 0, 0], material: m.red),
            // 허벅지 앞 붉은 판 — 금 판 위에 얹힌 두 번째 층, 가로 홈
            CSG.roundBox(half: [0.36, 1.2, 0.16], radius: 0.10, .translate(0, -2.6, 0.78), material: m.red)
              - groove(from: [0, -2.2, 0.94], along: [1, 0, 0], len: 0.6, face: [0, 0, 1], material: m.suit)
              - groove(from: [0, -3.0, 0.94], along: [1, 0, 0], len: 0.6, face: [0, 0, 1], material: m.suit),
            // 허벅지 바깥 은색 원판 (사진의 회색 디스크)
            CSG.cylinder(.translate(0.86, -1.3, 0.1) * .rotateZ(90) * .scale(0.32, 0.05, 0.32), material: m.steel),
            CSG.cylinder(.translate(-0.86, -1.3, 0.1) * .rotateZ(90) * .scale(0.32, 0.05, 0.32), material: m.steel),
            // 무릎
            CSG.sphere(.translate(0, -4.85, 0.12) * .scale(0.70, 0.62, 0.70), material: m.gold),
            CSG.roundBox(half: [0.42, 0.42, 0.22], radius: 0.14, .translate(0, -4.85, 0.72), material: m.red),
            // 정강이: 붉은 판 + 금색 가운데 줄
            CSG.roundBox(half: [0.60, 1.85, 0.70], radius: 0.26, .translate(0, -6.95, 0.05), material: m.red)
              - inset([0.22, 1.2], at: [0.60, -6.95, 0.05], face: [1, 0, 0], material: m.red)
              - inset([0.22, 1.2], at: [-0.60, -6.95, 0.05], face: [-1, 0, 0], material: m.red),
            CSG.roundBox(half: [0.22, 1.7, 0.30], radius: 0.10, .translate(0, -6.9, 0.60), material: m.gold)
              - groove(from: [0, -6.9, 0.90], along: [0, 1, 0], len: 2.8, face: [0, 0, 1], material: m.suit),
            // 종아리 뒤 금색 판 + 은색 발목 관절
            CSG.roundBox(half: [0.42, 1.3, 0.22], radius: 0.10, .translate(0, -6.8, -0.62), material: m.gold),
            CSG.roundBox(half: [0.48, 0.32, 0.50], radius: 0.12, .translate(0, sole + 1.55, 0.0), material: m.steel),
            // 부츠 — 앞으로 길게
            CSG.roundBox(half: [0.70, 0.62, 1.30], radius: 0.26, .translate(0, sole + 0.62, 0.42), material: m.red)
              - groove(from: [0, sole + 0.62, 1.10], along: [1, 0, 0], len: 1.2, face: [0, 1, 0], depth: 0.05, material: m.suit)
              - inset([0.42, 0.34], at: [0.70, sole + 0.62, 0.3], face: [1, 0, 0], material: m.red)
              - inset([0.42, 0.34], at: [-0.70, sole + 0.62, 0.3], face: [-1, 0, 0], material: m.red),
            CSG.roundBox(half: [0.62, 0.30, 0.55], radius: 0.14, .translate(0, sole + 1.35, 0.95), material: m.gold),
        ])
    }

    /// 볼트 자리 (위치, 법선) — 각 부위 로컬 좌표
    static let armBolts: [(SIMD3<Float>, SIMD3<Float>)] = [
        ([ 0.48, -1.10, 0.78], [0, 0, 1]), ([-0.48, -1.10, 0.78], [0, 0, 1]),
        ([ 0.48, -2.20, 0.78], [0, 0, 1]), ([-0.48, -2.20, 0.78], [0, 0, 1]),
        ([ 0.46, -3.55, 0.74], [0, 0, 1]), ([-0.46, -3.55, 0.74], [0, 0, 1]),
        ([ 0.46, -5.15, 0.74], [0, 0, 1]), ([-0.46, -5.15, 0.74], [0, 0, 1]),
    ]
    static let legBolts: [(SIMD3<Float>, SIMD3<Float>)] = [
        ([ 0.86, -2.9, 0.1], [1, 0, 0]), ([-0.86, -2.9, 0.1], [-1, 0, 0]),
        ([ 0.86, -3.7, 0.1], [1, 0, 0]), ([-0.86, -3.7, 0.1], [-1, 0, 0]),
        ([ 0.60, -5.7, 0.05], [1, 0, 0]), ([-0.60, -5.7, 0.05], [-1, 0, 0]),
        ([ 0.60, -8.2, 0.05], [1, 0, 0]), ([-0.60, -8.2, 0.05], [-1, 0, 0]),
        ([ 0.35, -4.85, 0.94], [0, 0, 1]), ([-0.35, -4.85, 0.94], [0, 0, 1]),
    ]
    static let torsoBolts: [(SIMD3<Float>, SIMD3<Float>)] = [
        ([ 1.75, 14.55, 0.85], [0, 0, 1]), ([-1.75, 14.55, 0.85], [0, 0, 1]),
        ([ 1.30, 10.45, 1.10], [0, 0, 1]), ([-1.30, 10.45, 1.10], [0, 0, 1]),
        ([ 2.23, 13.8, 0.7], [1, 0, 0]), ([-2.23, 13.8, 0.7], [-1, 0, 0]),
        ([ 2.23, 12.6, 0.7], [1, 0, 0]), ([-2.23, 12.6, 0.7], [-1, 0, 0]),
        ([ 0.0, 15.55, 0.95], [0, 0, 1]),
    ]

    static func hips(_ m: Materials) -> CSG {
        CSG.unionAll([
            CSG.roundBox(half: [1.65, 0.32, 1.10], radius: 0.16, .translate(0, 10.45, 0.0), material: m.gold),  // 벨트
            CSG.roundBox(half: [0.72, 0.62, 0.52], radius: 0.20, .translate(0, 9.55, 0.72), material: m.red),   // 앞 판
            CSG.roundBox(half: [1.20, 0.55, 0.45], radius: 0.20, .translate(0, 9.7, -0.85), material: m.red),   // 뒤 판
            CSG.cylinder(.translate( 1.85, 9.95, 0.15) * .rotateZ(90) * .scale(0.48, 0.10, 0.48), material: m.gold),
            CSG.cylinder(.translate(-1.85, 9.95, 0.15) * .rotateZ(90) * .scale(0.48, 0.10, 0.48), material: m.gold),
        ])
    }
}
