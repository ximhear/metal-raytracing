//
//  Shaders.metal
//  16종 부품(구·박스·원기둥·원뿔·토러스·캡슐·각기둥·다면체·원뿔대·반구·링)을 해석적으로 레이 트레이싱하고,
//  구간(interval) 불리언 연산으로 CSG를 평가하는 intersection function
//  + 확산/거울/유리 재질을 지원하는 렌더 커널
//

#include <metal_stdlib>
#include <metal_raytracing>
#include "ShaderTypes.h"

using namespace metal;
using namespace raytracing;

// 한계값은 ShaderTypes.h 에 있다 — Swift 쪽 검증과 같은 값을 써야 하기 때문.
#define MAX_INTERVALS CSG_MAX_INTERVALS
#define MAX_STACK     CSG_MAX_STACK

// ---------------------------------------------------------------------------
// 자료구조
// ---------------------------------------------------------------------------

// 레이가 솔리드 내부에 있는 구간 [tIn, tOut] 과 양쪽 경계의 법선/재질
//
// float3 는 16바이트 정렬이라 순진하게 쓰면 이 구조체가 64바이트가 되고,
// stack[MAX_STACK] 하나만 3KB 를 넘겨 A15 에서 파이프라인 생성이 실패한다.
// packed_float3(12B) + ushort 재질로 36바이트까지 줄인다.
struct Interval {
    float         tIn;
    float         tOut;
    packed_float3 nIn;
    packed_float3 nOut;
    ushort        mIn;
    ushort        mOut;
};

struct IntervalList {
    Interval iv[MAX_INTERVALS];
    int      count;
};

struct Hit { float t; packed_float3 n; };   // 32B → 16B (위와 같은 이유)

// 부품의 경계 교차 후보 (볼록: ≤2 유효 + 이음새 중복, 토러스: ≤4)
#define MAX_CANDS 6
struct Cands {
    Hit h[MAX_CANDS];
    int n;
};

// 이 크기들이 intersection function 의 스레드 스택을 결정한다.
// float3(16B 정렬)로 되돌리면 Interval 64B / IntervalList 400B 가 되어
// A15 급 기기에서 "Compute pipeline exceeds available stack space" 로 파이프라인 생성이 실패한다.
static_assert(sizeof(Interval) == 36, "Interval 이 커졌다 — packed_float3 / ushort 를 유지할 것");
static_assert(sizeof(Hit) == 16, "Hit 이 커졌다 — packed_float3 를 유지할 것");

struct CSGPayload {
    float3 normal;
    uint   material;
};

static inline void addCand(thread Cands& c, float t, float3 n) {
    if (c.n < MAX_CANDS) { c.h[c.n].t = t; c.h[c.n].n = n; c.n++; }
}

static inline void pushInterval(thread IntervalList& L, Interval iv) {
    if (L.count < MAX_INTERVALS) { L.iv[L.count] = iv; L.count++; }
}

// ---------------------------------------------------------------------------
// 부품별 교차 (로컬 공간, 단위 크기). 후보 t 값들을 모은다.
// ---------------------------------------------------------------------------

static void candSphere(float3 o, float3 d, thread Cands& c) {
    float a = dot(d, d);
    float b = 2.0f * dot(o, d);
    float k = dot(o, o) - 1.0f;
    float disc = b * b - 4.0f * a * k;
    if (disc < 0.0f) return;
    float s = sqrt(disc);
    float t1 = (-b - s) / (2.0f * a);
    float t2 = (-b + s) / (2.0f * a);
    addCand(c, t1, normalize(o + d * t1));
    addCand(c, t2, normalize(o + d * t2));
}

static void candBox(float3 o, float3 d, thread Cands& c) {
    float3 inv = 1.0f / d;
    float3 t0 = (-1.0f - o) * inv;
    float3 t1 = ( 1.0f - o) * inv;
    float3 tmin3 = min(t0, t1);
    float3 tmax3 = max(t0, t1);
    float tmin = max(max(tmin3.x, tmin3.y), tmin3.z);
    float tmax = min(min(tmax3.x, tmax3.y), tmax3.z);
    if (tmax < tmin) return;

    float3 nIn, nOut;
    if      (tmin == tmin3.x) nIn = float3(-sign(d.x), 0, 0);
    else if (tmin == tmin3.y) nIn = float3(0, -sign(d.y), 0);
    else                      nIn = float3(0, 0, -sign(d.z));
    if      (tmax == tmax3.x) nOut = float3(sign(d.x), 0, 0);
    else if (tmax == tmax3.y) nOut = float3(0, sign(d.y), 0);
    else                      nOut = float3(0, 0, sign(d.z));

    addCand(c, tmin, nIn);
    addCand(c, tmax, nOut);
}

static void candCylinder(float3 o, float3 d, thread Cands& c) {
    float a = d.x * d.x + d.z * d.z;
    float b = 2.0f * (o.x * d.x + o.z * d.z);
    float k = o.x * o.x + o.z * o.z - 1.0f;
    if (a > 1e-8f) {
        float disc = b * b - 4.0f * a * k;
        if (disc >= 0.0f) {
            float s = sqrt(disc);
            for (int i = 0; i < 2; i++) {
                float t = (i == 0) ? (-b - s) / (2.0f * a) : (-b + s) / (2.0f * a);
                float3 p = o + d * t;
                if (fabs(p.y) <= 1.0f) addCand(c, t, normalize(float3(p.x, 0, p.z)));
            }
        }
    }
    if (fabs(d.y) > 1e-8f) {
        for (int i = 0; i < 2; i++) {
            float s = (i == 0) ? -1.0f : 1.0f;
            float t = (s - o.y) / d.y;
            float3 p = o + d * t;
            if (p.x * p.x + p.z * p.z <= 1.0f) addCand(c, t, float3(0, s, 0));
        }
    }
}

// 회전 원뿔대 옆면: 반지름 r(y) = a - b·y, y ∈ [-1,1]. 뚜껑은 반지름이 0보다 크면 추가.
static void candConeGeneric(float3 o, float3 d, float a, float b, thread Cands& c) {
    float g0 = a - b * o.y;                       // t=0 에서의 r(y)
    float A = d.x * d.x + d.z * d.z - b * b * d.y * d.y;
    float B = 2.0f * (o.x * d.x + o.z * d.z + g0 * b * d.y);
    float C = o.x * o.x + o.z * o.z - g0 * g0;

    if (fabs(A) > 1e-8f) {
        float disc = B * B - 4.0f * A * C;
        if (disc >= 0.0f) {
            float s = sqrt(disc);
            for (int i = 0; i < 2; i++) {
                float t = (i == 0) ? (-B - s) / (2.0f * A) : (-B + s) / (2.0f * A);
                float3 p = o + d * t;
                if (p.y >= -1.0f && p.y <= 1.0f && (a - b * p.y) >= 0.0f)
                    addCand(c, t, normalize(float3(p.x, b * (a - b * p.y), p.z)));
            }
        }
    } else if (fabs(B) > 1e-8f) {
        float t = -C / B;
        float3 p = o + d * t;
        if (p.y >= -1.0f && p.y <= 1.0f && (a - b * p.y) >= 0.0f)
            addCand(c, t, normalize(float3(p.x, b * (a - b * p.y), p.z)));
    }
    if (fabs(d.y) > 1e-8f) {
        for (int i = 0; i < 2; i++) {
            float sgn = (i == 0) ? -1.0f : 1.0f;
            float rr = a - b * sgn;               // 그 높이의 반지름
            if (rr <= 1e-6f) continue;
            float t = (sgn - o.y) / d.y;
            float3 p = o + d * t;
            if (p.x * p.x + p.z * p.z <= rr * rr) addCand(c, t, float3(0, sgn, 0));
        }
    }
}

static void candCone(float3 o, float3 d, thread Cands& c)    { candConeGeneric(o, d, 0.5f,  0.5f,  c); }
static void candFrustum(float3 o, float3 d, thread Cands& c) { candConeGeneric(o, d, 0.75f, 0.25f, c); }

// 반구: 구의 y ≥ 0 부분 (볼록)
static void candHemisphere(float3 o, float3 d, thread Cands& c) {
    float a = dot(d, d), b = 2.0f * dot(o, d), k = dot(o, o) - 1.0f;
    float disc = b * b - 4.0f * a * k;
    if (disc >= 0.0f) {
        float s = sqrt(disc);
        for (int i = 0; i < 2; i++) {
            float t = (i == 0) ? (-b - s) / (2.0f * a) : (-b + s) / (2.0f * a);
            float3 p = o + d * t;
            if (p.y >= 0.0f) addCand(c, t, normalize(p));
        }
    }
    if (fabs(d.y) > 1e-8f) {
        float t = -o.y / d.y;
        float3 p = o + d * t;
        if (p.x * p.x + p.z * p.z <= 1.0f) addCand(c, t, float3(0, -1, 0));
    }
}

// 링(고리): 바깥 1, 안쪽 0.6, y ∈ [-1,1]. 비볼록 → 교차점을 정렬해 쌍으로 묶는다.
#define RING_INNER 0.6f
static void candRing(float3 o, float3 d, thread Cands& c) {
    float a = d.x * d.x + d.z * d.z;
    float b = 2.0f * (o.x * d.x + o.z * d.z);
    float oxz = o.x * o.x + o.z * o.z;
    if (a > 1e-8f) {
        for (int w = 0; w < 2; w++) {
            float rr = (w == 0) ? 1.0f : RING_INNER;
            float k = oxz - rr * rr;
            float disc = b * b - 4.0f * a * k;
            if (disc < 0.0f) continue;
            float s = sqrt(disc);
            for (int i = 0; i < 2; i++) {
                float t = (i == 0) ? (-b - s) / (2.0f * a) : (-b + s) / (2.0f * a);
                float3 p = o + d * t;
                if (fabs(p.y) <= 1.0f) {
                    float3 n = normalize(float3(p.x, 0, p.z));
                    addCand(c, t, (w == 0) ? n : -n);   // 안쪽 벽 법선은 중심을 향함
                }
            }
        }
    }
    if (fabs(d.y) > 1e-8f) {
        for (int i = 0; i < 2; i++) {
            float sgn = (i == 0) ? -1.0f : 1.0f;
            float t = (sgn - o.y) / d.y;
            float3 p = o + d * t;
            float r2 = p.x * p.x + p.z * p.z;
            if (r2 <= 1.0f && r2 >= RING_INNER * RING_INNER) addCand(c, t, float3(0, sgn, 0));
        }
    }
}

