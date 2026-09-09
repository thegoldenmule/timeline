import CryptoKit
import Foundation

/// RFC 7636 proof key plus the OAuth `state` value, one per authorization attempt
/// (docs/research/10-google-account-auth.md, "Exact HTTP sequence", step 0).
public struct PKCE: Sendable, Hashable {
    /// base64url of 32 random bytes: 43 unreserved characters.
    public let verifier: String
    /// base64url(SHA-256(verifier)), method `S256`.
    public let challenge: String
    /// base64url of 16 random bytes.
    public let state: String

    public init(verifier: String, state: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
        self.state = state
    }

    public static func make() -> PKCE {
        PKCE(verifier: Base64URL.encode(randomBytes(32)), state: Base64URL.encode(randomBytes(16)))
    }

    /// The `S256` challenge of a verifier.
    public static func challenge(for verifier: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }
}
