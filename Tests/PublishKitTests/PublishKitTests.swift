import Testing

@testable import PublishKit

@Suite struct PublishKitSmoke {
    @Test func moduleCompiles() {
        #expect(true)
    }
}
