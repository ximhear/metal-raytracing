//
//  Renderer.swift
//  CSG 오브젝트마다 AABB 1개짜리 primitive 가속 구조를 만들고,
//  인스턴스 가속 구조로 배치한 뒤 intersection function table로 렌더링한다.
//

import Foundation
import CoreGraphics
import Metal
import MetalKit
import simd

/// 초기화가 어디서 실패했는지 화면/콘솔에 그대로 보여 주기 위한 에러.
/// 예전에는 전부 `init?` 의 nil 로 뭉개져서 흰 화면만 남았다.
enum RendererError: LocalizedError {
    case noRaytracingSupport(String)
    case noCommandQueue
    case noDefaultLibrary
    case missingFunction(String)
    case pipelineFailed(String)
    case bufferFailed(String)
    case functionTableFailed
    case accelerationStructureFailed(String)
    case csgTooDeep(object: Int, depth: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .noRaytracingSupport(let gpu):
            return "이 GPU 는 Metal Ray Tracing 미지원: \(gpu)\nA13/M1 이상 실기기가 필요합니다 (시뮬레이터 불가)."
        case .noCommandQueue:
            return "MTLCommandQueue 생성 실패"
        case .noDefaultLibrary:
            return "default.metallib 로드 실패.\n.metal 파일이 타깃에 포함됐는지, MTL_LANGUAGE_REVISION 이 이 OS 버전보다 높지 않은지 확인하세요."
        case .missingFunction(let name):
            return "셰이더 함수 '\(name)' 를 찾을 수 없음"
        case .pipelineFailed(let why):
            return "컴퓨트 파이프라인 생성 실패:\n\(why)"
        case .bufferFailed(let what):
            return "버퍼 생성 실패: \(what)"
        case .functionTableFailed:
            return "intersection function table 생성 실패.\nGPU 가 함수 포인터(supportsFunctionPointers)를 지원하지 않을 수 있습니다."
        case .accelerationStructureFailed(let why):
            return "가속 구조 빌드 실패: \(why)"
        case .csgTooDeep(let object, let depth, let limit):
            return "오브젝트 \(object) 의 CSG 스택 깊이 \(depth) 가 한계 \(limit) 초과.\n"
                 + "CSG.unionAll 로 묶거나 ShaderTypes.h 의 CSG_MAX_STACK 을 올리세요."
        }
    }
}

final class Renderer: NSObject, MTKViewDelegate, ObservableObject {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let functionTable: MTLIntersectionFunctionTable

    /// 화면 구석 HUD 용. "정말 그리고 있는지" 를 흰 화면과 구분하기 위한 것.
    @Published private(set) var hud: String = "첫 프레임 대기 중…"
    private var lastGPUms: Double = 0
    /// 저장 해상도를 화면 비율에 맞추기 위해 기억해 둔다
    private(set) var lastDrawableSize: (width: Int, height: Int) = (0, 0)

    /// 사용자가 조작하는 궤도 카메라. 자동 회전 대신 드래그·핀치로 움직인다.
    struct Camera {
        var azimuth: Float = 0.85          // 방위각 (rad)
        var elevation: Float = 0.32        // 고도각 (rad)
        var zoom: Float = 1                // 1 = 씬 크기에 맞춘 자동 거리

        /// 수직에 가까워지면 카메라 기저(forward × up)가 무너지므로 넉넉히 잘라 둔다.
        /// 하한은 씬이 정한다 (`CSGScene.minElevation`) — 바닥 아래로 내려가면 화면이 깨진다.
        static let maxElevation: Float = 1.25
        static let zoomLimits: (Float, Float) = (0.35, 3.0)
    }
    private(set) var camera = Camera()

    /// 드래그 → 회전. `d*` 는 화면 포인트 단위 이동량.
    func orbit(dx: Float, dy: Float) {
        let k: Float = 0.006               // rad / 포인트
        camera.azimuth -= dx * k
        camera.elevation = min(max(camera.elevation + dy * k, minElevation), Camera.maxElevation)
    }

    /// 드래그·핀치 중에는 참. 슈퍼샘플링과 소프트 섀도를 끄고 그려서 제스처가 따라온다.
    /// 제스처가 끝나면 뷰가 false 로 돌리고 한 프레임을 더 요청해 풀 품질로 덮어쓴다.
    var interacting = false