// ---- 토러스: 4차 방정식 ----

// z^3 + a z^2 + b z + c = 0 의 가장 큰 실근
static float cubicLargestRoot(float a, float b, float c) {
    float a2 = a * a;
    float p = b - a2 / 3.0f;
    float q = 2.0f * a2 * a / 27.0f - a * b / 3.0f + c;
    float off = -a / 3.0f;
    float disc = q * q / 4.0f + p * p * p / 27.0f;
    if (disc >= 0.0f) {
        float s = sqrt(disc);
        float u = -q / 2.0f + s;
        float v = -q / 2.0f - s;
        u = sign(u) * pow(fabs(u), 1.0f / 3.0f);
        v = sign(v) * pow(fabs(v), 1.0f / 3.0f);
        return u + v + off;
    } else {
        float r = sqrt(-p / 3.0f);
        float phi = acos(clamp(-q / (2.0f * r * r * r), -1.0f, 1.0f));
        return 2.0f * r * cos(phi / 3.0f) + off;
    }
}

// a4 x^4 + a3 x^3 + a2 x^2 + a1 x + a0 = 0 의 실근 (Ferrari + Newton 보정)
static int solveQuartic(float a4, float a3, float a2, float a1, float a0, thread float* roots) {
    float b = a3 / a4, c = a2 / a4, d = a1 / a4, e = a0 / a4;
    float b2 = b * b;
    float p = c - 3.0f * b2 / 8.0f;
    float q = d - b * c / 2.0f + b2 * b / 8.0f;
    float r = e - b * d / 4.0f + b2 * c / 16.0f - 3.0f * b2 * b2 / 256.0f;
    float shift = -b / 4.0f;
    int n = 0;

    if (fabs(q) < 1e-6f) {
        // 복이차: y^2 + p y + r = 0, y = x^2
        float disc = p * p - 4.0f * r;
        if (disc < 0.0f) return 0;
        float s = sqrt(disc);
        float y1 = (-p - s) / 2.0f, y2 = (-p + s) / 2.0f;
        if (y1 >= 0.0f) { float x = sqrt(y1); roots[n++] = -x + shift; roots[n++] = x + shift; }
        if (y2 >= 0.0f) { float x = sqrt(y2); roots[n++] = -x + shift; roots[n++] = x + shift; }
    } else {
        // 분해 3차식: m^3 + p m^2 + (2p^2 - 8r)/8 m - q^2/8 = 0
        float mm = cubicLargestRoot(p, (2.0f * p * p - 8.0f * r) / 8.0f, -q * q / 8.0f);
        if (mm <= 0.0f) return 0;
        float s2m = sqrt(2.0f * mm);
        float t1 = p / 2.0f + mm - q / (2.0f * s2m);
        float t2 = p / 2.0f + mm + q / (2.0f * s2m);
        float d1 = s2m * s2m - 4.0f * t1;
        if (d1 >= 0.0f) { float s = sqrt(d1); roots[n++] = (-s2m - s) / 2.0f + shift; roots[n++] = (-s2m + s) / 2.0f + shift; }
        float d2 = s2m * s2m - 4.0f * t2;
        if (d2 >= 0.0f) { float s = sqrt(d2); roots[n++] = (s2m - s) / 2.0f + shift; roots[n++] = (s2m + s) / 2.0f + shift; }
    }

    // Newton 보정 (float 정밀도 보완)
    for (int i = 0; i < n; i++) {
        float x = roots[i];
        for (int k = 0; k < 3; k++) {
            float f  = (((x + b) * x + c) * x + d) * x + e;
            float fp = ((4.0f * x + 3.0f * b) * x + 2.0f * c) * x + d;
            if (fabs(fp) > 1e-12f) x -= f / fp;
        }
        roots[i] = x;
    }
    return n;
}

#define TORUS_R  1.0f
#define TORUS_r  0.35f

static void candTorus(float3 o0, float3 d, thread Cands& c) {
    // 정밀도: 원점을 토러스 중심에 가장 가까운 지점으로 옮겨서 푼다
    float A = dot(d, d);
    float tShift = -dot(o0, d) / A;
    float3 o = o0 + d * tShift;

    float R2 = TORUS_R * TORUS_R;
    float B = 2.0f * dot(o, d);
    float C = dot(o, o) + R2 - TORUS_r * TORUS_r;
    float dxz = d.x * d.x + d.z * d.z;
    float oxz = o.x * o.x + o.z * o.z;
    float odxz = o.x * d.x + o.z * d.z;

    float a4 = A * A;
    float a3 = 2.0f * A * B;
    float a2 = B * B + 2.0f * A * C - 4.0f * R2 * dxz;
    float a1 = 2.0f * B * C - 8.0f * R2 * odxz;
    float a0 = C * C - 4.0f * R2 * oxz;

    float roots[4];
    int n = solveQuartic(a4, a3, a2, a1, a0, roots);
    for (int i = 0; i < n; i++) {
        float t = roots[i];
        float3 p = o + d * t;
        float3 nrm = (dot(p, p) + R2 - TORUS_r * TORUS_r) * p - 2.0f * R2 * float3(p.x, 0.0f, p.z);
        addCand(c, t + tShift, normalize(nrm));
    }
}

// ---- 캡슐: 원기둥 + 양끝 반구 (볼록) ----
static void candCapsule(float3 o, float3 d, thread Cands& c) {
    float a = d.x * d.x + d.z * d.z;
    float b = 2.0f * (o.x * d.x + o.z * d.z);
    float k = o.x * o.x + o.z * o.z - 1.0f;
    if (a > 1e-8f) {
        float disc = b * b - 4.0f * a * k;
        if (disc >= 0.0f) {
            float s = sqrt(disc);
            for (int i = 0; i < 2; i++) {
                float t = (i == 0) ? (-b - s) / (2.0f * a) : (-b + s) / (2.0f * a);
                float3 p = o + d * t;
                if (fabs(p.y) <= 1.0f) addCand(c, t, normalize(float3(p.x, 0, p.z)));
            }
        }
    }
    float A = dot(d, d);
    for (int i = 0; i < 2; i++) {
        float sgn = (i == 0) ? -1.0f : 1.0f;
        float3 center = float3(0, sgn, 0);
        float3 oc = o - center;
        float B = 2.0f * dot(oc, d);
        float K = dot(oc, oc) - 1.0f;
        float disc = B * B - 4.0f * A * K;
        if (disc < 0.0f) continue;
        float s = sqrt(disc);
        for (int j = 0; j < 2; j++) {
            float t = (j == 0) ? (-B - s) / (2.0f * A) : (-B + s) / (2.0f * A);
            float3 p = o + d * t;
            if ((sgn > 0.0f && p.y > 1.0f) || (sgn < 0.0f && p.y < -1.0f))
                addCand(c, t, normalize(p - center));
        }
    }
}

// ---- 볼록 다면체(반공간 교집합) 일반 루틴 ----
static void candPlanes(float3 o, float3 d, constant float3* normals, constant float* offsets, int count,
                       thread Cands& c)
{
    float tIn = -INFINITY, tOut = INFINITY;
    float3 nIn = float3(0), nOut = float3(0);
    for (int i = 0; i < count; i++) {
        float3 n = normals[i];
        float denom = dot(n, d);
        float num = offsets[i] - dot(n, o);
        if (fabs(denom) < 1e-8f) {
            if (num < 0.0f) return;           // 평행 & 바깥
            continue;
        }
        float t = num / denom;
        if (denom < 0.0f) { if (t > tIn)  { tIn = t;  nIn = n; } }
        else              { if (t < tOut) { tOut = t; nOut = n; } }
    }
    if (tIn < tOut) { addCand(c, tIn, nIn); addCand(c, tOut, nOut); }
}

// 버퍼에 저장된 평면(nx,ny,nz,h) 배열 버전 — 임의의 볼록 다면체
static void candPlanes4(float3 o, float3 d, constant float4* planes, int count, thread Cands& c)
{
    float tIn = -INFINITY, tOut = INFINITY;
    float3 nIn = float3(0), nOut = float3(0);
    for (int i = 0; i < count; i++) {
        float3 n = planes[i].xyz;
        float denom = dot(n, d);
        float num = planes[i].w - dot(n, o);
        if (fabs(denom) < 1e-8f) {
            if (num < 0.0f) return;
            continue;
        }
        float t = num / denom;
        if (denom < 0.0f) { if (t > tIn)  { tIn = t;  nIn = n; } }
        else              { if (t < tOut) { tOut = t; nOut = n; } }
    }
    if (tIn < tOut) { addCand(c, tIn, nIn); addCand(c, tOut, nOut); }
}

// 정삼각 프리즘: 단위원 내접 정삼각형(꼭짓점 +x), y ∈ [-1,1]
constant float3 kPrismN[5] = {
    float3(-1.0f, 0.0f, 0.0f),
    float3( 0.5f, 0.0f,  0.8660254f),
    float3( 0.5f, 0.0f, -0.8660254f),
    float3( 0.0f, 1.0f, 0.0f),
    float3( 0.0f,-1.0f, 0.0f),
};
constant float kPrismH[5] = { 0.5f, 0.5f, 0.5f, 1.0f, 1.0f };

static void candPrism(float3 o, float3 d, thread Cands& c) {
    candPlanes(o, d, kPrismN, kPrismH, 5, c);
}

// 정육각기둥 (단위원 내접, 변심거리 cos30°)
constant float3 kHexN[8] = {
    float3( 1.0f, 0, 0), float3( 0.5f, 0,  0.8660254f), float3(-0.5f, 0,  0.8660254f),
    float3(-1.0f, 0, 0), float3(-0.5f, 0, -0.8660254f), float3( 0.5f, 0, -0.8660254f),
    float3(0, 1, 0), float3(0, -1, 0)
};
constant float kHexH[8] = { 0.8660254f, 0.8660254f, 0.8660254f, 0.8660254f, 0.8660254f, 0.8660254f, 1.0f, 1.0f };

