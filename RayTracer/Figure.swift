//
//  Figure.swift
//  인물상 — **부드럽게 섞이는 덩어리(CSG.blob)** 로 만든 인체.
//
//  로컬 단위 = 10 cm. 키 약 16.7 ≈ 1.67 m. 발바닥이 y = 0.
//
//  **왜 처음 판이 장난감처럼 보였는가**
//  불리언 합집합으로 타원체를 쌓았기 때문이다. 두 면이 만나는 교선에서 법선이 꺾여
//  이음매가 그대로 흉터로 남고, 그 흉터를 피하려다 보면 근육 굴곡을 포기하게 된다.
//  기계는 그 능선이 오히려 부품 경계로 읽히지만 인체에서는 곧바로 "조립품"이 된다.
//
//  이번에는 **엔진 쪽을 고쳤다.** `CSG_PART_BLOB` 은 타원체들의 거리장을 smooth-min 으로
//  섞은 뒤 구 추적으로 표면을 찾는다. 이어 붙는 자리가 아예 생기지 않으므로
//  이제 인체를 **조각하듯** 만들 수 있다 — 원소를 더 얹을수록 좋아진다.
//
//  세 가지가 함께 필요했다:
//   1. 형상: 이 파일 (blob)
//   2. 셰이딩: `Material.sss` — 피부는 명암 경계가 칼같이 끊기면 석고상이 된다
//   3. 자세: 콘트라포스토. 좌우 대칭으로 세워 두면 아무리 잘 조각해도 마네킹이다
//
//  **자세** — 오른다리(+x)에 체중을 싣는다. 그러면 실제 인체에서 이런 연쇄가 일어난다:
//    체중 쪽 골반이 올라가고 → 척추가 반대로 휘고 → 어깨선이 골반과 **반대로** 기울고
//    → 노는 다리는 무릎이 앞으로 살짝 굽는다. 이 연쇄를 좌표에 그대로 박아 뒀다.
//

import Foundation
import simd

enum Figure {

    struct Materials {
        let skin: Int
        let hair: Int
        let sclera: Int
        let limbus: Int
        let iris: Int
        let pupil: Int
        let cornea: Int
        let lip: Int
        let suit: Int
        var brow: Int = 0     // 눈썹 — 머리카락보다 옅은 갈색이어야 험상궂지 않다
    }

    typealias B = CSG.Blob

    /// 옷은 몸의 원소를 그대로 쓰되 SDF 에서 이 값을 뺀다 = **정확한 오프셋 표면**.
    static let inflate: Float = 0.055

    // MARK: - 몸통 + 머리 (덩어리 하나)
    //
    // 목·어깨·가슴이 한 덩어리 안에서 섞여야 매끄럽다. 오브젝트를 나누면
    // 그 경계가 다시 이음매가 되므로, 구간 한계가 허락하는 한 **한 덩어리로 둔다.**
    // 몸통은 어느 방향으로 잘라도 구간 하나라 안전하다 (팔·다리는 따로 뺀 이유가 그것).