    /// 핀치/스크롤 → 확대. `factor` > 1 이면 가까워진다.
    func zoom(by factor: Float) {
        guard factor > 0 else { return }
        let (lo, hi) = Camera.zoomLimits
        camera.zoom = min(max(camera.zoom / factor, lo), hi)
    }

    func resetCamera() {
        camera = Camera()
        camera.elevation = defaultElevation
    }
    private var defaultElevation: Float = 0.32
    private var minElevation: Float = 0.02

    private let nodeBuffer: MTLBuffer
    private let objectBuffer: MTLBuffer
    private let instanceObjectBuffer: MTLBuffer
    private let partDataBuffer: MTLBuffer
    private let instanceDataBuffer: MTLBuffer
    private let materialBuffer: MTLBuffer
    private var primitiveAccels: [MTLAccelerationStructure] = []
    private var instanceAccel: MTLAccelerationStructure!


    /// 카메라가 담아야 할 범위 — 씬이 정한다 (XZ 반지름 + 반높이의 원기둥)
    private var focusCenter = SIMD3<Float>(0, -1, 0)
    private var environment: CSGScene.Environment = .outdoor
    private var sunDirection: SIMD3<Float>?
    private var shadowSoftness: Float = 0
    private var samplesPerPixel: Int = 1
    private var exposure: Float = 1.25
    private var maxBounces: Int = 6
    private var fogStart: Float = 28
    private var focusRadius: Float = 5.4
    private var focusHalfHeight: Float = 2.5

    private static let fovDegrees: Float = 50

    init(device: MTLDevice, scene sceneKind: CSGScene.Kind) throws {
        guard device.supportsRaytracing else { throw RendererError.noRaytracingSupport(device.name) }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.noCommandQueue }
        guard let library = device.makeDefaultLibrary() else { throw RendererError.noDefaultLibrary }
        guard let kernel = library.makeFunction(name: "rtKernel") else {
            throw RendererError.missingFunction("rtKernel")
        }
        guard let csgFunction = library.makeFunction(name: "csgIntersection") else {
            throw RendererError.missingFunction("csgIntersection")
        }
        self.queue = queue

        // ---- 컴퓨트 파이프라인 + intersection function 링크 ----
        let linked = MTLLinkedFunctions()
        linked.functions = [csgFunction]
        let pDesc = MTLComputePipelineDescriptor()
        pDesc.computeFunction = kernel
        pDesc.linkedFunctions = linked
        pDesc.threadGroupSizeIsMultipleOfThreadExecutionWidth = true
        let pipeline: MTLComputePipelineState
        do {
            pipeline = try device.makeComputePipelineState(descriptor: pDesc, options: [], reflection: nil)
        } catch {
            throw RendererError.pipelineFailed(error.localizedDescription)
        }
        self.pipeline = pipeline

        // ---- 씬 데이터 평탄화 ----
        let scene = CSGScene(sceneKind)
        focusCenter = scene.focusCenter
        focusRadius = scene.focusRadius
        environment = scene.environment
        sunDirection = scene.sunDirection
        shadowSoftness = scene.shadowSoftness
        samplesPerPixel = scene.samplesPerPixel
        exposure = scene.exposure
        maxBounces = scene.maxBounces
        fogStart = scene.fogStart
        focusHalfHeight = scene.focusHalfHeight
        camera.elevation = scene.focusElevation
        minElevation = scene.minElevation
        defaultElevation = scene.focusElevation
        var nodes: [CSGNode] = []
        var partData: [SIMD4<Float>] = []
        var objects: [CSGObject] = []
        var bounds: [MTLAxisAlignedBoundingBox] = []
        for (index, obj) in scene.objects.enumerated() {
            // 셰이더 스택이 넘치면 부품이 조용히 사라지므로 여기서 먼저 잡는다
            let depth = obj.stackDepth()
            guard depth <= Int(CSG_MAX_STACK) else {
                throw RendererError.csgTooDeep(object: index, depth: depth, limit: Int(CSG_MAX_STACK))
            }
            let offset = nodes.count
            obj.flatten(into: &nodes, partData: &partData)
            objects.append(CSGObject(nodeOffset: UInt32(offset), nodeCount: UInt32(nodes.count - offset),
                                     reserved0: 0, reserved1: 0))
            let b = obj.bounds()
            let pad: Float = 0.01
            bounds.append(MTLAxisAlignedBoundingBox(
                min: MTLPackedFloat3Make(b.min.x - pad, b.min.y - pad, b.min.z - pad),
                max: MTLPackedFloat3Make(b.max.x + pad, b.max.y + pad, b.max.z + pad)))
        }
        let instanceObjects = scene.placements.map { UInt32($0.objectIndex) }
        let instanceData = scene.placements.map { InstanceData(normalMatrix: $0.transform.inverse.transpose) }
        let materials = scene.materials

