//
//  SportsCar.swift
//  1960년대 영국 로드스터 (E-타입풍). 참고: 위키미디어 커먼스 사진 3장 (측면·전시장·후면 3/4).
//
//  단위 = 10 cm. 전장 44.5 · 전폭 16.5 · 휠베이스 24.4 · 타이어 반지름 3.3. 앞 = +x, 바닥 y = 0.
//
//  **차체는 blob 이다.** 이 차의 매력은 이음매 없이 흐르는 곡면이라 상자를 쌓아서는 안 된다.
//  타원체 열 개를 smooth-min 으로 섞은 덩어리를 바닥 평면·휠 아치·콕핏·그릴 입으로 **잘라 낸다**.
//  와이어 휠은 스포크 하나를 48 × 4 = 192번 인스턴싱한다.
//

import Foundation
import simd

enum SportsCar {
    typealias B = CSG.Blob

    struct Materials {
        let paint: Int, chrome: Int, glass: Int, rubber: Int
        let black: Int, leather: Int, lamp: Int, amber: Int, red: Int
    }

    static let axleX: Float = 12.2, wheelY: Float = 3.3, trackZ: Float = 6.9
    static let sillY: Float = 2.5

    // MARK: - 차체

    static func bodyBlob(_ mat: Int, inflate: Float = 0) -> CSG {
        CSG.blob([
            B.ell([ 19.8, 4.9, 0], [3.4, 1.9, 4.9], blend: 2.0),                 // 코 — 낮고 뾰족하게
            B.ell([ 12.0, 5.4, 0], [10.5, 2.5, 7.0], blend: 2.4),                // 보닛 — 앞으로 갈수록 낮게
            B.ell([  3.0, 5.7, 0], [6.5, 2.7, 7.9], blend: 2.4),                 // 카울
            B.ell([ -4.0, 5.5, 0], [8.0, 2.65, 8.3], blend: 2.4),                // 도어 — 허리선을 낮게
            B.ell([-12.0, 5.6, 0], [8.0, 2.5, 7.8], blend: 2.4),                 // 리어 데크
            B.ell([-19.0, 5.0, 0], [4.0, 2.2, 6.2], blend: 2.2),                 // 꼬리
            B.ell([ 10.0, 7.6, 0], [7.5, 0.55, 2.0], blend: 1.6),                // 보닛 파워 벌지 (낮게)
            B.ell([ axleX, 5.4,  6.0], [5.6, 3.2, 2.3], blend: 1.6),             // 앞 펜더
            B.ell([ axleX, 5.4, -6.0], [5.6, 3.2, 2.3], blend: 1.6),
            B.ell([-axleX, 5.4,  6.0], [6.0, 3.2, 2.3], blend: 1.6),             // 뒤 펜더
            B.ell([-axleX, 5.4, -6.0], [6.0, 3.2, 2.3], blend: 1.6),
        ], inflate: inflate, material: mat)
    }

    static func body(_ m: Materials) -> CSG {
        var b = bodyBlob(m.paint)
        b = b & CSG.box(.translate(0, sillY + 8, 0) * .scale(30, 8, 12), material: m.paint)   // 바닥 평면
        // 휠 아치
        for x in [axleX, -axleX] {
            b = b - CSG.cylinder(.translate(x, wheelY + 0.3, 0) * .rotateX(90) * .scale(3.95, 12, 3.95), material: m.black)
        }
        // 콕핏 (오픈 로드스터)
        b = b - CSG.roundBox(half: [5.4, 3.4, 6.1], radius: 0.8, .translate(-3.2, 9.6, 0), material: m.black)
        // 그릴 입 — 타원
        b = b - CSG.sphere(.translate(23.0, 4.9, 0) * .scale(2.4, 1.25, 2.6), material: m.black)
        // 헤드라이트 자리
        for s: Float in [1, -1] {
            b = b - CSG.sphere(.translate(19.0, 6.3, 5.0 * s) * .scale(1.5, 1.3, 1.5), material: m.black)
        }
        // 패널 라인 — 보닛 절개선(카울 앞), 도어 앞·뒤, 트렁크
        let lineMat = m.black
        for x in [2.4, -0.6, -9.6, -15.5] as [Float] {
            b = b - CSG.box(.translate(x, 6.5, 0) * .scale(0.035, 4.8, 12), material: lineMat)
        }
        b = b - CSG.box(.translate(-12.5, 8.9, 0) * .scale(3.0, 0.3, 0.035), material: lineMat)  // 트렁크 가운데는 없고 옆선만
        return b
    }

