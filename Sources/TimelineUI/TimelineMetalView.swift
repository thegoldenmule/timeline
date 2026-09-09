import AppKit
import Contracts
import Metal
import MetalKit
import Observation
import SwiftUI
import TimelineCore

extension EditModifiers {
    public init(_ flags: NSEvent.ModifierFlags) {
        var m: EditModifiers = []
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.shift) { m.insert(.shift) }
        self = m
    }
}

/// The timeline: an `MTKView` that draws a `TimelineScene` on demand (no display link; it redraws
/// when the view model changes or a media fetch lands) and forwards input to the gesture controller.
/// Flipped so y grows downward like the layout.
public final class TimelineMetalView: MTKView {
    public let viewModel: TimelineViewModel
    public let gestures: TimelineGestureController
    public private(set) var renderer: TimelineRenderer?
    public private(set) var mediaCache: TimelineMediaCache?
    public private(set) var lastScene: TimelineScene?
    public private(set) var renderError: (any Error)?
    public private(set) var frameCount = 0
    /// Redraws requested by model changes and media fetches (`needsDisplay` is inert without a window).
    public private(set) var redrawRequests = 0

    public init(viewModel: TimelineViewModel, device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) {
        self.viewModel = viewModel
        self.gestures = TimelineGestureController(viewModel: viewModel)
        super.init(
            frame: NSRect(x: 0, y: 0, width: viewModel.viewSize.width, height: viewModel.viewSize.height),
            device: device)
        colorPixelFormat = TimelineRenderer.pixelFormat
        clearColor = MTLClearColor(
            red: Double(TimelineTheme.background.r), green: Double(TimelineTheme.background.g),
            blue: Double(TimelineTheme.background.b), alpha: 1)
        isPaused = true
        enableSetNeedsDisplay = true
        framebufferOnly = true
        if let device {
            do {
                let r = try TimelineRenderer(device: device)
                let cache = TimelineMediaCache(
                    device: device, thumbnails: viewModel.thumbnails, waveforms: viewModel.waveforms)
                cache.onUpdate = { [weak self] in self?.requestRedraw() }
                r.mediaCache = cache
                renderer = r
                mediaCache = cache
            } catch {
                renderError = error
            }
        }
        observe()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    private func requestRedraw() {
        redrawRequests += 1
        needsDisplay = true
    }

    /// Re-registers observation on every change so any tracked property triggers a redraw.
    private func observe() {
        withObservationTracking {
            viewModel.touchRenderInputs()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.requestRedraw()
                self.observe()
            }
        }
    }

    public override func layout() {
        super.layout()
        if viewModel.viewSize != bounds.size { viewModel.viewSize = bounds.size }
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let renderer, let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
            let cb = renderer.makeCommandBuffer()
        else { return }
        let scene = TimelineSceneBuilder.build(from: viewModel)
        lastScene = scene
        let scale = window?.backingScaleFactor ?? 2
        renderer.encode(scene: scene, scale: scale, renderPass: pass, commandBuffer: cb)
        cb.present(drawable)
        cb.commit()
        frameCount += 1
    }

    /// Renders the current scene offscreen (tests and previews).
    public func renderOffscreen(scale: CGFloat = 1) throws -> RenderedFrame {
        guard let renderer else { throw renderError ?? TimelineRendererError.noDevice }
        let scene = TimelineSceneBuilder.build(from: viewModel)
        lastScene = scene
        return try renderer.render(scene: scene, scale: scale)
    }

    // MARK: Input

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        gestures.mouseDown(at: point(event), modifiers: EditModifiers(event.modifierFlags))
    }

    public override func mouseDragged(with event: NSEvent) {
        gestures.mouseDragged(to: point(event), modifiers: EditModifiers(event.modifierFlags))
    }

    public override func mouseUp(with event: NSEvent) {
        let p = point(event)
        let m = EditModifiers(event.modifierFlags)
        Task { @MainActor in await gestures.mouseUp(at: p, modifiers: m) }
    }

    public override func flagsChanged(with event: NSEvent) {
        gestures.flagsChanged(EditModifiers(event.modifierFlags))
    }

    public override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            if event.scrollingDeltaY > 0 { viewModel.zoomIn(anchorX: point(event).x) }
            if event.scrollingDeltaY < 0 { viewModel.zoomOut(anchorX: point(event).x) }
            return
        }
        let dx = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
        viewModel.scrollSeconds -= Double(dx) * viewModel.secondsPerPoint
    }

    public override func magnify(with event: NSEvent) {
        if event.magnification > 0.1 { viewModel.zoomIn(anchorX: point(event).x) }
        if event.magnification < -0.1 { viewModel.zoomOut(anchorX: point(event).x) }
    }

    public override func keyDown(with event: NSEvent) {
        let m = EditModifiers(event.modifierFlags)
        let key: TimelineKey?
        switch event.keyCode {
        case 51, 117: key = .delete
        case 123: key = .left
        case 124: key = .right
        case 53: key = .escape
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b": key = .split
            case "n": key = .toggleSnapping
            case "z": key = m.contains(.command) ? (m.contains(.shift) ? .redo : .undo) : nil
            case "=", "+": key = .zoomIn
            case "-": key = .zoomOut
            default: key = nil
            }
        }
        guard let key else {
            super.keyDown(with: event)
            return
        }
        Task { @MainActor in await gestures.key(key, modifiers: m) }
    }
}

/// The SwiftUI face of the timeline.
public struct TimelineView: NSViewRepresentable {
    public let viewModel: TimelineViewModel

    public init(viewModel: TimelineViewModel) {
        self.viewModel = viewModel
    }

    public func makeNSView(context: Context) -> TimelineMetalView {
        TimelineMetalView(viewModel: viewModel)
    }

    public func updateNSView(_ view: TimelineMetalView, context: Context) {
        view.needsDisplay = true
    }
}
