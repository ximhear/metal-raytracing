//
//  Scene.swift
//  부품을 조립해서 오브젝트를 만들고, 오브젝트를 월드에 배치(인스턴스)한다.
//

import Foundation
import simd

struct Placement {
    let objectIndex: Int
    let transform: float4x4      // objectToWorld
}

final class CSGScene {
    /// 씬 목록. **여기에 case 를 추가하면 시작 메뉴에 버튼이 자동으로 생긴다** —
    /// 메뉴 화면은 `Kind.allCases` 를 그대로 그린다.
    enum Kind: String, CaseIterable, Identifiable, Hashable {
        /// 버스 하나만 (기본)
        case bus
        /// 부품 색을 유지한 채 전부 유리로 — 색이 남는 반투명 모형
        case tintedGlassBus
        /// 색 없는 완전 투명 유리
        case glassBus
        /// 기계식 시계 무브먼트
        case watch
        /// 터보팬 제트엔진 커터웨이
        case turbofan
        /// 양식화한 여성 얼굴 (흉상)
        case face
        /// 붉은색·금색 파워드 아머
        case ironMan
        /// 얇은 금테 안경 — 제품 사진 구도
        case glasses
        /// 굵은 테 썬글라스 — 제품 사진 구도
        case sunglasses
        /// 16종 부품 전시장 + 버스
        case showcase
        /// 둥근 상자 부품 검증 — 라운드 방식 비교 + 차집합 테스트
        case roundBoxTest

        var id: String { rawValue }

        var title: String {
            switch self {
            case .bus:          return "시내버스"
            case .tintedGlassBus: return "반투명 유리 시내버스"
            case .glassBus:     return "유리 버스"
            case .watch:        return "기계식 시계 무브먼트"
            case .turbofan:     return "터보팬 제트엔진 커터웨이"
            case .face:         return "여성 얼굴"
            case .ironMan:      return "아이언맨"
            case .glasses:      return "안경"
            case .sunglasses:   return "썬글라스"
            case .showcase:     return "부품 전시장"
            case .roundBoxTest: return "둥근 상자 검증"
            }
        }

        var subtitle: String {
            switch self {
            case .bus:
                return "현대 슈퍼 에어로시티 · 부품 62개를 해석적으로 레이 트레이싱"
            case .tintedGlassBus:
                return "부품 색을 그대로 둔 채 유리로 · 색이 남는 크리스털 모형"
            case .glassBus:
                return "색 없는 완전 투명 유리 · 굴절과 프레넬 반사만으로 형태가 드러난다"
            case .watch:
                return "기어 트레인 · 탈진기 · 헤어스프링 · 루비 보석 — 전부 불리언 가공물"
            case .turbofan:
                return "블레이드 1500장을 인스턴스로 · 사분면을 빼서 카울을 걷어낸 단면"
            case .face:
                return "smooth-min 거리장으로 조각한 양식화 흉상 · 피부 산란 · 비등방 머리카락"
            case .ironMan:
                return "붉은 캔디 도장 · 금색 거울 · 발광 눈과 아크 리액터 — 갑옷 판 60여 장"
            case .glasses:
                return "라운드 검은 림 + 로즈골드 다리 · 베지에 튜브 · 굴절률 1.5 유리 렌즈"
            case .sunglasses:
                return "스퀘어 하프림 금테 · 갈색 그라데이션 유리 · 거북등 다리 끝"
            case .showcase:
                return "16종 해석적 부품 + 불리언 조립 · 거울과 유리"
            case .roundBoxTest:
                return "윤곽 교차 vs 진짜 둥근 상자 · 꼭짓점 능선 비교"
            }
        }

        var symbol: String {
            switch self {
            case .bus:          return "bus.fill"
            case .tintedGlassBus: return "bus.doubledecker"
            case .glassBus:     return "bus"
            case .watch:        return "gearshape.2.fill"
            case .turbofan:     return "airplane.circle.fill"   // fan.fill 은 iOS 16.4+ 라 배포 타깃(16.0)에서 빈칸이 된다
            case .face:         return "face.smiling"
            case .ironMan:      return "bolt.shield.fill"
            case .glasses:      return "eyeglasses"
            case .sunglasses:   return "sunglasses"
            case .showcase:     return "cube.transparent"
            case .roundBoxTest: return "square.on.circle"
            }
        }

        /// 개발 검증용 씬 — 메뉴에서 구분해 표시한다
        var isDebugScene: Bool { self == .roundBoxTest }
    }

    var materials: [Material] = []
    var objects: [CSG] = []
    var placements: [Placement] = []

    /// 궤도 카메라가 담아야 할 범위. 물체는 전부 지면에 놓이므로 구가 아니라 **원기둥**으로 잡는다
    /// — 버스처럼 길고 낮은 것을 구로 감싸면 위아래 여백만 커진다.
    var focusCenter: SIMD3<Float> = [0, -1, 0]
    var focusRadius: Float = 5.4          // XZ 평면 반지름 (궤도를 도니 최대 단면 기준)
    var focusHalfHeight: Float = 2.5
    /// 처음 보여 줄 카메라 고도각(rad). 평평한 물건은 위에서 내려다봐야 한다.
    var focusElevation: Float = 0.32
    /// 궤도 카메라가 내려갈 수 있는 최저 고도(rad). **눈높이가 바닥면 아래로 내려가면
    /// 바닥 상자 속에서 보게 되어 화면이 깨진다.** 물체가 바닥 가까이 낮게 놓인 씬일수록 높여야 한다.
    var minElevation: Float = 0.02

    /// 조명 환경. `.studio` 는 어두운 배경 + 소프트박스 —
    /// **금속을 금속처럼 보이게 하려면 비칠 것이 있어야 한다.**
    enum Environment: UInt32 { case outdoor = 0, studio = 1, whiteCyc = 2, brightStudio = 3 }
    var environment: Environment = .outdoor
    /// 광원 각반지름(rad). 0 = 딱딱한 그림자. 제품 사진은 0.05 안팎.
    var shadowSoftness: Float = 0
    /// 픽셀당 샘플 (1 또는 4). 가는 것이 많은 씬만 4.
    var samplesPerPixel: Int = 1
    /// 노출 배율. 기본 1.25.
    var exposure: Float = 1.25
    /// 태양(키 라이트) 방향. nil 이면 환경 기본값.
    /// **인물은 조명 방향이 곧 인상이다** — 머리 위에서 내리쬐면 눈확·코 밑에 검은 그림자가 앉아
    /// 누구든 해골처럼 보인다. 카메라 쪽 위에서 비추는 "뷰티 라이트"가 정석.
    var sunDirection: SIMD3<Float>? = nil

    init(_ kind: Kind = .bus) {
        switch kind {
        case .bus:            buildBus(finish: .solid)
        case .tintedGlassBus: buildBus(finish: .tinted)
        case .glassBus:       buildBus(finish: .clear)
        case .watch:    buildWatch()
        case .turbofan: buildTurbofan()
        case .face:     buildFace(eyewear: nil)
        case .ironMan:    buildIronMan()
        case .glasses:    buildSpectacles()
        case .sunglasses: buildSquareSunglasses()
        case .showcase: buildShowcase()
        case .roundBoxTest: buildRoundBoxTest()
        }
    }

    /// 검증 하네스용 — 실제 씬과 같은 재질 구성으로 Bus.Materials 를 만든다
    static func busMaterialsForAudit() -> Bus.Materials {
        Bus.Materials(paint: 0, black: 1, cabin: 2, stripe: 3, glass: 4, clearGlass: 5,
                      tire: 6, rim: 7, chrome: 8, seat: 9, headLight: 10, amber: 11,
                      tailLight: 12, plate: 13, rail: 14, acCover: 15)
    }

