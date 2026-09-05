//
//  Spectacles.swift
//  라운드 금테 안경 — 제품 사진용. 얼굴 좌표와 무관하게 **원점 중심, 렌즈 면 = z 0, 다리 = -z.**
//
//  참고 사진의 요소: 얇은 검은 림(에나멜), 로즈골드 브릿지·다리·힌지, 다리 끝 1/3 만 검은 아세테이트,
//  투명 코 받침, 흰 배경. 단위 = 10 cm (렌즈 지름 47 mm → 0.47, 다리 145 mm → 1.45).
//

import Foundation
import simd

enum Spectacles {
    typealias B = CSG.Blob

    static let lensR = SIMD2<Float>(0.235, 0.225)   // 판토형: 옆으로 살짝 긴 원
    static let lensX: Float = 0.34                    // 렌즈 중심 간격의 절반 (68 mm)
    static let lensY: Float = 0.02

    struct Materials {
        let rim: Int      // 검은 에나멜
        let metal: Int    // 로즈골드
        let tip: Int      // 검은 아세테이트
        let glass: Int    // 렌즈 · 코 받침
    }

    /// 림 + 브릿지 + 힌지 + 다리 (불투명 부분 전부)
    static func frame(_ m: Materials) -> CSG {
        var parts: [CSG] = []
        // 림 — 얇은 철사 고리. 원기둥 축을 z 로 눕히고 안쪽을 빼낸다
        for s: Float in [1, -1] {
            let base = float4x4.translate(s * lensX, lensY, 0) * .rotateX(90)
            // 철사 굵기 1.3 mm — 두 배로 두면 뿔테처럼 읽힌다
            parts.append(CSG.cylinder(base * .scale(lensR.x, 0.010, lensR.y), material: m.rim)
                       - CSG.cylinder(base * .scale(lensR.x - 0.013, 0.1, lensR.y - 0.013),
                                      material: m.rim))
        }
        // 금속 부분 — 브릿지 아치, 코 받침 팔, 다리 앞부분
        var gold: [B] = [
            // 브릿지 — 낮고 완만한 아치. 높이 솟으면 잠자리 안경이 된다
            B.curve([-(lensX - lensR.x) - 0.01, lensY + 0.03, 0], via: [0, lensY + 0.095, 0],
                    [ (lensX - lensR.x) + 0.01, lensY + 0.03, 0], 0.012, 0.012, blend: 0.01),
        ]
        for s: Float in [1, -1] {
            // 코 받침 팔: 림 안쪽 아래에서 코 쪽으로 굽어 내려간다
            gold.append(B.curve([s * (lensX - lensR.x + 0.02), lensY - 0.05, -0.01],
                                via: [s * 0.10, lensY - 0.10, -0.05],
                                [s * 0.085, lensY - 0.13, -0.10], 0.009, 0.008, blend: 0.01))
            // 힌지는 림의 2시 방향(위쪽 바깥)에 — 사진의 다리는 렌즈 중앙이 아니라 위에서 뻗는다
            let hy = lensY + 0.12
            let hx = s * (lensX + sqrt(max(lensR.x * lensR.x * (1 - (0.12 / lensR.y) * (0.12 / lensR.y)), 0)) + 0.012)
            let hinge = SIMD3<Float>(hx, hy, -0.015)
            gold.append(B.cone(hinge, [hx + s * 0.06, hy, -0.95], 0.012, 0.011, blend: 0.01))
            // 힌지 블록은 blob 이 아니라 **둥근 상자 부품**으로 — blob 안에 두면 다리·림과 섞여 공이 된다
            parts.append(CSG.roundBox(half: [0.016, 0.022, 0.022], radius: 0.006,
                                      .translate(hinge.x, hinge.y, hinge.z - 0.004), material: m.metal))
        }
        parts.append(CSG.blob(gold, material: m.metal))
        // 다리 끝 — 검은 아세테이트, 귀 뒤로 살짝 휜다
        var tips: [B] = []
        for s: Float in [1, -1] {
            let hx = s * (lensX + sqrt(max(lensR.x * lensR.x * (1 - (0.12 / lensR.y) * (0.12 / lensR.y)), 0)) + 0.012)
            let a = SIMD3<Float>(hx + s * 0.06, lensY + 0.12, -0.93)
            // 아세테이트 끝 — 금속보다 살짝 굵고, 끝으로 갈수록 아래로 휜다
            tips.append(B.curve(a, via: [hx + s * 0.07, lensY + 0.09, -1.25],
                                [hx + s * 0.02, lensY - 0.06, -1.45], 0.020, 0.015, blend: 0.01))
        }
        parts.append(CSG.blob(tips, material: m.tip))
        return CSG.unionAll(parts)
    }