// 정팔각기둥 (변심거리 cos22.5°)
constant float3 kOctPN[10] = {
    float3( 1.0f, 0, 0), float3( 0.7071068f, 0,  0.7071068f), float3(0, 0,  1.0f), float3(-0.7071068f, 0,  0.7071068f),
    float3(-1.0f, 0, 0), float3(-0.7071068f, 0, -0.7071068f), float3(0, 0, -1.0f), float3( 0.7071068f, 0, -0.7071068f),
    float3(0, 1, 0), float3(0, -1, 0)
};
constant float kOctPH[10] = { 0.9238795f, 0.9238795f, 0.9238795f, 0.9238795f,
                              0.9238795f, 0.9238795f, 0.9238795f, 0.9238795f, 1.0f, 1.0f };

// 쐐기: 직각삼각형 (-1,-1),(1,-1),(-1,1) in xy, z ∈ [-1,1]
constant float3 kWedgeN[5] = {
    float3(0, -1, 0), float3(-1, 0, 0), float3(0.7071068f, 0.7071068f, 0), float3(0, 0, 1), float3(0, 0, -1)
};
constant float kWedgeH[5] = { 1.0f, 1.0f, 0.0f, 1.0f, 1.0f };

// 정사면체: 꼭짓점 (1,1,1),(1,-1,-1),(-1,1,-1),(-1,-1,1). 면 법선 = -꼭짓점/√3
constant float3 kTetraN[4] = {
    float3(-0.5773503f, -0.5773503f, -0.5773503f), float3(-0.5773503f,  0.5773503f,  0.5773503f),
    float3( 0.5773503f, -0.5773503f,  0.5773503f), float3( 0.5773503f,  0.5773503f, -0.5773503f)
};
constant float kTetraH[4] = { 0.5773503f, 0.5773503f, 0.5773503f, 0.5773503f };

// 정팔면체 |x|+|y|+|z| ≤ 1
constant float3 kOctaN[8] = {
    float3( 0.5773503f,  0.5773503f,  0.5773503f), float3( 0.5773503f,  0.5773503f, -0.5773503f),
    float3( 0.5773503f, -0.5773503f,  0.5773503f), float3( 0.5773503f, -0.5773503f, -0.5773503f),
    float3(-0.5773503f,  0.5773503f,  0.5773503f), float3(-0.5773503f,  0.5773503f, -0.5773503f),
    float3(-0.5773503f, -0.5773503f,  0.5773503f), float3(-0.5773503f, -0.5773503f, -0.5773503f)
};
constant float kOctaH[8] = { 0.5773503f, 0.5773503f, 0.5773503f, 0.5773503f,
                             0.5773503f, 0.5773503f, 0.5773503f, 0.5773503f };

// 사각뿔: 밑면 [-1,1]² (y=-1), 꼭짓점 (0,1,0). 옆면 법선 (±2,1,0)/√5, (0,1,±2)/√5
constant float3 kPyrN[5] = {
    float3(0, -1, 0),
    float3( 0.8944272f, 0.4472136f, 0), float3(-0.8944272f, 0.4472136f, 0),
    float3(0, 0.4472136f,  0.8944272f), float3(0, 0.4472136f, -0.8944272f)
};
constant float kPyrH[5] = { 1.0f, 0.4472136f, 0.4472136f, 0.4472136f, 0.4472136f };

static void candHexPrism(float3 o, float3 d, thread Cands& c) { candPlanes(o, d, kHexN,   kHexH,   8,  c); }
static void candOctPrism(float3 o, float3 d, thread Cands& c) { candPlanes(o, d, kOctPN,  kOctPH,  10, c); }
static void candWedge(float3 o, float3 d, thread Cands& c)    { candPlanes(o, d, kWedgeN, kWedgeH, 5,  c); }
static void candTetra(float3 o, float3 d, thread Cands& c)    { candPlanes(o, d, kTetraN, kTetraH, 4,  c); }
static void candOcta(float3 o, float3 d, thread Cands& c)     { candPlanes(o, d, kOctaN,  kOctaH,  8,  c); }
static void candPyramid(float3 o, float3 d, thread Cands& c)  { candPlanes(o, d, kPyrN,   kPyrH,   5,  c); }

// ---------------------------------------------------------------------------
// 둥근 상자 = 상자 ⊕ 반지름 r 구 (민코프스키 합)
//
// **왜 별도 부품인가**: 세 방향의 둥근 윤곽(평면도·옆모습·단면)을 교차시키면
// 모서리는 둥글어지지만 세 면이 만나는 **꼭짓점이 구면이 아니다** —
// 원기둥 두 개의 교선(Steinmetz 곡선)이라 대각선 능선이 남고 하이라이트가 거기서 끊긴다.
// 진짜 둥근 상자는 꼭짓점이 구면이라 법선이 어디서나 연속이다.
//
// 볼록이므로 구간은 하나. 형상이 **중심대칭**이라 탈출 t 는 방향을 뒤집어 다시 풀면 된다:
// ray(o, -d) 의 진입 s 에 대해 원래 레이의 탈출은 t = -s.
// 진입 풀이는 Inigo Quilez, "Intersectors" (roundedboxIntersect) 를 따랐고,
// **양수 t 필터만 제거**했다 — CSG 는 원점이 안에 있는(=t 가 음수인) 경우도 다뤄야 한다.
// ---------------------------------------------------------------------------

/// 진입 t. 안 맞으면 INFINITY.
static float roundBoxEntry(float3 ro, float3 rd, float3 b, float r) {
    float3 m = 1.0f / rd;
    float3 nn = m * ro;
    float3 k = fabs(m) * (b + r);
    float3 ta = -nn - k, tb = -nn + k;
    float tN = max(max(ta.x, ta.y), ta.z);
    float tF = min(min(tb.x, tb.y), tb.z);
    if (tN > tF) return INFINITY;

    // 세 축 대칭이므로 제1팔분공간으로 접는다 (t 는 보존된다)
    float3 pos = ro + tN * rd;
    float3 sg = float3(pos.x < 0.0f ? -1.0f : 1.0f,
                       pos.y < 0.0f ? -1.0f : 1.0f,
                       pos.z < 0.0f ? -1.0f : 1.0f);
    float3 o = ro * sg, d = rd * sg, p = pos * sg;

    // 한 축만 넘었으면 평평한 면 — 바깥 상자 교차가 곧 답이다
    float3 q = p - b;
    float3 mx = max(q, q.yzx);
    if (min(min(mx.x, mx.y), mx.z) < 0.0f) return tN;

    float3 oc = o - b, dd = d * d, oo = oc * oc, od = oc * d;
    float ra2 = r * r;
    float t = INFINITY;

    // 꼭짓점 구
    {
        float bb = od.x + od.y + od.z;
        float cc = oo.x + oo.y + oo.z - ra2;
        float h = bb * bb - cc;
        if (h > 0.0f) t = -bb - sqrt(h);
    }
    // 모서리 원기둥 3개 (각 축 방향). 축 방향 성분이 안쪽 상자 안에 있어야 유효하다.
    {
        float a = dd.y + dd.z, bb = od.y + od.z, cc = oo.y + oo.z - ra2;
        float h = bb * bb - a * cc;
        if (h > 0.0f && a > 1e-12f) {
            float u = (-bb - sqrt(h)) / a;
            if (u < t && fabs(o.x + u * d.x) < b.x) t = u;
        }
    }
    {
        float a = dd.z + dd.x, bb = od.z + od.x, cc = oo.z + oo.x - ra2;
        float h = bb * bb - a * cc;
        if (h > 0.0f && a > 1e-12f) {
            float u = (-bb - sqrt(h)) / a;
            if (u < t && fabs(o.y + u * d.y) < b.y) t = u;
        }
    }
    {
        float a = dd.x + dd.y, bb = od.x + od.y, cc = oo.x + oo.y - ra2;
        float h = bb * bb - a * cc;
        if (h > 0.0f && a > 1e-12f) {
            float u = (-bb - sqrt(h)) / a;
            if (u < t && fabs(o.z + u * d.z) < b.z) t = u;
        }
    }
    return t;
}

static void candRoundBox(float3 o, float3 d, float3 b, float r, thread Cands& c) {
    float t0 = roundBoxEntry(o,  d, b, r);
    if (isinf(t0)) return;
    float s  = roundBoxEntry(o, -d, b, r);
    if (isinf(s)) return;
    float t1 = -s;
    if (t1 - t0 < 1e-6f) return;

    // 법선은 닫힌 식으로 얻는다: 안쪽 상자에서 가장 가까운 점으로부터의 방향.
    // 면·모서리·꼭짓점 어디서나 같은 식이라 이음매가 없다.
    float3 p0 = o + t0 * d, p1 = o + t1 * d;
    addCand(c, t0, p0 - clamp(p0, -b, b));
    addCand(c, t1, p1 - clamp(p1, -b, b));
}


// ---------------------------------------------------------------------------
// BLOB — 부드럽게 섞이는 타원체 덩어리 (smooth-min SDF + 구 추적)
//
// 불리언 합집합은 두 면의 교선에서 법선이 꺾인다. 기계라면 그 능선이 오히려 맞지만
// **인체에서는 그것이 곧 흉터**다. 여기서는 거리장(SDF)을 부드럽게 섞은 뒤
// 구 추적으로 경계를 찾으므로 이어 붙는 자리가 아예 생기지 않는다.
//
// 값은 두 가지로 치른다:
//   1. 해석적 해가 아니라 반복이다 (원소 수 × 스텝 수). AABB 안에 들어온 레이만 돌므로 감당된다.
//   2. 타원체 SDF 는 근사라 거리 하한이 완벽하지 않다 → 스텝을 0.75 배로 줄여 넘어가지 않게 한다.
// ---------------------------------------------------------------------------

#define BLOB_MAX_ELEMS 48
#define BLOB_MAX_STEPS 160