    // MARK: - 기계식 시계 무브먼트

    /// 기어 하나 = 오브젝트 하나. 보석·나사처럼 같은 모양은 인스턴스로 반복한다.
    private func buildWatch() {
        // 금속은 완전 거울(METAL)보다 **광택 높은 확산**이 낫다 —
        // 배경이 단순한 스튜디오라 순수 거울은 하늘만 비쳐 밋밋해진다.
        // 고급 무브먼트의 전형 배색: 저먼 실버(샴페인) 지판 · 옐로 골드 휠 ·
        // 블루 스틸 나사 · 금 샤통에 박힌 루비. 흰색·회색만 쓰면 실물처럼 안 보인다.
        // 스튜디오 조명이라 **연마된 부품은 거울(METAL)로 둔다** — 소프트박스가 띠로 비쳐
        // 비로소 금속으로 읽힌다. 무광 처리된 지판만 확산으로 남긴다.
        let m = Watch.Materials(
            plate:     addMaterial([0.21, 0.195, 0.165], gloss: 0.40, grain: 0.32),  // 프로스팅 저먼실버
            bridge:    addMaterial([0.76, 0.70, 0.54], type: MATERIAL_METAL),       // 연마 저먼실버
            wheel:     addMaterial([0.94, 0.72, 0.30], type: MATERIAL_METAL),       // 옐로 골드 휠
            pinion:    addMaterial([0.93, 0.94, 0.96], type: MATERIAL_METAL),       // 연마 강철
            ruby:      addMaterial([0.70, 0.05, 0.09], type: MATERIAL_GLASS, ior: 1.77),
            blueSteel: addMaterial([0.16, 0.30, 0.72], type: MATERIAL_METAL),       // 블루 스틸
            chrome:    addMaterial([0.95, 0.96, 0.97], type: MATERIAL_METAL),
            crystal:   addMaterial([0.94, 0.97, 0.98], type: MATERIAL_GLASS, ior: 1.77),
            chaton:    addMaterial([0.95, 0.70, 0.36], type: MATERIAL_METAL))       // 금 샤통

        let deskTop = addMaterial([0.030, 0.032, 0.038], gloss: 0.22, grain: 0.20)
        let caseMat = addMaterial([0.92, 0.74, 0.40], type: MATERIAL_METAL)

        var objs: [CSG] = [
            CSG.box(.scale(400, 0.4, 400), material: deskTop),      // 0 작업대
            Watch.mainPlate(m),                                      // 1
            Watch.barrelBridge(m),                                   // 2
            Watch.trainBridge(m),                                    // 3
            Watch.balanceCock(m),                                    // 4
            Watch.palletFork(m),                                     // 5
            Watch.balanceWheel(m),                                   // 6
            Watch.hairspring(m),                                     // 7
            Watch.jewel(m),                                          // 8  인스턴스
            Watch.screw(m),                                          // 9  인스턴스
            Watch.ratchetWheel(m),                                   // 10 래칫 휠
            Watch.crownWheel(m),                                     // 11 크라운 휠
            Watch.click(m),                                          // 12 클릭
            Watch.perlageDisc(m),                                    // 13 페를라주 (인스턴스)
            Watch.crownAndStem(m),                                   // 14 용두 + 스템
            Watch.escapeCock(m),                                     // 15 이스케이프 콕
            Watch.regulator(m),                                      // 16 완급침
            Watch.clickSpring(m),                                    // 17 클릭 스프링
            Watch.chaton(m),                                         // 18 금 샤통 (인스턴스)
            // 케이스 링 — 무브먼트를 감싸는 테두리
            CSG.cylinder(.translate(0, -0.4, 0) * .scale(Watch.plateRadius + 1.1, 1.4,
                                                         Watch.plateRadius + 1.1), material: caseMat)
          - CSG.cylinder(.translate(0, -0.4, 0) * .scale(Watch.plateRadius + 0.05, 2.0,
                                                         Watch.plateRadius + 0.05), material: caseMat),
        ]
        // 인덱스는 objs 배열 순서와 정확히 맞아야 한다 — 하나만 밀려도
        // 엉뚱한 오브젝트가 엉뚱한 자리에 배치된다 (케이스 링이 샤통 자리에 깔린 적이 있다)
        let ground = 0, jewelObj = 8, screwObj = 9
        let ratchet = 10, crown = 11, clickObj = 12, perlage = 13, chatonObj = 18, caseRing = 19
        let firstWheel = objs.count
        objs += Watch.train.enumerated().map { Watch.wheelAssembly($1, index: $0, m) }
        objects = objs

        placements = [Placement(objectIndex: ground, transform: .translate(0, -3.0, 0))]
        // 플레이트 ~ 케이스링 (인스턴스 오브젝트 8·9 는 제외)
        // 한 번만 놓는 것들 (인스턴스 오브젝트 8·9·13·18 은 아래에서 따로 배치)
        placements += [1, 2, 3, 4, 5, 6, 7, 14, 15, 16, 17, caseRing].map {
            Placement(objectIndex: $0, transform: .identity)
        }
        // 태엽 감기 계열 — 브리지 위에 얹힌다
        placements.append(Placement(objectIndex: ratchet,
            transform: .translate(Watch.ratchetCenter.x, Watch.upperWheelY, Watch.ratchetCenter.y)))
        placements.append(Placement(objectIndex: crown,
            transform: .translate(Watch.crownCenter.x, Watch.upperWheelY, Watch.crownCenter.y)))
        placements.append(Placement(objectIndex: clickObj, transform: .identity))
        // 페를라주 — 오브젝트 하나를 수백 번
        placements += Watch.perlagePlacements.map { Placement(objectIndex: perlage, transform: $0) }
        // 기어 트레인 — 각자 제 자리에
        for (i, w) in Watch.train.enumerated() {
            placements.append(Placement(objectIndex: firstWheel + i,
                transform: .translate(w.center.x, Watch.wheelY(i), w.center.y)))
        }
        // 보석 · 나사 · 밸런스 림 나사 — 같은 오브젝트를 여러 번
        placements += Watch.jewelPlacements.map { Placement(objectIndex: jewelObj, transform: $0) }
        // 금 샤통 — 브리지에 박힌 보석 둘레
        placements += Watch.chatonPlacements.map { Placement(objectIndex: chatonObj, transform: $0) }
        placements += Watch.screwPlacements.map { Placement(objectIndex: screwObj, transform: $0) }
        placements += Watch.rimScrewPlacements.map { Placement(objectIndex: screwObj, transform: $0) }

        // 평평한 물건이라 위에서 내려다봐야 트레인이 보인다
        focusCenter = [0, 0, 0]
        focusRadius = 15.0
        focusHalfHeight = 4.0
        focusElevation = 0.82        // 평평한 기계라 위에서 내려다봐야 트레인이 읽힌다
        environment = .studio        // 소프트박스가 금속에 비쳐야 시계처럼 보인다
    }

    // MARK: - 터보팬 제트엔진 커터웨이

