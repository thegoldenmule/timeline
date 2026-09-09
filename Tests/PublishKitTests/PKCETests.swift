import Foundation
import Testing

@testable import PublishKit

@Suite struct PKCETests {
    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    @Test func verifierIs43UnreservedCharacters() {
        let pkce = PKCE.make()
        #expect(pkce.verifier.count == 43)
        #expect(pkce.verifier.allSatisfy { Self.unreserved.contains($0) })
        #expect(pkce.challenge.count == 43)
        #expect(pkce.challenge.allSatisfy { Self.unreserved.contains($0) })
        #expect(!pkce.verifier.contains("="))
    }

    @Test func challengeMatchesRFC7636Vector() {
        // RFC 7636 appendix B.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(PKCE(verifier: verifier, state: "s").challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func stateIsUniquePerAttempt() {
        let states = Set((0..<50).map { _ in PKCE.make().state })
        #expect(states.count == 50)
        #expect(states.allSatisfy { $0.count == 22 && $0.allSatisfy { Self.unreserved.contains($0) } })
        let verifiers = Set((0..<50).map { _ in PKCE.make().verifier })
        #expect(verifiers.count == 50)
    }
}
