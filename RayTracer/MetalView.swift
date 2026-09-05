//
//  MetalView.swift
//  iOS(UIViewRepresentable) / macOS(NSViewRepresentable) 공용 MTKView 래퍼.
//
//  카메라는 **수동 조작**이다. 자동 회전이 아니라 드래그·핀치로 움직이므로
//  화면이 멈춰 있을 때 60fps 로 계속 그릴 이유가 없다 —
//  `isPaused` + `enableSetNeedsDisplay` 로 **요청이 있을 때만** 렌더링한다.
//  레이 트레이서라 프레임당 비용이 커서 배터리·발열 차이가 크다.
//

import SwiftUI
import MetalKit

/// drawable 해상도를 `renderScale` 배로 줄이고, 궤도 카메라 제스처를 받는 MTKView.
/// autoResizeDrawable 을 끄고 레이아웃 시점마다 직접 계산하므로 두 플랫폼에서 동일하게 동작한다.
final class ScaledMTKView: MTKView {
    /// 카메라 상태를 들고 있는 렌더러 (delegate 와 같은 객체)
    weak var camera: Renderer?

    var renderScale: CGFloat = 0.6 {
        didSet { if renderScale != oldValue { updateDrawableSize() } }
    }

    // MARK: - 레이아웃

    #if os(macOS)
    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    /// 리사이즈가 끝나면 낮췄던 해상도를 원래대로 되돌린다
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        updateDrawableSize()
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }
    #endif

    // 요청 시 렌더링이라 **첫 프레임을 놓치면 영원히 빈 화면**이다. 창에 붙는 시점에도 한 번 요청한다.
    #if os(macOS)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestRedraw()
    }
    #else
    override func didMoveToWindow() {
        super.didMoveToWindow()
        requestRedraw()
    }
    #endif

    private var backingScale: CGFloat {
        #if os(macOS)
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        #else
        window?.screen.scale ?? UIScreen.main.scale
        #endif
    }

    /// 리사이즈 중에는 해상도를 더 낮춰 드래그가 끊기지 않게 한다 (놓으면 원래대로).
    private var effectiveRenderScale: CGFloat {
        #if os(macOS)
        inLiveResize ? min(renderScale, 0.35) : renderScale
        #else
        renderScale
        #endif
    }

    private func updateDrawableSize() {
        let scale = backingScale * effectiveRenderScale
        let w = (bounds.width * scale).rounded()
        let h = (bounds.height * scale).rounded()
        guard w >= 1, h >= 1 else { return }
        let size = CGSize(width: w, height: h)
        guard drawableSize != size else { return }
        drawableSize = size

        // **크기가 바뀌면 요청만 걸지 말고 즉시 한 프레임 그린다.**
        // 요청 시 렌더링(isPaused)이라 리사이즈 중에는 새 프레임이 안 나오는데,
        // CAMetalLayer 는 직전 프레임 텍스처를 새 창 크기에 **늘여서** 보여 준다.
        // 그래서 창을 끄는 동안 버스 비율이 틀어져 보이다가 나중에 제자리로 돌아온다.
        draw()
    }

    /// 요청 시 렌더링이라 카메라나 크기가 바뀔 때마다 명시적으로 다시 그려 줘야 한다.
    func requestRedraw() {
        #if os(macOS)
        needsDisplay = true
        #else
        setNeedsDisplay()
        #endif
    }

    // MARK: - 제스처 (공통 처리)

    /// dx > 0 = 오른쪽으로 끌기, dy > 0 = 아래로 끌기
    fileprivate func handleDrag(dx: CGFloat, dy: CGFloat) {
        beginInteraction()
        camera?.orbit(dx: Float(dx), dy: Float(dy))
        requestRedraw()
    }

    fileprivate func handleZoom(factor: CGFloat) {
        beginInteraction()
        camera?.zoom(by: Float(factor))
        requestRedraw()
    }

    /// 제스처 동안은 빠른 품질로. 마지막 입력 후 0.25 초 지나면 풀 품질로 한 번 더 그린다.
    /// (스크롤 휠은 '끝' 이벤트가 없어서 타이머로 판정한다)
    private var interactionEnd: DispatchWorkItem?
    private func beginInteraction() {
        camera?.interacting = true
        interactionEnd?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.endInteraction() }
        interactionEnd = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }
    private func endInteraction() {
        interactionEnd?.cancel()
        interactionEnd = nil
        guard camera?.interacting == true else { return }
        camera?.interacting = false
        requestRedraw()
    }

    fileprivate func handleReset() {
        camera?.resetCamera()
        requestRedraw()
    }

    // MARK: - macOS 입력

    #if os(macOS)
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { handleReset() }
    }

    override func mouseDragged(with event: NSEvent) {
        // AppKit 의 deltaY 는 아래로 끌 때 양수라 iOS 의 translation.y 와 부호가 같다
        handleDrag(dx: event.deltaX, dy: event.deltaY)
    }

    override func mouseUp(with event: NSEvent) { endInteraction() }

    override func scrollWheel(with event: NSEvent) {
        handleZoom(factor: 1 + event.scrollingDeltaY * 0.012)
    }

    override func magnify(with event: NSEvent) {          // 트랙패드 핀치
        handleZoom(factor: 1 + event.magnification)
    }
    #endif

    // MARK: - iOS 입력

    #if !os(macOS)
    func installGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        pan.maximumNumberOfTouches = 1                    // 두 손가락은 핀치에 양보
        for g in [pan, pinch, doubleTap] as [UIGestureRecognizer] { addGestureRecognizer(g) }
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)                 // 매번 델타로 받는다
        handleDrag(dx: t.x, dy: t.y)
        if g.state == .ended || g.state == .cancelled { endInteraction() }
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        handleZoom(factor: g.scale)
        g.scale = 1
        if g.state == .ended || g.state == .cancelled { endInteraction() }
    }

    @objc private func onDoubleTap() { handleReset() }
    #endif
}

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

