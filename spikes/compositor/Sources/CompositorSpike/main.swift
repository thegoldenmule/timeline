import AVFoundation

setvbuf(stdout, nil, _IOLBF, 0)

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let tmp = root.appendingPathComponent("tmp", isDirectory: true)
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

print("== Generating media ==")
let red = tmp.appendingPathComponent("red.mov"), green = tmp.appendingPathComponent("green.mov"), blue = tmp.appendingPathComponent("blue.mov")
let tGen = ContinuousClock.now
try Media.makeClip(url: red, color: (1, 0, 0), toneHz: 440, seconds: 4)
try Media.makeClip(url: green, color: (0, 1, 0), toneHz: 880, seconds: 4)
try Media.makeClip(url: blue, color: (0, 0, 1), toneHz: 1320, seconds: 4)
print("  3 clips written in \(ms(tGen))")

// Timeline: red 0-4s; green 3-7s with 1s crossfade; blue PiP 4.5-6.5s (scale 0.4, top-right, 80% opacity); caption 1.0-2.5s.
let timeline = Timeline(clips: [
    Clip(url: red, timelineStart: .s(0), sourceIn: .s(0), sourceOut: .s(4)),
    Clip(url: green, timelineStart: .s(3), sourceIn: .s(0), sourceOut: .s(4), crossfadeFromPrevious: .s(1)),
    Clip(url: blue, timelineStart: .s(4.5), sourceIn: .s(1), sourceOut: .s(3),
         transform: Transform(scale: 0.4, center: CGPoint(x: 984, y: 224), opacity: 0.8)),
], caption: Caption(text: "Hello, compositor!", start: .s(1), end: .s(2.5)))

let compiled = try await compile(timeline)
print("\n== Compiled ==\n  duration \(compiled.composition.duration.seconds)s, \(compiled.videoComposition.instructions.count) instructions:")
for i in compiled.videoComposition.instructions as! [SpikeInstruction] {
    print("   \(String(format: "%5.2f-%5.2f", i.timeRange.start.seconds, i.timeRange.end.seconds)) base=\(i.base) xfTo=\(i.crossfadeTo.map(String.init) ?? "-") pip=\(i.pip.map { String($0.trackID) } ?? "-") caption=\(i.caption != nil) tracks=\(i.requiredSourceTrackIDs!)")
}
print("  10-bit/HDR attribute dict compiles: \(SpikeCompositor.tenBit)")

try await runImageGeneratorChecks(asset: compiled.composition, vc: compiled.videoComposition, label: "Composition")
// Diagnostic: what color does the raw green clip decode to (no composition)? Explains the (0,231,40) reading above.
let rawGen = AVAssetImageGenerator(asset: AVURLAsset(url: green))
let rawGreen = try await rawGen.image(at: CMTime(value: 1, timescale: 1))
let rawGreenMean = Pixels(rawGreen.image).mean(Region.center)
let rawGreenSpace: String = rawGreen.image.colorSpace.flatMap { $0.name }.map { $0 as String } ?? "nil"
print("\n== Diagnostic: raw green.mov @1s center mean = \(rawGreenMean); CGImage colorSpace = \(rawGreenSpace)")
let exported = try await runExport(compiled, to: tmp.appendingPathComponent("export.mov"), preset: AVAssetExportPreset1280x720)
try await runImageGeneratorChecks(asset: exported, vc: nil, label: "Exported file (no videoComposition)")
_ = try await runExport(compiled, to: tmp.appendingPathComponent("export-hevc.mov"), preset: AVAssetExportPresetHEVCHighestQuality)
try await runPlayerChecks(compiled)

print("\n== Compositor instrumentation ==")
print("  total startRequest calls: \(SpikeCompositor.frameCount); renderContextChanged calls: \(SpikeCompositor.renderContextChanges)")
print("  startRequest ran on queues: \(SpikeCompositor.queueLabels.sorted())")
print("\n\(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")")
exit(failures == 0 ? 0 : 1)