    /// **단(stage) 하나 = 오브젝트 하나, 날개 수만큼 인스턴스.**
    /// 오브젝트는 40여 개뿐인데 인스턴스는 1500개가 넘는다 — 가속 구조는 오브젝트 수만큼만 선다.
    private func buildTurbofan() {
        // 연마 금속만 거울(METAL)로 둔다. 날개가 1500장이라 전부 거울로 두면
        // 반사 재귀가 그대로 곱해져 급격히 느려진다. 압축기·터빈은 **광택 높은 확산**으로
        // 환경 반사만 프레넬로 얹는다 — 재귀 없이도 스튜디오 조명이 띠로 비친다.
        let m = Engine.Materials(
            cowl:       addMaterial([0.86, 0.87, 0.89], gloss: 0.60, grain: 0.05),  // 도장 카울
            duct:       addMaterial([0.26, 0.28, 0.31], gloss: 0.50),               // 덕트 안쪽
            fanBlade:   addMaterial([0.78, 0.80, 0.84], gloss: 0.92),               // 연마 티타늄
            compressor: addMaterial([0.66, 0.70, 0.77], gloss: 0.90),               // 압축기 (냉간부: 티타늄)
            turbine:    addMaterial([0.52, 0.40, 0.26], gloss: 0.80, grain: 0.16),  // 저압터빈 (황동빛)
            combustor:  addMaterial([0.19, 0.15, 0.12], gloss: 0.34, grain: 0.36),  // 연소기 라이너
            shaft:      addMaterial([0.88, 0.89, 0.92], type: MATERIAL_METAL),      // 강철 축
            hub:        addMaterial([0.74, 0.76, 0.80], type: MATERIAL_METAL),      // 스피너 · 드럼
            cut:        addMaterial([0.72, 0.15, 0.09], gloss: 0.45))               // 절단면 (전시 모형처럼 붉게)

        // 고압터빈은 연소기 바로 뒤라 가장 뜨겁다 — 더 짙게 산화된 색으로 저압터빈과 구분한다.
        // 색을 하나로 두면 뜨거운 쪽과 찬 쪽의 경계가 안 보여 기계가 밋밋해진다.
        let hotBlade = addMaterial([0.31, 0.22, 0.15], gloss: 0.72, grain: 0.22)
        let plinth = addMaterial([0.030, 0.032, 0.038], gloss: 0.22, grain: 0.20)

        var objs: [CSG] = [
            CSG.box(.scale(400, 0.5, 400), material: plinth),   // 0 받침
            Engine.fanCowl(m),                                  // 1
            Engine.coreCowl(m),                                 // 2
            Engine.coreCasing(m),                               // 3
            Engine.rotorDrum(m),                                // 4
            Engine.spinner(m),                                  // 5
            Engine.exhaustCone(m),                              // 6
            Engine.combustor(m),                                // 7
            Engine.pylon(m),                                    // 8
            Engine.bifurcation(m),                              // 9  위·아래 두 번
            Engine.fuelNozzle(m),                               // 10 인스턴스
        ]
        let plinthObj = 0, bifurcationObj = 9, nozzleObj = 10

        // 단마다 블레이드 오브젝트를 하나씩 만들고, 그 자리에서 링으로 배치한다.
        // (오브젝트 인덱스와 배치를 같이 만들어야 어긋나지 않는다 — 시계에서 한 칸 밀려 크게 데었다)
        var rings: [(obj: Int, xforms: [float4x4])] = []
        func addStage(_ s: Engine.Stage, _ material: Int, phase: Float = 0) {
            rings.append((objs.count, Engine.ring(s, phase: phase)))
            objs.append(Engine.bladeFor(s, material))
        }

        addStage(Engine.fan, m.fanBlade)
        addStage(Engine.outletGuideVanes, m.compressor)
        for (i, s) in Engine.boosterStages.enumerated() {
            addStage(s, m.compressor, phase: Float(i) * 3.5)
        }
        for (i, s) in Engine.hpcStages.enumerated() {
            addStage(s, m.compressor, phase: Float(i) * 2.5)
        }
        // 앞 4단(고압터빈 동익 2 + 정익 2)만 더 짙은 산화색
        for (i, s) in Engine.turbineStages.enumerated() {
            addStage(s, i < 4 ? hotBlade : m.turbine, phase: Float(i) * 2.0)
        }

        objects = objs

        placements = [Placement(objectIndex: plinthObj, transform: .translate(0, -15.0, 0))]
        placements += (1...8).map { Placement(objectIndex: $0, transform: .identity) }
        placements += [float4x4.identity, .rotateX(180)].map {
            Placement(objectIndex: bifurcationObj, transform: $0)
        }
        placements += Engine.nozzlePlacements.map {
            Placement(objectIndex: nozzleObj, transform: $0)
        }
        for r in rings {
            placements += r.xforms.map { Placement(objectIndex: r.obj, transform: $0) }
        }
        print("터보팬: 오브젝트 \(objects.count)개 · 인스턴스 \(placements.count)개")

        // 길고 굵은 물체라 원기둥으로 감싼다. 커터웨이가 위-앞쪽(y>0, z>0)에 열려 있으므로
        // 살짝 위에서 봐야 속이 보인다.
        focusCenter = [4.5, 0.5, 0]
        focusRadius = 21.0
        focusHalfHeight = 14.0
        focusElevation = 0.30
        environment = .studio        // 금속은 비칠 것이 있어야 금속으로 읽힌다
    }

    // MARK: - 비키니 인물상

    /// 흉상 하나. 전신 인물상(비키니)에서 얼굴만 남긴 것이다 —
    /// 몸 코드는 `Figure.swift` 에 그대로 있다 (이 저장소는 git 이 아니라 지우면 못 돌린다).
    private func buildFace(eyewear: Figure.Eyewear?) {
        // 피부는 **gloss 를 올리는 순간 플라스틱**이 된다. 대신 `sss` 로 표면하 산란을 흉내낸다.
        // grain 은 쓰지 않는다 — 노이즈가 xz 기준이라 수직면(얼굴)에서 회색 반점이 된다.
        let m = Figure.Materials(
            skin:   addMaterial([0.95, 0.76, 0.66], gloss: 0.18, sss: 0.55),        // 밝고 맑은 피부, 살짝 따뜻하게
            hair:   addMaterial([0.045, 0.036, 0.036], type: MATERIAL_HAIR, gloss: 0.55), // 검은 생머리 — 광택을 올리면 회색 금속이 된다
            sclera: addMaterial([0.93, 0.92, 0.92], gloss: 0.25, sss: 0.2),   // 너무 희면 눈이 튄다
            limbus: addMaterial([0.06, 0.04, 0.03], gloss: 0.3),
            iris:   addMaterial([0.17, 0.10, 0.07], gloss: 0.9),                  // 짙은 갈색
            pupil:  addMaterial([0.02, 0.02, 0.02], gloss: 0.2),
            cornea: addMaterial([0.97, 0.98, 0.99], type: MATERIAL_GLASS, ior: 1.38),
            lip:    addMaterial([0.84, 0.40, 0.38], gloss: 0.50, sss: 0.6),       // 산호빛
            suit:   addMaterial([0.96, 0.36, 0.30], gloss: 0.22, grain: 0.10),
            brow:   addMaterial([0.17, 0.12, 0.10], gloss: 0.2))                  // 눈썹 (짙은 갈색)
        let cream  = addMaterial([0.94, 0.90, 0.84], gloss: 0.30)                  // 드레스
        let silver = addMaterial([0.95, 0.96, 0.97], type: MATERIAL_METAL)
        let gold   = addMaterial([0.88, 0.72, 0.42], type: MATERIAL_METAL)
        let lens   = addMaterial([0.96, 0.97, 0.98], type: MATERIAL_GLASS, ior: 1.50)
        // 썬글라스: 검은 아세테이트 테 + 짙은 갈색 유리. 렌즈가 얇아 빛이 두 번만 지나므로
        // 0.3 으로 두면 눈이 다 보인다 — 0.13 이어야 썬글라스답게 눈이 희미하고 배경이 비친다
        let acetate = addMaterial([0.035, 0.03, 0.03], gloss: 0.85)
        let tint    = addMaterial([0.13, 0.10, 0.09], type: MATERIAL_GLASS, ior: 1.50)
        // 배경 — 보라빛 벽. 하늘만 두면 초상이 아니라 야외 스냅이 된다
        // grain 은 xz 노이즈라 수직 벽에서는 세로 줄무늬가 된다 — 쓰지 않는다
        let backdrop = addMaterial([0.42, 0.33, 0.58], gloss: 0.05)

        objects = [
            Figure.bust(m),                       // 0 머리 + 목 + 어깨
            Figure.hairCap(m),                    // 1
            Figure.eyes(m),                       // 2
            Figure.lips(m),                       // 3
            Figure.lashes(m),                     // 4
            Figure.brows(m),                      // 5
            Figure.dress(m, cloth: cream),        // 6
            Figure.earrings(silver),              // 7
            CSG.box(.scale(40, 30, 0.5), material: backdrop),   // 8 배경 벽
        ]
        placements = (0...7).map { Placement(objectIndex: $0, transform: .identity) }
        placements.append(Placement(objectIndex: 8, transform: .translate(0, 10, -18)))
        if let e = eyewear {
            let sun = e.rimWidth > 0.05
            objects.append(Figure.eyewearFrame(e, material: sun ? acetate : gold))
            objects.append(Figure.eyewearLenses(e, material: sun ? tint : lens))
            placements.append(Placement(objectIndex: objects.count - 2, transform: .identity))
            placements.append(Placement(objectIndex: objects.count - 1, transform: .identity))
        }

        // 초상 구도: 눈높이에서, 머리카락 끝부터 어깨까지
        focusCenter = [0, 15.15, 0]
        focusRadius = 2.1
        focusHalfHeight = 2.7
        focusElevation = 0.04
        // 카메라 쪽 위·오른쪽에서 — 얼굴에 그림자가 앉지 않는 뷰티 라이트
        sunDirection = simd_normalize(SIMD3<Float>(0.38, 0.58, 1.05))   // 더 정면에서 — 코 밑 그늘을 줄인다
    }

