import Foundation
import Metal

/// 모든 띠의 완료 결과. 뒤쪽 띠가 성공해도 앞쪽 실패를 지우지 않는다.
struct FrameOutcome {
    private(set) var milliseconds: Double = 0
    private(set) var failure: String?
    var intervalOverflows: [String] = []

    mutating func record(status: MTLCommandBufferStatus, error: Error?, milliseconds: Double, label: String) {
        if status != .completed || error != nil {
            if failure == nil {
                failure = "\(label): \(error?.localizedDescription ?? "GPU status \(status.rawValue)")"
            }
        } else {
            self.milliseconds += max(0, milliseconds)
        }
    }

    func check() throws {
        if let failure { throw RendererError.renderFailed(failure) }
    }

    var warning: String? {
        guard !intervalOverflows.isEmpty else { return nil }
        return "⚠️ CSG 구간 한계(\(CSG_MAX_INTERVALS)) 초과: " + intervalOverflows.joined(separator: ", ")
    }
}
