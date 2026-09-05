//
//  ShaderTypes.h
//  Swift ↔ Metal 공유 타입. Bridging Header에서 #import.
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// CSG 평가기의 한계값 — Swift(검증)와 Metal(배열 크기)이 반드시 같은 값을 봐야 한다.
//
// 이 둘이 intersection function 의 **스레드 스택 사용량**을 그대로 결정한다:
//   IntervalList = Interval(36B) * CSG_MAX_INTERVALS + 4
//   evalCSG 의 stack[CSG_MAX_STACK] 이 그 대부분
// 키우면 A15 같은 기기에서 파이프라인 생성이
// "Compute pipeline exceeds available stack space" 로 실패한다. 늘릴 때는 실기기에서 반드시 확인할 것.
//
// CSG_MAX_INTERVALS: 레이 하나가 오브젝트 하나를 통과하며 만들 수 있는 최대 구간 수
// CSG_MAX_STACK    : 후위 표기 평가에 필요한 최대 스택 깊이.
//                    Renderer 가 오브젝트마다 CSG.stackDepth() 로 검사해서 초과하면 에러를 던진다.
#define CSG_MAX_INTERVALS 6
#define CSG_MAX_STACK     5

// 부품 종류 (모두 로컬 좌표계에서 "단위 크기")
//   SPHERE   : 반지름 1, 원점
//   BOX      : [-1,1]^3
//   CYLINDER : 반지름 1, y ∈ [-1,1]
//   CONE     : 꼭짓점 y=1, 밑면 y=-1 반지름 1
//   TORUS    : 대반지름 1, 소반지름 0.35, 축 y   (범위 ±1.35, y ±0.35)
//   CAPSULE  : 반지름 1, 원기둥 y ∈ [-1,1] + 양끝 반구 (범위 y ±2)
//   PRISM    : 단위원에 내접한 정삼각형(꼭짓점 +x)을 y ∈ [-1,1]로 압출
//   HEX_PRISM / OCT_PRISM : 단위원 내접 정육각형/정팔각형 압출, y ∈ [-1,1]
//   WEDGE    : xy 평면 직각삼각형 (-1,-1),(1,-1),(-1,1) 을 z ∈ [-1,1] 로 압출
//   TETRA    : 정사면체 (꼭짓점 (±1,±1,±1) 중 짝수 부호)
//   OCTA     : 정팔면체 |x|+|y|+|z| ≤ 1
//   PYRAMID  : 밑면 [-1,1]² (y=-1), 꼭짓점 (0,1,0)
//   FRUSTUM  : 잘린 원뿔, 밑면 y=-1 반지름 1, 윗면 y=1 반지름 0.5
//   HEMISPHERE : 반지름 1 구의 y ≥ 0 부분
//   RING     : 바깥 반지름 1, 안쪽 반지름 0.6, y ∈ [-1,1] (비볼록)
//   POLY     : 임의의 볼록 다면체 — partData[reserved0 ..< reserved0+reserved1] 에 평면(nx,ny,nz,h)
//   FRUSTUM_GENERIC : r(y) = a - b·y, y ∈ [-1,1]. partData[reserved0] = (a, b, 0, 0)
//   ROUND_BOX : 진짜 둥근 상자 = 상자 ⊕ 반지름 r 구 (민코프스키 합).
//               면은 평평, 모서리는 원기둥, **꼭짓점은 구면**이라 법선이 매끄럽게 이어진다.
//               partData[reserved0] = (bx, by, bz, r) — 안쪽 상자 반크기 + 반지름.
//               전체 반크기는 (bx+r, by+r, bz+r). 다른 부품과 달리 **크기를 data 로 받는다**
//               (비균등 스케일하면 꼭짓점이 타원체가 되어 매끈함이 깨지므로).
//   BLOB     : **부드럽게 섞이는 타원체 덩어리** (메타볼 / smooth-min SDF).
//               불리언 합집합은 교선에서 법선이 꺾여 능선을 남기므로 인체·동물처럼
//               유기적인 형상을 만들 수 없다. BLOB 은 SDF 를 구 추적(sphere tracing)해서
//               **원소들이 이어 붙는 자리를 아예 없앤다.**
//               partData[reserved0] = (halfX, halfY, halfZ, boundRadius)  ← AABB + 경계구
//               partData[reserved0+1] = (원소 수, inflate, 0, 0)
//                 inflate: SDF 에서 그냥 빼는 값 = **정확한 오프셋 표면.** 옷을 만들 때 쓴다.
//               이후 원소마다 float4 **네 개**:
//                 A = (p0.xyz, r0), B = (p1.xyz 또는 (ry,rz,0), r1), C = (blend, sign, type, -)
//                 D = 타원체: 회전 쿼터니언 (x,y,z,w) / 베지에: 제어점 p2
//                 type 0 → 타원체: p0 = 중심, 반지름 = (A.w, B.x, B.y), D 로 **회전** (눈꼬리·광대)
//                 type 1 → 둥근 원뿔: p0→p1, 반지름 r0→r1. **팔다리는 반드시 이쪽.**
//                 type 2 → 2차 베지에 튜브: p0 → (제어 D) → p1, 반지름 r0→r1 (눈썹·입술선·머리결)
//                   구를 줄줄이 꿰면 간격이 반지름의 1.5배만 넘어도 소시지처럼 울퉁불퉁해진다.
//                 sign < 0 이면 **음의 원소** — smooth-max 로 파낸다 (눈두덩·배꼽·입선).
//                 blend 는 그 원소가 이웃과 섞이는 반경. 작게 주면 코끝처럼 또렷하게 남는다.
// 불리언 연산은 100 이상
typedef enum {
    CSG_PART_SPHERE   = 0,
    CSG_PART_BOX      = 1,
    CSG_PART_CYLINDER = 2,
    CSG_PART_CONE     = 3,
    CSG_PART_TORUS    = 4,
    CSG_PART_CAPSULE  = 5,
    CSG_PART_PRISM    = 6,
    CSG_PART_HEX_PRISM  = 7,
    CSG_PART_OCT_PRISM  = 8,
    CSG_PART_WEDGE      = 9,
    CSG_PART_TETRA      = 10,
    CSG_PART_OCTA       = 11,
    CSG_PART_PYRAMID    = 12,
    CSG_PART_FRUSTUM    = 13,
    CSG_PART_HEMISPHERE = 14,
    CSG_PART_RING       = 15,
    CSG_PART_POLY       = 16,
    CSG_PART_FRUSTUM_GENERIC = 17,
    CSG_PART_ROUND_BOX       = 18,
    CSG_PART_BLOB            = 19,
    CSG_OP_UNION      = 100,
    CSG_OP_INTERSECT  = 101,
    CSG_OP_SUBTRACT   = 102
} CSGNodeType;

