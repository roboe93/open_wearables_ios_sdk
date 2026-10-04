import XCTest
@testable import OpenWearablesHealthSDK

/// Covers the disconnect `signOut` reports to the backend, so a deliberately
/// disconnected user stops looking like a healthy connection whose sync simply stalled.
/// See issue #39.
final class SignOutDisconnectTests: XCTestCase {

    private func disconnectRequests() -> [URLRequest] {
        StubURLProtocol.requests.filter { $0.httpMethod == "DELETE" }
    }

    /// The credential is only readable until `signOut` clears the Keychain, so the
    /// request carrying it is proof that it was built first.
    func testSignOutReportsDisconnectWithTheCredentialItStillHas() {
        withIsolatedSDK { sdk, _ in
            StubURLProtocol.install { _ in .status(204) }

            sdk.signOut()

            XCTAssertTrue(waitUntil { !disconnectRequests().isEmpty })
            let request = disconnectRequests()[0]
            XCTAssertEqual(request.url?.path, "/api/v1/users/test-user/connections/apple")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
            XCTAssertNotNil(
                request.value(forHTTPHeaderField: "X-Request-Id"),
                "the disconnect should be attributable like every other SDK request"
            )
        }
    }

    func testSignOutClearsTheSessionLocally() {
        withIsolatedSDK { sdk, _ in
            StubURLProtocol.install { _ in .status(204) }

            sdk.signOut()

            XCTAssertFalse(sdk.isSessionValid)
        }
    }

    /// Sign out is local truth. A backend that is unreachable, or one that rejects the
    /// call outright, must not leave the user signed in on the device.
    func testSignOutStillCompletesWhenTheDisconnectFails() {
        withIsolatedSDK { sdk, _ in
            StubURLProtocol.install { _ in .failure(URLError(.notConnectedToInternet)) }

            sdk.signOut()

            XCTAssertFalse(sdk.isSessionValid)
            XCTAssertTrue(waitUntil { !disconnectRequests().isEmpty }, "it should still have tried")
        }
    }

    func testSignOutIsUnaffectedByARejectedDisconnect() {
        withIsolatedSDK { sdk, _ in
            StubURLProtocol.install { _ in .status(401) }

            sdk.signOut()

            XCTAssertFalse(sdk.isSessionValid)
        }
    }

    /// Signing out twice, or before signing in, has nothing to report and no credential
    /// to report it with.
    func testSignOutWithoutASessionSendsNothing() {
        withIsolatedSDK { sdk, _ in
            StubURLProtocol.install { _ in .status(204) }
            OpenWearablesHealthSdkKeychain.clearAll()

            sdk.signOut()

            XCTAssertFalse(waitUntil(timeout: 1) { !StubURLProtocol.requests.isEmpty })
        }
    }
}
