// 실제 셰이더 평가기를 사용해 수치·법선·구간 초과를 검사한다.
#include "../RayTracer/Shaders.metal"

kernel void csgProbe(constant CSGNode* nodes [[buffer(0)]],
                     constant float4* data [[buffer(1)]],
                     constant float4* rayInfo [[buffer(2)]],
                     constant uint& count [[buffer(3)]],
                     device float4* output [[buffer(4)]]) {
    IntervalList intervals;
    intervals.overflow = 0;
    bool hit = evalCSG(nodes, count, rayInfo[0].xyz, rayInfo[1].xyz, data, intervals);
    output[0] = float4(hit ? intervals.count : 0, intervals.overflow ? 1 : 0, 0, 0);
    for (int i = 0; hit && i < intervals.count; ++i) {
        Interval v = intervals.iv[i];
        output[1 + i * 3] = float4(v.tIn, v.tOut, v.mIn, v.mOut);
        output[2 + i * 3] = float4(float3(v.nIn), 0);
        output[3 + i * 3] = float4(float3(v.nOut), 0);
    }
}
