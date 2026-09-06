import XCTest
import Metal
import simd
@testable import RayTracer_macOS

final class RayTracerTests: XCTestCase {
    private func gpu() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsRaytracing else {
            throw XCTSkip("Metal Ray Tracing 가능한 Mac 필요")
        }
        return device
    }

    private func probe(_ shape: CSG, origin: SIMD3<Float> = [-3, 0, 0],
                       direction: SIMD3<Float> = [1, 0, 0]) throws -> [SIMD4<Float>] {
        let device = try gpu()
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: Self.self))
        let function = try XCTUnwrap(library.makeFunction(name: "csgProbe"))
        let pipeline = try device.makeComputePipelineState(function: function)
        var nodes: [CSGNode] = [], data: [SIMD4<Float>] = []
        shape.flatten(into: &nodes, partData: &data)
        if data.isEmpty { data = [.zero] }
        func buffer<T>(_ values: [T]) throws -> MTLBuffer {
            try values.withUnsafeBufferPointer {
                try XCTUnwrap(device.makeBuffer(bytes: $0.baseAddress!, length: $0.count * MemoryLayout<T>.stride))
            }
        }
        let output = try XCTUnwrap(device.makeBuffer(length: 19 * MemoryLayout<SIMD4<Float>>.stride,
                                                     options: .storageModeShared))
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(try buffer(nodes), offset: 0, index: 0)
        encoder.setBuffer(try buffer(data), offset: 0, index: 1)
        encoder.setBuffer(try buffer([SIMD4<Float>(origin, 0), SIMD4<Float>(direction, 0)]), offset: 0, index: 2)
        var count = UInt32(nodes.count)
        encoder.setBytes(&count, length: 4, index: 3)
        encoder.setBuffer(output, offset: 0, index: 4)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "")
        return Array(UnsafeBufferPointer(start: output.contents().bindMemory(to: SIMD4<Float>.self, capacity: 19), count: 19))
    }

    func testBooleanIntervalsAndCutNormals() throws {
        let a = CSG.box(material: 0)
        let b = CSG.box(.translate(1, 0, 0), material: 1)
        let union = try probe(a | b)
        XCTAssertEqual(union[0].x, 1)
        XCTAssertEqual(union[1].x, 2, accuracy: 0.0001)
        XCTAssertEqual(union[1].y, 5, accuracy: 0.0001)
        let intersection = try probe(a & b)
        XCTAssertEqual(intersection[1].x, 3, accuracy: 0.0001)
        XCTAssertEqual(intersection[1].y, 4, accuracy: 0.0001)
        let cut = try probe(a - b)
        XCTAssertEqual(cut[1].x, 2, accuracy: 0.0001)
        XCTAssertEqual(cut[1].y, 3, accuracy: 0.0001)
        XCTAssertEqual(cut[1].w, 1, "절단면은 커터 재질")
        XCTAssertEqual(cut[3].x, 1, accuracy: 0.0001, "커터의 진입 법선을 뒤집는다")
        XCTAssertEqual(try probe(a - a)[0].x, 0)
        XCTAssertEqual(try probe(a & CSG.box(.translate(4, 0, 0), material: 0))[0].x, 0)
    }

    func testInsideRayAndTransformedNormals() throws {
        let inside = try probe(CSG.sphere(material: 0), origin: .zero)
        XCTAssertEqual(inside[1].x, -1, accuracy: 0.0001)
        XCTAssertEqual(inside[1].y, 1, accuracy: 0.0001)
        XCTAssertEqual(inside[3].x, 1, accuracy: 0.0001)
        let ellipsoid = try probe(CSG.sphere(.scale(2, 1, 1), material: 0), origin: [-3, 0.5, 0])
        let normal = SIMD3<Float>(ellipsoid[2].x, ellipsoid[2].y, ellipsoid[2].z)
        let expected = simd_normalize(SIMD3<Float>(-sqrt(3) / 4, 0.5, 0))
        XCTAssertLessThan(simd_length(normal - expected), 0.001)
    }

    func testIntervalOverflowAndStackDepth() throws {
        func chain(_ count: Int) -> CSG {
            CSG.unionAll((0..<count).map { CSG.sphere(.translate(Float($0) * 3, 0, 0), material: 0) })
        }
        XCTAssertEqual(chain(40).stackDepth(), 2)
        XCTAssertEqual(try probe(chain(6))[0].y, 0)
        let overflow = try probe(chain(7))
        XCTAssertEqual(overflow[0].x, 6)
        XCTAssertEqual(overflow[0].y, 1)
        // 중간 union이 넘친 뒤 교집합이 비어도 진단을 유지한다.
        XCTAssertEqual(try probe(chain(7) & CSG.box(.translate(0, 8, 0), material: 0))[0].y, 1)
    }

    func testIntersectionDiagnosticsAreIsolatedPerFrame() throws {
        let scene = CSGScene(.roundBoxTest)
        scene.objects = [CSG.unionAll((0..<7).map {
            CSG.sphere(.translate(Float($0) * 3, 0, 0), material: 0)
        })]
        scene.placements = [Placement(objectIndex: 0, transform: .identity)]
        let renderer = try Renderer(device: gpu(), scene: scene)
        let requests = try main {
            renderer.cameraOverride = .init(eye: [-3, 0, 0], target: [25, 0, 0])
            let overflow = try renderer.makeRequest(width: 1, height: 1)
            renderer.cameraOverride = .init(eye: [-3, 10, 0], target: [25, 10, 0])
            return [overflow, try renderer.makeRequest(width: 1, height: 1)]
        }
        let first = try renderer.renderOffscreen(requests[0])
        XCTAssertTrue(first.outcome.warning?.contains("오브젝트 0:") == true)
        XCTAssertNil(try renderer.renderOffscreen(requests[1]).outcome.warning)
    }

    func testEarlierGPUFailureCannotBeOverwritten() throws {
        var outcome = FrameOutcome()
        outcome.record(status: .error, error: NSError(domain: "GPU test", code: 1), milliseconds: 0, label: "first band")
        outcome.record(status: .completed, error: nil, milliseconds: 1, label: "last band")
        XCTAssertThrowsError(try outcome.check())
        XCTAssertTrue(outcome.failure?.contains("first band") == true)
        var incomplete = FrameOutcome()
        incomplete.record(status: .committed, error: nil, milliseconds: 0, label: "incomplete")
        XCTAssertThrowsError(try incomplete.check())
    }

    private func main<T>(_ action: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try action() }
        return try DispatchQueue.main.sync(execute: action)
    }

    func testConcurrentFramesKeepCapturedCameraAndSamples() throws {
        let scene = CSGScene(.roundBoxTest)
        scene.samplesPerPixel = 4
        let renderer = try Renderer(device: gpu(), scene: scene)
        let requests = try main {
            let first = try renderer.makeRequest(width: 96, height: 260)
            renderer.orbit(dx: 85, dy: 10)
            let second = try renderer.makeRequest(width: 512, height: 80)
            renderer.interacting = true
            XCTAssertThrowsError(try renderer.makeRequest(width: 0, height: 20))
            XCTAssertThrowsError(try renderer.makeRequest(width: 20, height: -1))
            XCTAssertThrowsError(try renderer.makeRequest(width: Int.max, height: 1))
            return [first, second]
        }
        let baseline = try requests.map { try renderer.renderOffscreen($0).pixels }
        let done = expectation(description: "동시 프레임")
        done.expectedFulfillmentCount = 4
        for i in 0..<4 {
            DispatchQueue.global().async {
                defer { done.fulfill() }
                do {
                    let result = try renderer.renderOffscreen(requests[i % 2])
                    XCTAssertEqual(result.pixels, baseline[i % 2])
                    XCTAssertNil(result.outcome.warning)
                } catch { XCTFail(error.localizedDescription) }
            }
        }
        wait(for: [done], timeout: 60)
    }
}