    static func torsoElements(_ full: Bool) -> [B] {
        var e: [B] = [
            // 골반 — 체중 쪽(오른쪽) 엉덩이가 **올라가 있다.** 이 기울기가 콘트라포스토의 시작이다
            B.ell([ 0.30,  9.15, -0.05], [1.52, 1.26, 0.90], blend: 0.85),
            B.ell([ 1.02,  9.38, -0.10], [0.76, 0.80, 0.84], blend: 0.70),
            B.ell([-0.48,  8.94, -0.10], [0.76, 0.80, 0.84], blend: 0.70),
            B.ell([ 0.98,  9.18, -0.62], [0.84, 0.80, 0.70], blend: 0.60),   // 볼기
            B.ell([-0.42,  8.78, -0.62], [0.84, 0.80, 0.70], blend: 0.60),
            // 허리 — 폭과 **두께**를 함께 줄인다. 폭만 줄이면 옆에서 배가 그대로 나온다
            B.ell([ 0.12, 10.95,  0.00], [1.04, 1.24, 0.70], blend: 0.85),
            B.ell([ 0.16, 10.15,  0.24], [0.80, 0.58, 0.50], blend: 0.55),   // 아랫배
            // 흉곽 — 꼭대기가 턱보다 낮아야 목이 생긴다
            B.ell([-0.08, 12.45,  0.00], [1.54, 1.12, 0.90], blend: 0.75),
            B.ell([-0.14, 13.02, -0.05], [1.36, 0.58, 0.82], blend: 0.55),
            B.ell([ 0.46, 12.26,  0.52], [0.64, 0.56, 0.62], blend: 0.30),   // 가슴 (어깨 기울기를 따라간다)
            B.ell([-0.76, 12.40,  0.52], [0.64, 0.56, 0.62], blend: 0.30),
            // 승모근 — 목에서 어깨로 내려오는 경사. 이게 없으면 목 옆에 공이 두 개 얹힌다
            B.ell([ 0.42, 13.06, -0.12], [0.90, 0.44, 0.68], blend: 0.50),
            B.ell([-0.74, 13.28, -0.12], [0.90, 0.44, 0.68], blend: 0.50),
            // 삼각근 — 어깨선. 골반과 **반대로** 기울어 있다 (오른쪽이 낮다)
            B.ell([ 1.18, 12.98,  0.00], [0.58, 0.62, 0.58], blend: 0.45),
            B.ell([-1.48, 13.26,  0.00], [0.58, 0.62, 0.58], blend: 0.45),
            B.ell([-0.05, 14.00,  0.02], [0.47, 0.85, 0.48], blend: 0.45),   // 목 — 큰 머리에 가는 목이면 기린이 된다
        ]
        guard full else { return e }
        e += [
            // 쇄골 위 오목 — 작지만 여기가 파여 있어야 어깨가 어깨로 읽힌다
            // 음의 원소는 **아주 작게** 시작한다. 처음 값(0.52×0.15×0.30)은 어깨에 구덩이를 팠다
            B.ell([ 0.44, 13.16,  0.62], [0.26, 0.07, 0.14], blend: 0.10, negative: true),
            B.ell([-0.72, 13.34,  0.62], [0.26, 0.07, 0.14], blend: 0.10, negative: true),
            B.ell([ 0.14, 10.22,  0.58], [0.09, 0.12, 0.13], blend: 0.05, negative: true), // 배꼽
        ]
        e += headElements()
        return e
    }

    // MARK: - 얼굴
    //
    // 얼굴은 **원소를 얹는 순서가 곧 조각 순서**다. 두개골 → 턱 → 광대 → 눈두덩(음각)
    // → 눈꺼풀 → 코 순으로 접으면 눈꺼풀이 파인 눈두덩 위에 제대로 얹힌다.
    // 순서를 바꾸면 눈꺼풀이 통째로 파여 사라진다.

    /// 머리 중심. 사진과 비교해 잡은 비율:
    ///   **이마 : 코 : 턱 = 1 : 1 : 1** (헤어라인 16.41 · 눈썹 15.80 · 코끝 15.08 · 턱끝 14.40)
    ///   얼굴 폭 / 얼굴 길이 ≈ 0.78 (좁은 계란형), 눈은 실제 크기, 눈썹은 눈에서 0.18 위.
    /// 처음엔 눈이 만화처럼 크고 눈썹이 높고 이마가 얼굴의 절반이었다 — 그게 "예쁘지 않은" 이유였다.
    static let headC = SIMD3<Float>(-0.02, 15.70, -0.02)

