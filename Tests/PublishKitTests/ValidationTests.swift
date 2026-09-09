import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@testable import PublishKit

@Suite struct ValidationTests {
    private func request(in directory: URL, _ change: (inout PublishRequest) -> Void = { _ in }) throws
        -> PublishRequest
    {
        let file = try randomFile(bytes: 300 * 1024, in: directory)
        var request = Fixtures.publishRequest(renderId: "render-1", fileURL: file)
        change(&request)
        return request
    }

    private func expectInvalid(_ request: PublishRequest, containing fragment: String) {
        do {
            _ = try YouTubeValidation.validate(request)
            Issue.record("expected invalidRequest containing \(fragment)")
        } catch PublishError.invalidRequest(let reason) {
            #expect(reason.contains(fragment), "\(reason)")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func titleLength() throws {
        let directory = try temporaryDirectory("validate")
        expectInvalid(try request(in: directory) { $0.title = "" }, containing: "empty")
        expectInvalid(try request(in: directory) { $0.title = "   " }, containing: "empty")
        expectInvalid(
            try request(in: directory) { $0.title = String(repeating: "x", count: 101) }, containing: "101 characters")
        #expect(
            try YouTubeValidation.validate(try request(in: directory) { $0.title = String(repeating: "é", count: 100) })
                .isEmpty)
    }

    @Test func angleBrackets() throws {
        let directory = try temporaryDirectory("validate")
        expectInvalid(try request(in: directory) { $0.title = "a <b> c" }, containing: "< or >")
        expectInvalid(try request(in: directory) { $0.description = "1 > 0" }, containing: "< or >")
    }

    @Test func descriptionBytes() throws {
        let directory = try temporaryDirectory("validate")
        // 1,667 party poppers are 6,668 bytes but only 1,667 characters.
        let emoji = String(repeating: "🎉", count: 1667)
        #expect(emoji.count < 5000 && emoji.utf8.count > 5000)
        expectInvalid(try request(in: directory) { $0.description = emoji }, containing: "6668 bytes")
        let fits = String(repeating: "🎉", count: 1250)
        #expect(try YouTubeValidation.validate(try request(in: directory) { $0.description = fits }).isEmpty)
    }

    @Test func tagsWithSpacesCountQuotes() throws {
        #expect(YouTubeValidation.tagsLength([]) == 0)
        #expect(YouTubeValidation.tagsLength(["live"]) == 4)
        #expect(YouTubeValidation.tagsLength(["live", "rehearsal"]) == 4 + 1 + 9)
        #expect(YouTubeValidation.tagsLength(["band rehearsal"]) == 14 + 2)
        #expect(YouTubeValidation.tagsLength(["a b", "c"]) == 5 + 1 + 1)
        let directory = try temporaryDirectory("validate")
        // 20 tags of 24 characters plus a space each: 20 * 26 + 19 commas = 539.
        let tags = (0..<20).map { _ in "\(String(repeating: "x", count: 12)) \(String(repeating: "y", count: 11))" }
        #expect(YouTubeValidation.tagsLength(tags) == 539)
        expectInvalid(try request(in: directory) { $0.tags = tags }, containing: "539 characters")
        // 18 tags: 18 * 26 + 17 commas = 485.
        #expect(YouTubeValidation.tagsLength(Array(tags.prefix(18))) == 485)
        #expect(try YouTubeValidation.validate(try request(in: directory) { $0.tags = Array(tags.prefix(18)) }).isEmpty)
    }