    // MARK: - 아이언맨

    private func buildIronMan() {
        let m = IronMan.Materials(
            red:   addMaterial([0.52, 0.025, 0.02], gloss: 0.98),                 // 캔디 레드 — 어둡고 광택은 최대
            // 금은 새틴 금속 — 완전 거울은 어두운 스튜디오를 비춰 녹은 금덩이가 되고,
            // 확산은 겨자색 플라스틱이 된다. SATIN 이 색 착색 반사 + 확산 바탕으로 그 사이를 잡는다
            gold:  addMaterial([0.98, 0.64, 0.20], type: MATERIAL_SATIN, gloss: 0.9),
            suit:  addMaterial([0.09, 0.09, 0.10], gloss: 0.35),                  // 언더슈트
            glow:  addMaterial([4.5, 5.5, 6.5], type: MATERIAL_EMISSIVE),         // 눈 · 리펄서
            core:  addMaterial([1.2, 2.6, 4.8], type: MATERIAL_EMISSIVE),         // 리액터
            steel: addMaterial([0.66, 0.67, 0.70], type: MATERIAL_SATIN, gloss: 0.7))
        let floor = addMaterial([0.035, 0.036, 0.04], gloss: 0.35, grain: 0.15)

        objects = [
            CSG.box(.scale(200, 0.2, 200), material: floor),   // 0
            IronMan.torsoSuit(m),                              // 1
            IronMan.helmet(m),                                 // 2
            IronMan.faceplate(m),                              // 3
            IronMan.eyes(m),                                   // 4
            IronMan.chest(m),                                  // 5
            IronMan.reactor(m),                                // 6
            IronMan.shoulders(m),                              // 7
            IronMan.hips(m),                                   // 8
            IronMan.arm(m, open: false),                       // 9  주먹 팔
            IronMan.arm(m, open: true),                        // 10 리펄서 팔
            IronMan.leg(m),                                    // 11
            IronMan.bolt(m),                                   // 12 볼트 (인스턴스)
        ]
        placements = [Placement(objectIndex: 0, transform: .translate(0, -0.2, 0))]
        placements += (1...8).map { Placement(objectIndex: $0, transform: .identity) }
        // 오른팔: 살짝 벌려 내린 주먹. 왼팔: 앞으로 뻗어 손바닥(리펄서)이 카메라를 향한다
        let armR = float4x4.translate(IronMan.shoulderX + 0.1, IronMan.shoulderY - 0.1, 0) * .rotateZ(14)
        let armL = float4x4.translate(-(IronMan.shoulderX + 0.1), IronMan.shoulderY - 0.1, 0.3)
                 * .rotateX(-84) * .rotateZ(-8)
        // 스탠스는 넓게 — 허벅지 판이 붙으면 두 다리가 한 덩어리로 보인다 (그랬다)
        let legR = float4x4.translate( 1.45, IronMan.hipY, 0) * .rotateZ(-11) * .rotateY(-12)
        let legL = float4x4.translate(-1.45, IronMan.hipY, 0) * .rotateZ(11) * .rotateY(12)
        placements.append(Placement(objectIndex: 9, transform: armR))
        placements.append(Placement(objectIndex: 10, transform: armL))
        placements.append(Placement(objectIndex: 11, transform: legR))
        placements.append(Placement(objectIndex: 11, transform: legL))
        // 볼트 — 오브젝트 하나를 부위마다 그 부위의 배치 변환으로 심는다
        var bolts = IronMan.boltPlacements(IronMan.torsoBolts)
        for f in [armR, armL] { bolts += IronMan.boltPlacements(IronMan.armBolts, frame: f) }
        for f in [legR, legL] { bolts += IronMan.boltPlacements(IronMan.legBolts, frame: f) }
        placements += bolts.map { Placement(objectIndex: 12, transform: $0) }
        print("아이언맨: 오브젝트 \(objects.count)개 · 인스턴스 \(placements.count)개")

        focusCenter = [0, 9.4, 0]
        focusRadius = 5.2
        focusHalfHeight = 9.9
        focusElevation = 0.08          // 살짝 아래에서 올려다봐야 영웅적이다
        environment = .brightStudio    // 사진은 밝은 전시장 — 어두운 스튜디오에선 금이 회색으로 죽는다
        exposure = 1.35
        samplesPerPixel = 4            // 패널 라인·볼트는 픽셀보다 가늘다
        sunDirection = simd_normalize(SIMD3<Float>(0.35, 0.85, 0.65))
    }

    // MARK: - 안경 · 썬글라스 (제품 사진)

    /// 라운드 금테 안경 — 흰 배경 제품 사진. 야외 조명(밝은 반구 앰비언트) + 흰 탁자·흰 벽.
    private func buildSpectacles() {
        let m = Spectacles.Materials(
            // 흰 환경에서 광택 0.9 검정은 회색으로 뜬다 — 더 검게, 광택은 낮춰야 검정으로 남는다
            rim:   addMaterial([0.015, 0.015, 0.017], gloss: 0.55),              // 검은 에나멜
            // 흰 환경이 밝아서 금속 색은 실제보다 어둡게 둬야 화면에서 금으로 보인다
            metal: addMaterial([0.74, 0.50, 0.36], type: MATERIAL_METAL),        // 로즈골드
            tip:   addMaterial([0.035, 0.035, 0.038], gloss: 0.80),              // 검은 아세테이트
            // 완전 투명이면 흰 배경에서 렌즈가 사라진다 — 아주 옅은 회청색이 있어야 "유리가 있다"
            glass: addMaterial([0.92, 0.94, 0.96], type: MATERIAL_GLASS, ior: 1.50))
        let table = addMaterial([0.96, 0.96, 0.97], gloss: 0.32)                  // 흰 아크릴 (살짝 비친다)

        // 앞을 12° 들고 3/4 로 돌려 놓는다 (참고 사진의 자세). 벽은 없다 — 환경 자체가 흰색이다
        let pose = float4x4.rotateY(-26) * .rotateX(-9)
        objects = [
            CSG.box(.scale(60, 0.1, 60), material: table),   // 0
            Spectacles.frame(m),                             // 1
            Spectacles.glass(m),                             // 2
        ]
        let rimBottom = Spectacles.lensY - Spectacles.lensR.y - 0.013
        placements = [
            Placement(objectIndex: 0, transform: .translate(0, rimBottom - 0.1, 0)),
            Placement(objectIndex: 1, transform: pose),
            Placement(objectIndex: 2, transform: pose),
        ]
        focusCenter = [0.10, -0.06, -0.45]
        focusRadius = 1.15
        focusHalfHeight = 0.40
        focusElevation = 0.26
        productLighting()
    }

