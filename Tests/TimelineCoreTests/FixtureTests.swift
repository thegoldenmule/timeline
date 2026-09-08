import Foundation
import Testing
import TimelineCore

@Suite struct FixtureTests {
    static let writeDirectory = ProcessInfo.processInfo.environment["TIMELINE_WRITE_FIXTURES"]

    func write(_ data: Data, to relativePath: String) throws {
        guard let dir = Self.writeDirectory else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    @Test(arguments: ProjectFixtures.names)
    func fixtureMatchesBuilder(name: String) throws {
        let builder = try ProjectFixtures.builder(for: name)
        try Invariants.check(builder.project)
        let projectData = try ProjectCodec.prettyEncoder.encode(builder.project)
        let eventsData = try ProjectCodec.prettyEncoder.encode(builder.events)
        try write(projectData, to: "\(name).json")
        try write(eventsData, to: "\(name).events.json")

        let loaded = try ProjectFixtures.load(name, from: Bundle.module)
        #expect(loaded == builder.project, "\(name).json is stale; regenerate with TIMELINE_WRITE_FIXTURES")
        #expect(try Data(contentsOf: try ProjectFixtures.url(name, in: Bundle.module)) == projectData)
        let events = try ProjectFixtures.loadEvents(name, from: Bundle.module)
        #expect(events == builder.events)
        #expect(evolve(Project.blank, events) == loaded)
        #expect(try loaded.canonicalJSON() == builder.project.canonicalJSON())
    }

    @Test func linkedFixtureHasTheRequiredShape() throws {
        let p = try ProjectFixtures.load("linked-transition-caption-undone", from: Bundle.module)
        let seq = try #require(p.sequences.values.first)
        let groups = Set(seq.tracks.flatMap { $0.clips.values.compactMap(\.linkGroupId) })
        #expect(groups.count == 2)
        for g in groups {
            let members = seq.members(of: g)
            #expect(members.count == 2)
            #expect(Set(members.map { seq.track($0.trackId)?.kind }) == [.video, .audio])
        }
        #expect(seq.transitions.count == 1)
        #expect(seq.tracks.contains { $0.kind == .caption && $0.clips.count == 2 })
        #expect(seq.markers.count == 1)
        let events = try ProjectFixtures.loadEvents("linked-transition-caption-undone", from: Bundle.module)
        let history = History.fold(events: events)
        #expect(history.transactions.last?.kind == .undo)
        #expect(history.undone.count == 1)
        #expect(history.redoTarget != nil)
        #expect(history.transactions.last?.target == history.redoTarget?.id)
        let transitionsSurvive =
            events.contains { if case .transitionRemoved = $0.payload { true } else { false } } == false
        #expect(transitionsSurvive)
    }

    @Test func threeClipsFixture() throws {
        let p = try ProjectFixtures.load("three-clips", from: Bundle.module)
        let seq = try #require(p.sequences.values.first)
        #expect(seq.tracks.first { $0.kind == .video }?.clips.count == 3)
        #expect(seq.tracks.first { $0.kind == .audio }?.clips.count == 1)
        #expect(p.assets.count == 3)
        let empty = try ProjectFixtures.load("empty", from: Bundle.module)
        #expect(empty.assets.isEmpty && empty.sequences.values.first?.tracks.count == 2)
    }

    @Test func eventExamplesMatchFiles() throws {
        let examples = ProjectFixtures.exampleEvents()
        for (type, event) in examples {
            try write(try ProjectCodec.prettyEncoder.encode(event), to: "events/\(type).json")
        }
        for (type, event) in examples.sorted(by: { $0.key < $1.key }) {
            let data = try ProjectCodec.prettyEncoder.encode(event)
            let loaded = try ProjectFixtures.loadEventExample(type, from: Bundle.module)
            #expect(loaded == event, "events/\(type).json is stale")
            #expect(
                try Data(contentsOf: try ProjectFixtures.url(type, subdirectory: "Fixtures/events", in: Bundle.module))
                    == data)
        }
        // Every file in the directory is a known type.
        let dir = try ProjectFixtures.url("ClipAdded", subdirectory: "Fixtures/events", in: Bundle.module)
            .deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }
        #expect(Set(files.map { String($0.dropLast(5)) }) == Set(EventPayload.allTypeNames))
    }
}