struct MetalView: PlatformViewRepresentable {
    /// Renderer 는 ContentView 가 만들어서 넘긴다 — 초기화 실패를 화면에 띄워야 하기 때문.
    let renderer: Renderer
    /// 1.0 = 네이티브 해상도. 반사·굴절 바운스가 늘어난 만큼 기본값을 낮춰 둔다.
    var renderScale: CGFloat = 0.6

    func makeCoordinator() -> Renderer { renderer }

    private func makeMTKView(context: Context) -> ScaledMTKView {
        let view = ScaledMTKView()
        view.device = renderer.device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false          // 컴퓨트 커널이 drawable 에 직접 쓰기 위해
        view.autoResizeDrawable = false
        view.isPaused = true                  // 요청 시에만 렌더링
        view.enableSetNeedsDisplay = true
        view.renderScale = renderScale
        view.delegate = renderer
        view.camera = renderer
        // 한 프레임도 present 되지 않으면 이 색이 보인다 — 흰 화면(= 아무것도 안 그림)과 구분하기 위해
        #if os(macOS)
        view.wantsLayer = true
        view.layer?.backgroundColor = CGColor(red: 0.05, green: 0.02, blue: 0.10, alpha: 1)
        #else
        view.backgroundColor = UIColor(red: 0.05, green: 0.02, blue: 0.10, alpha: 1)
        view.installGestures()
        #endif
        return view
    }

    #if os(macOS)
    func makeNSView(context: Context) -> ScaledMTKView { makeMTKView(context: context) }
    func updateNSView(_ view: ScaledMTKView, context: Context) { view.renderScale = renderScale }
    #else
    func makeUIView(context: Context) -> ScaledMTKView { makeMTKView(context: context) }
    func updateUIView(_ view: ScaledMTKView, context: Context) { view.renderScale = renderScale }
    #endif
}
