import Testing

@testable import MediaKit

@Suite struct MediaKitSmoke {
    @Test func moduleCompiles() {
        #expect(true)
    }
}
