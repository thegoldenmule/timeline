import Contracts
import Foundation
import Testing

@testable import PublishKit

@Suite struct LoopbackListenerTests {
    private func get(_ url: URL) async throws -> (HTTPURLResponse, String) {
        let (data, response) = try await URLSession.shared.data(from: url)
        return (response as! HTTPURLResponse, String(decoding: data, as: UTF8.self))
    }

    private func callback(_ redirect: URL, _ query: String) -> URL {
        URL(string: redirect.absoluteString + "?" + query)!
    }

    @Test func answersOneCallbackAndClosesItsPort() async throws {
        let listener = LoopbackRedirectListener(expectedState: "st-1", timeout: .seconds(10))
        let redirect = try await listener.start()
        #expect(redirect.path() == "/callback")
        let port = try #require(await listener.port)

        // A browser's favicon probe is a 404 that keeps the listener open.
        let favicon = try await get(URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        #expect(favicon.0.statusCode == 404)

        async let code = listener.waitForCode()
        let (response, body) = try await get(callback(redirect, "state=st-1&code=abc"))
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type")?.contains("text/html") == true)
        #expect(body.contains("You can close this window"))
        let received = try await code
        #expect(received == "abc")
        #expect(await listener.port == nil)

        // The port is closed: a second GET is refused.
        await #expect(throws: URLError.self) {
            _ = try await get(URL(string: "http://127.0.0.1:\(port)/callback?state=st-1&code=again")!)
        }
    }

    @Test func rejectsAWrongState() async throws {
        let listener = LoopbackRedirectListener(expectedState: "expected", timeout: .seconds(10))
        let redirect = try await listener.start()
        async let code = listener.waitForCode()
        let (response, _) = try await get(callback(redirect, "state=forged&code=abc"))
        #expect(response.statusCode == 400)
        var caught: AccountError?
        do { _ = try await code } catch { caught = error as? AccountError }
        #expect(caught == .protocolError("state mismatch on the redirect"))
        #expect(await listener.port == nil, "one hit closes the port, right or wrong")
    }

    @Test func reportsAccessDenied() async throws {
        let listener = LoopbackRedirectListener(expectedState: "st-2", timeout: .seconds(10))
        let redirect = try await listener.start()
        async let code = listener.waitForCode()
        let (response, body) = try await get(callback(redirect, "state=st-2&error=access_denied"))
        #expect(response.statusCode == 200 && body.contains("Not connected"))
        var caught: AccountError?
        do { _ = try await code } catch { caught = error as? AccountError }
        #expect(caught == .denied("access_denied"))
    }

    @Test func timesOutAsCancelled() async throws {
        let listener = LoopbackRedirectListener(expectedState: "st-3", timeout: .milliseconds(200))
        _ = try await listener.start()
        let started = ContinuousClock.now
        await #expect(throws: AccountError.cancelled) { _ = try await listener.waitForCode() }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await listener.port == nil)
    }

    @Test func bindsToLoopbackOnly() async throws {
        let listener = LoopbackRedirectListener(expectedState: "st-4", timeout: .seconds(10))
        let redirect = try await listener.start()
        #expect(await listener.boundAddress == "127.0.0.1")
        #expect(redirect.host() == "127.0.0.1")
        #expect(!redirect.absoluteString.contains("0.0.0.0"))
        await listener.stop()
        #expect(await listener.port == nil)
    }
}
