import Contracts
import CoreGraphics
import Foundation
import TimelineCore

/// A linear RGBA colour, 0...1 per channel.
public struct SceneColor: Hashable, Sendable {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public init(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public func with(alpha: Float) -> SceneColor { SceneColor(r, g, b, alpha) }

    public func scaled(_ k: Float) -> SceneColor { SceneColor(min(1, r * k), min(1, g * k), min(1, b * k), a) }

    /// The 8-bit value each channel renders to (BGRA8 unorm, no colour management).
    public var bytes: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        (UInt8((r * 255).rounded()), UInt8((g * 255).rounded()), UInt8((b * 255).rounded()), UInt8((a * 255).rounded()))
    }

    /// Hue on the colour wheel (0...1), for link-group stripes.
    public static func hue(_ h: Float, saturation s: Float = 0.7, value v: Float = 0.95) -> SceneColor {
        let hh = (h - floor(h)) * 6
        let i = Int(hh)
        let f = hh - Float(i)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch i % 6 {
        case 0: return SceneColor(v, t, p)
        case 1: return SceneColor(q, v, p)
        case 2: return SceneColor(p, v, t)
        case 3: return SceneColor(p, q, v)
        case 4: return SceneColor(t, p, v)
        default: return SceneColor(v, p, q)
        }
    }
}

/// The timeline's palette. Tests assert on these values.
public enum TimelineTheme {
    public static let background = SceneColor(0.11, 0.11, 0.12)
    public static let ruler = SceneColor(0.16, 0.16, 0.18)
    public static let rulerTick = SceneColor(0.6, 0.6, 0.65)
    public static let header = SceneColor(0.14, 0.14, 0.16)
    public static let rowVideo = SceneColor(0.17, 0.17, 0.19)
    public static let rowAudio = SceneColor(0.15, 0.17, 0.16)
    public static let rowCaption = SceneColor(0.17, 0.15, 0.19)
    public static let clipVideo = SceneColor(0.25, 0.45, 0.75)
    public static let clipAudio = SceneColor(0.22, 0.58, 0.42)
    public static let clipCaption = SceneColor(0.55, 0.40, 0.70)
    public static let clipOffline = SceneColor(0.45, 0.30, 0.30)
    public static let clipInvalid = SceneColor(0.80, 0.30, 0.30)
    public static let waveform = SceneColor(0.85, 0.95, 0.90, 0.9)
    public static let selection = SceneColor(1.0, 0.80, 0.20)
    public static let transition = SceneColor(0.92, 0.92, 0.97)
    public static let playhead = SceneColor(1.0, 0.30, 0.30)
    public static let snapGuide = SceneColor(0.40, 0.90, 1.0)
    public static let text = SceneColor(1, 1, 1)
    public static let dimText = SceneColor(0.75, 0.75, 0.8)
    public static let mutedBadge = SceneColor(0.85, 0.25, 0.25)
    public static let lockedBadge = SceneColor(0.95, 0.60, 0.15)
    /// Blue rather than the conventional yellow: `selection` is already yellow, and red/blue is the pairing
    /// that survives red-green colour blindness.
    public static let soloBadge = SceneColor(0.35, 0.65, 0.95)
    /// The plate of a header button in its off state.
    public static let controlOff = SceneColor(0.24, 0.24, 0.27)
    public static let marker = SceneColor(0.4, 0.7, 1.0)
    /// The row a file drag would land on, and the line at its drop time.
    public static let dropHighlight = SceneColor(0.40, 0.90, 1.0, 0.18)
    public static let dropIndicator = SceneColor(0.40, 0.90, 1.0)
    /// The razor's blade. Pink because every other meaning is taken: red is the playhead, cyan the drop,
    /// yellow the selection, blue solo, orange the lock badge.
    public static let razorIndicator = SceneColor(1.0, 0.35, 0.75)
    /// What the blade fades to when the click under it would cut nothing.
    public static let razorInertAlpha: Float = 0.35

