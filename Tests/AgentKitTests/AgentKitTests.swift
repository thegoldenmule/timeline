import Testing

@testable import AgentKit

@Suite struct AgentKitSmoke {
    @Test func moduleCompiles() {
        #expect(EditorTools.names.count == 18)
    }
}