    /// 제품 사진 공통: 흰 사이클로라마 + 면광원 소프트 섀도 + 4 spp
    private func productLighting() {
        minElevation = 0.10            // 탁자면이 초점 바로 아래라 조금만 내려가도 탁자 속이다
        environment = .whiteCyc
        sunDirection = simd_normalize(SIMD3<Float>(0.30, 0.90, 0.45))
        shadowSoftness = 0.06
        samplesPerPixel = 4
    }

    /// 스퀘어 하프림 썬글라스 — 흰 배경 제품 사진
    private func buildSquareSunglasses() {
        // 렌즈: 위(y ≥ 0.20)는 짙은 갈색, 아래(y ≤ −0.24)로 갈수록 92% 맑아진다.
        // GLASS 의 gloss/sss 가 그라데이션 y 범위, grain 이 세기다 (ShaderTypes.h 참고)
        let m = SquareSunglasses.Materials(
            metal:    addMaterial([0.78, 0.60, 0.34], type: MATERIAL_METAL),          // 옅은 금 (흰 환경 보정)
            tortoise: addMaterial([0.22, 0.10, 0.04], gloss: 0.85, grain: 0.30),       // 거북등
            lens:     addMaterial([0.15, 0.075, 0.06], type: MATERIAL_GLASS, ior: 1.50,
                                  gloss: -0.26, grain: 0.93, sss: 0.08),
            pad:      addMaterial([0.97, 0.98, 0.99], type: MATERIAL_GLASS, ior: 1.50))
        let table = addMaterial([0.96, 0.96, 0.97], gloss: 0.32)

        let pose = float4x4.rotateY(-26) * .rotateX(-9)
        objects = [
            CSG.box(.scale(60, 0.1, 60), material: table),   // 0
            SquareSunglasses.frame(m),                       // 1
            SquareSunglasses.glass(m),                       // 2
        ]
        let bottom = SquareSunglasses.lensY - SquareSunglasses.halfH
        placements = [
            Placement(objectIndex: 0, transform: .translate(0, bottom - 0.1, 0)),
            Placement(objectIndex: 1, transform: pose),
            Placement(objectIndex: 2, transform: pose),
        ]
        focusCenter = [0.10, -0.06, -0.45]
        focusRadius = 1.2
        focusHalfHeight = 0.40
        focusElevation = 0.26
        productLighting()
    }

    /// 안경테는 얼굴 좌표(`Figure.headC`)에 맞춰 만들어지므로, 여기서 원점으로 옮기고
    /// 앞을 살짝 들어 탁자에 놓는다. 스튜디오 소프트박스가 금테와 렌즈에 비쳐야 제품처럼 보인다.
    private func buildEyewear(_ e: Figure.Eyewear, sun: Bool) {
        let gold    = addMaterial([0.88, 0.72, 0.42], type: MATERIAL_METAL)
        let lens    = addMaterial([0.96, 0.97, 0.98], type: MATERIAL_GLASS, ior: 1.50)
        let acetate = addMaterial([0.035, 0.03, 0.03], gloss: 0.85)
        let tint    = addMaterial([0.13, 0.10, 0.09], type: MATERIAL_GLASS, ior: 1.50)
        let desk    = addMaterial([0.06, 0.062, 0.07], gloss: 0.35, grain: 0.15)

        let c = Figure.headC
        // 얼굴 좌표 → 원점. 렌즈 중심(y = c.y − 0.08)을 원점 높이로, 안경 폭 중심(x ≈ −0.02)을 0 으로
        let center = SIMD3<Float>(c.x - 0.02, c.y - 0.08, e.lensZ)
        // 앞을 12° 들어 올린다 — 다리 끝(갈고리)과 림 아래가 탁자에 닿는 자세
        // 기본 시점이 3/4 이 되게 28° 돌려 둔다 — 정면은 다리가 안 보여 납작하다
        let pose = float4x4.rotateY(-28) * .rotateX(-12) * .translate(-center.x, -center.y, -center.z)

        objects = [
            CSG.box(.scale(60, 0.2, 60), material: desk),                     // 0 탁자
            Figure.eyewearFrame(e, material: sun ? acetate : gold),           // 1
            Figure.eyewearLenses(e, material: sun ? tint : lens),             // 2
        ]
        let lowest = -(e.lensR.y + e.rimWidth) - 0.06                         // 림 아래 + 갈고리
        placements = [
            Placement(objectIndex: 0, transform: .translate(0, lowest - 0.2, 0)),
            Placement(objectIndex: 1, transform: pose),
            Placement(objectIndex: 2, transform: pose),
        ]
        focusCenter = [0, -0.1, -0.25]
        focusRadius = 1.55
        focusHalfHeight = 0.55
        focusElevation = 0.42          // 위에서 내려다보는 제품 사진
        environment = .studio          // 금테·유리는 비칠 것이 있어야 산다
    }

    // MARK: - 둥근 상자 부품 검증 씬

    /// 왼쪽: 세 윤곽 교차(예전 방식) · 가운데: 새 `roundBox` · 오른쪽: `roundBox` 에서 구를 뺀 것.
    /// 가운데와 왼쪽의 **꼭짓점**을 비교하면 능선 유무가 바로 보인다.
    private func buildRoundBoxTest() {
        let floor = addMaterial([0.30, 0.31, 0.32], gloss: 0.10, grain: 0.30)
        let a = addMaterial([0.85, 0.30, 0.22], gloss: 0.85)
        let b = addMaterial([0.25, 0.55, 0.85], gloss: 0.85)
        let c = addMaterial([0.35, 0.75, 0.40], gloss: 0.85)

        let h = SIMD3<Float>(1.1, 0.8, 0.9)
        let r: Float = 0.34

        // 예전 방식 — 세 방향 둥근 윤곽의 교집합
        let profiles = CSG.roundedRectPrism(halfX: h.x, halfZ: h.z, corner: r, halfY: h.y, material: a)
                     & CSG.roundedPanel(halfX: h.x, halfY: h.y, halfZ: h.z + 0.3, corner: r, material: a)
                     & CSG.roundedSection(halfY: h.y, halfZ: h.z, halfX: h.x + 0.3, corner: r, material: a)

        let solid = CSG.roundBox(half: h, radius: r, material: b)
        let cut = CSG.roundBox(half: h, radius: r, material: c)
                - CSG.sphere(.translate(0, 0.6, 0.6) * .scale(0.75), material: c)

        objects = [CSG.box(.scale(40, 0.1, 40), material: floor), profiles, solid, cut]
        placements = [
            Placement(objectIndex: 0, transform: .translate(0, -1.0, 0)),
            Placement(objectIndex: 1, transform: .translate(-2.8, 0, 0)),
            Placement(objectIndex: 2, transform: .translate(0, 0, 0)),
            Placement(objectIndex: 3, transform: .translate(2.8, 0, 0)),
        ]
        focusCenter = [0, 0, 0]
        focusRadius = 4.4
        focusHalfHeight = 1.1
    }

