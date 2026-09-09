import ContractsTestSupport
import Testing

@testable import PublishKit

@Suite struct PublishKitSmoke {
    @Test func moduleCompiles() {
        #expect(YouTubePublisher.scopes == Fixtures.publishScopes)
    }
}