    /// 렌즈 두 장 + 투명 코 받침
    static func glass(_ m: Materials) -> CSG {
        var parts: [CSG] = []
        for s: Float in [1, -1] {
            parts.append(CSG.cylinder(.translate(s * lensX, lensY, 0) * .rotateX(90)
                                      * .scale(lensR.x - 0.012, 0.012, lensR.y - 0.012),
                                      material: m.glass))
            parts.append(CSG.sphere(.translate(s * 0.075, lensY - 0.135, -0.11) * .rotateY(s * 25)
                                    * .scale(0.014, 0.045, 0.030), material: m.glass))
        }
        return CSG.unionAll(parts)
    }
}

// MARK: - 스퀘어 하프림 썬글라스

/// 참고 사진: 큰 사각 렌즈(모서리 둥글게), 위쪽 가장자리에만 얇은 금속 바(하프림), 이중 브릿지,
/// 렌즈 바깥 위 모서리의 힌지 리벳, 가는 금 다리에 거북등 무늬 끝, 갈색 그라데이션 렌즈.
/// 그라데이션은 재질 하나로는 안 되므로 **렌즈를 세 띠로 나눠** 위에서 아래로 옅어지게 한다.
enum SquareSunglasses {
    typealias B = CSG.Blob

    static let topHalfW: Float = 0.31, botHalfW: Float = 0.27, halfH: Float = 0.27
    static let cornerTop: Float = 0.045, cornerBot: Float = 0.10
    static let lensX: Float = 0.38                    // 렌즈 중심 (브릿지 18 mm)
    static let lensY: Float = 0.0
    static let lensZ: Float = 0.0
    static let baseCurve: Float = 1.3                 // 렌즈 구면 반지름

    struct Materials {
        let metal: Int
        let tortoise: Int
        let lens: Int         // 그라데이션 유리 (grain/gloss/sss 로 높이 착색)
        let pad: Int
    }

    /// 렌즈 윤곽 — 위가 넓고 아래 모서리가 더 둥근 사다리꼴. z 방향으로 두껍게 뽑은 기둥.
    /// (`roundedPanel` 처럼 xz 평면 다각형을 y 로 뽑은 뒤 `rotateX(90)` 으로 세운다.
    ///  그러면 다각형의 z 가 세계의 −y 가 되므로, 위쪽이 넓으려면 z 가 음수인 쪽을 넓게 둔다)
    static func lensPrism(_ x: Float, halfZ: Float, material: Int) -> CSG {
        var pts: [SIMD2<Float>] = []
        // (중심, 반지름, 시작각) — 시계 방향으로 네 모서리. 다각형 z = −y
        let corners: [(SIMD2<Float>, Float, Float)] = [
            ([ topHalfW - cornerTop, -halfH + cornerTop], cornerTop, 270),  // 위 오른쪽
            ([ botHalfW - cornerBot,  halfH - cornerBot], cornerBot, 0),    // 아래 오른쪽
            ([-botHalfW + cornerBot,  halfH - cornerBot], cornerBot, 90),   // 아래 왼쪽
            ([-topHalfW + cornerTop, -halfH + cornerTop], cornerTop, 180),  // 위 왼쪽
        ]
        for (c, r, a0) in corners {
            for k in 0...5 {
                let a = (a0 + Float(k) / 5 * 90) * .pi / 180
                pts.append(c + SIMD2<Float>(cos(a), sin(a)) * r)
            }
        }
        let sc = max(topHalfW, halfH)
        return CSG.polygon(pts.map { $0 / sc },
                           .translate(x, lensY, lensZ) * .rotateX(90) * .scale(sc, halfZ, sc),
                           material: material)
    }

    /// 렌즈 윗변의 y (사다리꼴 위쪽) 와 그 x 범위
    static var lensTop: Float { lensY + halfH }