    public static let clipCornerRadius: CGFloat = 4
    public static let controlCornerRadius: CGFloat = 3
    /// Thickness of the ring a button draws instead of a fill when the state was not set on this track.
    public static let controlRingWidth: CGFloat = 1.5
    /// Where a button's capital sits inside its plate; the scene builder has no font metrics, so these are
    /// tuned for a 10pt capital in an 18pt plate.
    public static let controlGlyphInset = CGPoint(x: 5, y: 3)
    public static let controlFontSize: CGFloat = 10
    /// How much a soloed row brightens and a silenced row dims, relative to its kind's colour.
    public static let soloRowBoost: Float = 1.12
    public static let silentRowDim: Float = 0.75
    /// Width of the accent bar down the left edge of a soloed track's lane.
    public static let soloAccentWidth: CGFloat = 2
    public static let labelBandHeight: CGFloat = 16
    public static let labelFontSize: CGFloat = 11
    public static let rulerFontSize: CGFloat = 10
    /// Clips narrower than this draw no label or media.
    public static let minimumLabelWidth: CGFloat = 24
    public static let minimumMediaWidth: CGFloat = 32

    public static func row(_ kind: TrackKind) -> SceneColor {
        switch kind {
        case .video: rowVideo
        case .audio: rowAudio
        case .caption: rowCaption
        }
    }

    public static func clip(_ kind: TrackKind) -> SceneColor {
        switch kind {
        case .video: clipVideo
        case .audio: clipAudio
        case .caption: clipCaption
        }
    }

    public static func linkGroupColor(_ id: LinkGroupID) -> SceneColor {
        var h: UInt32 = 2_166_136_261
        for byte in id.rawValue.utf8 {
            h ^= UInt32(byte)
            h = h &* 16_777_619
        }
        return SceneColor.hue(Float(h % 360) / 360)
    }
}

public struct SceneQuad: Hashable, Sendable {
    public var rect: CGRect
    public var color: SceneColor
    public var cornerRadius: CGFloat

    public init(rect: CGRect, color: SceneColor, cornerRadius: CGFloat = 0) {
        self.rect = rect
        self.color = color
        self.cornerRadius = cornerRadius
    }
}

public struct SceneTriangle: Hashable, Sendable {
    public var a: CGPoint
    public var b: CGPoint
    public var c: CGPoint
    public var color: SceneColor

    public init(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, color: SceneColor) {
        self.a = a
        self.b = b
        self.c = c
        self.color = color
    }
}

public struct SceneLabel: Hashable, Sendable {
    public var text: String
    /// Top-left of the text box.
    public var origin: CGPoint
    public var fontSize: CGFloat
    public var color: SceneColor
    public var maxWidth: CGFloat

    public init(text: String, origin: CGPoint, fontSize: CGFloat, color: SceneColor, maxWidth: CGFloat) {
        self.text = text
        self.origin = origin
        self.fontSize = fontSize
        self.color = color
        self.maxWidth = maxWidth
    }
}

/// Identifies one filmstrip request: what the cache keys textures by.
public struct FilmstripKey: Hashable, Sendable {
    public var media: MediaReference
    public var sourceIn: RationalTime
    public var sourceOut: RationalTime
    public var count: Int
    public var height: Int
}

public struct SceneFilmstrip: Hashable, Sendable {
    /// Where the chunk's frames lay out. Extends past the visible area when the clip is scrolled off.
    public var rect: CGRect
    /// The visible part of the clip; the renderer clips `rect` to it rather than squeezing it.
    public var clipRect: CGRect
    public var key: FilmstripKey
}

public struct WaveformKey: Hashable, Sendable {
    public var media: MediaReference
    public var sourceIn: RationalTime
    public var sourceOut: RationalTime
    public var samplesPerPixel: Int
}

public struct SceneWaveform: Hashable, Sendable {
    /// Where the chunk's columns lay out. Extends past the visible area when the clip is scrolled off.
    public var rect: CGRect
    /// The visible part of the clip; the renderer clips `rect` to it rather than squeezing it.
    public var clipRect: CGRect
    public var key: WaveformKey
    public var color: SceneColor
}

public struct SceneStats: Hashable, Sendable {
    public var clipsDrawn = 0
    public var clipsCulled = 0
    public var transitionsDrawn = 0
    public var labels = 0
    public var filmstrips = 0
    public var waveforms = 0
    public init() {}
}

/// Everything one frame draws, in points, already culled to the visible range. The renderer walks the
/// arrays in order: `quads`, then media, then `triangles` and `overlayQuads`, then `labels`.
public struct TimelineScene: Sendable {
    public var size: CGSize
    public var background: SceneColor
    public var quads: [SceneQuad] = []
    public var filmstrips: [SceneFilmstrip] = []
    public var waveforms: [SceneWaveform] = []
    public var triangles: [SceneTriangle] = []
    public var overlayQuads: [SceneQuad] = []
    public var labels: [SceneLabel] = []
    public var stats = SceneStats()
    /// Screen rects of the drawn clips, for tests and hit tests.
    public var clipRects: [ClipID: CGRect] = [:]
    /// Screen rects of the transition wedges.
    public var transitionRects: [TransitionID: CGRect] = [:]