/// 둥근 원뿔(테이퍼진 캡슐)까지의 **정확한** 거리 (Inigo Quilez).
/// 팔다리는 이걸로 만든다 — 구를 줄줄이 꿰면 간격이 반지름의 1.5배만 넘어도
/// 메타볼 사슬이 **울퉁불퉁한 소시지**가 된다. 마디 하나를 원뿔 하나로 덮으면
/// 길이 방향으로는 애초에 이음매가 생기지 않는다.
static float sdRoundCone(float3 p, float3 a, float3 b, float r1, float r2) {
    float3 ba = b - a;
    float l2 = dot(ba, ba);
    float rr = r1 - r2;
    float a2 = l2 - rr * rr;
    float il2 = 1.0f / max(l2, 1e-9f);
    float3 pa = p - a;
    float y = dot(pa, ba);
    float z = y - l2;
    float3 x = pa * l2 - ba * y;
    float x2 = dot(x, x);
    float y2 = y * y * l2;
    float z2 = z * z * l2;
    float k = sign(rr) * rr * rr * x2;
    if (sign(z) * a2 * z2 > k) return sqrt(x2 + z2) * il2 - r2;
    if (sign(y) * a2 * y2 < k) return sqrt(x2 + y2) * il2 - r1;
    return (sqrt(max(x2 * a2 * il2, 0.0f)) + y * rr) * il2 - r1;
}

/// 2차 베지에 곡선까지의 거리와 매개변수 t (Inigo Quilez). 눈썹·입술선·머리 타래처럼
/// **굽은 튜브**가 필요한 곳에 쓴다. 곧은 원뿔을 이어 붙이면 마디마다 꺾인 각이 남는다.
/// 3차 방정식을 푸므로 타원체보다 몇 배 비싸다 — 얼굴에 몇 개만.
static float2 sdBezier(float3 pos, float3 A, float3 B, float3 C) {
    float3 a = B - A, b = A - 2.0f * B + C, c = a * 2.0f, d = A - pos;
    float bb = dot(b, b);
    if (bb < 1e-7f) {                        // 제어점이 일직선 → 그냥 선분
        float3 ac = C - A;
        float t = clamp(dot(pos - A, ac) / max(dot(ac, ac), 1e-9f), 0.0f, 1.0f);
        return float2(length(pos - (A + ac * t)), t);
    }
    float kk = 1.0f / bb;
    float kx = kk * dot(a, b);
    float ky = kk * (2.0f * dot(a, a) + dot(d, b)) / 3.0f;
    float kz = kk * dot(d, a);
    float2 res;
    float p = ky - kx * kx;
    float p3 = p * p * p;
    float q = kx * (2.0f * kx * kx - 3.0f * ky) + kz;
    float h = q * q + 4.0f * p3;
    if (h >= 0.0f) {
        h = sqrt(h);
        float2 x = (float2(h, -h) - q) / 2.0f;
        float2 uv = sign(x) * pow(abs(x), float2(1.0f / 3.0f));
        float t = clamp(uv.x + uv.y - kx, 0.0f, 1.0f);
        float3 q2 = d + (c + b * t) * t;
        res = float2(dot(q2, q2), t);
    } else {
        float z = sqrt(-p);
        float v = acos(q / (p * z * 2.0f)) / 3.0f;
        float m = cos(v), n = sin(v) * 1.732050808f;
        float3 t3 = clamp(float3(m + m, -n - m, n - m) * z - kx, 0.0f, 1.0f);
        float3 q1 = d + (c + b * t3.x) * t3.x; float d1 = dot(q1, q1);
        float3 q2 = d + (c + b * t3.y) * t3.y; float d2 = dot(q2, q2);
        res = (d1 < d2) ? float2(d1, t3.x) : float2(d2, t3.y);
    }
    res.x = sqrt(res.x);
    return res;
}

/// 쿼터니언 q 의 역회전을 p 에 적용 (원소 로컬 공간으로)
static inline float3 quatUnrotate(float4 q, float3 p) {
    float3 u = -q.xyz;                       // 켤레
    return p + 2.0f * cross(u, cross(u, p) + q.w * p);
}

/// 타원체까지의 근사 거리 (Inigo Quilez). 정확한 거리는 6차 방정식이라 쓸 수 없다.
static inline float sdEllipsoid(float3 p, float3 r) {
    float k0 = length(p / r);
    float k1 = length(p / (r * r));
    return k0 * (k0 - 1.0f) / max(k1, 1e-8f);
}

/// 다항 smooth-min. k 가 섞이는 반경이다 (0 이면 평범한 min = 날카로운 능선).
static inline float sminPoly(float a, float b, float k) {
    float h = clamp(0.5f + 0.5f * (b - a) / max(k, 1e-5f), 0.0f, 1.0f);
    return mix(b, a, h) - k * h * (1.0f - h);
}
static inline float smaxPoly(float a, float b, float k) {
    float h = clamp(0.5f - 0.5f * (b - a) / max(k, 1e-5f), 0.0f, 1.0f);
    return mix(b, a, h) + k * h * (1.0f - h);
}

// 원소 하나당 float4 네 개:
//   A = (p0, r0)  B = (p1 | (ry, rz, 0), r1)  C = (blend, sign, type, -)
//   D = 타원체: 회전 쿼터니언 (x,y,z,w) / 베지에: 세 번째 제어점 p2
#define BLOB_STRIDE 4

static float blobSDF(float3 p, constant float4* D, int n, float inflate) {
    float d = 1e9f;
    for (int i = 0; i < n; i++) {
        float4 A = D[2 + BLOB_STRIDE * i];
        float4 B = D[3 + BLOB_STRIDE * i];
        float4 C = D[4 + BLOB_STRIDE * i];
        float4 E = D[5 + BLOB_STRIDE * i];
        float e;
        if (C.z > 1.5f) {                                  // 2 = 베지에 튜브 (p0 → p2 제어 → p1)
            float2 bt = sdBezier(p, A.xyz, E.xyz, B.xyz);
            e = bt.x - mix(A.w, B.w, bt.y);
        } else if (C.z > 0.5f) {                           // 1 = 둥근 원뿔
            e = sdRoundCone(p, A.xyz, B.xyz, A.w, B.w);
        } else {                                           // 0 = 타원체 (회전 가능)
            float3 q = p - A.xyz;
            if (E.w < 0.9999f) q = quatUnrotate(E, q);     // 항등 쿼터니언(w=1)이면 건너뛴다
            e = sdEllipsoid(q, float3(A.w, B.x, B.y));
        }
        if (C.y < 0.0f) d = smaxPoly(d, -e, C.x);   // 음의 원소 — 파낸다
        else            d = sminPoly(d, e, C.x);
    }
    return d - inflate;
}

/// 사면체 차분 법선. 교차점에서만 부르므로 4번 평가해도 부담이 적다.
static float3 blobNormal(float3 p, constant float4* D, int n, float inflate) {
    const float h = 0.0015f;
    const float2 k = float2(1.0f, -1.0f);
    return normalize(k.xyy * blobSDF(p + k.xyy * h, D, n, inflate) +
                     k.yyx * blobSDF(p + k.yyx * h, D, n, inflate) +
                     k.yxy * blobSDF(p + k.yxy * h, D, n, inflate) +
                     k.xxx * blobSDF(p + k.xxx * h, D, n, inflate));
}

/// 경계구 안을 행진하며 **부호가 바뀌는 곳마다** 이분법으로 교차점을 조인다.
/// 진입·탈출이 번갈아 나오므로 `convex = false` 경로가 쌍으로 묶어 준다.
///
/// 순수한 구 추적(스텝 = 거리)만 쓰면 실루엣을 스치는 레이가 거리장이 작은 채로 기어가다
/// 스텝을 다 쓰고 빗나가서, 팔다리 가장자리가 **물어뜯긴 것처럼** 우글거린다.
/// 그렇다고 최소 스텝을 키우면 표면을 통째로 뛰어넘어 **안쪽에 착지**하고,
/// 거기서 교차를 기록해 형상이 부풀고 시커멓게 된다 (둘 다 실제로 겪었다).
///
/// 그래서 둘을 나눈다: **전진은 최소 스텝으로 보장하고, 정확도는 이분법이 책임진다.**
/// 스텝 크기는 이제 "얇은 것을 통째로 건너뛰는가"만 결정하므로 넉넉히 키워도 안전하다.
static void candBlob(float3 o, float3 d, constant float4* D, thread Cands& c) {
    int n = min((int)D[1].x, BLOB_MAX_ELEMS);
    float inflate = D[1].y;
    float R = D[0].w + inflate;
    if (n <= 0) return;

    // 구 추적은 **정규화된 방향**이어야 스텝이 거리와 같은 단위가 된다.
    // 로컬 공간의 d 는 정규화돼 있지 않으므로 여기서 나누고, 마지막에 다시 나눠 t 로 되돌린다.
    float len = length(d);
    if (len < 1e-9f) return;
    float3 dn = d / len;

    float b = dot(o, dn);
    float cc = dot(o, o) - R * R;
    float disc = b * b - cc;
    if (disc <= 0.0f) return;
    float sq = sqrt(disc);
    float u = -b - sq, uMax = -b + sq;      // 경계구 안 구간 (원점이 안이면 u 는 음수)

    // 스텝 수 × 최소 스텝 > 구간 길이 여야 실루엣에서 중도 포기하지 않는다
    float minStep = max(0.0025f, (uMax - u) * 0.0075f);   // 160 스텝 × 0.0075 > 구간 길이
    float sPrev = blobSDF(o + dn * u, D, n, inflate);

    for (int i = 0; i < BLOB_MAX_STEPS && u < uMax && c.n < MAX_CANDS; i++) {
        float step = max(fabs(sPrev) * 0.8f, minStep);
        float u2 = min(u + step, uMax);
        float s2 = blobSDF(o + dn * u2, D, n, inflate);

        if ((s2 < 0.0f) != (sPrev < 0.0f)) {
            // 부호가 바뀌었다 — 이분법으로 조인다. 10회면 구간이 1/1024 로 줄어든다
            float a = u, bb = u2;
            bool aIn = sPrev < 0.0f;
            for (int k = 0; k < 14; k++) {
                float mid = 0.5f * (a + bb);
                float sm = blobSDF(o + dn * mid, D, n, inflate);
                if ((sm < 0.0f) != aIn) bb = mid; else a = mid;
            }
            float uc = 0.5f * (a + bb);
            addCand(c, uc / len, blobNormal(o + dn * uc, D, n, inflate));
        }
        u = u2;
        sPrev = s2;
    }
    // 홀수로 끝나면(스텝 소진) 짝이 안 맞으므로 마지막 하나를 버린다
    if ((c.n & 1) != 0) c.n--;
}