    static func frame(_ m: Materials) -> CSG {
        var e: [B] = []
        var hinges: [CSG] = []
        for s: Float in [1, -1] {
            let top = lensTop
            // 위쪽 바 — 렌즈 윗변을 따라, 양 끝은 모서리 라운드 안쪽까지
            e.append(B.cone([s * (lensX - topHalfW + cornerTop * 0.6), top - 0.006, lensZ],
                            [s * (lensX + topHalfW - cornerTop * 0.6), top - 0.006, lensZ],
                            0.010, 0.010, blend: 0.008))
            // 바깥 위 모서리 힌지 블록 (납작한 직사각) + 다리
            let hinge = SIMD3<Float>(s * (lensX + topHalfW - 0.01), top - 0.045, lensZ - 0.03)
            hinges.append(CSG.roundBox(half: [0.020, 0.030, 0.034], radius: 0.006,
                                       .translate(hinge.x, hinge.y, hinge.z), material: m.metal))
            e.append(B.cone(hinge + [0, 0, -0.02], [s * (lensX + topHalfW + 0.05), top - 0.045, -0.98],
                            0.012, 0.010, blend: 0.008))
            // 리벳 둘 — 바깥 모서리 아래, 안쪽 모서리 아래 (렌즈를 바에 고정하는 나사)
            e.append(B.ball([s * (lensX + topHalfW - 0.05), top - 0.085, lensZ + 0.012], 0.013, blend: 0.004))
            e.append(B.ball([s * (lensX - topHalfW + 0.05), top - 0.085, lensZ + 0.012], 0.013, blend: 0.004))
            // 코 받침 팔 — 렌즈 안쪽 가장자리 **뒤**에서 시작해 코 쪽으로 굽어 내려간다.
            // 렌즈에 베이스 커브가 있어 안쪽 가장자리가 z −0.033 까지 물러나 있으므로,
            // 팔을 z 0 근처에서 시작하면 렌즈 앞으로 튀어나온 것처럼 보인다
            e.append(B.curve([s * (lensX - topHalfW + 0.015), top - 0.12, lensZ - 0.065],
                             via: [s * 0.10, lensY - 0.02, -0.11],
                             [s * 0.075, lensY - 0.07, -0.15], 0.009, 0.008, blend: 0.008))
        }
        // 브릿지 — 위쪽 직선 바 (두 렌즈의 윗바를 잇는다)
        let inner = lensX - topHalfW + 0.005
        e.append(B.cone([-inner, lensTop - 0.006, lensZ], [inner, lensTop - 0.006, lensZ],
                        0.012, 0.012, blend: 0.008))
        let metal = CSG.blob(e, material: m.metal)

        var tips: [B] = []
        for s: Float in [1, -1] {
            let a = SIMD3<Float>(s * (lensX + topHalfW + 0.05), lensTop - 0.045, -0.96)
            tips.append(B.curve(a, via: [s * (lensX + topHalfW + 0.07), lensTop - 0.07, -1.26],
                                [s * (lensX + topHalfW + 0.02), lensTop - 0.22, -1.45],
                                0.020, 0.015, blend: 0.008))
        }
        return CSG.unionAll([metal, CSG.blob(tips, material: m.tortoise)] + hinges)
    }

    /// 렌즈 — 사다리꼴 기둥 ∩ 구면 껍데기(베이스 커브). 그라데이션은 재질이 맡는다.
    static func glass(_ m: Materials) -> CSG {
        var parts: [CSG] = []
        let R = baseCurve, thick: Float = 0.018
        for s: Float in [1, -1] {
            let shell = CSG.sphere(.translate(s * lensX, lensY, lensZ - R) * .scale(R), material: m.lens)
                      - CSG.sphere(.translate(s * lensX, lensY, lensZ - R) * .scale(R - thick), material: m.lens)
            parts.append(lensPrism(s * lensX, halfZ: 0.10, material: m.lens) & shell)
            // 받침은 팔 끝, 렌즈 면보다 1.5 cm 뒤
            parts.append(CSG.sphere(.translate(s * 0.07, lensY - 0.075, -0.16) * .rotateY(s * 25)
                                    * .scale(0.012, 0.040, 0.026), material: m.pad))
        }
        return CSG.unionAll(parts)
    }
}