    public init(size: CGSize, background: SceneColor = TimelineTheme.background) {
        self.size = size
        self.background = background
    }
}

/// Builds a `TimelineScene` from the model. Pure: the same inputs give the same scene.
public enum TimelineSceneBuilder {
    public struct Input: Sendable {
        public var project: Project
        public var sequence: Sequence?
        public var layout: TimelineLayout
        public var selection: Set<ClipID>
        public var playhead: RationalTime
        public var preview: GesturePreview?
        public var pendingClipIds: Set<ClipID>
        public var libraryLayout: LibraryLayout
        public var showMedia: Bool
        /// A file drag in progress: the scene highlights its row and draws a line at its time.
        public var dropTarget: TimelineDropTarget?
        /// The razor hovering: the scene draws a blade at its time, over one row or all of them.
        public var razorTarget: RazorTarget?

        public init(
            project: Project, sequence: Sequence?, layout: TimelineLayout, selection: Set<ClipID>,
            playhead: RationalTime,
            preview: GesturePreview? = nil, pendingClipIds: Set<ClipID> = [], libraryLayout: LibraryLayout = .default,
            showMedia: Bool = true, dropTarget: TimelineDropTarget? = nil, razorTarget: RazorTarget? = nil
        ) {
            self.project = project
            self.sequence = sequence
            self.layout = layout
            self.selection = selection
            self.playhead = playhead
            self.preview = preview
            self.pendingClipIds = pendingClipIds
            self.libraryLayout = libraryLayout
            self.showMedia = showMedia
            self.dropTarget = dropTarget
            self.razorTarget = razorTarget
        }
    }

    @MainActor
    public static func input(from vm: TimelineViewModel, showMedia: Bool = true) -> Input {
        var pendingIds: Set<ClipID> = []
        if let p = vm.pending, let seq = vm.sequence {
            pendingIds = [p.clipId]
            if !p.modifiers.contains(.option), let g = p.original.linkGroupId {
                pendingIds.formUnion(seq.members(of: g).map(\.id))
            }
        }
        return Input(
            project: vm.project, sequence: vm.displaySequence, layout: vm.layout, selection: vm.selection,
            playhead: vm.playhead, preview: vm.preview, pendingClipIds: pendingIds, libraryLayout: vm.libraryLayout,
            showMedia: showMedia && (vm.thumbnails != nil || vm.waveforms != nil), dropTarget: vm.dropTarget,
            razorTarget: vm.razorTarget)
    }

    @MainActor
    public static func build(from vm: TimelineViewModel, showMedia: Bool = true) -> TimelineScene {
        build(input(from: vm, showMedia: showMedia))
    }

