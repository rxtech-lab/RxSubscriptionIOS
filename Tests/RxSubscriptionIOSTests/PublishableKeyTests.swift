import Foundation
import XCTest
@testable import RxSubscriptionIOS

/// Records what each attempt saw, so a retry can be told apart from a first try.
private actor RequestLog {
    private(set) var authorizations: [String?] = []

    func record(_ value: String?) { authorizations.append(value) }
}

@MainActor
final class PublishableKeyTests: XCTestCase {
    private var log: RequestLog!

    override func setUp() {
        super.setUp()
        log = RequestLog()
    }

    override func tearDown() {
        URLProtocolStub.handler = nil
        log = nil
        super.tearDown()
    }

    private func makeClient(
        userToken: @escaping UserTokenProvider
    ) -> Client {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return Client(
            serverURL: URL(string: "https://subscriptions.example.test")!,
            publishableKey: "rxs_pk_sandbox_test",
            rxlabUserID: "user-42",
            email: "reader@example.test",
            userToken: userToken,
            session: URLSession(configuration: configuration)
        )
    }

    func testSendsPublishableKeyAndUserTokenTogether() async throws {
        let client = makeClient { _ in "access-token-1" }
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "rxs_pk_sandbox_test")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer access-token-1"
            )
            return (200, Self.balancesJSON)
        }

        let balances = try await client.balances()
        XCTAssertEqual(balances.first?.unit, "credits")
    }

    func testRetriesOnceWithAFreshTokenAfter401() async throws {
        let log = log!
        let client = makeClient { forceRefresh in
            forceRefresh ? "access-token-2" : "access-token-1"
        }

        URLProtocolStub.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            Task { await log.record(authorization) }
            if authorization == "Bearer access-token-1" {
                return (401, #"{"error":"invalid_user_token"}"#)
            }
            return (200, Self.balancesJSON)
        }

        let balances = try await client.balances()
        XCTAssertEqual(balances.first?.unit, "credits")

        // Give the detached recording tasks a turn before reading the log.
        try await Task.sleep(nanoseconds: 50_000_000)
        let seen = await log.authorizations
        XCTAssertEqual(seen, ["Bearer access-token-1", "Bearer access-token-2"])
    }

    func testGivesUpAfterOneRetryRatherThanLoopingOnAStaleSession() async throws {
        let log = log!
        let client = makeClient { _ in "always-stale" }

        URLProtocolStub.handler = { request in
            Task { await log.record(request.value(forHTTPHeaderField: "Authorization")) }
            return (401, #"{"error":"invalid_user_token"}"#)
        }

        do {
            _ = try await client.balances()
            XCTFail("expected the second 401 to surface")
        } catch let error as ClientError {
            guard case .server(let status, let payload, _) = error else {
                return XCTFail("expected a server error, got \(error)")
            }
            XCTAssertEqual(status, 401)
            XCTAssertEqual(payload?.error, "invalid_user_token")
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let seen = await log.authorizations
        XCTAssertEqual(seen.count, 2, "one attempt plus exactly one refreshed retry")
    }

    func testReportsAFailedTokenLookupAsSuchRatherThanAsANetworkError() async throws {
        struct SignedOut: Error {}
        let client = makeClient { _ in throw SignedOut() }
        URLProtocolStub.handler = { _ in
            XCTFail("no request should be sent without a token")
            return (200, Self.balancesJSON)
        }

        do {
            _ = try await client.balances()
            XCTFail("expected the token failure to surface")
        } catch let error as ClientError {
            guard case .userTokenUnavailable(let underlying) = error else {
                return XCTFail("expected .userTokenUnavailable, got \(error)")
            }
            XCTAssertTrue(underlying is SignedOut)
        }
    }

    func testSecretKeyClientStillSendsNoAuthorizationHeader() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = Client(
            serverURL: URL(string: "https://subscriptions.example.test")!,
            apiKey: "rxs_sandbox_test",
            rxlabUserID: "user-42",
            session: URLSession(configuration: configuration)
        )
        URLProtocolStub.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "rxs_sandbox_test")
            return (200, Self.balancesJSON)
        }

        _ = try await client.balances()
    }

    func testA401IsNotRetriedForASecretKeyClient() async throws {
        let log = log!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = Client(
            serverURL: URL(string: "https://subscriptions.example.test")!,
            apiKey: "rxs_sandbox_test",
            rxlabUserID: "user-42",
            session: URLSession(configuration: configuration)
        )
        URLProtocolStub.handler = { request in
            Task { await log.record(request.value(forHTTPHeaderField: "X-Api-Key")) }
            return (401, #"{"error":"invalid_api_key"}"#)
        }

        do {
            _ = try await client.balances()
            XCTFail("expected the 401 to surface")
        } catch let error as ClientError {
            guard case .server(let status, _, _) = error else {
                return XCTFail("expected a server error, got \(error)")
            }
            XCTAssertEqual(status, 401)
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let seen = await log.authorizations
        XCTAssertEqual(seen.count, 1, "a bad secret key is not something a refresh can fix")
    }

    /// `recordUsage` accepts 402 as a decodable outcome. That must not be
    /// confused with the 401 path, which is the only status the client retries.
    func testAcceptedStatusCodesAreLeftAlone() async throws {
        let client = makeClient { _ in "access-token-1" }
        URLProtocolStub.handler = { _ in (402, Self.usageDeniedJSON) }

        let result = try await client.recordUsage(item: "generation", idempotencyKey: "k")
        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.reason, "limit_exceeded")
    }

    private static let balancesJSON = """
    {"balances":[{"unit":"credits","name":"Credits","symbol":null,"precision":0,"amount":25,"available":25}]}
    """

    private static let usageDeniedJSON = """
    {"allowed":false,"reason":"limit_exceeded","used":10,"limit":10,"remaining":0,\
    "chargedUnits":0,"periodEnd":null,"duplicate":false}
    """
}