// 후위(postfix) 순서로 저장된 CSG 트리 노드
typedef struct {
    matrix_float4x4 worldToLocal;   // 부품 노드: 오브젝트 공간 → 부품 로컬 공간
    unsigned int    type;           // CSGNodeType
    unsigned int    material;       // 부품 노드: 재질 인덱스
    unsigned int    reserved0;      // POLY/FRUSTUM_GENERIC: partData 오프셋
    unsigned int    reserved1;      // POLY: 평면 개수
} CSGNode;

// CSG 오브젝트 하나 = nodes[nodeOffset ..< nodeOffset+nodeCount]
typedef struct {
    unsigned int nodeOffset;
    unsigned int nodeCount;
    unsigned int reserved0;
    unsigned int reserved1;
} CSGObject;

typedef enum {
    MATERIAL_DIFFUSE = 0,
    MATERIAL_METAL   = 1,   // 완전 거울 반사, color 로 착색
    MATERIAL_GLASS   = 2,   // 굴절 + 프레넬 반사, color 로 착색, ior 사용
    /// 머리카락. 확산 경로를 타되 **가닥 방향의 비등방 하이라이트**(Kajiya-Kay)와
    /// 가닥 결을 흉내낸 미세 법선 요동을 얹는다. 가닥을 기하로 심으면 튜브 다발이 되지만,
    /// 매끈한 덩어리에 이 셰이딩을 주면 머리카락으로 읽힌다.
    MATERIAL_HAIR    = 3,
    /// 발광. 조명·그림자 무시하고 color 를 그대로 낸다 (아크 리액터, 눈, 리펄서).
    /// 톤매핑 화이트포인트가 2.6 이므로 color 를 3~6 으로 주면 하얗게 타면서 색 테두리가 남는다
    MATERIAL_EMISSIVE = 4,
    /// 새틴 금속 (도장된 티타늄·브러시드 스틸). 완전 거울(METAL)과 확산 사이 —
    /// color 로 착색된 프레넬 반사(F0 ≈ 0.55·color)에 확산 바탕을 더한다.
    /// 어두운 스튜디오에서 METAL 은 검게 죽고 DIFFUSE 는 플라스틱이 되는데, 이건 둘 다 피한다.
    MATERIAL_SATIN    = 5
} MaterialType;

