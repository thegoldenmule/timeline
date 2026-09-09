import Contracts
import Foundation
import Testing
import TimelineCore

@testable import PublishKit

@Suite struct QuotaMeterTests {
    /// 2026-09-09 23:30 Pacific (PDT, UTC-7) = 2026-09-10 06:30 UTC.
    private let lateEvening = Date(timeIntervalSince1970: 1_789_021_800)

    @Test func countsUploadsAndUnitsPerPacificDay() async throws {
        let directory = try temporaryDirectory("quota")
        let file = QuotaMeter.fileURL(cacheDir: directory)
        let clock = FixedClock(lateEvening)
        let meter = QuotaMeter(fileURL: file, clock: clock)
        await meter.recordUpload()
        await meter.record(units: 1)
        await meter.record(units: 400)
        let snapshot = await meter.snapshot()
        #expect(snapshot.uploadsUsed == 1 && snapshot.unitsUsed == 401)
        #expect(snapshot.uploadsLimit == 100 && snapshot.unitsLimit == 10_000)
        #expect(snapshot.uploadsRemaining == 99 && snapshot.unitsRemaining == 9599)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(file.lastPathComponent == "publish-quota.json")
        // The file is keyed by the Pacific day and survives a new meter.
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(json["day"] as? String == "2026-09-09")
        let reopened = QuotaMeter(fileURL: file, clock: clock)
        #expect(await reopened.snapshot().uploadsUsed == 1)
        #expect(await reopened.snapshot().unitsUsed == 401)
        #expect(QuotaMeter.dayKey(for: lateEvening) == "2026-09-09")
        #expect(QuotaMeter.dayKey(for: lateEvening.addingTimeInterval(1800)) == "2026-09-10")
    }

    @Test func resetsAtMidnightPacific() async throws {
        let clock = FixedClock(lateEvening)
        let meter = QuotaMeter(fileURL: nil, clock: clock)
        await meter.recordUpload()
        let snapshot = await meter.snapshot()
        // Midnight Pacific is 07:00 UTC on 2026-09-10 (PDT).
        #expect(snapshot.resetsAt == Date(timeIntervalSince1970: 1_789_023_600))
        #expect(QuotaMeter.resetsAt(after: lateEvening).timeIntervalSince(lateEvening) == 1800)
        // Thirty-one minutes later it is a new Pacific day: the count is back to zero.
        let later = QuotaMeter(fileURL: nil, clock: FixedClock(lateEvening.addingTimeInterval(1860)))
        #expect(await later.snapshot().uploadsUsed == 0)
        let directory = try temporaryDirectory("quota-reset")
        let file = QuotaMeter.fileURL(cacheDir: directory)
        let today = QuotaMeter(fileURL: file, clock: clock)
        await today.recordUpload()
        let tomorrow = QuotaMeter(fileURL: file, clock: FixedClock(lateEvening.addingTimeInterval(1860)))
        #expect(await tomorrow.snapshot().uploadsUsed == 0)
        #expect(await tomorrow.snapshot().resetsAt == Date(timeIntervalSince1970: 1_789_023_600 + 86_400))
        // A winter date resets at 08:00 UTC (PST).
        let winter = Date(timeIntervalSince1970: 1_798_761_600)  // 2027-01-01 00:00 UTC = 2026-12-31 16:00 PST
        #expect(QuotaMeter.resetsAt(after: winter) == Date(timeIntervalSince1970: 1_798_761_600 + 8 * 3600))
    }

    @Test func refusesTheHundredAndFirstUpload() async {
        let meter = QuotaMeter(fileURL: nil, clock: FixedClock(lateEvening))
        for _ in 0..<99 { await meter.recordUpload() }
        #expect(await meter.canUpload())
        #expect(await meter.snapshot().uploadsRemaining == 1)
        await meter.recordUpload()
        #expect(await !meter.canUpload())
        #expect(await meter.snapshot().uploadsRemaining == 0)
        #expect(await meter.snapshot().uploadsUsed == 100)
    }

    @Test func quotaExceededMarksTheDayExhausted() async throws {
        let directory = try temporaryDirectory("quota-exhausted")
        let file = QuotaMeter.fileURL(cacheDir: directory)
        let clock = FixedClock(lateEvening)
        let meter = QuotaMeter(fileURL: file, clock: clock)
        await meter.recordUpload()
        await meter.markExhausted()
        let snapshot = await meter.snapshot()
        #expect(snapshot.uploadsRemaining == 0 && snapshot.unitsRemaining == 0)
        #expect(await !meter.canUpload())
        // Persisted, and gone with the next Pacific day.
        #expect(await !QuotaMeter(fileURL: file, clock: clock).canUpload())
        #expect(await QuotaMeter(fileURL: file, clock: FixedClock(lateEvening.addingTimeInterval(3600))).canUpload())
        await meter.reset()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await meter.canUpload())
    }

    @Test func survivesAMissingFile() async throws {
        let directory = try temporaryDirectory("quota-missing")
        let file = directory.appendingPathComponent("nowhere/publish-quota.json")
        let meter = QuotaMeter(fileURL: file, clock: FixedClock(lateEvening))
        #expect(await meter.snapshot().uploadsUsed == 0)
        #expect(await meter.canUpload())
        await meter.record(units: 50)
        #expect(FileManager.default.fileExists(atPath: file.path))
        // Garbage in the file reads as an empty day.
        try Data("not json".utf8).write(to: file)
        let corrupt = QuotaMeter(fileURL: file, clock: FixedClock(lateEvening))
        #expect(await corrupt.snapshot().unitsUsed == 0)
        // No file at all keeps the count in memory.
        let memory = QuotaMeter(fileURL: nil, clock: FixedClock(lateEvening))
        await memory.record(units: 7)
        #expect(await memory.snapshot().unitsUsed == 7)
    }
}
