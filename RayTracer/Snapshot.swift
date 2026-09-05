//
//  Snapshot.swift
//  `--snapshot <out.png> [width] [height] [time]` 로 실행하면 창을 띄우지 않고
//  한 프레임만 오프스크린 렌더링해서 PNG 로 저장하고 종료한다.
//  UI 없이 셰이더/가속 구조가 실제로 그림을 뱉는지 확인할 때 쓴다.
//
//  `--eye x,y,z --look x,y,z` 를 덧붙이면 궤도 카메라 대신 그 위치에서 본다 (time 은 무시).
//  `--scene <이름>` 으로 씬을 고른다 (기본 bus). 코드를 고치지 않고 다른 씬을 찍을 수 있다.
//

import Foundation
import Metal
import SwiftUI
import CoreGraphics

enum Snapshot {
    /// 커맨드라인에 --snapshot 이 있으면 렌더링 후 종료. 아니면 그냥 돌아온다.
    @MainActor static func runIfRequested() {
        let args = CommandLine.arguments

        // 시작 메뉴를 이미지로 뽑는다 (레이아웃 확인용 — 화면 캡처 없이 볼 수 있다)
        if let i = args.firstIndex(of: "--menu-shot") {
            let path = args.count > i + 1 ? args[i + 1] : "menu.png"
            renderMenu(to: path)
            exit(0)
        }

        guard let i = args.firstIndex(of: "--snapshot") else { return }

        let path = args.count > i + 1 ? args[i + 1] : "snapshot.png"
        let width = args.count > i + 2 ? Int(args[i + 2]) ?? 800 : 800
        let height = args.count > i + 3 ? Int(args[i + 3]) ?? 500 : 500
        let time = args.count > i + 4 ? Float(args[i + 4]) ?? 0 : 0

        guard let device = MTLCreateSystemDefaultDevice() else {
            fail("Metal 디바이스 없음")
        }
        guard device.supportsRaytracing else {
            fail("이 디바이스는 Metal Ray Tracing 미지원: \(device.name)")
        }
        var kind = CSGScene.Kind.bus
        if let i = args.firstIndex(of: "--scene"), i + 1 < args.count {
            guard let k = CSGScene.Kind(rawValue: args[i + 1]) else {
                fail("알 수 없는 씬: \(args[i + 1]) — \(CSGScene.Kind.allCases.map(\.rawValue))")
            }
            kind = k
        }

        let renderer: Renderer
        do {
            renderer = try Renderer(device: device, scene: kind)
        } catch {
            fail(error.localizedDescription)
        }
        if let eye = vector(named: "--eye", in: args) {
            renderer.cameraOverride = Renderer.CameraOverride(
                eye: eye, target: vector(named: "--look", in: args) ?? SIMD3<Float>(0, -1, 0))
        }
        guard let (pixels, bytesPerRow) = renderer.renderOffscreen(width: width, height: height, time: time) else {
            fail("오프스크린 렌더링 실패")
        }

        write(pixels: pixels, bytesPerRow: bytesPerRow, width: width, height: height, to: path)
        FileHandle.standardError.write("snapshot: \(path) (\(width)x\(height), t=\(time), scene=\(kind.rawValue), gpu=\(device.name))\n".data(using: .utf8)!)
        exit(0)
    }

    @MainActor private static func renderMenu(to path: String) {
        // ImageRenderer 는 ScrollView / NavigationStack 안의 내용을 레이아웃하지 않는다.
        // 그래서 메뉴를 구성하는 부품(헤더 + 카드)을 같은 배치로 직접 그려 **레이아웃만** 확인한다.
        let view = VStack(alignment: .leading, spacing: 20) {
            MenuHeader()
            VStack(spacing: 12) {
                ForEach(CSGScene.Kind.allCases) { SceneCard(kind: $0) }
            }
        }
        .padding(24)
        .frame(width: 700, alignment: .leading)
        .background(Color(white: 0.13))
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { fail("메뉴 렌더 실패") }
        guard ImageExport.write(image, to: URL(fileURLWithPath: path)) else { fail("PNG 쓰기 실패") }
        FileHandle.standardError.write("menu-shot: \(path)\n".data(using: .utf8)!)
    }

    /// `--eye 3,2,-1` 형태를 파싱한다
    private static func vector(named flag: String, in args: [String]) -> SIMD3<Float>? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        let n = args[i + 1].split(separator: ",").compactMap { Float($0) }
        guard n.count == 3 else { fail("\(flag) 는 'x,y,z' 형식이어야 합니다: \(args[i + 1])") }
        return SIMD3<Float>(n[0], n[1], n[2])
    }

    private static func write(pixels: [UInt8], bytesPerRow: Int, width: Int, height: Int, to path: String) {
        guard let image = ImageExport.makeImage(pixels: pixels, bytesPerRow: bytesPerRow,
                                                width: width, height: height)
        else { fail("CGImage 생성 실패") }
        guard ImageExport.write(image, to: URL(fileURLWithPath: path))
        else { fail("PNG 쓰기 실패: \(path)") }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("snapshot 실패: \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}