    // MARK: - 크롬 · 램프

    /// 섀시·휠 하우스 — 차 밑이 뚫려 있으면 아치 너머로 반대편 바퀴가 보인다
    static func underbody(_ m: Materials) -> CSG {
        var parts: [CSG] = [
            // 섀시는 문턱 안쪽에 숨긴다 — 옆에서 보이면 검은 판이 차 밑에 깔린 꼴이다
            CSG.roundBox(half: [16.0, 0.5, 6.2], radius: 0.3, .translate(-0.5, sillY + 0.35, 0), material: m.black),
        ]
        for x in [axleX, -axleX] {
            for s: Float in [1, -1] {
                // 라이너: 아치보다 살짝 작은 검은 원통, 바퀴 안쪽 절반
                parts.append(CSG.cylinder(.translate(x, wheelY + 0.3, 3.9 * s) * .rotateX(90) * .scale(3.85, 2.4, 3.85), material: m.black)
                           - CSG.cylinder(.translate(x, wheelY + 0.3, 3.9 * s) * .rotateX(90) * .scale(3.6, 3, 3.6), material: m.black))
            }
        }
        return CSG.unionAll(parts)
    }

    static func brightwork(_ m: Materials) -> CSG {
        var parts: [CSG] = []
        // 그릴 링 (얇은 타원 고리) + 가로 바. rotateZ(90) 뒤에는 로컬 x 가 세계 y 다 —
        // 스케일을 (높이, 두께, 폭) 순으로 넣어야 가로로 긴 타원이 된다 (처음에 세로 타원이 됐다)
        parts.append(CSG.cylinder(.translate(22.3, 4.9, 0) * .rotateZ(90) * .scale(1.42, 0.14, 2.75), material: m.chrome)
                   - CSG.cylinder(.translate(22.3, 4.9, 0) * .rotateZ(90) * .scale(1.20, 0.4, 2.48), material: m.chrome))
        parts.append(CSG.roundBox(half: [0.25, 0.12, 2.5], radius: 0.08, .translate(22.15, 4.9, 0), material: m.chrome))
        // 앞 쿼터 범퍼 둘
        for s: Float in [1, -1] {
            parts.append(CSG.roundBox(half: [0.45, 0.32, 2.4], radius: 0.25,
                                      .translate(22.2, 4.3, 5.0 * s) * .rotateY(-12 * s), material: m.chrome))
        }
        // 뒤 범퍼 + 오버라이더
        parts.append(CSG.roundBox(half: [0.42, 0.35, 7.2], radius: 0.28, .translate(-22.6, 4.4, 0), material: m.chrome))
        for s: Float in [1, -1] {
            parts.append(CSG.roundBox(half: [0.55, 0.9, 0.55], radius: 0.25, .translate(-22.8, 4.9, 4.2 * s), material: m.chrome))
        }
        // 배기관 둘
        for s: Float in [1, -1] {
            parts.append(CSG.cylinder(.translate(-23.0, 2.4, 1.1 * s) * .rotateZ(90) * .scale(0.38, 1.4, 0.38), material: m.chrome)
                       - CSG.cylinder(.translate(-23.6, 2.4, 1.1 * s) * .rotateZ(90) * .scale(0.28, 1.0, 0.28), material: m.black))
        }
        // 도어 손잡이 · 사이드미러
        for s: Float in [1, -1] {
            parts.append(CSG.roundBox(half: [0.9, 0.16, 0.14], radius: 0.08, .translate(-5.5, 7.9, 8.15 * s), material: m.chrome))
        }
        parts.append(CSG.roundBox(half: [0.35, 0.55, 0.9], radius: 0.2, .translate(1.6, 10.4, -8.1), material: m.chrome))
        parts.append(CSG.cylinder(.translate(1.6, 9.5, -8.1) * .scale(0.12, 0.6, 0.12), material: m.chrome))
        // 윈드스크린 프레임 (기울인 상자에서 안을 뺀 것)
        let wsFrame = float4x4.translate(0.15, 10.35, 0) * .rotateZ(40)
        parts.append(CSG.roundBox(half: [0.14, 2.1, 5.9], radius: 0.1, wsFrame, material: m.chrome)
                   - CSG.box(wsFrame * .scale(0.4, 1.88, 5.62), material: m.chrome))
        // 헤드라이트 크롬 보울 + 렌즈
        for s: Float in [1, -1] {
            // 보울은 오목한 반사경 — 안쪽에 묻힌 반구. 튀어나오면 크롬 혹이 된다
            parts.append(CSG.sphere(.translate(18.3, 6.3, 5.0 * s) * .scale(1.3, 1.2, 1.35), material: m.chrome)
                       - CSG.sphere(.translate(19.3, 6.3, 5.0 * s) * .scale(1.5, 1.3, 1.5), material: m.chrome))
            parts.append(CSG.sphere(.translate(18.7, 6.3, 5.0 * s) * .scale(0.85, 0.8, 0.9), material: m.lamp))
        }
        // 테일램프 · 방향지시등
        for s: Float in [1, -1] {
            parts.append(CSG.roundBox(half: [0.25, 0.55, 0.7], radius: 0.2, .translate(-22.3, 6.1, 6.2 * s) * .rotateY(-25 * s), material: m.red))
            parts.append(CSG.roundBox(half: [0.25, 0.4, 0.55], radius: 0.18, .translate(21.4, 4.1, 6.3 * s) * .rotateY(25 * s), material: m.amber))
        }
        return CSG.unionAll(parts)
    }