    public static func build(_ input: Input) -> TimelineScene {
        let layout = input.layout
        var scene = TimelineScene(size: layout.size)
        let width = layout.size.width
        let height = layout.size.height

        // Chrome: ruler, header, track rows.
        scene.quads.append(
            SceneQuad(rect: CGRect(x: 0, y: 0, width: width, height: layout.rulerHeight), color: TimelineTheme.ruler))
        scene.quads.append(
            SceneQuad(
                rect: CGRect(
                    x: 0, y: layout.rulerHeight, width: layout.headerWidth, height: height - layout.rulerHeight),
                color: TimelineTheme.header))
        guard let seq = input.sequence else {
            scene.labels.append(
                SceneLabel(
                    text: "No sequence", origin: CGPoint(x: layout.headerWidth + 8, y: layout.rulerHeight + 8),
                    fontSize: 12, color: TimelineTheme.dimText, maxWidth: 200))
            addRuler(&scene, layout: layout, frameDuration: RationalTime(1001, 24000))
            return scene
        }
        let trackAreaRect = CGRect(
            x: layout.trackAreaMinX, y: layout.rulerHeight, width: layout.trackAreaWidth,
            height: height - layout.rulerHeight)

        for row in layout.rows where row.maxY > layout.rulerHeight && row.y < height {
            guard let track = seq.track(row.trackId) else { continue }
            // One rule, asked once: the lane, the clips, and the header all read the same answer.
            let silence = seq.silence(of: track)
            var rowColor = TimelineTheme.row(track.kind)
            if track.solo { rowColor = rowColor.scaled(TimelineTheme.soloRowBoost) }
            if silence != nil { rowColor = rowColor.scaled(TimelineTheme.silentRowDim) }
            if track.locked { rowColor = rowColor.scaled(0.8) }
            scene.quads.append(
                SceneQuad(
                    rect: CGRect(x: layout.trackAreaMinX, y: row.y, width: layout.trackAreaWidth, height: row.height),
                    color: rowColor))
            if track.solo {
                // Over the clips, not under them, so the soloed lane is findable however full it is.
                scene.overlayQuads.append(
                    SceneQuad(
                        rect: CGRect(
                            x: layout.trackAreaMinX, y: row.y, width: TimelineTheme.soloAccentWidth,
                            height: row.height), color: TimelineTheme.soloBadge))
            }
            addTrackHeader(&scene, track: track, row: row, layout: layout, silence: silence)
            addClips(&scene, track: track, row: row, seq: seq, input: input, clip: trackAreaRect, silence: silence)
        }
        addTransitions(&scene, seq: seq, layout: layout, clip: trackAreaRect)
        addMarkers(&scene, seq: seq, layout: layout)
        addRuler(&scene, layout: layout, frameDuration: seq.frameDuration)
        if let snap = input.preview?.snappedTo {
            let x = layout.x(for: snap)
            if x >= layout.trackAreaMinX && x <= width {
                scene.overlayQuads.append(
                    SceneQuad(
                        rect: CGRect(x: x - 0.5, y: layout.rulerHeight, width: 1, height: height - layout.rulerHeight),
                        color: TimelineTheme.snapGuide))
            }
        }
        addPlayhead(&scene, at: input.playhead, layout: layout)
        if let drop = input.dropTarget { addDropIndicator(&scene, drop: drop, layout: layout) }
        if let razor = input.razorTarget { addRazorIndicator(&scene, razor: razor, layout: layout) }
        if let message = input.preview?.message {
            scene.labels.append(
                SceneLabel(
                    text: message, origin: CGPoint(x: layout.headerWidth + 8, y: height - 18), fontSize: 11,
                    color: TimelineTheme.clipInvalid, maxWidth: width - layout.headerWidth - 16))
        }
        scene.stats.labels = scene.labels.count
        return scene
    }

    // MARK: Pieces

    private static func addTrackHeader(
        _ scene: inout TimelineScene, track: Track, row: TrackRow, layout: TimelineLayout, silence: TrackSilence?
    ) {
        scene.quads.append(
            SceneQuad(
                rect: CGRect(x: 0, y: row.y, width: layout.headerWidth, height: row.height),
                color: TimelineTheme.header.scaled(track.locked ? 0.85 : 1.05)))
        let name = layout.nameRect(in: row)
        scene.labels.append(
            SceneLabel(
                text: track.name, origin: name.origin, fontSize: 11,
                color: silence == nil ? TimelineTheme.text : TimelineTheme.dimText, maxWidth: name.width))
        for (control, rect) in layout.controls(in: row) {
            addTrackControl(&scene, control, rect: rect, track: track, silence: silence)
        }
    }

    /// One header button: a rounded plate and a centred capital. A *filled* plate is a state this track was
    /// put in; a *ring* is a state something else caused. That is how "you muted this" and "another track is
    /// soloed" stay tellable apart while both meaning silence.
    private static func addTrackControl(
        _ scene: inout TimelineScene, _ control: TrackControl, rect: CGRect, track: Track, silence: TrackSilence?
    ) {
        var fill = TimelineTheme.controlOff
        var glyph = TimelineTheme.dimText
        var ring: SceneColor?
        switch control {
        case .mute:
            if track.muted {
                fill = TimelineTheme.mutedBadge
                glyph = TimelineTheme.text
            } else if silence == .solo {
                ring = TimelineTheme.mutedBadge
                glyph = TimelineTheme.mutedBadge
            }
        case .solo:
            if track.solo {
                fill = TimelineTheme.soloBadge
                glyph = SceneColor(0, 0, 0)
            }
        case .lock:
            if track.locked {
                fill = TimelineTheme.lockedBadge
                glyph = SceneColor(0, 0, 0)
            }
        case .remove:
            // `decide` rejects removing a locked track, so the button shows itself inert instead of sending
            // a command that would only come back as an error.
            if track.locked {
                fill = fill.with(alpha: 0.4)
                glyph = glyph.with(alpha: 0.4)
            }
        }
        if let ring {
            scene.overlayQuads.append(
                SceneQuad(rect: rect, color: ring, cornerRadius: TimelineTheme.controlCornerRadius))
            let inset = TimelineTheme.controlRingWidth
            scene.overlayQuads.append(
                SceneQuad(
                    rect: rect.insetBy(dx: inset, dy: inset), color: fill,
                    cornerRadius: TimelineTheme.controlCornerRadius - 1))
        } else {
            scene.overlayQuads.append(
                SceneQuad(rect: rect, color: fill, cornerRadius: TimelineTheme.controlCornerRadius))
        }
        scene.labels.append(
            SceneLabel(
                text: control.glyph,
                origin: CGPoint(
                    x: rect.minX + TimelineTheme.controlGlyphInset.x, y: rect.minY + TimelineTheme.controlGlyphInset.y),
                fontSize: TimelineTheme.controlFontSize, color: glyph, maxWidth: rect.width))
    }

