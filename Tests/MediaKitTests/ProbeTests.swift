import ContractsTestSupport
import CoreGraphics
import Foundation
import Synchronization
import Testing
import TimelineCore

@testable import MediaKit

@Suite struct ProbeTests {
    static let iphoneClip = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Downloads/IMG_1575.MOV")

    @Test func syntheticClipProbe() async throws {
        let dir = try TestMedia.Directory()
        let clip = try await TestMedia.videoWithAudio(
            .tone(frequency: 440), duration: 1, videoCodec: .hevc, channels: 2, in: dir.url, name: "probe")
        let inspection = try await MediaProbe.inspect(clip.url)
        #expect(inspection.kind == .video)
        #expect(inspection.hasVideo && inspection.hasAudio)
        #expect(inspection.probe.codec == "hvc1")
        #expect(inspection.probe.width == 1280 && inspection.probe.height == 720)
        #expect(inspection.probe.fps == Rational(30, 1))
        #expect(inspection.frameDuration == RationalTime(1, 30))
        #expect(inspection.probe.rotation == 0)
        #expect(inspection.duration.seconds == 1)
        #expect(inspection.audioTracks.count == 1)
        #expect(inspection.audioTracks[0].isPrimary)
        #expect(inspection.audioTracks[0].channels == 2)
        #expect(inspection.audioTracks[0].codec == "aac")
        #expect(inspection.sampleRate == 48000)
        #expect(inspection.probe.extra["hdr"] == .bool(false))
        #expect(inspection.probe.extra["fileSize"]?.numberValue ?? 0 > 0)
        #expect(inspection.probe.colorPrimaries == "bt709")
    }

    @Test func hlgClipProbe() async throws {
        let dir = try TestMedia.Directory()
        let clip = try await TestMedia.solidColor(.green, duration: 0.5, codec: .hevcHLG10, in: dir.url, name: "hlg")
        let probe = try await MediaProbe.inspect(clip.url).probe
        #expect(probe.transfer == "arib-std-b67")
        #expect(probe.colorPrimaries == "bt2020")
        #expect(probe.extra["hdr"] == .bool(true))
        #expect(probe.extra["hdrFormat"] == .string("hlg"))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: ProbeTests.iphoneClip.path)))
    func iphonePortraitHLGProbe() async throws {
        let started = ContinuousClock.now
        let inspection = try await MediaProbe.inspect(ProbeTests.iphoneClip)
        print("IMG_1575.MOV probe in \(String(format: "%.3f", elapsed(started))) s: \(inspection.probe)")
        let probe = inspection.probe
        #expect(probe.rotation == -90, "portrait: preferred transform (0, 1, -1, 0)")
        #expect(probe.transfer == "arib-std-b67", "HLG")
        #expect(probe.colorPrimaries == "bt2020")
        #expect(probe.extra["hdr"] == .bool(true))
        #expect(probe.extra["hdrFormat"] == .string("hlg"))
        #expect(probe.codec == "hvc1")
        #expect(probe.width == 3840 && probe.height == 2160)
        #expect(probe.capturedAt != nil)
        #expect(probe.extra["make"] == .string("Apple"))
        #expect(probe.extra["model"]?.stringValue?.hasPrefix("iPhone") == true)
        #expect(probe.extra["gps"]?["lat"]?.numberValue != nil)
        #expect(inspection.audioTracks.count == 2)
        let primary = try #require(inspection.audioTracks.first { $0.isPrimary })
        #expect(primary.codec == "aac")
        #expect(primary.channels == 2)
        let spatial = try #require(inspection.audioTracks.first(where: { !$0.isPrimary }))
        #expect(spatial.codec == "apac")
        #expect(spatial.channels == 4)
        #expect(probe.extra["primaryAudioTrackID"]?.numberValue == Double(primary.trackID))
        #expect(inspection.sampleRate == 48000)
        #expect(inspection.frameDuration == RationalTime(9, 600))
    }

    @Test func rotationConvention() {
        #expect(MediaProbe.rotationDegrees(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)) == -90)
        #expect(MediaProbe.rotationDegrees(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)) == 90)
        #expect(MediaProbe.rotationDegrees(.identity) == 0)
        #expect(MediaProbe.rotationDegrees(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)) == 180)
    }

    @Test func iso6709Parsing() {
        let gps = MediaProbe.parseISO6709("+38.5959-090.3353+151.361/")
        #expect(gps?.lat == 38.5959)
        #expect(gps?.lon == -90.3353)
        #expect(gps?.altitude == 151.361)
        #expect(MediaProbe.parseISO6709("+48.8566+002.3522/")?.altitude == nil)
        #expect(MediaProbe.parseISO6709("garbage") == nil)
    }

    @Test func stillProbe() async throws {
        let dir = try TestMedia.Directory()
        let still = try TestMedia.still(.red, size: CGSize(width: 320, height: 200), in: dir.url, name: "red")
        let inspection = try await MediaProbe.inspect(still.url)
        #expect(inspection.kind == .image)
        #expect(inspection.probe.width == 320 && inspection.probe.height == 200)
        #expect(inspection.probe.codec == "png")
    }

    @Test func contentHashMatchesReference() async throws {
        let dir = try TestMedia.Directory()
        let url = dir.file("bytes.bin")
        let data = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try data.write(to: url)
        let streamed = try await ContentHash.sha256(of: url)
        #expect(streamed == ContentHash.sha256(of: data))
        let reported = Mutex<[Int64]>([])
        _ = try await ContentHash.sha256(of: url) { done in reported.withLock { $0.append(done) } }
        #expect(reported.withLock { $0.last } == 100_000)
    }
}
