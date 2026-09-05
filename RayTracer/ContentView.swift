//
//  ContentView.swift
//  시작 메뉴 → 씬 선택 → 렌더링 화면.
//
//  메뉴는 `CSGScene.Kind.allCases` 를 그대로 그린다 —
//  **씬을 추가하려면 `Kind` 에 case 하나만 넣으면 버튼이 따라 생긴다.**
//
//  Renderer 는 화면에 들어갈 때 만든다 (가속 구조를 세우느라 몇 초 걸릴 수 있어 백그라운드에서),
//  나가면 함께 해제되어 GPU 메모리를 붙들고 있지 않는다.
//

import SwiftUI
import Metal
import MetalKit

struct ContentView: View {
    var body: some View {
        NavigationStack {
            MenuView()
                .navigationDestination(for: CSGScene.Kind.self) { kind in
                    SceneHost(kind: kind)
                }
        }
    }
}

// MARK: - 시작 메뉴

struct MenuView: View {
    private var supportsRaytracing: Bool {
        MTLCreateSystemDefaultDevice()?.supportsRaytracing ?? false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if supportsRaytracing {
                    VStack(spacing: 12) {
                        ForEach(CSGScene.Kind.allCases) { kind in
                            NavigationLink(value: kind) { SceneCard(kind: kind) }
                                .buttonStyle(.plain)
                        }
                    }
                } else {
                    unsupportedNotice
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("RayTracer")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var header: some View { MenuHeader() }

    private var unsupportedNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Metal Ray Tracing 미지원", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text("A13 / M1 이상 실기기가 필요합니다. 시뮬레이터에서는 동작하지 않습니다.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MenuHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("해석적 CSG 레이 트레이서")
                .font(.title2.weight(.semibold))
            Text("삼각형 없이 수식으로 교차하는 Metal Ray Tracing 데모")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct SceneCard: View {
    let kind: CSGScene.Kind

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: kind.symbol)
                .font(.title2)
                .frame(width: 40, height: 40)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(kind.title).font(.headline)
                    if kind.isDebugScene {
                        Text("검증")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(kind.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - 씬 하나를 띄우는 화면

private struct SceneHost: View {
    let kind: CSGScene.Kind
    @StateObject private var store: RendererStore

    init(kind: CSGScene.Kind) {
        self.kind = kind
        _store = StateObject(wrappedValue: RendererStore(kind: kind))
    }

    var body: some View {
        Group {
            if let renderer = store.renderer {
                RenderSurface(renderer: renderer)
            } else if let failure = store.failure {
                failureView(failure)
            } else {
                ProgressView("가속 구조 준비 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(kind.title)
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func failureView(_ message: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("렌더러를 시작하지 못했습니다").font(.headline)
                Text(message).font(.callout)
                Divider()
                Text(store.diagnostics)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

/// Renderer 를 **백그라운드에서** 한 번 만들고, 실패 원인을 붙들고 있는 상자.
/// 가속 구조 빌드가 몇 초 걸릴 수 있어 메인 스레드에서 만들면 화면이 멈춘다.
final class RendererStore: ObservableObject {
    @Published private(set) var renderer: Renderer?
    @Published private(set) var failure: String?
    let diagnostics: String

    init(kind: CSGScene.Kind) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            diagnostics = "GPU 없음"
            failure = "MTLCreateSystemDefaultDevice() 실패 — Metal 을 쓸 수 없는 환경입니다."
            return
        }
        diagnostics = RendererStore.describe(device)
        print(diagnostics)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let r = try Renderer(device: device, scene: kind)
                DispatchQueue.main.async { self?.renderer = r }
            } catch {
                print("Renderer 초기화 실패: \(error.localizedDescription)")
                DispatchQueue.main.async { self?.failure = error.localizedDescription }
            }
        }
    }

    private static func describe(_ device: MTLDevice) -> String {
        var lines = ["GPU: \(device.name)"]
        lines.append("raytracing: \(device.supportsRaytracing)")
        lines.append("functionPointers: \(device.supportsFunctionPointers)")
        lines.append("maxThreadsPerThreadgroup: \(device.maxThreadsPerThreadgroup.width)")

        // 지원하는 가장 높은 Apple GPU 패밀리 — A15 = apple8
        let families: [(String, MTLGPUFamily)] = [
            ("apple9", .apple9), ("apple8", .apple8), ("apple7", .apple7),
            ("apple6", .apple6), ("apple5", .apple5),
        ]
        if let top = families.first(where: { device.supportsFamily($0.1) }) {
            lines.append("family: \(top.0)")
        }
        #if os(iOS)
        lines.append("iOS \(UIDevice.current.systemVersion)")
        #endif
        return lines.joined(separator: "\n")
    }
}

// MARK: - 렌더링 화면

/// MetalView + HUD + 저장 버튼.
private struct RenderSurface: View {
    @ObservedObject var renderer: Renderer
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            MetalView(renderer: renderer)
                .ignoresSafeArea(edges: .bottom)

            VStack(alignment: .leading, spacing: 6) {
                if let message { chip(message) }
                chip(renderer.hud)
                chip(Self.gestureHint)
            }
            .padding(12)

            saveButton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(16)
        }
    }

    private static var gestureHint: String {
        #if os(macOS)
        "드래그: 회전 · 스크롤/핀치: 확대 · 더블클릭: 초기화"
        #else
        "드래그: 회전 · 핀치: 확대 · 두 번 탭: 초기화"
        #endif
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var saveButton: some View {
        Button(action: save) {
            Label(saving ? "저장 중…" : "저장", systemImage: "square.and.arrow.down")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.6))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(saving)
    }

    /// 현재 카메라 그대로 고해상도로 다시 렌더링해서 저장한다.
    /// **GPU 를 기다리므로 백그라운드에서** — 화면 해상도의 몇 배라 몇 초 걸릴 수 있다.
    private func save() {
        saving = true
        message = nil
        let size = renderer.suggestedSaveSize()
        DispatchQueue.global(qos: .userInitiated).async {
            guard let image = renderer.makeImage(width: size.width, height: size.height) else {
                DispatchQueue.main.async {
                    saving = false
                    message = "렌더링 실패"
                }
                return
            }
            ImageExport.save(image) { result in
                saving = false
                message = "\(result)  (\(size.width)x\(size.height))"
            }
        }
    }
}
