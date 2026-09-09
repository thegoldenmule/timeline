import Contracts
import Foundation
import TimelineCore

/// A local count of the Google Cloud project's daily allowance (publish-plan.md D11): uploads (100
/// `videos.insert` calls) and units (10,000) per Pacific day, kept in `<cacheDir>/publish-quota.json`
/// (disposable: a lost file only under-counts). `markExhausted` answers a `403 quotaExceeded`.
public actor QuotaMeter {
    public static let fileName = "publish-quota.json"
    public static let timeZone = TimeZone(identifier: "America/Los_Angeles")!

    struct Day: Codable, Sendable, Hashable {
        var day: String
        var uploadsUsed: Int
        var unitsUsed: Int
        var exhausted: Bool
    }

    public let fileURL: URL?
    public let uploadsLimit: Int
    public let unitsLimit: Int
    private let clock: any Clock
    private var state: Day?

    /// - Parameter fileURL: nil keeps the count in memory only.
    public init(fileURL: URL?, clock: any Clock = SystemClock(), uploadsLimit: Int = 100, unitsLimit: Int = 10_000) {
        self.fileURL = fileURL
        self.clock = clock
        self.uploadsLimit = uploadsLimit
        self.unitsLimit = unitsLimit
    }

    /// `<cacheDir>/publish-quota.json`.
    public static func fileURL(cacheDir: URL) -> URL { cacheDir.appendingPathComponent(fileName) }

    // MARK: Reading

    public func snapshot() -> PublishQuota {
        let now = clock.now()
        let day = current(now)
        return PublishQuota(
            uploadsUsed: day.exhausted ? max(day.uploadsUsed, uploadsLimit) : day.uploadsUsed,
            uploadsLimit: uploadsLimit,
            unitsUsed: day.exhausted ? max(day.unitsUsed, unitsLimit) : day.unitsUsed, unitsLimit: unitsLimit,
            resetsAt: Self.resetsAt(after: now))
    }

    /// True while the day has an upload left and is not marked exhausted.
    public func canUpload() -> Bool { snapshot().uploadsRemaining > 0 }

    /// The next midnight in `America/Los_Angeles` after `date`.
    public static func resetsAt(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
    }

    /// `YYYY-MM-DD` of the Pacific day containing `date`.
    public static func dayKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: Writing

    /// One `videos.insert` call (failed uploads count too).
    public func recordUpload() {
        var day = current(clock.now())
        day.uploadsUsed += 1
        persist(day)
    }

    public func record(units: Int) {
        guard units > 0 else { return }
        var day = current(clock.now())
        day.unitsUsed += units
        persist(day)
    }

    /// A `403 quotaExceeded` from Google: the day is spent whatever the local count says.
    public func markExhausted() {
        var day = current(clock.now())
        day.exhausted = true
        persist(day)
    }

    /// Forgets the count and deletes the file (disconnect cleanup, publish-plan.md D13).
    public func reset() {
        state = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    // MARK: State

    private func current(_ now: Date) -> Day {
        let key = Self.dayKey(for: now)
        if state == nil { state = load() }
        if let state, state.day == key { return state }
        let fresh = Day(day: key, uploadsUsed: 0, unitsUsed: 0, exhausted: false)
        state = fresh
        return fresh
    }

    private func load() -> Day? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? ProjectCodec.decode(Day.self, from: data)
    }

    private func persist(_ day: Day) {
        state = day
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ProjectCodec.encode(day).write(to: fileURL, options: [.atomic])
        } catch {
            // The file is a disposable cache: an unwritable one only under-counts.
        }
    }
}