    static func glassParts(_ m: Materials) -> CSG {
        let ws = CSG.roundBox(half: [0.06, 1.9, 5.65], radius: 0.05,
                              .translate(0.15, 10.35, 0) * .rotateZ(40), material: m.glass)
        var parts = [ws]
        for s: Float in [1, -1] {                       // 헤드라이트 커버 (유리 블리스터)
            parts.append(CSG.sphere(.translate(18.9, 6.3, 5.0 * s) * .scale(1.75, 1.45, 1.75), material: m.glass)
                       & CSG.box(.translate(20.4, 6.3, 5.0 * s) * .scale(1.5, 2, 2), material: m.glass))
        }
        return CSG.unionAll(parts)
    }

    // MARK: - 실내

    static func interior(_ m: Materials) -> CSG {
        var parts: [CSG] = [
            CSG.roundBox(half: [5.0, 0.5, 5.9], radius: 0.2, .translate(-3.5, 6.4, 0), material: m.black),     // 바닥
            CSG.roundBox(half: [1.3, 0.95, 5.9], radius: 0.25, .translate(0.6, 8.0, 0), material: m.black),    // 대시보드
            CSG.roundBox(half: [2.4, 0.4, 6.0], radius: 0.3, .translate(-10.2, 8.5, 0), material: m.black),    // 토노 커버
            CSG.torus(.translate(-1.6, 9.2, -3.4) * .rotateZ(72) * .scale(1.75, 1.75, 1.75) * .scale(1, 0.2, 1), material: m.black),
            CSG.cylinder(.translate(-0.6, 8.9, -3.4) * .rotateZ(72) * .scale(0.18, 1.2, 0.18), material: m.chrome),
        ]
        for s: Float in [1, -1] {                       // 버킷 시트 둘
            parts.append(CSG.roundBox(half: [2.0, 0.75, 1.9], radius: 0.4, .translate(-4.8, 7.0, 3.3 * s), material: m.leather))
            parts.append(CSG.roundBox(half: [0.7, 2.3, 1.9], radius: 0.4, .translate(-7.3, 8.8, 3.3 * s) * .rotateZ(14), material: m.leather))
        }
        // 계기판 — 크롬 링 둘
        for z in [-4.6, -2.4] as [Float] {
            parts.append(CSG.cylinder(.translate(1.9, 8.3, z) * .rotateZ(90) * .scale(0.55, 0.06, 0.55), material: m.chrome))
        }
        return CSG.unionAll(parts)
    }