typedef struct {
    vector_float3 color;
    unsigned int  type;     // MaterialType
    float         ior;      // GLASS 굴절률 (유리 1.5, 물 1.33, 다이아몬드 2.42)
    /// 클리어코트 광택. 0 = 완전 무광, 1 = 자동차 도장급.
    /// 하이라이트 세기 + 프레넬 환경 반사량을 함께 정한다 —
    /// 이게 0 이면 아무리 형상이 정확해도 점토 모형처럼 보인다.
    float         gloss;
    /// 표면 얼룩(절차적 노이즈) 세기. 0 = 균일.
    /// **GLASS 에서는 다른 뜻**: 높이 그라데이션 착색의 세기 (gloss = 맑은 아래쪽 y, sss = 짙은 위쪽 y).
    /// 썬글라스 렌즈용. 띠로 나누면 열 개여도 계단이 보이지만 이건 연속이다.
    /// 완벽하게 균일한 큰 면은 아무리 조명이 좋아도 CG 처럼 보인다 — 노면에 특히 필요하다.
    float         grain;
    /// 표면하 산란(SSS) 근사. 0 = 불투명, 1 = 피부.
    /// 빛이 표면 아래로 들어갔다 나오는 것을 **감싸는 확산 + 터미네이터의 붉은 띠**로 흉내낸다.
    /// 피부는 이게 없으면 아무리 형상이 좋아도 **석고상**으로 보인다 —
    /// 명암 경계가 칼같이 끊기는 것이 사람 피부에서 가장 어색한 지점이다.
    float         sss;
} Material;

// 인스턴스(배치)별 법선 변환 행렬 = transpose(inverse(objectToWorld))
typedef struct {
    matrix_float4x4 normalMatrix;
} InstanceData;

typedef struct {
    vector_float3 cameraPos;
    vector_float3 forward;
    vector_float3 right;
    vector_float3 up;
    vector_float3 lightDir;
    unsigned int  width;
    unsigned int  height;
    float         aspect;
    float         tanHalfFov;
    /// 0 = 야외(하늘·태양), 1 = 스튜디오(어두운 배경 + 소프트박스),
    /// 2 = **흰 사이클로라마** (제품 사진: 배경은 노출 과다로 순백, 금속·유리에는 소프트박스가 비친다),
    /// 3 = **밝은 스튜디오** (전시장: 중간 회색 배경 + 큰 소프트박스 넷 — 금속이 회색으로 죽지 않는다).
    /// **금속은 비칠 것이 있어야 금속으로 보인다** — 매끈한 그라데이션만 있으면
    /// 완벽한 거울도 단색 판때기가 된다.
    unsigned int  envMode;
    /// 광원의 각반지름(rad). 0 = 점광원(딱딱한 그림자). 0.05 정도면 면광원의 부드러운 접지 그림자.
    /// 그림자 레이를 8개 쏘므로 8배 비싸다 — 작은 제품 씬에서만.
    float         shadowSoftness;
    /// 픽셀당 샘플 수 (1 또는 4). 가는 철사 테처럼 픽셀보다 얇은 것은 4 가 아니면 계단이 된다.
    unsigned int  spp;
    /// 노출 배율 (기본 1.25). 어두운 스튜디오에서 밝은 전시장 느낌을 내려면 올린다.
    float         exposure;
} Uniforms;

#endif /* ShaderTypes_h */