// 후보들을 정렬해 구간으로 만든다 (볼록: 1개, 토러스: 최대 2개).
static void partIntervals(constant CSGNode& node, float3 o, float3 d, uint material,
                          constant float4* partData, thread IntervalList& L)
{
    L.count = 0;

    // 오브젝트 공간 → 부품 로컬 공간
    float4x4 M = node.worldToLocal;
    float3 lo = (M * float4(o, 1.0f)).xyz;
    float3 ld = (M * float4(d, 0.0f)).xyz;
    ld.x = fabs(ld.x) < 1e-7f ? 1e-7f : ld.x;
    ld.y = fabs(ld.y) < 1e-7f ? 1e-7f : ld.y;
    ld.z = fabs(ld.z) < 1e-7f ? 1e-7f : ld.z;

    bool convex = true;
    Cands c; c.n = 0;
    switch (node.type) {
        case CSG_PART_SPHERE:   candSphere(lo, ld, c);   break;
        case CSG_PART_BOX:      candBox(lo, ld, c);      break;
        case CSG_PART_CYLINDER: candCylinder(lo, ld, c); break;
        case CSG_PART_CONE:     candCone(lo, ld, c);     break;
        case CSG_PART_TORUS:    candTorus(lo, ld, c); convex = false; break;
        case CSG_PART_CAPSULE:  candCapsule(lo, ld, c);  break;
        case CSG_PART_PRISM:    candPrism(lo, ld, c);    break;
        case CSG_PART_HEX_PRISM:  candHexPrism(lo, ld, c);   break;
        case CSG_PART_OCT_PRISM:  candOctPrism(lo, ld, c);   break;
        case CSG_PART_WEDGE:      candWedge(lo, ld, c);      break;
        case CSG_PART_TETRA:      candTetra(lo, ld, c);      break;
        case CSG_PART_OCTA:       candOcta(lo, ld, c);       break;
        case CSG_PART_PYRAMID:    candPyramid(lo, ld, c);    break;
        case CSG_PART_FRUSTUM:    candFrustum(lo, ld, c);    break;
        case CSG_PART_HEMISPHERE: candHemisphere(lo, ld, c); break;
        case CSG_PART_RING:       candRing(lo, ld, c); convex = false; break;
        case CSG_PART_POLY:       candPlanes4(lo, ld, partData + node.reserved0, (int)node.reserved1, c); break;
        case CSG_PART_ROUND_BOX: {
            float4 br = partData[node.reserved0];
            candRoundBox(lo, ld, br.xyz, br.w, c);
            break;
        }
        case CSG_PART_BLOB:
            candBlob(lo, ld, partData + node.reserved0, c);
            convex = false;
            break;
        case CSG_PART_FRUSTUM_GENERIC: {
            float4 ab = partData[node.reserved0];
            candConeGeneric(lo, ld, ab.x, ab.y, c);
            break;
        }
        default: return;
    }
    if (c.n < 2) return;

    // 삽입 정렬
    for (int i = 1; i < c.n; i++) {
        Hit key = c.h[i];
        int j = i - 1;
        while (j >= 0 && c.h[j].t > key.t) { c.h[j + 1] = c.h[j]; j--; }
        c.h[j + 1] = key;
    }

    // 법선을 오브젝트 공간으로 (worldToLocal의 전치)
    float3x3 nm = transpose(float3x3(M[0].xyz, M[1].xyz, M[2].xyz));

    if (convex) {
        Hit first = c.h[0];
        Hit last  = c.h[c.n - 1];
        if (last.t - first.t < 1e-6f) return;
        Interval iv;
        iv.tIn = first.t;  iv.nIn  = normalize(nm * float3(first.n));
        iv.tOut = last.t;  iv.nOut = normalize(nm * float3(last.n));
        iv.mIn = (ushort)material; iv.mOut = (ushort)material;
        pushInterval(L, iv);
    } else {
        // 비볼록(토러스): 정렬된 후보를 (진입, 탈출) 쌍으로 묶는다
        for (int i = 0; i + 1 < c.n; i += 2) {
            Hit a = c.h[i], b = c.h[i + 1];
            if (b.t - a.t < 1e-6f) continue;
            Interval iv;
            iv.tIn = a.t;  iv.nIn  = normalize(nm * float3(a.n));
            iv.tOut = b.t; iv.nOut = normalize(nm * float3(b.n));
            iv.mIn = (ushort)material; iv.mOut = (ushort)material;
            pushInterval(L, iv);
        }
    }
}

// ---------------------------------------------------------------------------
// 구간 불리언 연산 (입력은 정렬된 비중첩 구간 리스트)
// ---------------------------------------------------------------------------

static void opUnion(thread const IntervalList& A, thread const IntervalList& B,
                    thread IntervalList& R)
{
    R.count = 0;
    int i = 0, j = 0;
    Interval cur;
    bool has = false;
    while (i < A.count || j < B.count) {
        Interval nxt;
        bool takeA = (j >= B.count) || (i < A.count && A.iv[i].tIn < B.iv[j].tIn);
        if (takeA) nxt = A.iv[i++]; else nxt = B.iv[j++];

        if (!has) { cur = nxt; has = true; }
        else if (nxt.tIn <= cur.tOut) {
            if (nxt.tOut > cur.tOut) { cur.tOut = nxt.tOut; cur.nOut = nxt.nOut; cur.mOut = nxt.mOut; }
        } else {
            pushInterval(R, cur);
            cur = nxt;
        }
    }
    if (has) pushInterval(R, cur);
}

static void opIntersect(thread const IntervalList& A, thread const IntervalList& B,
                        thread IntervalList& R)
{
    R.count = 0;
    for (int i = 0; i < A.count; i++) {
        for (int j = 0; j < B.count; j++) {
            Interval a = A.iv[i], b = B.iv[j];
            Interval r;
            if (a.tIn > b.tIn) { r.tIn = a.tIn; r.nIn = a.nIn; r.mIn = a.mIn; }
            else               { r.tIn = b.tIn; r.nIn = b.nIn; r.mIn = b.mIn; }
            if (a.tOut < b.tOut) { r.tOut = a.tOut; r.nOut = a.nOut; r.mOut = a.mOut; }
            else                 { r.tOut = b.tOut; r.nOut = b.nOut; r.mOut = b.mOut; }
            if (r.tIn < r.tOut) pushInterval(R, r);
        }
    }
}

// A - B : 깎인 면은 A의 재질을 유지하고, 법선은 B의 법선을 뒤집어 사용
// R 은 A/B 와 겹치면 안 된다 (호출부에서 별도 슬롯을 넘긴다).
// 결과를 R 에 바로 누적해서 `cur` 사본 하나(IntervalList 통째)를 아낀다.
static void opSubtract(thread const IntervalList& A, thread const IntervalList& B,
                       thread IntervalList& R)
{
    R = A;
    for (int j = 0; j < B.count; j++) {
        Interval b = B.iv[j];
        IntervalList nxt; nxt.count = 0;
        for (int i = 0; i < R.count; i++) {
            Interval a = R.iv[i];
            if (b.tOut <= a.tIn || b.tIn >= a.tOut) {      // 겹치지 않음
                pushInterval(nxt, a);
                continue;
            }
            // 잘린 면은 **자르는 쪽(B)의 재질**을 쓴다. 노멀도 B 의 것을 뒤집어 쓰므로
            // 재질만 A 에서 가져오면 앞뒤가 안 맞는다. 컷어웨이 모형이 단면을 다른 색으로
            // 칠하는 것을 이걸로 공짜로 얻는다 — 메시였다면 단면을 손으로 막아야 한다.
            if (a.tIn < b.tIn) {                            // 앞쪽 조각
                Interval r = a;
                r.tOut = b.tIn; r.nOut = -float3(b.nIn); r.mOut = b.mIn;
                pushInterval(nxt, r);
            }
            if (b.tOut < a.tOut) {                          // 뒤쪽 조각
                Interval r = a;
                r.tIn = b.tOut; r.nIn = -float3(b.nOut); r.mIn = b.mOut;
                pushInterval(nxt, r);
            }
        }
        R = nxt;
    }
}

// ---------------------------------------------------------------------------
// CSG 트리(후위 표기) 평가: 스택 머신
// ---------------------------------------------------------------------------

static bool evalCSG(constant CSGNode* nodes, uint count, float3 o, float3 d,
                    constant float4* partData, thread IntervalList& result)
{
    IntervalList stack[MAX_STACK];
    int sp = 0;

    // 스택 슬롯에 직접 쓰고, 연산 결과는 `result` 를 임시 슬롯으로 재사용한다.
    // 예전처럼 A/B/R 사본을 따로 두면 IntervalList 3개(≈660B)를 스레드 스택에서 더 먹는다.
    for (uint n = 0; n < count; n++) {
        constant CSGNode& node = nodes[n];
        if (node.type < 100) {
            if (sp >= MAX_STACK) continue;           // Renderer 가 미리 검증하므로 정상 씬에선 안 걸린다
            partIntervals(node, o, d, node.material, partData, stack[sp]);
            sp++;
        } else {
            if (sp < 2) continue;
            result.count = 0;
            switch (node.type) {
                case CSG_OP_UNION:     opUnion(stack[sp - 2], stack[sp - 1], result);     break;
                case CSG_OP_INTERSECT: opIntersect(stack[sp - 2], stack[sp - 1], result); break;
                case CSG_OP_SUBTRACT:  opSubtract(stack[sp - 2], stack[sp - 1], result);  break;
            }
            sp--;
            stack[sp - 1] = result;
        }
    }
    if (sp == 0) return false;
    result = stack[0];
    return result.count > 0;
}

// ---------------------------------------------------------------------------
// Intersection function: 오브젝트 하나(AABB 1개) 전체가 CSG 트리 하나
// 레이 origin/direction은 Metal이 이미 인스턴스(오브젝트) 공간으로 변환해서 넘겨준다.
// ---------------------------------------------------------------------------