    // MARK: - 와이어 휠 (타이어 + 림 + 허브 오브젝트 하나, 스포크는 인스턴스)

    /// 로컬: 축 = z, 바깥면 = +z
    static func wheel(_ m: Materials) -> CSG {
        let tire = CSG.torus(.rotateX(90) * .scale(2.55, 2.55, 2.55) * .scale(1, 0.92, 1), material: m.rubber)
        let rim = CSG.cylinder(.rotateX(90) * .scale(1.95, 0.85, 1.95), material: m.chrome)
                - CSG.cylinder(.rotateX(90) * .scale(1.72, 1.2, 1.72), material: m.chrome)
        let hub = CSG.lathe([(-0.6, 0.55), (0.2, 0.62), (0.6, 0.45), (0.9, 0.35), (1.15, 0.12)],
                            .rotateX(90), material: m.chrome)
        // 3날 노크오프 스피너
        var ears: [CSG] = []
        for k in 0..<3 {
            ears.append(CSG.roundBox(half: [0.55, 0.14, 0.16], radius: 0.08,
                                     .translate(0, 0, 1.0) * .rotateZ(Float(k) * 120) * .translate(0.35, 0, 0), material: m.chrome))
        }
        return CSG.unionAll([tire, rim, hub] + ears)
    }

    static func spoke(_ m: Materials) -> CSG {
        CSG.cylinder(.scale(0.035, 0.5, 0.035), material: m.chrome)
    }

    /// 스포크 배치 (휠 로컬) — 두 줄이 서로 반대로 비스듬히 교차한다
    static func spokeLocal() -> [float4x4] {
        var out: [float4x4] = []
        for row in 0..<2 {
            let zHub: Float = row == 0 ? 0.42 : -0.42
            let zRim: Float = row == 0 ? -0.28 : 0.28
            let twist: Float = row == 0 ? 16 : -16
            for i in 0..<24 {
                let a = Float(i) / 24 * 360 + Float(row) * 7.5
                let a2 = (a + twist) * .pi / 180
                let a1 = a * .pi / 180
                let p0 = SIMD3<Float>(0.55 * cos(a1), 0.55 * sin(a1), zHub)
                let p1 = SIMD3<Float>(1.80 * cos(a2), 1.80 * sin(a2), zRim)
                let d = p1 - p0
                let len = simd_length(d)
                let mid = (p0 + p1) / 2
                out.append(.translate(mid.x, mid.y, mid.z) * IronMan.alignY(d) * .scale(1, len / 2 / 0.5, 1))
            }
        }
        return out
    }

    /// 네 바퀴의 배치 (바깥면이 차 바깥을 향하도록 왼쪽은 180° 돌린다)
    static func wheelPlacements() -> [float4x4] {
        var out: [float4x4] = []
        for x in [axleX, -axleX] {
            for s: Float in [1, -1] {
                out.append(.translate(x, wheelY, trackZ * s) * .rotateY(s > 0 ? 0 : 180) * .rotateZ(Float(x) * 3))
            }
        }
        return out
    }
}