        func makeBuffer<T>(_ array: [T]) -> MTLBuffer? {
            device.makeBuffer(bytes: array, length: MemoryLayout<T>.stride * max(array.count, 1),
                              options: .storageModeShared)
        }
        guard let nb = makeBuffer(nodes) else { throw RendererError.bufferFailed("nodes") }
        guard let ob = makeBuffer(objects) else { throw RendererError.bufferFailed("objects") }
        guard let iob = makeBuffer(instanceObjects) else { throw RendererError.bufferFailed("instanceObjects") }
        guard let idb = makeBuffer(instanceData) else { throw RendererError.bufferFailed("instanceData") }
        guard let mb = makeBuffer(materials) else { throw RendererError.bufferFailed("materials") }
        guard let pdb = makeBuffer(partData) else { throw RendererError.bufferFailed("partData") }
        nodeBuffer = nb; objectBuffer = ob; instanceObjectBuffer = iob
        instanceDataBuffer = idb; materialBuffer = mb; partDataBuffer = pdb

        // ---- Intersection function table ----
        let tDesc = MTLIntersectionFunctionTableDescriptor()
        tDesc.functionCount = 1
        guard let table = pipeline.makeIntersectionFunctionTable(descriptor: tDesc),
              let handle = pipeline.functionHandle(function: csgFunction)
        else { throw RendererError.functionTableFailed }
        table.setFunction(handle, index: 0)
        table.setBuffer(nodeBuffer, offset: 0, index: 0)
        table.setBuffer(objectBuffer, offset: 0, index: 1)
        table.setBuffer(instanceObjectBuffer, offset: 0, index: 2)
        table.setBuffer(partDataBuffer, offset: 0, index: 3)
        functionTable = table