struct BBoxResult {
    bool  accept   [[accept_intersection]];
    float distance [[distance]];
};

[[intersection(bounding_box, instancing)]]
BBoxResult csgIntersection(float3 origin              [[origin]],
                           float3 direction           [[direction]],
                           float  minDist             [[min_distance]],
                           float  maxDist             [[max_distance]],
                           uint   instanceId          [[instance_id]],
                           ray_data CSGPayload& payload [[payload]],
                           constant CSGNode*   nodes         [[buffer(0)]],
                           constant CSGObject* objects       [[buffer(1)]],
                           constant uint*      instanceObject[[buffer(2)]],
                           constant float4*    partData      [[buffer(3)]])
{
    BBoxResult res;
    res.accept = false;
    res.distance = maxDist;

    CSGObject obj = objects[instanceObject[instanceId]];

    IntervalList L;
    if (!evalCSG(nodes + obj.nodeOffset, obj.nodeCount, origin, direction, partData, L)) return res;

    // minDist 이후 첫 경계 찾기
    for (int i = 0; i < L.count; i++) {
        Interval iv = L.iv[i];
        if (iv.tIn > minDist) {
            if (iv.tIn < maxDist) {
                res.accept = true; res.distance = iv.tIn;
                payload.normal = float3(iv.nIn); payload.material = iv.mIn;
            }
            return res;
        }
        if (iv.tOut > minDist) {          // 레이 원점이 솔리드 내부
            if (iv.tOut < maxDist) {
                res.accept = true; res.distance = iv.tOut;
                payload.normal = float3(iv.nOut); payload.material = iv.mOut;
            }
            return res;
        }
    }
    return res;
}

// ---------------------------------------------------------------------------
// 렌더 커널: 확산 / 거울 / 유리 재질, 반복(iterative) 바운스
// ---------------------------------------------------------------------------

#define MAX_BOUNCES 6

struct SurfaceHit {
    bool   valid;
    float  t;
    float3 pos;
    float3 n;          // 레이를 향하도록 뒤집은 법선
    bool   frontFace;  // 바깥→안 으로 들어가는 중인지
    uint   material;
};

// ---------------------------------------------------------------------------
// 환경광
// ---------------------------------------------------------------------------

constant float3 kSunColor = float3(1.00f, 0.955f, 0.87f);

/// 소프트박스 하나 — 방향 n 을 중심으로 한 각도 반경 `halfAngle` 의 부드러운 광원.
static float softbox(float3 d, float3 n, float halfAngle, float feather) {
    float a = acos(clamp(dot(d, n), -1.0f, 1.0f));
    return 1.0f - smoothstep(halfAngle - feather, halfAngle + feather, a);
}

/// 스튜디오 환경 — 어두운 배경에 큰 소프트박스 몇 개.
/// 금속·유리가 이걸 비추면서 **밝은 띠와 또렷한 경계**가 생겨야 비로소 금속으로 보인다.
/// 제품 사진이 실제로 이렇게 찍는다.
static float3 studioEnv(float3 dir) {
    float t = clamp(dir.y * 0.5f + 0.5f, 0.0f, 1.0f);
    // 배경을 완전히 까맣게 두면 **거울면의 절반이 새까맣게 죽는다.**
    // 실제 제품 촬영도 큰 필 패널로 어두운 쪽을 받쳐 준다.
    float3 c = mix(float3(0.055f, 0.058f, 0.068f), float3(0.22f, 0.23f, 0.25f), t);
    // 키 라이트 — 넓은 오버헤드 소프트박스
    c += softbox(dir, normalize(float3( 0.22f, 1.00f,  0.10f)), 0.72f, 0.26f) * float3(2.9f, 2.9f, 2.85f);
    // 좁고 밝은 하이라이트 두 개 — 금속에 또렷한 띠를 만든다
    c += softbox(dir, normalize(float3(-0.88f, 0.50f,  0.18f)), 0.24f, 0.08f) * float3(2.6f, 2.6f, 2.8f);
    c += softbox(dir, normalize(float3( 0.45f, 0.30f, -0.84f)), 0.20f, 0.07f) * float3(2.0f, 2.0f, 2.2f);
    return c;
}

/// 하늘 + 태양 + 지평선 아래 노면 톤.
/// **광택 재질이 이걸 반사한다** — 단색 그라데이션이면 반사에 아무 구조가 없어서
/// 금속·도장이 여전히 밋밋해 보인다. 태양 원반과 지평선 밝기 차이가 형태를 만든다.
/// 흰 사이클로라마 — 제품 사진. 배경은 어디를 봐도 노출 과다의 흰색이고,
/// 그 위에 큰 소프트박스가 몇 개 더 밝게 떠 있어 금속에 **부드러운 그라데이션**이 생긴다.
/// 배경 자체가 이미 밝으므로 소프트박스는 배경보다 살짝만 밝아도 반사에서 읽힌다.
static float3 whiteCycEnv(float3 dir) {
    float3 c = float3(2.3f);
    c += softbox(dir, normalize(float3( 0.10f, 1.00f,  0.35f)), 0.80f, 0.35f) * float3(1.6f);   // 큰 오버헤드
    c += softbox(dir, normalize(float3(-0.85f, 0.35f,  0.40f)), 0.45f, 0.20f) * float3(1.4f);   // 왼쪽 사이드
    c += softbox(dir, normalize(float3( 0.80f, 0.25f, -0.55f)), 0.30f, 0.12f) * float3(1.2f);   // 오른쪽 뒤
    // 지평선 아래는 약간 어둡게 — 금속 아랫면에 톤 차이가 있어야 입체가 산다
    // 아래 반구는 확실히 어둡게 — 금속 아랫면과 윗면의 톤 차이가 없으면 금이 흰 플라스틱이 된다
    // 지평선 위는 전부 흰색이어야 화면 위쪽에 회색 띠가 안 생긴다. 어두워지는 건 확실히 아래쪽만
    c *= mix(0.42f, 1.0f, clamp(dir.y * 4.0f + 1.0f, 0.0f, 1.0f));
    return c;
}

/// 밝은 스튜디오 — 전시장. 배경이 중간 회색이라 금속 반사가 회색으로 죽지 않고,
/// 소프트박스가 더 크고 많아 캔디 도장에 반사가 흐른다.
static float3 brightStudioEnv(float3 dir) {
    float t = clamp(dir.y * 0.5f + 0.5f, 0.0f, 1.0f);
    float3 c = mix(float3(0.16f, 0.165f, 0.18f), float3(0.48f, 0.50f, 0.55f), t);
    c += softbox(dir, normalize(float3( 0.20f, 1.00f,  0.30f)), 0.80f, 0.30f) * float3(2.6f, 2.6f, 2.5f);
    c += softbox(dir, normalize(float3(-0.90f, 0.35f,  0.30f)), 0.40f, 0.15f) * float3(2.2f, 2.2f, 2.4f);
    c += softbox(dir, normalize(float3( 0.85f, 0.30f, -0.40f)), 0.35f, 0.12f) * float3(1.8f, 1.9f, 2.2f);
    c += softbox(dir, normalize(float3( 0.00f, 0.20f,  1.00f)), 0.55f, 0.25f) * float3(1.2f, 1.2f, 1.25f); // 카메라 쪽 필
    return c;
}

static float3 skyColor(float3 dir, float3 sunDir, uint envMode) {
    if (envMode == 1) return studioEnv(dir);
    if (envMode == 2) return whiteCycEnv(dir);
    if (envMode == 3) return brightStudioEnv(dir);
    const float3 zenith  = float3(0.09f, 0.26f, 0.72f);
    const float3 horizon = float3(0.50f, 0.62f, 0.82f);
    const float3 ground  = float3(0.11f, 0.11f, 0.12f);

    float3 c = (dir.y >= 0.0f)
             ? mix(horizon, zenith, pow(dir.y, 0.55f))
             : mix(horizon, ground, clamp(-dir.y * 5.0f, 0.0f, 1.0f));

    float s = max(dot(dir, sunDir), 0.0f);
    c += kSunColor * pow(s, 1500.0f) * 9.0f;     // 태양 원반
    c += kSunColor * pow(s, 24.0f) * 0.16f;      // 주변 글로우
    return c;
}

/// 반구 앰비언트 — 위는 하늘색, 아래는 노면 반사색.
/// 상수 앰비언트(예전의 0.18)로 두면 그림자 쪽이 죽은 회색이 된다.
static float3 ambientLight(float3 n, uint envMode) {
    float t = clamp(n.y * 0.5f + 0.5f, 0.0f, 1.0f);
    if (envMode == 1) {
        // 스튜디오는 배경이 어둡다 — 앰비언트도 낮아야 소프트박스 하이라이트가 산다
        return mix(float3(0.050f, 0.052f, 0.058f), float3(0.19f, 0.196f, 0.21f), t);
    }
    if (envMode == 2) {
        // 사이클로라마는 사방이 흰 반사판이라 앰비언트가 높다. 흰 탁자가 배경만큼 희어야 이음매가 사라진다
        return mix(float3(0.95f), float3(1.35f), t);
    }
    if (envMode == 3) {
        return mix(float3(0.14f, 0.145f, 0.16f), float3(0.42f, 0.44f, 0.48f), t);
    }
    return mix(float3(0.075f, 0.075f, 0.085f), float3(0.20f, 0.26f, 0.36f), t);
}

