import Testing

@testable import ProjectStore

@Suite struct ProjectStoreSmoke {
    @Test func moduleCompiles() {
        #expect(true)
    }
}