        super.init()
        try buildAccelerationStructures(bounds: bounds, placements: scene.placements)
    }

    // MARK: - Acceleration structures

    private func buildAccelerationStructures(bounds: [MTLAxisAlignedBoundingBox],
                                             placements: [Placement]) throws {
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeAccelerationStructureCommandEncoder()
        else { throw RendererError.accelerationStructureFailed("encoder 생성 실패") }

        // 1) 오브젝트마다 AABB 1개짜리 primitive 가속 구조
        var scratches: [MTLBuffer] = []
        for box in bounds {
            var b = box
            guard let bboxBuffer = device.makeBuffer(bytes: &b, length: MemoryLayout<MTLAxisAlignedBoundingBox>.stride,
                                                     options: .storageModeShared)
            else { throw RendererError.accelerationStructureFailed("bounding box 버퍼") }

            let geo = MTLAccelerationStructureBoundingBoxGeometryDescriptor()
            geo.boundingBoxBuffer = bboxBuffer
            geo.boundingBoxCount = 1
            geo.boundingBoxStride = MemoryLayout<MTLAxisAlignedBoundingBox>.stride
            geo.intersectionFunctionTableOffset = 0

            let desc = MTLPrimitiveAccelerationStructureDescriptor()
            desc.geometryDescriptors = [geo]

            let sizes = device.accelerationStructureSizes(descriptor: desc)
            guard let accel = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
                  let scratch = device.makeBuffer(length: sizes.buildScratchBufferSize, options: .storageModePrivate)
            else { throw RendererError.accelerationStructureFailed("primitive 구조 할당 (\(sizes.accelerationStructureSize) B)") }
            enc.build(accelerationStructure: accel, descriptor: desc, scratchBuffer: scratch, scratchBufferOffset: 0)
            primitiveAccels.append(accel)
            scratches.append(scratch)
        }

        // 2) 인스턴스 디스크립터
        var descriptors: [MTLAccelerationStructureInstanceDescriptor] = placements.map { p in
            var d = MTLAccelerationStructureInstanceDescriptor()
            d.transformationMatrix = packed4x3(p.transform)
            d.options = []
            d.mask = 0xFF
            d.intersectionFunctionTableOffset = 0
            d.accelerationStructureIndex = UInt32(p.objectIndex)
            return d
        }
        guard let instBuffer = device.makeBuffer(bytes: &descriptors,
                                                 length: MemoryLayout<MTLAccelerationStructureInstanceDescriptor>.stride * descriptors.count,
                                                 options: .storageModeShared)
        else { throw RendererError.accelerationStructureFailed("인스턴스 디스크립터 버퍼") }

        let iDesc = MTLInstanceAccelerationStructureDescriptor()
        iDesc.instancedAccelerationStructures = primitiveAccels
        iDesc.instanceCount = descriptors.count
        iDesc.instanceDescriptorBuffer = instBuffer

        let sizes = device.accelerationStructureSizes(descriptor: iDesc)
        guard let accel = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
              let scratch = device.makeBuffer(length: sizes.buildScratchBufferSize, options: .storageModePrivate)
        else { throw RendererError.accelerationStructureFailed("인스턴스 구조 할당") }
        enc.build(accelerationStructure: accel, descriptor: iDesc, scratchBuffer: scratch, scratchBufferOffset: 0)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        if let error = cmd.error {
            throw RendererError.accelerationStructureFailed(error.localizedDescription)
        }
        instanceAccel = accel
    }

    private func packed4x3(_ m: float4x4) -> MTLPackedFloat4x3 {
        func col(_ c: SIMD4<Float>) -> MTLPackedFloat3 { MTLPackedFloat3Make(c.x, c.y, c.z) }
        return MTLPackedFloat4x3(columns: (col(m.columns.0), col(m.columns.1), col(m.columns.2), col(m.columns.3)))
    }

    // MARK: - Camera

    /// 스냅샷에서 카메라를 직접 지정할 때 쓴다 (모델 검수용). nil 이면 궤도 회전.
    struct CameraOverride {
        var eye: SIMD3<Float>
        var target: SIMD3<Float>
    }
    var cameraOverride: CameraOverride?

    /// 카메라 상태 → Uniforms **값**.
    /// 예전처럼 인스턴스 프로퍼티를 고쳐 쓰면 화면 렌더링과 백그라운드 저장이 같은 값을 밟는다.
    private func makeUniforms(width: Int, height: Int, time: Float? = nil) -> Uniforms {
        // 스냅샷은 time 으로 방위각을 직접 준다 (`make snapshot T=...`)
        let az = time ?? camera.azimuth
        let el = camera.elevation
        let aspect = Float(width) / Float(height)
        let tanHalfFov = tan(Renderer.fovDegrees * .pi / 180 / 2)

        // 가로: 반지름 R 인 원이 화각 θ 안에 들어오는 거리는 R / sin(θ/2).
        //       (tan 이 아니라 sin 인 게 핵심 — 가까운 쪽 접선 기준이라 원근이 반영된다)
        // 세로: 가장 가까운 지점(거리 d − R)에서 높이가 화각에 들어와야 한다.
        // 세로 화각은 FOV 로 고정이고 가로 화각만 aspect 에 비례하므로,
        // 세로 화면(aspect < 1)에서는 더 물러나야 한다 — 고정하면 아이폰 세로에서 양 끝이 잘린다.
        let halfFovH = atan(tanHalfFov * aspect)
        let fitDistance = max(focusRadius / sin(halfFovH),
                              focusRadius + focusHalfHeight / tanHalfFov)
        let distance = fitDistance * camera.zoom
        let orbit = SIMD3<Float>(sin(az) * cos(el), sin(el), cos(az) * cos(el))

        let eye = cameraOverride?.eye ?? (focusCenter + orbit * distance)
        let target = cameraOverride?.target ?? focusCenter
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = simd_cross(right, forward)

        var u = Uniforms()
        u.cameraPos = eye
        u.forward = forward
        u.right = right
        u.up = up
        u.lightDir = sunDirection ?? (environment == .studio || environment == .brightStudio
            ? simd_normalize(SIMD3<Float>(0.22, 1.0, 0.10))   // 메인 소프트박스와 같은 방향
            : simd_normalize(SIMD3<Float>(0.4, 1.0, 0.3)))
        u.width = UInt32(width)
        u.height = UInt32(height)
        u.aspect = aspect
        u.tanHalfFov = tanHalfFov
        u.envMode = environment.rawValue
        u.shadowSoftness = interacting ? 0 : shadowSoftness
        u.spp = UInt32(interacting ? 1 : samplesPerPixel)
        u.exposure = exposure
        u.maxBounces = UInt32(maxBounces)
        u.fogStart = fogStart
        return u
    }

    // MARK: - Rendering

    /// 커널 한 번 디스패치. drawable 이든 오프스크린 텍스처든 동일한 경로를 쓴다.
    /// 한 띠의 행 수. 무거운 씬에서도 띠 하나가 워치독(수백 ms) 안에 끝나야 한다.
    private let bandRows = 128

    /// 샘플 누적 버퍼 (float4 × 픽셀). 슈퍼샘플링 패스가 여기에 더한다. 크기가 모자라면 다시 만든다.
    private var accumBuffer: MTLBuffer?
    private func accumulator(pixels: Int) -> MTLBuffer? {
        let bytes = pixels * MemoryLayout<SIMD4<Float>>.stride
        if let b = accumBuffer, b.length >= bytes { return b }
        accumBuffer = device.makeBuffer(length: bytes, options: .storageModePrivate)
        return accumBuffer
    }

    /// 텍스처 전체를 **샘플 패스 × 가로 띠**로 나눠 각각 별도 커맨드 버퍼로 그린다.
    /// 스레드 하나는 한 샘플만 계산한다 — 커널 안에서 4샘플을 돌면 GPU 가 스레드그룹을 소리 없이 죽인다.
    /// `each` 는 커밋 직전에 (버퍼, 마지막인가) 로 불린다 — present·완료 핸들러는 여기서 건다.
    @discardableResult
    private func encodeBanded(texture tex: MTLTexture, time: Float? = nil,
                              each: ((MTLCommandBuffer, Bool) -> Void)? = nil) -> MTLCommandBuffer? {
        let samples = interacting ? 1 : max(1, samplesPerPixel)
        guard let acc = accumulator(pixels: tex.width * tex.height) else { return nil }
        var lastCmd: MTLCommandBuffer?
        for sample in 0..<samples {
            var row = 0
            while row < tex.height {
                guard let cmd = queue.makeCommandBuffer() else { return lastCmd }
                let rows = min(bandRows, tex.height - row)
                encode(into: cmd, texture: tex, accum: acc, time: time,
                       rowOffset: row, rows: rows, sampleIndex: sample)
                row += rows
                each?(cmd, sample == samples - 1 && row >= tex.height)
                cmd.commit()
                lastCmd = cmd
            }
        }
        return lastCmd
    }

    private func encode(into cmd: MTLCommandBuffer, texture tex: MTLTexture, accum: MTLBuffer,
                        time: Float? = nil, rowOffset: Int = 0, rows: Int? = nil, sampleIndex: Int = 0) {
        guard let enc = cmd.makeComputeCommandEncoder() else { return }
        var u = makeUniforms(width: tex.width, height: tex.height, time: time)
        u.rowOffset = UInt32(rowOffset)
        u.sampleIndex = UInt32(sampleIndex)

        enc.setComputePipelineState(pipeline)
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setAccelerationStructure(instanceAccel, bufferIndex: 1)
        enc.setIntersectionFunctionTable(functionTable, bufferIndex: 2)
        enc.setBuffer(instanceDataBuffer, offset: 0, index: 3)
        enc.setBuffer(materialBuffer, offset: 0, index: 4)
        enc.setBuffer(accum, offset: 0, index: 5)
        enc.setTexture(tex, index: 0)

        // 인스턴스 가속 구조가 참조하는 하위 구조 + function table이 쓰는 버퍼는 useResource 필수
        enc.useResources(primitiveAccels, usage: .read)
        enc.useResources([nodeBuffer, objectBuffer, instanceObjectBuffer, partDataBuffer], usage: .read)

        let w = pipeline.threadExecutionWidth
        let h = pipeline.maxTotalThreadsPerThreadgroup / w
        enc.dispatchThreads(MTLSize(width: tex.width, height: rows ?? tex.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc.endEncoding()
    }

    /// 사람이 읽을 카메라 상태 (HUD 용)
    var cameraSummary: String {
        String(format: "%.0f° / %.0f°  ×%.2f",
               camera.azimuth * 180 / .pi, camera.elevation * 180 / .pi, 1 / camera.zoom)
    }

    /// 오프스크린으로 한 프레임 렌더링해서 BGRA8 픽셀을 돌려준다 (스냅샷/검증용).
    func renderOffscreen(width: Int, height: Int, time: Float? = nil) -> (pixels: [UInt8], bytesPerRow: Int)? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: width, height: height, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }

        guard let cmd = encodeBanded(texture: tex, time: time) else { return nil }
        cmd.waitUntilCompleted()
        if let error = cmd.error {
            // GPU 가 중간에 죽으면(타임아웃·폴트) 텍스처의 남은 타일이 쓰레기로 남는다 — 조용히 넘기지 않는다
            FileHandle.standardError.write("⚠️ GPU 커맨드 실패: \(error.localizedDescription) (status \(cmd.status.rawValue))\n".data(using: .utf8)!)
        }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { buf in
            tex.getBytes(buf.baseAddress!, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return (pixels, bytesPerRow)
    }

    /// 현재 카메라 그대로 고해상도 이미지를 만든다 (저장용).
    /// GPU 를 기다리므로 **백그라운드 큐에서 부를 것** — 큰 해상도는 몇 초 걸린다.
    func makeImage(width: Int, height: Int) -> CGImage? {
        guard let (pixels, bytesPerRow) = renderOffscreen(width: width, height: height) else { return nil }
        return ImageExport.makeImage(pixels: pixels, bytesPerRow: bytesPerRow,
                                     width: width, height: height)
    }

    /// 저장용 권장 해상도 — 화면 비율을 유지한 채 긴 변을 2400 으로.
    func suggestedSaveSize() -> (width: Int, height: Int) {
        let (w, h) = lastDrawableSize
        guard w > 0, h > 0 else { return (2400, 1500) }
        let scale = 2400 / Float(max(w, h))
        return (Int((Float(w) * scale).rounded()), Int((Float(h) * scale).rounded()))
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        (view as? ScaledMTKView)?.requestRedraw()
    }

    func draw(in view: MTKView) {
        // drawableSize 가 0 이면 currentDrawable 이 계속 nil 이라 한 프레임도 안 그려진다.
        // 흰 화면의 흔한 원인이라 여기서 원인을 남긴다.
        guard view.drawableSize.width >= 1, view.drawableSize.height >= 1 else {
            publishHUD("drawableSize = \(Int(view.drawableSize.width))x\(Int(view.drawableSize.height)) — 그릴 수 없음")
            return
        }
        guard let drawable = view.currentDrawable else {
            publishHUD("currentDrawable == nil")
            return
        }
        let tex = drawable.texture
        lastDrawableSize = (tex.width, tex.height)
        // 띠마다 커맨드 버퍼 하나 — 무거운 씬이 워치독에 걸리지 않는다. 마지막 띠가 present 한다.
        final class Acc { var ms = 0.0 }
        let acc = Acc()
        encodeBanded(texture: tex) { [weak self] cmd, isLast in
            cmd.addCompletedHandler { buffer in
                guard let self else { return }
                if let error = buffer.error {
                    self.publishHUD("GPU 에러: \(error.localizedDescription)")
                    return
                }
                acc.ms += (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
                guard isLast else { return }
                // 요청 시에만 그리므로 fps 는 의미가 없다 — GPU 프레임 시간(띠 합)을 보여 준다
                self.lastGPUms = acc.ms
                self.publishHUD(String(format: "%dx%d  %.1f ms  %@  |  %@",
                                       tex.width, tex.height, self.lastGPUms,
                                       self.device.name, self.cameraSummary))
            }
            if isLast { cmd.present(drawable) }
        }
    }

    private func publishHUD(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hud != text else { return }
            self.hud = text
        }
    }
}