// 값 노이즈 — 노면 골재 얼룩용
static float hash21(float2 p) {
    p = fract(p * float2(123.34f, 456.21f));
    p += dot(p, p + 45.32f);
    return fract(p.x * p.y);
}
static float valueNoise(float2 q) {
    float2 i = floor(q), f = fract(q);
    f = f * f * (3.0f - 2.0f * f);
    float a = hash21(i),                 b = hash21(i + float2(1.0f, 0.0f));
    float c = hash21(i + float2(0.0f, 1.0f)), d = hash21(i + float2(1.0f, 1.0f));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

/// 클리어코트 프레넬. F0 = 0.04 (유전체), 스치는 각도에서 1 로 간다.
static float coatFresnel(float cosV, float gloss) {
    float x = 1.0f - clamp(cosV, 0.0f, 1.0f);
    float x2 = x * x;
    return (0.04f + 0.96f * x2 * x2 * x) * gloss;
}

static SurfaceHit traceScene(ray r,
                             instance_acceleration_structure accel,
                             intersection_function_table<instancing> funcTable,
                             constant InstanceData* instances)
{
    SurfaceHit h;
    h.valid = false;
    CSGPayload payload;
    payload.normal = float3(0, 1, 0);
    payload.material = 0;

    intersector<instancing> isect;
    isect.accept_any_intersection(false);
    intersection_result<instancing> res = isect.intersect(r, accel, funcTable, payload);
    if (res.type == intersection_type::none) return h;

    float4x4 nmat = instances[res.instance_id].normalMatrix;
    float3 n = normalize((nmat * float4(payload.normal, 0.0f)).xyz);
    h.frontFace = dot(n, r.direction) < 0.0f;
    h.n = h.frontFace ? n : -n;
    h.t = res.distance;
    h.pos = r.origin + r.direction * res.distance;
    h.material = payload.material;
    h.valid = true;
    return h;
}

// 그림자: 유리는 빛을 조금 통과시킨다
static float shadowRay(float3 pos, float3 n, float3 lightDir,
                       instance_acceleration_structure accel,
                       intersection_function_table<instancing> funcTable,
                       constant Material* materials);

/// 면광원 소프트 섀도 — `softness` 가 0 이면 그림자 레이 하나, 아니면 광원 원반 위 8점.
/// 점 배치는 픽셀 위치 해시로 돌려서 띠 무늬 대신 미세한 잡음이 되게 한다.
static float shadowFactor(float3 pos, float3 n, float3 lightDir, float softness,
                          instance_acceleration_structure accel,
                          intersection_function_table<instancing> funcTable,
                          constant Material* materials)
{
    if (softness <= 0.0f) return shadowRay(pos, n, lightDir, accel, funcTable, materials);
    float3 t = normalize(cross(lightDir, fabs(lightDir.y) < 0.9f ? float3(0, 1, 0) : float3(1, 0, 0)));
    float3 b = cross(lightDir, t);
    float rot = fract(sin(dot(pos, float3(12.9898f, 78.233f, 37.719f))) * 43758.5453f) * 6.2831853f;
    float sum = 0.0f;
    for (int i = 0; i < 8; i++) {
        float a = rot + float(i) * 2.399963f;                 // 황금각 — 8점이 고르게 퍼진다
        float rad = softness * sqrt((float(i) + 0.5f) / 8.0f);
        float3 d = normalize(lightDir + (t * cos(a) + b * sin(a)) * rad);
        sum += shadowRay(pos, n, d, accel, funcTable, materials);
    }
    return sum / 8.0f;
}

static float shadowRay(float3 pos, float3 n, float3 lightDir,
                       instance_acceleration_structure accel,
                       intersection_function_table<instancing> funcTable,
                       constant Material* materials)
{
    ray sr;
    // 오프셋을 넉넉히 준다. BLOB 은 해석적 부품과 달리 표면 위치가 **수치적**이라
    // 스치는 각도에서 교차점이 제 표면 안쪽으로 미세하게 들어간다. 그러면 그림자 레이가
    // 자기 자신을 맞아 실루엣을 따라 **검은 띠**가 생긴다 (팔다리 가장자리가 그랬다).
    sr.origin = pos + n * 0.014f;
    sr.direction = lightDir;
    sr.min_distance = 0.008f;
    sr.max_distance = INFINITY;
    CSGPayload sp;
    sp.material = 0;
    intersector<instancing> si;
    si.accept_any_intersection(true);
    intersection_result<instancing> sh = si.intersect(sr, accel, funcTable, sp);
    if (sh.type == intersection_type::none) return 1.0f;
    return (materials[sp.material].type == MATERIAL_GLASS) ? 0.55f : 0.0f;
}

/// 확산 + 반구 앰비언트 + 클리어코트 하이라이트.
/// `viewDir` 는 표면을 향해 들어오는 레이 방향.
static float3 shadeSurface(SurfaceHit h, float3 viewDir, constant Uniforms& u,
                           instance_acceleration_structure accel,
                           intersection_function_table<instancing> funcTable,
                           constant Material* materials)
{
    constant Material& mat = materials[h.material];

    // 머리카락: 가닥 방향 T = 표면을 따라 아래로. 가닥에 **수직** 방향으로 고주파,
    // 가닥 **방향**으로 저주파인 노이즈로 법선을 흔들면 세로 결이 생긴다.
    float3 hairT = float3(0.0f);
    if (mat.type == MATERIAL_HAIR) {
        float3 down = float3(0.0f, -1.0f, 0.0f);
        hairT = down - h.n * dot(down, h.n);
        float lt = length(hairT);
        hairT = (lt > 1e-4f) ? hairT / lt : float3(1.0f, 0.0f, 0.0f);
        float3 bn = normalize(cross(h.n, hairT));
        float across = dot(h.pos, bn) * 34.0f, along = dot(h.pos, hairT) * 2.2f;
        float w = valueNoise(float2(across, along)) * 0.62f
                + valueNoise(float2(across * 2.7f, along * 1.9f)) * 0.38f - 0.5f;
        h.n = normalize(h.n + bn * w * 0.9f);
    }

    float rawNdL = dot(h.n, u.lightDir);
    float shadow = shadowFactor(h.pos, h.n, u.lightDir, u.shadowSoftness, accel, funcTable, materials);
    float ndotl = max(rawNdL, 0.0f);

    // 빛을 등진 면은 **반드시** 자기 자신에 가려지므로 그림자 레이가 0 을 돌려준다.
    // 보통은 n·l 도 같이 0 이라 티가 안 나지만, 아래의 감싸는 확산(SSS)은 그 너머까지
    // 빛을 끌고 가기 때문에 **그림자가 그 부드러운 경계를 도로 칼같이 잘라 버린다**
    // (팔다리 실루엣을 따라 검은 띠가 생겼다).
    // 그래서 빛을 향할수록 그림자 판정을 신뢰하고, 등질수록 1 로 보낸다.
    if (mat.sss > 0.001f) {
        shadow = mix(1.0f, shadow, clamp(rawNdL / 0.22f, 0.0f, 1.0f));
    }

    float3 albedo = mat.color;
    if (mat.grain > 0.0f) {
        // 최고 주파수를 40배까지 올리면 픽셀보다 촘촘해져서 에일리어싱이 된다.
        // 특히 **광택 있는 평면(램프 렌즈 등)이 노면을 비출 때** 반짝이 얼룩으로 증폭된다.
        float n = valueNoise(h.pos.xz * 1.5f) * 0.58f
                + valueNoise(h.pos.xz * 6.0f) * 0.30f
                + valueNoise(h.pos.xz * 16.0f) * 0.12f;
        albedo *= (1.0f - mat.grain) + mat.grain * (0.45f + 1.15f * n);
    }

    float3 sun = kSunColor * 1.15f;

    // 표면하 산란 근사 (피부).
    //
    // 사람 피부에서 가장 어색해 보이는 지점은 **명암 경계가 칼같이 끊기는 것**이다.
    // 실제로는 빛이 표면 아래로 몇 mm 들어갔다 나오면서 경계를 넘어 번지고,
    // 그 과정에서 짧은 파장이 먼저 흡수돼 **경계에 붉은 띠**가 남는다.
    // 여기서는 두 가지로 흉내낸다:
    //   1. 감싸는 확산(wrap) — n·l 을 -w 까지 늘려 경계를 부드럽게 편다
    //   2. 붉은 띠 — 경계 근처에서만 붉은 빛을 더한다
    // 물리적으로 옳은 확산 근사는 아니지만, 이거 하나로 석고상이 피부가 된다.
    float ndl = ndotl;
    float3 scatter = float3(0.0f);
    if (mat.sss > 0.001f) {
        float w = mat.sss * 0.75f;
        float raw = rawNdL;
        ndl = clamp((raw + w) / (1.0f + w), 0.0f, 1.0f);
        float band = clamp(1.0f - fabs(raw) / max(w, 1e-3f), 0.0f, 1.0f);
        scatter = albedo * float3(0.62f, 0.17f, 0.11f) * (band * band * mat.sss * 0.9f)
                * shadow;
    }

    float3 color = albedo * (ambientLight(h.n, u.envMode) + sun * ndl * shadow)
                 + sun * scatter;

    // 카메라 쪽 필 라이트 (사진가의 반사판). 피부에만 —
    // 키 라이트 하나로는 그늘 쪽 얼굴이 죽는다. 사람 사진은 언제나 필이 있다.
    if (mat.sss > 0.001f) {
        float facing = max(dot(h.n, -viewDir), 0.0f);
        color += albedo * float3(0.95f, 0.92f, 0.90f) * facing * (0.22f * mat.sss);
    }

    // 머리카락 하이라이트 (Kajiya-Kay): 가닥은 원기둥이라 하이라이트가 **가닥에 수직인 띠**로 흐른다.
    // 두 개의 로브 — 좁고 밝은 것 + 넓고 색 있는 것 — 이 실제 머리카락의 "윤기 띠"다.
    if (mat.type == MATERIAL_HAIR) {
        float3 hv = normalize(u.lightDir - viewDir);
        float th = dot(hairT, hv);
        float sinTH = sqrt(max(1.0f - th * th, 0.0f));
        float spec1 = pow(sinTH, 140.0f) * 0.55f;                 // 좁은 흰 띠
        float spec2 = pow(sinTH, 18.0f) * 0.22f;                  // 넓은 색 띠
        color += (sun * spec1 + sun * albedo * 2.5f * spec2) * shadow * mat.gloss
               * step(0.0f, rawNdL + 0.3f);
        // 뒤에서 오는 빛의 투과 (머리카락 가장자리가 밝아지는 것)
        float rim = pow(max(1.0f - fabs(dot(h.n, -viewDir)), 0.0f), 3.0f);
        color += albedo * kSunColor * rim * 0.18f;
        return color;
    }

    // 태양 하이라이트 (Blinn-Phong). 광택이 높을수록 좁고 강하다.
    if (mat.gloss > 0.01f) {
        float3 hv = normalize(u.lightDir - viewDir);
        float shininess = mix(28.0f, 1400.0f, mat.gloss);
        float spec = pow(max(dot(h.n, hv), 0.0f), shininess);
        // 피부의 하이라이트는 **넓고 약하다.** 좁고 강하면 젖은 플라스틱이 된다.
        float k = (mat.sss > 0.001f) ? 0.45f : 1.6f;
        color += sun * spec * mat.gloss * shadow * step(0.0f, ndotl) * k;
    }
    return color;
}

static float schlick(float cosTheta, float eta) {
    float r0 = (1.0f - eta) / (1.0f + eta);
    r0 = r0 * r0;
    float x = 1.0f - cosTheta;
    return r0 + (1.0f - r0) * x * x * x * x * x;
}

// 유리 표면에서 갈라지는 반사 가지: 재귀 없이 한 번만 추적해 근사
static float3 shadeReflectionOnce(ray r, constant Uniforms& u,
                                  instance_acceleration_structure accel,
                                  intersection_function_table<instancing> funcTable,
                                  constant InstanceData* instances,
                                  constant Material* materials)
{
    SurfaceHit h = traceScene(r, accel, funcTable, instances);
    if (!h.valid) return skyColor(r.direction, u.lightDir, u.envMode);
    constant Material& mat = materials[h.material];
    if (mat.type == MATERIAL_EMISSIVE) return mat.color;
    if (mat.type == MATERIAL_DIFFUSE || mat.type == MATERIAL_HAIR || mat.type == MATERIAL_SATIN) {
        return shadeSurface(h, r.direction, u, accel, funcTable, materials);
    }
    // 거울/유리에 또 부딪히면 하늘색으로 근사 (깊은 재귀 방지)
    float3 refl = reflect(r.direction, h.n);
    return mat.color * skyColor(refl, u.lightDir, u.envMode) * 0.8f;
}

/// 픽셀 하나(정확히는 서브샘플 하나)의 선형 색. `uv` 는 [-1, 1], y 위가 양수.
static float3 shadePixel(float2 uv, constant Uniforms& u,
                         instance_acceleration_structure accel,
                         intersection_function_table<instancing> funcTable,
                         constant InstanceData* instances,
                         constant Material* materials)
{

    ray r;
    r.origin = u.cameraPos;
    r.direction = normalize(u.forward
                            + uv.x * u.right * u.aspect * u.tanHalfFov
                            + uv.y * u.up * u.tanHalfFov);
    r.min_distance = 0.001f;
    r.max_distance = INFINITY;

    float3 result = float3(0);
    float3 throughput = float3(1);
    const float3 primaryDir = r.direction;
    float primaryT = -1.0f;
    const int maxB = (u.maxBounces > 0u) ? min((int)u.maxBounces, MAX_BOUNCES) : MAX_BOUNCES;

    int bounce = 0;
    for (; bounce < maxB; bounce++) {
        SurfaceHit h = traceScene(r, accel, funcTable, instances);
        if (bounce == 0 && h.valid) primaryT = h.t;
        if (!h.valid) {
            result += throughput * skyColor(r.direction, u.lightDir, u.envMode);
            break;
        }
        constant Material& mat = materials[h.material];

        if (mat.type == MATERIAL_DIFFUSE || mat.type == MATERIAL_HAIR) {
            // 광택 재질은 여기서 끝내지 않고 **환경 반사 한 번을 더 쏜다.**
            // 도장면이 하늘과 노면을 비추는 이 성분이 "실물처럼 보이는" 핵심이다.
            float3 direct = shadeSurface(h, r.direction, u, accel, funcTable, materials);
            float cosV = clamp(-dot(r.direction, h.n), 0.0f, 1.0f);
            float F = coatFresnel(cosV, mat.gloss);
            result += throughput * (1.0f - F) * direct;
            if (F > 0.015f && bounce + 1 < maxB) {
                throughput *= F;
                r.origin = h.pos + h.n * 0.003f;
                r.direction = reflect(r.direction, h.n);
                continue;
            }
            break;
        }
        else if (mat.type == MATERIAL_METAL) {
            throughput *= mat.color;
            r.origin = h.pos + h.n * 0.003f;
            r.direction = reflect(r.direction, h.n);
            continue;
        }
        else if (mat.type == MATERIAL_EMISSIVE) {
            result += throughput * mat.color;
            break;
        }
        else if (mat.type == MATERIAL_SATIN) {
            // 착색된 금속 프레넬: 정면에서도 색의 55% 를 반사하고, 스치면 흰색으로 간다
            float cosV = clamp(-dot(r.direction, h.n), 0.0f, 1.0f);
            float x = 1.0f - cosV;
            float x5 = x * x * x * x * x;
            float3 F0 = mat.color * 0.70f;
            float3 F = F0 + (float3(1.0f) - F0) * x5;
            // 금속은 확산이 거의 없다 — 바탕은 반만 남기고 나머지는 반사가 맡는다
            float3 direct = shadeSurface(h, r.direction, u, accel, funcTable, materials);
            result += throughput * (float3(1.0f) - F) * direct * 0.5f;
            if (bounce + 1 < maxB) {
                throughput *= F;
                r.origin = h.pos + h.n * 0.003f;
                r.direction = reflect(r.direction, h.n);
                continue;
            }
            break;
        }
        else { // MATERIAL_GLASS
            float eta = h.frontFace ? (1.0f / mat.ior) : mat.ior;
            float cosI = clamp(-dot(r.direction, h.n), 0.0f, 1.0f);
            float sin2T = eta * eta * (1.0f - cosI * cosI);

            float3 reflDir = reflect(r.direction, h.n);
            if (sin2T > 1.0f) {
                // 전반사
                r.origin = h.pos + h.n * 0.003f;
                r.direction = reflDir;
                continue;
            }
            float F = schlick(cosI, eta);

            // 반사 가지 (1회 추적 근사)
            ray rr;
            rr.origin = h.pos + h.n * 0.003f;
            rr.direction = reflDir;
            rr.min_distance = 0.001f;
            rr.max_distance = INFINITY;
            result += throughput * F * shadeReflectionOnce(rr, u, accel, funcTable, instances, materials);

            // 굴절 가지 계속 진행
            float cosT = sqrt(1.0f - sin2T);
            float3 refrDir = normalize(eta * r.direction + (eta * cosI - cosT) * h.n);
            throughput *= (1.0f - F);
            if (!h.frontFace) {
                // 유리 안을 통과한 만큼 착색 (단순화). grain > 0 이면 **높이에 따른 그라데이션** —
                // 썬글라스 렌즈처럼 위는 짙고 아래로 갈수록 맑아진다. gloss = 맑아지는 아래쪽 y,
                // sss = 짙은 위쪽 y (유리에서는 두 필드가 놀고 있어 빌려 쓴다).
                float3 tint = mat.color;
                if (mat.grain > 0.0f) {
                    float g = smoothstep(mat.gloss, mat.sss, h.pos.y);
                    tint = mix(float3(1.0f), mat.color, mix(1.0f - mat.grain, 1.0f, g));
                }
                throughput *= tint;
            }
            r.origin = h.pos - h.n * 0.003f;
            r.direction = refrDir;
            continue;
        }
    }

    // 바운스 예산이 바닥나서 끝났다면 **남은 에너지를 하늘로 근사**한다.
    // 그냥 버리면 유리를 여러 겹 통과하는 픽셀이 까맣게 죽어 전체가 탁해진다
    // (유리 버스처럼 온통 투명한 씬에서 특히 심하다).
    if (bounce == maxB) {
        result += throughput * skyColor(r.direction, u.lightDir, u.envMode);
    }

    // 거리 안개 — 지면이 끝나는 딱딱한 경계를 지우고 원경에 공기감을 준다
    if (primaryT > 0.0f) {
        float fog = 1.0f - exp(-max(primaryT - 28.0f, 0.0f) * 0.0055f);
        result = mix(result, skyColor(primaryDir, u.lightDir, u.envMode), clamp(fog, 0.0f, 1.0f));
    }

    return result;
}

kernel void rtKernel(uint2 tid                                        [[thread_position_in_grid]],
                     constant Uniforms&                    u          [[buffer(0)]],
                     instance_acceleration_structure       accel      [[buffer(1)]],
                     intersection_function_table<instancing> funcTable [[buffer(2)]],
                     constant InstanceData*                instances  [[buffer(3)]],
                     constant Material*                    materials  [[buffer(4)]],
                     device float4*                        accum      [[buffer(5)]],
                     texture2d<float, access::write>       outTexture [[texture(0)]])
{
    tid.y += u.rowOffset;                      // 띠 디스패치 — 실제 픽셀 행으로
    if (tid.x >= u.width || tid.y >= u.height) return;

    // 슈퍼샘플링: spp = 4 면 픽셀을 2×2 로 나눠 네 번 추적하되, **한 패스에 한 샘플**만.
    // 가는 철사·속눈썹·손가락처럼 픽셀보다 얇은 것은 이게 아니면 계단·점선이 된다.
    int n = (u.spp >= 4) ? 4 : 1;
    int i = (int)u.sampleIndex;
    float2 off = (n == 1) ? float2(0.5f)
                          : float2((i & 1) ? 0.75f : 0.25f, (i & 2) ? 0.75f : 0.25f);
    float2 uv = (float2(tid) + off) / float2(u.width, u.height);
    uv = uv * 2.0f - 1.0f;
    uv.y = -uv.y;
    float3 sample = shadePixel(uv, u, accel, funcTable, instances, materials);

    uint idx = tid.y * u.width + tid.x;
    float3 result = (i == 0) ? sample : accum[idx].xyz + sample;
    if (i + 1 < n) { accum[idx] = float4(result, 1.0f); return; }   // 다음 패스가 이어 더한다
    result /= float(n);

    // 노출 + **화이트포인트 있는** Reinhard.
    // 그냥 x/(1+x) 로 누르면 1 이하 값까지 전부 압축돼 화면이 통째로 회색이 된다.
    result *= (u.exposure > 0.0f ? u.exposure : 1.25f);
    const float white = 2.6f;
    result = result * (1.0f + result / (white * white)) / (1.0f + result);
    result = pow(clamp(result, 0.0f, 1.0f), float3(1.0f / 2.2f));
    outTexture.write(float4(result, 1.0f), tid);
}