    private static func addClips(
        _ scene: inout TimelineScene, track: Track, row: TrackRow, seq: Sequence, input: Input, clip area: CGRect,
        silence: TrackSilence?
    ) {
        let layout = input.layout
        let visibleStart = layout.visibleStartSeconds
        let visibleEnd = layout.visibleEndSeconds
        let frameDuration = track.kind.isFrameAligned ? seq.frameDuration : nil
        for clip in track.clips.values {
            let start = clip.start.seconds
            let end = (clip.start + clip.duration(frameDuration: frameDuration)).seconds
            guard end >= visibleStart && start <= visibleEnd else {
                scene.stats.clipsCulled += 1
                continue
            }
            let fullRect = layout.rect(startSeconds: start, endSeconds: end, row: row)
            // Clamp huge rects to the view so the GPU never rasterises kilometres of quad.
            let minX = max(fullRect.minX, area.minX - 4)
            let maxX = min(fullRect.maxX, area.maxX + 4)
            let rect = CGRect(x: minX, y: fullRect.minY, width: max(1, maxX - minX), height: fullRect.height)
            scene.stats.clipsDrawn += 1
            scene.clipRects[clip.id] = rect

            let asset = clip.assetId.flatMap { input.project.assets[$0] }
            var color = TimelineTheme.clip(track.kind)
            if asset?.offline == true { color = TimelineTheme.clipOffline }
            if input.pendingClipIds.contains(clip.id) {
                color = input.preview?.isValid == false ? TimelineTheme.clipInvalid : color.scaled(1.15)
            }
            if silence != nil { color = color.scaled(0.7) }
            scene.quads.append(SceneQuad(rect: rect, color: color, cornerRadius: TimelineTheme.clipCornerRadius))

            if let group = clip.linkGroupId {
                scene.overlayQuads.append(
                    SceneQuad(
                        rect: CGRect(x: rect.minX + 2, y: rect.maxY - 4, width: rect.width - 4, height: 3),
                        color: TimelineTheme.linkGroupColor(group), cornerRadius: 1))
            }

            if input.showMedia, fullRect.width >= TimelineTheme.minimumMediaWidth, let asset,
                let assetId = clip.assetId, input.project.assets[assetId] != nil
            {
                let media = MediaReference(asset: asset, layout: input.libraryLayout)
                if track.kind == .video && asset.hasVideo && row.height >= 40 {
                    let band = CGRect(
                        x: fullRect.minX + 1, y: fullRect.minY + TimelineTheme.labelBandHeight,
                        width: fullRect.width - 2, height: fullRect.height - TimelineTheme.labelBandHeight - 6)
                    let thumbHeight = Int(band.height)
                    let thumbWidth = max(1, CGFloat(thumbHeight) * 16 / 9)
                    addMediaChunks(
                        clip: clip, startSeconds: start, endSeconds: end, band: band, area: area, layout: layout,
                        tileWidth: thumbWidth, tilesPerChunk: filmstripTilesPerChunk
                    ) { chunk, rect, bounds, sourceIn, sourceOut in
                        scene.filmstrips.append(
                            SceneFilmstrip(
                                rect: rect, clipRect: bounds,
                                key: FilmstripKey(
                                    media: media, sourceIn: sourceIn, sourceOut: sourceOut, count: chunk.tileCount,
                                    height: thumbHeight)))
                        scene.stats.filmstrips += 1
                    }
                } else if track.kind == .audio && asset.hasAudio {
                    let band = CGRect(
                        x: fullRect.minX + 1, y: fullRect.minY + 4, width: fullRect.width - 2,
                        height: fullRect.height - 10)
                    let sampleRate = asset.sampleRate ?? 48000
                    let spp = max(1, Int(layout.mediaSecondsPerPoint * Double(sampleRate)))
                    addMediaChunks(
                        clip: clip, startSeconds: start, endSeconds: end, band: band, area: area, layout: layout,
                        tileWidth: waveformChunkWidth, tilesPerChunk: 1
                    ) { _, rect, bounds, sourceIn, sourceOut in
                        scene.waveforms.append(
                            SceneWaveform(
                                rect: rect, clipRect: bounds,
                                key: WaveformKey(
                                    media: media, sourceIn: sourceIn, sourceOut: sourceOut, samplesPerPixel: spp),
                                color: TimelineTheme.waveform))
                        scene.stats.waveforms += 1
                    }
                }
            }

            if rect.width >= TimelineTheme.minimumLabelWidth {
                let text = clip.label ?? clip.text ?? asset?.displayName ?? "Clip"
                scene.labels.append(
                    SceneLabel(
                        text: text, origin: CGPoint(x: rect.minX + 6, y: rect.minY + 2),
                        fontSize: TimelineTheme.labelFontSize, color: TimelineTheme.text, maxWidth: rect.width - 12))
            }

            if input.selection.contains(clip.id) {
                let c = TimelineTheme.selection
                let w: CGFloat = 2
                scene.overlayQuads.append(
                    SceneQuad(rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: w), color: c))
                scene.overlayQuads.append(
                    SceneQuad(rect: CGRect(x: rect.minX, y: rect.maxY - w, width: rect.width, height: w), color: c))
                scene.overlayQuads.append(
                    SceneQuad(rect: CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height), color: c))
                scene.overlayQuads.append(
                    SceneQuad(rect: CGRect(x: rect.maxX - w, y: rect.minY, width: w, height: rect.height), color: c))
            }
        }
    }

    /// One aligned chunk of a clip's media: which tiles it covers and the span of the clip it draws over.
    private struct MediaChunk {
        var tileStart: Int
        var tileCount: Int
        var startSeconds: Double
        var endSeconds: Double
    }

    /// Filmstrip chunk size in thumbnails, and waveform chunk width in points. Large enough that a
    /// screenful is a handful of requests, small enough that a chunk scrolling into view is cheap.
    private static let filmstripTilesPerChunk = 8
    private static let waveformChunkWidth: CGFloat = 512

    /// Splits the visible part of a clip into chunks of `tilesPerChunk` tiles, each `tileWidth` points
    /// wide. Tiles are aligned to the clip's start, so panning brings one new chunk in at the leading edge
    /// and leaves the rest keyed — and drawn — where they were, instead of restretching a single request
    /// spanning the whole clip into whatever part of it happens to be on screen.
    ///
    /// Tiles are sized from `layout.mediaSecondsPerPoint`, not the live zoom: zoom is continuous, every
    /// distinct key is a decode, and a pinch that minted a fresh key per event would never hit the cache.
    /// Between two quantized rungs a tile is drawn slightly wider or narrower than the frame it holds.
    private static func mediaChunks(
        startSeconds: Double, endSeconds: Double, layout: TimelineLayout, tileWidth: CGFloat, tilesPerChunk: Int
    ) -> [MediaChunk] {
        let tileSeconds = Double(tileWidth) * layout.mediaSecondsPerPoint
        guard tileSeconds > 0, endSeconds > startSeconds, tilesPerChunk > 0 else { return [] }
        let totalTiles = max(1, Int(((endSeconds - startSeconds) / tileSeconds).rounded(.up)))
        let first = max(0, Int(((layout.visibleStartSeconds - startSeconds) / tileSeconds).rounded(.down)))
        let last = min(totalTiles, Int(((layout.visibleEndSeconds - startSeconds) / tileSeconds).rounded(.up)))
        guard first < last else { return [] }
        var chunks: [MediaChunk] = []
        var tile = (first / tilesPerChunk) * tilesPerChunk
        while tile < last {
            let count = min(tilesPerChunk, totalTiles - tile)
            chunks.append(
                MediaChunk(
                    tileStart: tile, tileCount: count,
                    startSeconds: startSeconds + Double(tile) * tileSeconds,
                    endSeconds: min(endSeconds, startSeconds + Double(tile + count) * tileSeconds)))
            tile += tilesPerChunk
        }
        return chunks
    }

    /// Calls `body` for each visible media chunk of `clip` with its rect, the bounds the renderer clips it
    /// to, and the source range it covers. `band` is the media area of the whole clip, unclamped.
    private static func addMediaChunks(
        clip: Clip, startSeconds: Double, endSeconds: Double, band: CGRect, area: CGRect, layout: TimelineLayout,
        tileWidth: CGFloat, tilesPerChunk: Int,
        body: (MediaChunk, CGRect, CGRect, RationalTime, RationalTime) -> Void
    ) {
        let bounds = band.intersection(area)
        guard !bounds.isNull, bounds.width >= 1, bounds.height >= 1 else { return }
        let sourcePerTile = Double(tileWidth) * layout.mediaSecondsPerPoint * clip.speed.doubleValue
        let scale = TimelineLayout.pointerTimescale
        for chunk in mediaChunks(
            startSeconds: startSeconds, endSeconds: endSeconds, layout: layout, tileWidth: tileWidth,
            tilesPerChunk: tilesPerChunk)
        {
            let x0 = layout.x(forSeconds: chunk.startSeconds)
            let x1 = layout.x(forSeconds: chunk.endSeconds)
            let rect = CGRect(x: x0, y: band.minY, width: max(1, x1 - x0), height: band.height)
            guard rect.intersects(bounds) else { continue }
            let offset = RationalTime(seconds: Double(chunk.tileStart) * sourcePerTile, timescale: scale)
            let sourceIn = chunk.tileStart == 0 ? clip.sourceIn : clip.sourceIn + offset
            let end =
                clip.sourceIn
                + RationalTime(
                    seconds: Double(chunk.tileStart + chunk.tileCount) * sourcePerTile,
                    timescale: scale)
            let sourceOut = min(clip.sourceOut, end)
            guard sourceIn < sourceOut else { continue }
            body(chunk, rect, bounds, sourceIn, sourceOut)
        }
    }

    /// A transition is drawn as an overlap wedge centred on the cut: a light band of the transition's
    /// duration with a diagonal from the left clip's colour to the right clip's.
    private static func addTransitions(
        _ scene: inout TimelineScene, seq: Sequence, layout: TimelineLayout, clip area: CGRect
    ) {
        for t in seq.transitions.values {
            guard let left = seq.clip(t.leftClipId), let row = layout.row(for: t.trackId) else { continue }
            let cut = seq.end(of: left)
            let handles = t.handles
            let x0 = layout.x(for: cut - handles.left)
            let x1 = layout.x(for: cut + handles.right)
            guard x1 >= area.minX && x0 <= area.maxX, x1 - x0 >= 2 else { continue }
            let rect = CGRect(x: x0, y: row.y + 1, width: x1 - x0, height: row.height - 2)
            scene.transitionRects[t.id] = rect
            scene.stats.transitionsDrawn += 1
            let kind = seq.track(t.trackId)?.kind ?? .video
            let clipColor = TimelineTheme.clip(kind)
            scene.triangles.append(
                SceneTriangle(
                    CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.minX, y: rect.maxY), color: TimelineTheme.transition))
            scene.triangles.append(
                SceneTriangle(
                    CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY),
                    CGPoint(x: rect.minX, y: rect.maxY), color: clipColor.scaled(0.55)))
            scene.overlayQuads.append(
                SceneQuad(
                    rect: CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height),
                    color: TimelineTheme.transition))
            scene.overlayQuads.append(
                SceneQuad(
                    rect: CGRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height),
                    color: TimelineTheme.transition))
        }
    }

    private static func addMarkers(_ scene: inout TimelineScene, seq: Sequence, layout: TimelineLayout) {
        for m in seq.markers.values {
            let x = layout.x(for: m.at)
            guard x >= layout.trackAreaMinX && x <= layout.size.width else { continue }
            scene.overlayQuads.append(
                SceneQuad(
                    rect: CGRect(x: x - 4, y: layout.rulerHeight - 8, width: 8, height: 8), color: TimelineTheme.marker,
                    cornerRadius: 2))
        }
    }

    private static func addRuler(_ scene: inout TimelineScene, layout: TimelineLayout, frameDuration: RationalTime) {
        let major = layout.majorTickSeconds()
        let minor = major / 4
        let start = floor(layout.visibleStartSeconds / minor) * minor
        var t = max(0, start)
        var guardCount = 0
        while t <= layout.visibleEndSeconds && guardCount < 4000 {
            guardCount += 1
            let x = layout.x(forSeconds: t)
            let isMajor = abs(t / major - (t / major).rounded()) < 1e-6
            let tickHeight: CGFloat = isMajor ? 10 : 5
            if x >= layout.trackAreaMinX {
                scene.overlayQuads.append(
                    SceneQuad(
                        rect: CGRect(x: x, y: layout.rulerHeight - tickHeight, width: 1, height: tickHeight),
                        color: TimelineTheme.rulerTick))
                if isMajor {
                    scene.labels.append(
                        SceneLabel(
                            text: Timecode.label(seconds: t, interval: major, frameDuration: frameDuration),
                            origin: CGPoint(x: x + 3, y: 3), fontSize: TimelineTheme.rulerFontSize,
                            color: TimelineTheme.dimText, maxWidth: 80))
                }
            }
            t += minor
        }
    }

    /// A file drag over the view: the target row tinted, a playhead-style line at the drop time, and the
    /// snap guide when the time snapped.
    private static func addDropIndicator(_ scene: inout TimelineScene, drop: TimelineDropTarget, layout: TimelineLayout)
    {
        if let trackId = drop.trackId, let row = layout.row(for: trackId) {
            scene.overlayQuads.append(
                SceneQuad(
                    rect: CGRect(x: layout.trackAreaMinX, y: row.y, width: layout.trackAreaWidth, height: row.height),
                    color: TimelineTheme.dropHighlight))
        }
        let x = layout.x(for: drop.at)
        guard x >= layout.trackAreaMinX - 1 && x <= layout.size.width + 1 else { return }
        if drop.snappedTo != nil {
            scene.overlayQuads.append(
                SceneQuad(
                    rect: CGRect(
                        x: x - 3, y: layout.rulerHeight, width: 6, height: layout.size.height - layout.rulerHeight),
                    color: TimelineTheme.snapGuide.with(alpha: 0.25)))
        }
        scene.overlayQuads.append(
            SceneQuad(
                rect: CGRect(
                    x: x - 1, y: layout.rulerHeight, width: 2, height: layout.size.height - layout.rulerHeight),
                color: TimelineTheme.dropIndicator))
        scene.triangles.append(
            SceneTriangle(
                CGPoint(x: x - 6, y: layout.rulerHeight), CGPoint(x: x + 6, y: layout.rulerHeight),
                CGPoint(x: x, y: layout.rulerHeight + 8), color: TimelineTheme.dropIndicator))
    }

    /// The razor hovering: a blade at the cut time, over the hovered row alone or the whole track area
    /// when Shift would cut every track, plus the snap band when the time snapped. A target that would
    /// cut nothing draws dimmed and drops the triangle, so an inert click looks inert before you make it.
    private static func addRazorIndicator(
        _ scene: inout TimelineScene, razor: RazorTarget, layout: TimelineLayout
    ) {
        let x = layout.x(for: razor.at)
        guard x >= layout.trackAreaMinX - 1 && x <= layout.size.width + 1 else { return }
        let top: CGFloat
        let height: CGFloat
        if !razor.allTracks, let trackId = razor.trackId, let row = layout.row(for: trackId) {
            top = row.y
            height = row.height
        } else {
            top = layout.rulerHeight
            height = layout.size.height - layout.rulerHeight
        }
        let alpha: Float = razor.isCuttable ? 1 : TimelineTheme.razorInertAlpha
        if razor.snappedTo != nil {
            scene.overlayQuads.append(
                SceneQuad(
                    rect: CGRect(
                        x: x - 3, y: layout.rulerHeight, width: 6, height: layout.size.height - layout.rulerHeight),
                    color: TimelineTheme.snapGuide.with(alpha: 0.25 * alpha)))
        }
        scene.overlayQuads.append(
            SceneQuad(
                rect: CGRect(x: x - 1, y: top, width: 2, height: height),
                color: TimelineTheme.razorIndicator.with(alpha: alpha)))
        guard razor.isCuttable else { return }
        scene.triangles.append(
            SceneTriangle(
                CGPoint(x: x - 6, y: top), CGPoint(x: x + 6, y: top), CGPoint(x: x, y: top + 8),
                color: TimelineTheme.razorIndicator))
    }

    private static func addPlayhead(_ scene: inout TimelineScene, at time: RationalTime, layout: TimelineLayout) {
        let x = layout.x(for: time)
        guard x >= layout.trackAreaMinX - 1 && x <= layout.size.width + 1 else { return }
        scene.overlayQuads.append(
            SceneQuad(rect: CGRect(x: x - 1, y: 0, width: 2, height: layout.size.height), color: TimelineTheme.playhead)
        )
        scene.triangles.append(
            SceneTriangle(
                CGPoint(x: x - 6, y: 0), CGPoint(x: x + 6, y: 0), CGPoint(x: x, y: 8), color: TimelineTheme.playhead))
    }
}