    static func headElements() -> [B] {
        let c = headC
        func at(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { c + [x, y - 15.70, z] }
        return [
            B.ell(at(0, 15.72, 0.00), [0.86, 1.20, 0.95], blend: 0.40),   // 두개골 (폭/길이 ≈ 0.8)
            B.ell(at(0, 15.95,-0.30), [0.80, 0.94, 0.86], blend: 0.45),   // 뒤통수
            B.ell(at(0, 15.00, 0.12), [0.52, 0.48, 0.58], blend: 0.34),   // 턱 — 좁고 매끈한 턱선
            B.ell(at(0, 14.60, 0.32), [0.20, 0.14, 0.20], blend: 0.16),   // 턱끝 — 작고 부드럽게
            B.ell(at( 0.50, 15.25, 0.50), [0.30, 0.27, 0.29], blend: 0.35), // 광대 — 은은하게
            B.ell(at(-0.54, 15.25, 0.50), [0.30, 0.27, 0.29], blend: 0.35),
            // 볼 — 크게 두면 다람쥐 볼이 되고 입까지 파묻힌다. 작게, 광대 바로 아래 바깥쪽에
            B.ell(at( 0.50, 15.02, 0.40), [0.22, 0.22, 0.18], blend: 0.40),
            B.ell(at(-0.54, 15.02, 0.40), [0.22, 0.22, 0.18], blend: 0.40),
            // 눈확 — 실제 크기의 아몬드형, **눈꼬리가 올라가게 7° 기울인다** (회전 타원체).
            // 눈 사이 간격 = 눈 하나 폭. 처음엔 간격이 폭의 0.7 이라 눈이 몰려 보였다
            B.ell(at( 0.44, 15.62, 0.84), [0.235, 0.125, 0.16], blend: 0.08, negative: true,
                  tilt: ([0, 0, 1],  7)),
            B.ell(at(-0.48, 15.62, 0.84), [0.235, 0.125, 0.16], blend: 0.08, negative: true,
                  tilt: ([0, 0, 1], -7)),
            // 눈꺼풀 — 같은 각도로 기울여 트임(높이 0.15)이 눈확을 따라간다
            B.ell(at( 0.44, 15.81, 0.64), [0.255, 0.080, 0.20], blend: 0.06, tilt: ([0, 0, 1],  7)),
            B.ell(at( 0.44, 15.48, 0.65), [0.235, 0.060, 0.19], blend: 0.06, tilt: ([0, 0, 1],  7)),
            B.ell(at(-0.48, 15.81, 0.64), [0.255, 0.080, 0.20], blend: 0.06, tilt: ([0, 0, 1], -7)),
            B.ell(at(-0.48, 15.48, 0.65), [0.235, 0.060, 0.19], blend: 0.06, tilt: ([0, 0, 1], -7)),
            // 쌍꺼풀선 — 위 눈꺼풀 바로 위를 따라가는 얕은 음각 곡선 (눈꺼풀 다음에 접는다)
            B.curve(at( 0.22, 15.83, 0.76), via: at( 0.44, 15.92, 0.80), at( 0.68, 15.86, 0.62),
                    0.012, 0.010, blend: 0.025, negative: true),
            B.curve(at(-0.26, 15.83, 0.76), via: at(-0.48, 15.92, 0.80), at(-0.72, 15.86, 0.62),
                    0.012, 0.010, blend: 0.025, negative: true),
            // 코 — 미간에서 시작해 곧게 내려오는 콧날 (원뿔) + 작은 코끝
            // 곧은 원뿔로 두면 얼굴에서 능선처럼 튀어나와 짙은 그림자를 만든다.
            // 베지에로 미간에서는 표면 안에 있다가 코끝으로 갈수록 드러나게 한다
            B.curve(at(0, 15.52, 0.84), via: at(0, 15.34, 0.88), at(0, 15.18, 0.91),
                    0.048, 0.072, blend: 0.06),
            B.ell(at(0, 15.13, 0.92), [0.086, 0.074, 0.088], blend: 0.055),
            B.ell(at( 0.095, 15.10, 0.85), [0.050, 0.044, 0.062], blend: 0.045),  // 콧방울
            B.ell(at(-0.135, 15.10, 0.85), [0.050, 0.044, 0.062], blend: 0.045),
            // 입선 — 양 끝이 올라간 두 마디 (미소)
            B.cone(at(-0.25, 14.815, 0.66), at(0, 14.795, 0.76), 0.010, 0.012, blend: 0.025, negative: true),
            B.cone(at( 0.25, 14.815, 0.66), at(0, 14.795, 0.76), 0.010, 0.012, blend: 0.025, negative: true),
            B.ell(at( 0.86, 15.55,-0.06), [0.09, 0.24, 0.18], blend: 0.11),  // 귀
            B.ell(at(-0.90, 15.55,-0.06), [0.09, 0.24, 0.18], blend: 0.11),
        ]
    }

    /// 흉상 — 머리 + 목 + 어깨·윗가슴을 어깨 높이에서 평평하게 자른 것. 고전 흉상의 절단.
    /// 쇄골 음각은 뺀다 — 절단면 바로 위라 가슴에 뚫린 검은 구멍처럼 보인다.
    static func bust(_ m: Materials) -> CSG {
        let e = Array(torsoElements(false)[7...15]) + headElements()
        return CSG.blob(e, material: m.skin)
             & CSG.box(.translate(0, 14.9, 0) * .scale(4, 2.0, 4), material: m.skin)  // y ≥ 12.9
    }

    static func torso(_ m: Materials) -> CSG {
        CSG.blob(torsoElements(true), material: m.skin)
    }

    /// 입술 — 폭은 두 동공 사이 정도, 아랫입술이 더 도톰하게.
    static func lips(_ m: Materials) -> CSG {
        let c = headC
        func upper(_ sg: Float) -> B {       // 입꼬리 → 산 → 가운데 결절
            B.curve(c + [0.24 * sg, -0.905, 0.62], via: c + [0.12 * sg, -0.835, 0.73],
                    c + [0.0, -0.87, 0.725], 0.022, 0.056, blend: 0.04)
        }
        return CSG.blob([
            upper(1), upper(-1),
            B.ell(c + [0.0, -0.985, 0.68], [0.20, 0.066, 0.082], blend: 0.05),     // 아랫입술
            B.curve(c + [0.24, -0.905, 0.62], via: c + [0.15, -1.0, 0.68],
                    c + [0.0, -1.01, 0.69], 0.018, 0.046, blend: 0.04),
            B.curve(c + [-0.24, -0.905, 0.62], via: c + [-0.15, -1.0, 0.68],
                    c + [0.0, -1.01, 0.69], 0.018, 0.046, blend: 0.04),
        ], material: m.lip)
    }

    /// 안구 — 실제 크기. 어두운 홍채가 트임의 대부분을 채우고 위 눈꺼풀이 살짝 덮는다.
    static func eyes(_ m: Materials) -> CSG {
        let c = headC
        func eye(_ x: Float) -> CSG {
            let e = c + [x, -0.08, 0.60]
            return CSG.sphere(.translate(e.x, e.y, e.z) * .scale(0.20), material: m.sclera)
              | CSG.sphere(.translate(e.x, e.y, e.z + 0.158) * .scale(0.160, 0.160, 0.058),
                           material: m.limbus)
              | CSG.sphere(.translate(e.x, e.y, e.z + 0.168) * .scale(0.135, 0.135, 0.058),
                           material: m.iris)
              | CSG.sphere(.translate(e.x, e.y, e.z + 0.194) * .scale(0.066, 0.066, 0.040),
                           material: m.pupil)
              | CSG.sphere(.translate(e.x - 0.045, e.y + 0.055, e.z + 0.212) * .scale(0.028, 0.021, 0.022),
                           material: m.sclera)
        }
        return eye(0.44) | eye(-0.48)
    }

    /// 속눈썹 + 아이라인 — 윗눈꺼풀 가장자리, 바깥 끝을 살짝 올려 뺀다
    static func lashes(_ m: Materials) -> CSG {
        let c = headC
        func lash(_ x: Float, _ s: Float) -> [B] {
            [B.ell(c + [x, 0.005, 0.85], [0.235, 0.020, 0.040], blend: 0.02),
             B.cone(c + [x + 0.20 * s, 0.01, 0.80], c + [x + 0.30 * s, 0.05, 0.71],
                    0.022, 0.008, blend: 0.02)]
        }
        return CSG.blob(lash(0.44, 1) + lash(-0.48, -1), material: m.hair)
    }

    /// 눈썹 — 베지에 튜브 한 줄. 안쪽이 굵고 바깥으로 가늘어지며, 살짝 위로 휜다
    static func brows(_ m: Materials) -> CSG {
        let c = headC
        func brow(_ s: Float) -> B {
            B.curve(c + [0.17 * s, 0.09, 0.88], via: c + [0.48 * s, 0.175, 0.86],
                    c + [0.76 * s, 0.07, 0.66], 0.056, 0.020, blend: 0.03)
        }
        return CSG.blob([brow(1), brow(-1)], material: m.brow)
    }

    /// 머리카락 — 가운데 가르마의 긴 검은 생머리. 좁아진 두개골에 맞춰 다시 계산했다.
    /// 앞 타래는 두개골 표면 + 0.12 (타원체식으로 계산). 얼굴을 파낸 **뒤에** 앞 타래를 접는다.
    /// 사진처럼 오른쪽(+x)은 귀 뒤로 넘기고 관자놀이에 잔머리 한 가닥, 왼쪽(-x)은 한 타래가 어깨 앞으로.
    static func hairCap(_ m: Materials) -> CSG {
        let c = headC
        return CSG.blob([
            B.ell(c + [ 0.00,  0.18, -0.04], [0.90, 1.24, 1.02], blend: 0.32),  // 두상에 딱 붙는 캡
            B.ell(c + [ 0.00,  0.52, -0.30], [0.70, 0.52, 0.76], blend: 0.40),  // 정수리 볼륨 (낮게)
            B.ell(c + [ 0.00, -1.60, -0.75], [0.90, 2.10, 0.62], blend: 0.55),  // 뒷머리 (길게)
            // 귀 뒤로 넘어가 목을 감싸며 어깨 뒤로 떨어지는 옆 타래
            // 베지에 튜브 — 목을 감싸며 내려오다 끝이 살짝 앞으로 흐른다 (곧은 원뿔은 판때기)
            B.curve(c + [ 0.86,  0.05, -0.30], via: c + [ 0.78, -1.50, -0.40],
                    c + [ 0.96, -2.95,  0.10], 0.30, 0.22, blend: 0.30),
            B.curve(c + [-0.90,  0.05, -0.30], via: c + [-0.82, -1.50, -0.40],
                    c + [-1.00, -2.95,  0.10], 0.30, 0.22, blend: 0.30),
            B.ell(c + [ 0.70, -1.30, -0.55], [0.32, 1.20, 0.40], blend: 0.40),  // 목 옆 채움
            B.ell(c + [-0.74, -1.30, -0.55], [0.32, 1.20, 0.40], blend: 0.40),
            // 볼 옆을 감싸는 앞쪽 볼륨 — 사진처럼 머리카락이 얼굴을 안는다
            B.ell(c + [ 0.84, -1.20, -0.12], [0.20, 0.95, 0.30], blend: 0.35),   // +x: 귀 뒤로 넘긴다
            B.ell(c + [-0.92, -0.75,  0.30], [0.22, 0.95, 0.32], blend: 0.35),   // -x: 볼 앞으로
            B.ell(c + [ 0.00, -0.42,  1.06], [0.76, 1.02, 0.94], blend: 0.24, negative: true), // 얼굴 (헤어라인 16.30, 경계 부드럽게)
            B.ell(c + [ 0.90, -0.15,  0.06], [0.20, 0.34, 0.30], blend: 0.08, negative: true), // 귀 노출
            B.ell(c + [-0.94, -0.15,  0.06], [0.20, 0.34, 0.30], blend: 0.08, negative: true),
            B.ell(c + [ 0.00,  1.20,  0.30], [0.018, 0.20, 0.70], blend: 0.05, negative: true), // 가르마
            // 가르마에서 관자놀이로 두피를 따라 내려가는 헤어라인 타래
            // 헤어라인 — 가르마에서 관자놀이까지 한 줄의 베지에 (원뿔 세 마디는 꺾인 각이 남았다)
            B.curve(c + [ 0.05,  1.04,  0.52], via: c + [ 0.60,  0.86,  0.76],
                    c + [ 0.88, -0.05,  0.22], 0.11, 0.12, blend: 0.20),
            B.curve(c + [-0.05,  1.04,  0.52], via: c + [-0.64,  0.86,  0.76],
                    c + [-0.92, -0.05,  0.22], 0.14, 0.12, blend: 0.16),
            // 왼쪽(-x) 앞으로 떨어지는 한 타래 — 완만한 S
            B.curve(c + [-0.92, -0.05,  0.22], via: c + [-1.12, -1.40,  0.60],
                    c + [-0.98, -2.80,  0.40], 0.18, 0.13, blend: 0.22),
            // 오른쪽(+x) 관자놀이 앞의 잔머리 한 가닥
            B.cone(c + [ 0.78,  0.30,  0.50], c + [ 0.92, -0.95,  0.52], 0.065, 0.035, blend: 0.05),
        ], material: m.hair)
    }

    /// 안경 스타일. 렌즈 크기·테 두께·다리 굵기가 다르고, 재질은 씬이 정한다.
    struct Eyewear {
        var lensR: SIMD2<Float>      // 타원 렌즈 반지름 (x, y)
        var rimWidth: Float          // 고리 폭
        var rimThick: Float          // 고리 앞뒤 두께 (반)
        var templeR: Float           // 다리 반지름
        var lensZ: Float             // 렌즈 면의 z (속눈썹 앞, 코끝 옆)

        /// 얇은 금테 안경
        static let glasses = Eyewear(lensR: [0.34, 0.27], rimWidth: 0.03, rimThick: 0.028,
                                     templeR: 0.022, lensZ: 1.00)
        /// 굵은 테 썬글라스 — 렌즈가 크고 테가 두껍다
        static let sunglasses = Eyewear(lensR: [0.43, 0.30], rimWidth: 0.070, rimThick: 0.055,
                                        templeR: 0.040, lensZ: 1.02)
    }

    static var lensCenters: [SIMD3<Float>] {
        [headC + [0.37, -0.08, 0], headC + [-0.41, -0.08, 0]]
    }

    /// 안경테. 림은 원기둥에서 원기둥을 뺀 납작한 타원 고리, 브릿지·다리는 베지에 튜브로
    /// 귀 위를 지나 귀 뒤로 휘어 내려간다. 렌즈는 별도 오브젝트 (`eyewearLenses`).
    static func eyewearFrame(_ e: Eyewear, material: Int) -> CSG {
        var parts: [CSG] = []
        for lc in lensCenters {
            let base = float4x4.translate(lc.x, lc.y, e.lensZ) * .rotateX(90)
            parts.append(CSG.cylinder(base * .scale(e.lensR.x, e.rimThick, e.lensR.y), material: material)
                       - CSG.cylinder(base * .scale(e.lensR.x - e.rimWidth, 0.3, e.lensR.y - e.rimWidth),
                                      material: material))
        }
        let c = headC
        let z = e.lensZ, t = e.templeR
        let ox = e.lensR.x + 0.03                      // 림 바깥 가장자리
        let bridge = CSG.blob([
            B.curve(c + [ 0.37 - ox + 0.04, -0.02, z], via: c + [-0.02, 0.05, z],
                    c + [-0.41 + ox - 0.04, -0.02, z], t, t, blend: 0.02),
            B.ball(c + [ 0.10, -0.20, 0.90], 0.026, blend: 0.02),     // 코 받침
            B.ball(c + [-0.14, -0.20, 0.90], 0.026, blend: 0.02),
        ], material: material)
        func temple(_ sx: Float, _ x0: Float) -> [B] {
            [B.curve(c + [x0 * sx, -0.05, z - 0.03], via: c + [(x0 + 0.20) * sx, -0.02, 0.50],
                     c + [0.88 * sx, -0.08, -0.05], t, t * 0.85, blend: 0.02),
             B.curve(c + [0.88 * sx, -0.08, -0.05], via: c + [0.90 * sx, -0.25, -0.28],
                     c + [0.84 * sx, -0.48, -0.20], t * 0.85, t * 0.6, blend: 0.02)]
        }
        let temples = CSG.blob(temple(1, 0.37 + ox) + temple(-1, 0.41 + ox), material: material)
        return CSG.unionAll(parts + [bridge, temples])
    }

    static func eyewearLenses(_ e: Eyewear, material: Int) -> CSG {
        CSG.unionAll(lensCenters.map { lc in
            CSG.cylinder(.translate(lc.x, lc.y, e.lensZ) * .rotateX(90)
                         * .scale(e.lensR.x - e.rimWidth + 0.01, 0.012, e.lensR.y - e.rimWidth + 0.01),
                         material: material)
        })
    }

    /// 크림색 오프숄더 드레스 — 흉상 절단면을 덮는 천 띠
    static func dress(_ m: Materials, cloth mat: Int) -> CSG {
        let e = Array(torsoElements(false)[7...15])
        return cloth(e, mat) & CSG.box(.translate(0, 13.05, 0) * .scale(6, 0.42, 6), material: mat)
             | (CSG.blob(e, material: mat)
                & CSG.box(.translate(0, 12.65, 0) * .scale(6, 0.30, 6), material: mat))  // 절단면 아래는 통짜
    }

    /// 드롭 귀걸이 — 은구슬 셋 + 큰 방울 하나
    static func earrings(_ metal: Int) -> CSG {
        let c = headC
        func chain(_ x: Float) -> [CSG] {
            let base = c + [x, -0.30, -0.02]
            return [
                CSG.sphere(.translate(base.x, base.y, base.z) * .scale(0.040), material: metal),
                CSG.sphere(.translate(base.x, base.y - 0.13, base.z) * .scale(0.042), material: metal),
                CSG.sphere(.translate(base.x, base.y - 0.27, base.z) * .scale(0.046), material: metal),
                CSG.sphere(.translate(base.x, base.y - 0.45, base.z) * .scale(0.075, 0.095, 0.075),
                           material: metal),
                CSG.cylinder(.translate(base.x, base.y - 0.22, base.z) * .scale(0.012, 0.24, 0.012),
                             material: metal),
            ]
        }
        return CSG.unionAll(chain(0.90) + chain(-0.94))
    }

    // MARK: - 팔
    //
    // 마디는 **둥근 원뿔**이다. 구를 줄줄이 꿰면 간격이 반지름의 1.5배만 넘어도
    // 메타볼 사슬이 울퉁불퉁한 소시지가 된다 (처음 판이 그랬다).
    // 원뿔 하나가 마디 전체를 덮으므로 길이 방향으로는 애초에 이음매가 없고,
    // 마디끼리는 끝점을 공유하니 smooth-min 이 관절만 둥글려 준다.
    //
    // 좌우를 대칭으로 두지 않는다. 체중을 실은 오른쪽 어깨가 낮으므로 오른팔이 더 아래에서
    // 시작하고, 노는 왼팔은 팔꿈치부터 앞으로 나온다.

    static func armElements(right: Bool) -> [B] {
        // (점, 반지름) — 어깨 → 위팔 → 팔꿈치 → 전완근 → 손목
        let st: [(SIMD3<Float>, Float)] = right ? [
            ([1.16, 12.82, 0.00], 0.43),
            ([1.44, 11.40, 0.06], 0.385),
            ([1.62, 10.52, 0.13], 0.325),   // 팔꿈치 — 여기가 잘록하다
            ([1.75,  9.86, 0.20], 0.345),   // 전완근이 다시 살짝 붙는다
            ([1.87,  9.02, 0.28], 0.265),
            ([1.94,  8.42, 0.33], 0.245),   // 손목
        ] : [
            ([-1.46, 13.10, 0.00], 0.43),
            ([-1.72, 11.68, 0.09], 0.385),
            ([-1.85, 10.82, 0.20], 0.325),
            ([-1.91, 10.12, 0.36], 0.345),
            ([-1.94,  9.24, 0.56], 0.265),
            ([-1.96,  8.66, 0.66], 0.245),
        ]
        var e: [B] = []
        for k in 0..<(st.count - 1) {
            e.append(B.cone(st[k].0, st[k + 1].0, st[k].1, st[k + 1].1, blend: 0.04))
        }

        // 손 — 손바닥 + 손가락 넷 + 엄지. 이 크기에서 손가락은 겨우 몇 픽셀이지만,
        // **있고 없고가 사람과 마네킹을 가른다.**
        let s: Float = right ? 1 : -1
        let w = st[st.count - 1].0
        // 실제 손은 길다 — 손목에서 중지 끝까지 18 cm. 작게 만들면 몸이 커 보인다
        let palm = w + SIMD3<Float>(0.04 * s, -0.50, 0.02)
        e.append(B.ell(palm, [0.245, 0.40, 0.105], blend: 0.13))
        let spread: [Float] = [-0.165, -0.056, 0.056, 0.162]
        let len: [Float] = [0.62, 0.78, 0.74, 0.58]
        for (i, dx) in spread.enumerated() {
            let root = palm + SIMD3<Float>(dx * s, -0.30, 0.01)
            let tip  = root + SIMD3<Float>(dx * s * 0.25, -len[i], 0.04)
            e.append(B.cone(root, tip, 0.058, 0.044, blend: 0.03))
        }
        let tRoot = palm + SIMD3<Float>(-0.21 * s, 0.10, 0.07)
        e.append(B.cone(tRoot, tRoot + SIMD3<Float>(-0.13 * s, -0.46, 0.12),
                        0.078, 0.056, blend: 0.04))
        return e
    }

    static func arm(_ m: Materials, right: Bool) -> CSG {
        CSG.blob(armElements(right: right), material: m.skin)
    }

    // MARK: - 다리
    //
    // 무릎이 가장 가늘고 장딴지에서 다시 굵어지는 것, 그리고 장딴지 최대 지름이
    // **뒤쪽으로 치우쳐** 있는 것이 다리를 다리로 만든다.

    static func legElements(right: Bool) -> [B] {
        // 오른다리 = 체중을 실은 쪽. 수직으로 곧고 골반이 높다.
        // 왼다리 = 노는 쪽. 무릎이 앞·바깥으로 나가고 발이 앞에 놓인다.
        let st: [(SIMD3<Float>, Float)] = right ? [
            ([0.98,  9.30, -0.05], 0.90),   // 엉덩관절
            ([0.94,  7.70,  0.02], 0.84),
            ([0.89,  6.30,  0.06], 0.74),
            ([0.83,  5.00,  0.09], 0.60),
            ([0.80,  4.28,  0.12], 0.485),  // 무릎 — 가장 가늘다
            ([0.77,  3.55,  0.00], 0.545),
            ([0.76,  3.00, -0.09], 0.560),  // 장딴지 최대 (뒤로 치우침)
            ([0.74,  1.90, -0.02], 0.345),
            ([0.72,  0.92, -0.02], 0.30),   // 발목
        ] : [
            ([-0.50,  8.90, -0.05], 0.90),
            ([-0.62,  7.40,  0.10], 0.84),
            ([-0.75,  6.08,  0.24], 0.74),
            ([-0.86,  4.90,  0.39], 0.60),
            ([-0.92,  4.18,  0.46], 0.485),
            ([-0.96,  3.46,  0.34], 0.545),
            ([-1.00,  2.90,  0.23], 0.560),
            ([-1.04,  1.86,  0.26], 0.345),
            ([-1.08,  0.90,  0.26], 0.30),
        ]
        var e: [B] = []
        for k in 0..<(st.count - 1) {
            // 이웃한 원뿔은 끝 반지름이 같아 이미 이어져 있다. blend 는 기울기가 꺾이는
            // 자리만 둥글리면 되므로 작게 — 크게 주면 smin 이 관절마다 k/4 만큼 살을 더해
            // 다리 윤곽이 **물결처럼** 출렁인다 (그랬다).
            e.append(B.cone(st[k].0, st[k + 1].0, st[k].1, st[k + 1].1, blend: 0.04))
        }
        let s: Float = right ? 1 : -1
        let knee = st[4].0, ankle = st[8].0
        e.append(B.ell(knee + [0, 0.04, 0.34], [0.25, 0.29, 0.14], blend: 0.14))  // 슬개골
        e.append(B.ball(ankle + [0.26 * s, 0.06, 0], 0.11, blend: 0.06))           // 복사뼈
        // 발 — 실제 길이 24 cm. 뒤꿈치 · 발등 · 앞볼 · 발가락. 뒤꿈치가 없으면 쐐기가 된다
        let f = SIMD3<Float>(ankle.x, 0, ankle.z)
        e.append(B.ell(f + [0, 0.42, -0.42], [0.30, 0.36, 0.34], blend: 0.20))
        e.append(B.ell(f + [0, 0.32,  0.20], [0.33, 0.28, 0.62], blend: 0.22))
        e.append(B.ell(f + [0, 0.25,  0.98], [0.36, 0.21, 0.42], blend: 0.17))
        e.append(B.cone(f + [-0.10 * s, 0.21, 1.30], f + [-0.16 * s, 0.20, 1.55],
                        0.17, 0.12, blend: 0.07))
        e.append(B.cone(f + [-0.26 * s, 0.22, 1.28], f + [-0.30 * s, 0.21, 1.62],
                        0.13, 0.10, blend: 0.05))   // 엄지발가락
        // 발바닥 아치 — 파내야 발이 통짜 덩어리가 아니게 된다
        e.append(B.ell(f + [0.10 * s, -0.16, 0.45], [0.42, 0.30, 0.42], blend: 0.16, negative: true))
        return e
    }

    static func leg(_ m: Materials, right: Bool) -> CSG {
        CSG.blob(legElements(right: right), material: m.skin)
    }

    // MARK: - 수영복
    //
    // **몸의 원소를 그대로 쓰고 `inflate` 만 준다.** SDF 에서 상수를 빼는 것이므로
    // 정확한 오프셋 표면이 되고, 실루엣이 몸을 한 치도 어긋나지 않게 따라간다.
    // 천을 따로 모델링하면 반드시 파고들거나 뜬다.
    //
    // 그리고 **부풀린 것에서 원래 몸을 빼서 껍데기로 만든다.** 이걸 빠뜨리면
    // `덩어리 ∩ 마스크` 가 통짜 슬래브가 되어, 위에서 내려다볼 때 몸통 단면만 한
    // **평평한 선반**이 드러난다 (처음에 옷에 커다란 구멍이 난 것처럼 보였던 게 이것이다).

    /// 몸을 `inflate` 만큼 부풀린 뒤 원래 몸을 빼낸 **천 두께의 껍데기**
    private static func cloth(_ e: [B], _ mat: Int) -> CSG {
        CSG.blob(e, inflate: inflate, material: mat) - CSG.blob(e, material: mat)
    }

    static func bikiniTop(_ m: Materials) -> CSG {
        // **몸통 원소를 하나도 빼지 않는다.** 일부만 골라 껍데기를 만들면
        // 빠뜨린 원소(목·승모근)가 만든 살이 옷을 뚫고 나온다.
        let e = torsoElements(false)
        let band = cloth(e, m.suit) & CSG.box(.translate(0, 12.36, 0) * .scale(6, 0.62, 6),
                                              material: m.suit)
        // 어깨끈도 같은 껍데기를 얇은 판으로 자른 것 — 그래야 어깨 곡면에 딱 붙는다.
        // 공중에 캡슐을 그으면 어깨에서 뜬다.
        let strapR = cloth(e, m.suit) & CSG.box(.translate(0.66, 13.5, -0.05) * .rotateZ(-12)
                                                * .scale(0.105, 1.2, 1.1), material: m.suit)
        let strapL = cloth(e, m.suit) & CSG.box(.translate(-0.98, 13.7, -0.05) * .rotateZ(12)
                                                * .scale(0.105, 1.2, 1.1), material: m.suit)
        return CSG.unionAll([band, strapR, strapL])
    }

    static func bikiniBottom(_ m: Materials) -> CSG {
        // 골반 + 양쪽 허벅지 위쪽. 다리는 다른 오브젝트라 여기서 다시 모아 준다
        var e = Array(torsoElements(false)[0...6])
        e.append(legElements(right: true)[0])     // 허벅지 위쪽 (엉덩관절 원뿔)
        e.append(legElements(right: false)[0])
        return (cloth(e, m.suit) & CSG.box(.translate(0.10, 8.80, 0) * .scale(6, 0.88, 6),
                                           material: m.suit))
             - CSG.sphere(.translate( 1.72, 7.90, 0.10) * .scale(0.90, 1.22, 1.45),
                          material: m.suit)
             - CSG.sphere(.translate(-1.24, 7.72, 0.24) * .scale(0.90, 1.22, 1.45),
                          material: m.suit)
    }
}