    // MARK: - 버스만 있는 씬

    /// 버스 마감. 형상·배치는 완전히 같고 **재질 매핑만 바뀐다.**
    enum BusFinish {
        /// 실차 도색
        case solid
        /// 부품 색을 유지한 반투명 유리
        case tinted
        /// 색 없는 완전 투명 유리
        case clear
    }

    /// 같은 버스를 세 가지 마감으로 만든다.
    /// 실내·좌석·바퀴까지 전부 같은 규칙을 타므로, 마감을 늘려도 여기만 손대면 된다.
    private func buildBus(finish: BusFinish) {
        // 완전 투명은 재질 하나를 모두가 공유한다 (색이 없으니 나눌 이유가 없다)
        let clearGlassMat = addMaterial([0.94, 0.97, 0.96], type: MATERIAL_GLASS, ior: 1.48)

        /// 부품 색 하나를 마감에 맞는 재질 인덱스로 바꾼다.
        ///
        /// **어두운 색을 그대로 유리에 쓰면 거의 검게 막힌다** — 유리는 통과할 때마다 색이 곱해지므로
        /// 타이어(0.04)나 창틀(0.04) 같은 색은 두 번만 지나도 0 에 가까워진다.
        /// 그래서 반투명 마감에서는 색을 흰색 쪽으로 끌어올려 **색은 남기고 투과를 살린다.**
        func mat(_ c: SIMD3<Float>, gloss: Float = 0, lift: Float = 0.52) -> Int {
            switch finish {
            case .solid:
                return addMaterial(c, gloss: gloss)
            case .tinted:
                let lifted = c + (SIMD3<Float>(repeating: 1) - c) * lift
                return addMaterial(lifted, type: MATERIAL_GLASS, ior: 1.48)
            case .clear:
                return clearGlassMat
            }
        }

        // 서울 지선버스 색 + 실차 배색. gloss 는 solid 에서만 의미가 있다.
        let busMat = Bus.Materials(
            paint:      mat([0.20, 0.60, 0.15], gloss: 0.90),                  // 지선 초록
            black:      mat([0.035, 0.04, 0.045], gloss: 0.35, lift: 0.82),    // 창틀 고무 — 더 많이 띄운다
            cabin:      mat([0.46, 0.47, 0.46], gloss: 0.06),                  // 실내 벽면
            stripe:     mat([0.86, 0.88, 0.88], gloss: 0.85),
            glass:      finish == .solid
                        ? addMaterial([0.24, 0.32, 0.28], type: MATERIAL_GLASS, ior: 1.52)  // 선팅
                        : clearGlassMat,
            clearGlass: finish == .solid
                        ? addMaterial([0.82, 0.90, 0.88], type: MATERIAL_GLASS, ior: 1.52)
                        : clearGlassMat,
            tire:       mat([0.035, 0.035, 0.040], gloss: 0.18, lift: 0.80),
            rim:        mat([0.70, 0.72, 0.74], gloss: 0.85),
            chrome:     finish == .solid
                        ? addMaterial([0.92, 0.93, 0.95], type: MATERIAL_METAL)
                        : mat([0.92, 0.93, 0.95]),
            seat:       mat([0.30, 0.36, 0.44], gloss: 0.20),
            headLight:  mat([0.93, 0.94, 0.90], gloss: 0.70),
            amber:      mat([0.90, 0.48, 0.03], gloss: 0.90, lift: 0.32),      // 색을 더 남긴다
            tailLight:  mat([0.62, 0.045, 0.045], gloss: 0.92, lift: 0.32),
            plate:      mat([0.92, 0.76, 0.10], gloss: 0.55, lift: 0.32),
            rail:       mat([0.86, 0.62, 0.05], gloss: 0.55, lift: 0.32),      // 노란 손잡이
            acCover:    mat([0.72, 0.74, 0.75], gloss: 0.45))

        // 부품이 둥근 차체를 뚫고 나가거나 허공에 떠 있는지 검사한다.
        // 코너 반지름·치수를 바꾸면 조용히 깨지는 종류라 눈으로 찾지 말고 여기서 잡는다.
        for issue in Bus.interiorViolations(busMat) + Bus.floatingViolations(busMat) {
            print("⚠️ Bus: \(issue)")
        }

        // 노면 — 약한 광택을 줘야 차가 바닥에 비쳐 접지감이 생긴다
        let asphalt = addMaterial([0.085, 0.088, 0.095], gloss: 0.08, grain: 0.55)

        // 노면은 안개에 묻힐 만큼 넓게 — 좁으면 판때기 가장자리가 그대로 보인다
        // 거리 맥락. 도장면이 **반사할 것이 있어야** 금속처럼 보인다 —
        // 빈 하늘만 비추면 아무리 광택을 줘도 단색 판때기다.
        let lineWhite = addMaterial([0.72, 0.72, 0.70], gloss: 0.10, grain: 0.35)
        let concrete  = addMaterial([0.30, 0.30, 0.29], gloss: 0.12, grain: 0.30)
        let facade    = addMaterial([0.09, 0.11, 0.13], gloss: 0.55)

        objects = [CSG.box(.scale(120, 0.1, 120), material: asphalt),
                   Bus.body(busMat), Bus.windowFrames(busMat), Bus.glazing(busMat),
                   Bus.interior(busMat), Bus.seats(busMat), Bus.trim(busMat),
                   Bus.frontEnd(busMat), Bus.rearEnd(busMat), Bus.wheel(busMat),
                   CSG.box(material: lineWhite),        // 10 차선
                   CSG.box(material: concrete),         // 11 연석 · 보도
                   CSG.box(material: facade)]           // 12 건물 (같은 상자를 여러 번 인스턴스)
        let ground = 0, wheel = 9, lane = 10, curb = 11, building = 12

        // 바퀴 아래 끝(Bus.groundOffset)이 바닥 윗면에 정확히 닿도록 높이를 맞춘다
        let groundTop: Float = -2.5
        let busXform = float4x4.translate(0, groundTop - Bus.groundOffset, 0)

        placements = [Placement(objectIndex: ground, transform: .translate(0, -2.6, 0))]
        // 차체~뒷면(1...8) 은 전부 같은 변환으로 겹쳐 놓는다
        placements += (1...8).map { Placement(objectIndex: $0, transform: busXform) }
        // 바퀴는 오브젝트 하나를 6번 인스턴스로
        placements += Bus.wheelPlacements.map {
            Placement(objectIndex: wheel, transform: busXform * $0)
        }

        // 차선 (점선) — 버스 양옆 차로
        for i in -6...6 {
            for z in [-5.2, 5.2] as [Float] {
                placements.append(Placement(objectIndex: lane,
                    transform: .translate(Float(i) * 5.0, groundTop + 0.005, z) * .scale(1.6, 0.01, 0.09)))
            }
        }
        // 연석 + 보도 (승객문 쪽)
        placements.append(Placement(objectIndex: curb,
            transform: .translate(0, groundTop + 0.07, -9.0) * .scale(60, 0.07, 0.35)))
        placements.append(Placement(objectIndex: curb,
            transform: .translate(0, groundTop + 0.04, -13.0) * .scale(60, 0.05, 3.7)))

        // 건물 — 하나뿐인 상자를 크기만 바꿔 인스턴스로 세운다.
        // 반사에 잡히는 게 목적이라 형태는 단순해도 된다.
        let blocks: [(x: Float, z: Float, w: Float, h: Float, d: Float)] = [
            (-56, -34, 10, 10, 8), (-30, -38,  8, 14, 7), (-6, -34, 12,  8, 8),
            ( 20, -40,  9, 17, 8), ( 46, -35, 11, 11, 9), ( 70, -42,  8, 15, 8),
            (-48,  36,  9, 12, 8), (-18,  40, 11,  9, 8), ( 8,  35,  8, 16, 7),
            ( 36,  42, 12, 10, 9), ( 62,  37,  9, 14, 8),
        ]
        for b in blocks {
            placements.append(Placement(objectIndex: building,
                transform: .translate(b.x, groundTop + b.h, b.z) * .scale(b.w, b.h, b.d)))
        }

        // 버스 10.64 × 2.49 × 3.33 m → XZ 반지름 √(5.32² + 1.245²) ≈ 5.47, 반높이 1.72
        focusCenter = [0, groundTop + 1.6, 0]
        focusRadius = 6.3          // 버스 바운딩 구가 5.67 — 여유를 둬야 끝이 안 잘린다
        focusHalfHeight = 1.9
    }

