import Testing

@testable import Contracts

@Suite struct ContractsSmoke {
    @Test func moduleCompiles() {
        #expect(true)
    }
}
