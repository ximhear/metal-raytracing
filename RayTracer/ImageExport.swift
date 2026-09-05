//
//  ImageExport.swift
//  렌더 결과(BGRA8 픽셀) → CGImage → PNG 저장.
//  화면의 저장 버튼과 `--snapshot` CLI 가 같은 경로를 쓴다.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
import Photos
#endif

enum ImageExport {

    /// Metal 텍스처가 `bgra8Unorm` 이라 **byteOrder32Little + premultipliedFirst** 로 읽으면 그대로 맞는다.
    /// (여기를 RGBA 로 두면 빨강과 파랑이 뒤바뀐다)
    static func makeImage(pixels: [UInt8], bytesPerRow: Int, width: Int, height: Int) -> CGImage? {
        let bitmap: CGBitmapInfo = [.byteOrder32Little,
                                    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)]
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: bitmap, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    @discardableResult
    static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    static func defaultFileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "RayTracer-\(f.string(from: Date())).png"
    }

    // MARK: - 플랫폼별 저장

    /// macOS 는 저장 패널, iOS 는 사진 앱. 결과 메시지를 **메인 스레드**로 돌려준다.
    static func save(_ image: CGImage, completion: @escaping (String) -> Void) {
        func finish(_ message: String) {
            DispatchQueue.main.async { completion(message) }
        }

        #if os(macOS)
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = defaultFileName()
            panel.begin { response in
                guard response == .OK, let url = panel.url else {
                    finish("저장 취소")
                    return
                }
                finish(write(image, to: url) ? "저장됨: \(url.lastPathComponent)" : "저장 실패")
            }
        }
        #else
        guard let data = pngData(image) else {
            finish("PNG 변환 실패")
            return
        }
        // 추가 전용 권한이면 사용자가 라이브러리를 읽히지 않아도 된다
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                finish("사진 접근 권한이 없습니다")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { ok, error in
                finish(ok ? "사진 앱에 저장됨" : "저장 실패: \(error?.localizedDescription ?? "알 수 없음")")
            }
        }
        #endif
    }
}