    // MARK: - 부품 전시장 (16종 부품 데모 + 버스)

    private func buildShowcase() {
        // 재질
        let gray   = addMaterial([0.75, 0.75, 0.75])   // 0
        let red    = addMaterial([0.90, 0.25, 0.25])   // 1
        let blue   = addMaterial([0.25, 0.45, 0.90])   // 2
        let green  = addMaterial([0.30, 0.80, 0.40])   // 3
        let white  = addMaterial([0.95, 0.95, 0.95])   // 4
        let yellow = addMaterial([0.95, 0.85, 0.30])   // 5
        let mirror = addMaterial([0.92, 0.92, 0.95], type: MATERIAL_METAL)            // 6
        let gold   = addMaterial([1.00, 0.78, 0.35], type: MATERIAL_METAL)            // 7
        let glass  = addMaterial([0.97, 0.99, 1.00], type: MATERIAL_GLASS, ior: 1.5)  // 8
        let ruby   = addMaterial([0.95, 0.35, 0.45], type: MATERIAL_GLASS, ior: 1.77) // 9

        // 버스용
        let busPaint  = addMaterial([0.13, 0.50, 0.45])                                // 10
        let busTrim   = addMaterial([0.16, 0.17, 0.20])                                // 11
        let tireBlack = addMaterial([0.09, 0.09, 0.10])                                // 12
        let chrome    = addMaterial([0.88, 0.90, 0.93], type: MATERIAL_METAL)          // 13
        let seatRed   = addMaterial([0.55, 0.18, 0.22])                                // 14

        // ---- 오브젝트 0: 바닥 ----
        let ground = CSG.box(.scale(14, 0.1, 14), material: gray)

        // ---- 오브젝트 1: 고전 CSG (박스 ∩ 구 − 원기둥 3개) ----
        let core  = CSG.box(material: red) & CSG.sphere(.scale(1.4), material: white)
        let holeY = CSG.cylinder(.scale(0.6, 1.3, 0.6), material: blue)
        let holeX = holeY.transformed(.rotateZ(90))
        let holeZ = holeY.transformed(.rotateX(90))
        let die   = core - (holeX | holeY | holeZ)

        // ---- 오브젝트 2: 머그컵 (원기둥 − 원기둥, + 손잡이 링) ----
        let outer = CSG.cylinder(.scale(1.0, 1.2, 1.0), material: blue)
        let inner = CSG.cylinder(.translate(0, 0.3, 0) * .scale(0.85, 1.2, 0.85), material: white)
        let ring  = (CSG.cylinder(.scale(0.75, 0.15, 0.75), material: blue)
                     - CSG.cylinder(.scale(0.5, 0.2, 0.5), material: blue))
                    .transformed(.translate(1.2, 0.1, 0) * .rotateX(90))
        let handle = ring & CSG.box(.translate(1.7, 0, 0) * .scale(0.7, 1, 1), material: blue)
        let mug = (outer - inner) | handle

        // ---- 오브젝트 3: 로켓 (원뿔 + 원기둥 + 핀 3개 − 창문) ----
        let nose = CSG.cone(.translate(0, 3.2, 0) * .scale(1, 1.2, 1), material: red)
        let body = CSG.cylinder(.scale(1, 2, 1), material: white)
        let fin  = CSG.box(.translate(0, -1.6, 1.3) * .scale(0.08, 0.7, 0.8), material: red)
        let fins = CSG.unionAll((0..<3).map { fin.transformed(.rotateY(Float($0) * 120)) })
        let window = CSG.sphere(.translate(0, 0.9, 1.0) * .scale(0.35), material: yellow)
        let rocket = (nose | body | fins) - window

        // ---- 오브젝트 4: 종(구 − 구 − 원기둥, + 원뿔 손잡이) ----
        let bellOuter = CSG.sphere(.scale(1.0), material: glass)
        let bellInner = CSG.sphere(.scale(0.85), material: glass)
        let cutBottom = CSG.box(.translate(0, -1.5, 0) * .scale(2, 1.2, 2), material: glass)
        let knob = CSG.cone(.translate(0, 1.1, 0) * .scale(0.5, 0.4, 0.5), material: green)
        let bell = ((bellOuter - bellInner) - cutBottom) | knob

        // ---- 오브젝트 5: 바퀴 (토러스 타이어 + 원기둥 허브 + 박스 스포크 3개) ----
        let tire   = CSG.torus(material: white)
        let hub    = CSG.cylinder(.scale(0.35, 0.25, 0.35), material: yellow)
        let spoke  = CSG.box(.scale(0.5, 0.12, 0.08), material: yellow).transformed(.translate(0.5, 0, 0))
        let spokes = CSG.unionAll((0..<3).map { spoke.transformed(.rotateY(Float($0) * 120)) })
        let wheel  = (tire | hub | spokes).transformed(.rotateX(90))   // 축을 z로 → 세워진 바퀴

        // ---- 오브젝트 6: 알약 (캡슐을 반씩 다른 재질로: 교집합 활용) ----
        let pill    = CSG.capsule(.scale(0.5), material: red)
        let topHalf = CSG.box(.translate(0, 1.5, 0) * .scale(2, 1.5, 2), material: red)
        let botHalf = CSG.box(.translate(0, -1.5, 0) * .scale(2, 1.5, 2), material: white)
        let capsulePill = ((pill & topHalf) | (CSG.capsule(.scale(0.5), material: white) & botHalf))
                            .transformed(.rotateZ(90) * .rotateY(30))

        // ---- 오브젝트 7: 집 (박스 몸체 + 프리즘 지붕 − 문/창문) ----
        let walls = CSG.box(.scale(1.0, 0.7, 0.8), material: white)
        let roof  = CSG.prism(.translate(0, 0.7, 0) * .rotateZ(90) * .scale(0.9, 1.15, 0.9), material: red)
        let door  = CSG.box(.translate(0, -0.4, 0.8) * .scale(0.2, 0.35, 0.3), material: blue)
        let win   = CSG.box(.translate(0.5, 0.1, 0.8) * .scale(0.18, 0.18, 0.3), material: blue)
        let house = (walls | roof) - (door | win)

        // ---- 오브젝트 8: 볼트 (육각 머리 + 축) ----
        let boltObj = CSG.bolt(material: gray).transformed(.scale(0.5))

        // ---- 오브젝트 9: 램프 (원뿔대 갓 − 안쪽 원뿔대, 반구 전구, 팔각기둥 받침) ----
        let shade = CSG.frustum(.translate(0, 1.6, 0) * .scale(1.1, 0.6, 1.1), material: red)
                  - CSG.frustum(.translate(0, 1.55, 0) * .scale(1.0, 0.6, 1.0), material: red)
        let bulb  = CSG.hemisphere(.translate(0, 1.2, 0) * .rotateX(180) * .scale(0.35), material: yellow)
        let pole  = CSG.cylinder(.translate(0, 0.5, 0) * .scale(0.08, 0.9, 0.08), material: gray)
        let base  = CSG.octPrism(.translate(0, -0.4, 0) * .scale(0.7, 0.1, 0.7), material: gray)
        let lamp  = shade | bulb | pole | base

        // ---- 오브젝트 10: 보석 진열 (정사면체 · 정팔면체 · 사각뿔 · 쐐기) ----
        let gems = CSG.unionAll([
            CSG.tetra(.translate(-2.4, 0, 0) * .rotateY(20) * .scale(0.55), material: green),
            CSG.octa(.translate(-0.8, 0.2, 0) * .rotateY(30) * .scale(0.6), material: ruby),
            CSG.pyramid(.translate(0.8, 0, 0) * .rotateY(15) * .scale(0.6), material: yellow),
            CSG.wedge(.translate(2.4, 0, 0) * .rotateY(-25) * .scale(0.55), material: red),
        ])

        // ---- 오브젝트 11: 둥근 박스 (복합 부품) + 튜브 ----
        let roundedBox = CSG.roundedBox(radius: 0.3, material: mirror).transformed(.scale(0.6))
        let tubeObj    = CSG.tube(material: gold).transformed(.rotateX(90) * .scale(0.6))

        // ---- 오브젝트 13: 회전체 꽃병 (lathe) — 유리 ----
        let vaseProfile: [(y: Float, r: Float)] = [
            (-1.0, 0.45), (-0.8, 0.7), (-0.3, 0.8), (0.3, 0.55), (0.7, 0.35), (1.0, 0.5)
        ]
        let vase = CSG.lathe(vaseProfile, material: glass)
                 - CSG.lathe(vaseProfile.map { ($0.y + 0.08, $0.r - 0.08) }, material: glass)

        // ---- 오브젝트 14: 오각 기둥 + 별 모양 구멍(볼록 폴리곤 압출) ----
        let penta = CSG.ngonPrism(5, .scale(0.9, 0.5, 0.9), material: green)
        let hole  = CSG.polygon([[-0.3, -0.3], [0.3, -0.3], [0.4, 0.2], [0, 0.45], [-0.4, 0.2]],
                                .scale(1, 0.6, 1), material: green)
        let pentaObj = penta - hole

        // ---- 오브젝트 15: 큰 거울 판 ----
        let mirrorPanel = CSG.box(.scale(3.0, 2.0, 0.08), material: mirror)

        // ---- 오브젝트 16~20: 버스 (Bus.swift) ----
        // 구간 한계(CSG_MAX_INTERVALS)는 오브젝트 단위라, 한 덩어리로 만들지 않고 다섯으로 나눈다.
        let busMat = Bus.Materials(paint: busPaint, black: busTrim, cabin: gray, stripe: white,
                                   glass: glass, clearGlass: glass, tire: tireBlack,
                                   rim: gray, chrome: chrome, seat: seatRed,
                                   headLight: white, amber: yellow, tailLight: red,
                                   plate: yellow, rail: yellow, acCover: white)

        objects = [ground, die, mug, rocket, bell, wheel, capsulePill, house,
                   boltObj, lamp, gems, roundedBox, tubeObj, vase, pentaObj, mirrorPanel,
                   Bus.body(busMat), Bus.windowFrames(busMat), Bus.glazing(busMat),
                   Bus.interior(busMat), Bus.seats(busMat), Bus.trim(busMat),
                   Bus.frontEnd(busMat), Bus.rearEnd(busMat), Bus.wheel(busMat)]
        let busFirst = 16, busLast = 23, busWheel = 24

        // 버스 배치 — 바퀴 아래 끝(Bus.groundOffset)이 바닥 윗면에 정확히 닿도록 높이를 계산한다
        let busScale: Float = 0.5          // 실차 치수(11 m)라 전시장에서는 줄여서 놓는다
        let groundTop: Float = -2.5                       // ground = box(scale(14, 0.1, 14)) @ y = -2.6
        let busXform = float4x4.translate(-0.5, groundTop - Bus.groundOffset * busScale, -4.2)
                     * .rotateY(-18) * .scale(busScale)

        // 배치
        placements = [
            Placement(objectIndex: 0, transform: .translate(0, -2.6, 0)),
            Placement(objectIndex: 1, transform: .translate(-3.0, -1.5, 0.5) * .rotateY(20)),
            Placement(objectIndex: 2, transform: .translate(3.0, -1.3, 0.5) * .rotateY(-30)),
            Placement(objectIndex: 3, transform: .translate(0, -0.9, -1.5) * .scale(0.8)),
            Placement(objectIndex: 4, transform: .translate(0, -1.5, 2.8) * .scale(0.9)),
            Placement(objectIndex: 5, transform: .translate(5.5, -1.2, -4.8) * .rotateY(40)),   // 버스 자리를 비켜 이동
            Placement(objectIndex: 6, transform: .translate(3.4, -2.05, -3.0)),
            Placement(objectIndex: 7, transform: .translate(-4.6, -1.8, 2.6) * .rotateY(60) * .scale(0.9)),
            Placement(objectIndex: 8,  transform: .translate(4.8, -1.3, 2.6) * .rotateZ(25)),
            Placement(objectIndex: 9,  transform: .translate(2.8, -2.5, -6.6)),               // 버스 자리를 비켜 이동
            Placement(objectIndex: 10, transform: .translate(0, -2.0, 5.5) * .rotateY(180)),
            Placement(objectIndex: 11, transform: .translate(-5.5, -1.95, -0.5) * .rotateY(30)),
            Placement(objectIndex: 12, transform: .translate(5.8, -1.9, -0.8)),
            Placement(objectIndex: 13, transform: .translate(-2.0, -1.5, 4.5) * .scale(1.0)),
            Placement(objectIndex: 14, transform: .translate(2.2, -2.0, 4.6) * .rotateY(20)),
            Placement(objectIndex: 15, transform: .translate(0, -0.6, -7.5)),
            // 같은 오브젝트를 여러 번 배치해도 가속 구조는 하나만 쓴다
            Placement(objectIndex: 1, transform: .translate(-4.8, -1.9, -3.5) * .rotateY(60) * .scale(0.6)),

        ]
        placements += (busFirst...busLast).map { Placement(objectIndex: $0, transform: busXform) }
        // 바퀴는 오브젝트 하나를 네 번 인스턴스로 쓴다
        placements += Bus.wheelPlacements.map {
            Placement(objectIndex: busWheel, transform: busXform * $0)
        }

        focusCenter = [0, -1, 0]
        focusRadius = 5.4          // 부품들이 x, z 로 ±6 까지 퍼져 있다
        focusHalfHeight = 2.5      // 로켓 꼭짓점이 제일 높다
    }

    /// `gloss` 0 = 무광, 1 = 자동차 도장급 클리어코트. 하이라이트와 환경 반사량을 함께 정한다.
    @discardableResult
    private func addMaterial(_ c: SIMD3<Float>, type: MaterialType = MATERIAL_DIFFUSE,
                             ior: Float = 1.5, gloss: Float = 0, grain: Float = 0,
                             sss: Float = 0) -> Int {
        materials.append(Material(color: c, type: type.rawValue, ior: ior,
                                  gloss: gloss, grain: grain, sss: sss))
        return materials.count - 1
    }
}