    @Test func publishAtRequiresPrivate() throws {
        let directory = try temporaryDirectory("validate")
        let when = Date().addingTimeInterval(3600)
        expectInvalid(
            try request(in: directory) {
                $0.privacy = .unlisted
                $0.publishAt = when
            }, containing: "publishAt requires privacy private")
        expectInvalid(
            try request(in: directory) {
                $0.privacy = .public
                $0.publishAt = when
            }, containing: "public")
        #expect(
            try YouTubeValidation.validate(
                try request(in: directory) {
                    $0.privacy = .private
                    $0.publishAt = when
                }
            ).isEmpty)
        expectInvalid(try request(in: directory) { $0.categoryId = "music" }, containing: "categoryId")
        expectInvalid(
            try request(in: directory) { $0.captions[0].name = String(repeating: "n", count: 151) },
            containing: "151 characters")
        expectInvalid(try request(in: directory) { $0.captions[0].language = " " }, containing: "no language")
    }

    @Test func portraitOverThreeMinutesWarns() throws {
        let directory = try temporaryDirectory("validate")
        let warnings = try YouTubeValidation.validate(
            try request(in: directory) {
                $0.width = 1080
                $0.height = 1920
                $0.durationSeconds = 181
            })
        #expect(
            warnings.count == 1 && warnings[0].contains("longer than 3:00") && warnings[0].contains("not as a Short"))
        #expect(YouTubeValidation.shapeWarnings(width: 1920, height: 1080, durationSeconds: 181).isEmpty)
    }

    @Test func portraitUnderThreeMinutesIsAShortWarning() throws {
        let directory = try temporaryDirectory("validate")
        let portrait = try YouTubeValidation.validate(
            try request(in: directory) {
                $0.width = 1080
                $0.height = 1920
                $0.durationSeconds = 59
            })
        #expect(portrait == ["Square or vertical export up to 3:00: YouTube will classify it as a Short"])
        #expect(YouTubeValidation.shapeWarnings(width: 1080, height: 1080, durationSeconds: 180).count == 1)
        #expect(YouTubeValidation.shapeWarnings(width: 1920, height: 1080, durationSeconds: 59).isEmpty)
        #expect(YouTubeValidation.shapeWarnings(width: nil, height: 1920, durationSeconds: 59).isEmpty)
        #expect(YouTubeValidation.shapeWarnings(width: 1080, height: 1920, durationSeconds: nil).isEmpty)
    }

    @Test func thumbnailOver2MBRejected() throws {
        let directory = try temporaryDirectory("validate")
        let big = try jpegFile(bytes: (2 << 20) + 1, in: directory, name: "big.jpg")
        expectInvalid(
            try request(in: directory) { $0.thumbnail = PublishThumbnail(fileURL: big) }, containing: "2097153 bytes")
        let ok = try jpegFile(bytes: 2 << 20, in: directory, name: "ok.jpg")
        #expect(
            try YouTubeValidation.validate(try request(in: directory) { $0.thumbnail = PublishThumbnail(fileURL: ok) })
                .isEmpty)
        let text = directory.appendingPathComponent("not-an-image.jpg")
        try Data("hello".utf8).write(to: text)
        expectInvalid(
            try request(in: directory) { $0.thumbnail = PublishThumbnail(fileURL: text) }, containing: "JPEG or PNG")
        let missing = directory.appendingPathComponent("missing.png")
        expectInvalid(
            try request(in: directory) { $0.thumbnail = PublishThumbnail(fileURL: missing) }, containing: "missing")
        #expect(YouTubeValidation.thumbnailContentType(of: ok) == "image/jpeg")
        let png = directory.appendingPathComponent("p.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]).write(to: png)
        #expect(YouTubeValidation.thumbnailContentType(of: png) == "image/png")
    }

    @Test func longUploadWarnsAboutVerification() throws {
        let directory = try temporaryDirectory("validate")
        let warnings = try YouTubeValidation.validate(try request(in: directory) { $0.durationSeconds = 901 })
        #expect(warnings.count == 1 && warnings[0].contains("15 minutes") && warnings[0].contains("youtube.com/verify"))
        #expect(try YouTubeValidation.validate(try request(in: directory) { $0.durationSeconds = 900 }).isEmpty)
        // A missing file is the one hard failure that is not an invalidRequest.
        let gone = directory.appendingPathComponent("gone.mp4")
        #expect(throws: PublishError.fileMissing(gone)) {
            _ = try YouTubeValidation.validate(try request(in: directory) { $0.fileURL = gone })
        }
    }
}
